import Darwin
import Foundation
import os

// MARK: - Protocol

/// Dynamic rule expansion (design §5.5).
///
/// Semantic contract:
/// - **"Target does not exist" returns an empty array** (Xcode not installed, version dir missing)—not a failure.
/// - **Real failures `throw`**: subprocess timeout, malformed output. The caller (ScanEngine) turns throws into
///   a `dynamicRuleFailed` limitation + reserved prefix and continues scanning; dynamic rules must never block the whole scan.
/// - On failure **do not return partial results**: skip the whole block (with the target's `reservedRootPaths` for ancestor protection)
///   rather than hand half-expanded candidates off as a complete result.
protocol DiskCleanDynamicRuleProviding: Sendable {
    func expand() async throws -> [DiskCleanFileItem]
}

enum DiskCleanDynamicRuleError: Error, Equatable {
    /// Subprocess output is not the expected structure (malformed JSON, missing fields, truncated).
    case malformedOutput(command: String)
    /// Directory is visible but cannot be listed (permissions, etc.).
    case directoryUnreadable(path: String)
}

// MARK: - Subprocess execution seam

struct DiskCleanSubprocessResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: Data
}

enum DiskCleanSubprocessError: Error, Equatable {
    /// Executable missing or not executable (e.g. command-line tools not installed).
    case executableUnavailable(path: String)
    case launchFailed(path: String, message: String)
    case timedOut(path: String)
}

/// Subprocess execution seam. Tests inject fakes to cover success/malformed/timeout/missing-command cases.
protocol DiskCleanSubprocessRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> DiskCleanSubprocessResult
}

/// Real implementation: every command runs in a dedicated process group. Timeout and
/// cancellation terminate the whole group, then escalate to SIGKILL so descendants that
/// inherited stdout cannot keep the pipe open indefinitely.
struct LocalDiskCleanSubprocessRunner: DiskCleanSubprocessRunning {
    /// Output cap. Stop reading past it so JSON parsing fails as `malformedOutput` instead of unbounded memory use.
    static let maximumOutputBytes = 8 * 1024 * 1024

    private let onOutputDrained: @Sendable () -> Void
    private let waitForLeaderExitWithoutReaping: @Sendable (pid_t) -> Bool

    init(
        onOutputDrained: @escaping @Sendable () -> Void = {},
        waitForLeaderExitWithoutReaping: (@Sendable (pid_t) -> Bool)? = nil
    ) {
        self.onOutputDrained = onOutputDrained
        self.waitForLeaderExitWithoutReaping = waitForLeaderExitWithoutReaping
            ?? Self.waitForLeaderExitWithoutReaping(processID:)
    }

    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> DiskCleanSubprocessResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw DiskCleanSubprocessError.executableUnavailable(path: executablePath)
        }

        let launch: LaunchResult
        do {
            launch = try Self.spawn(executablePath: executablePath, arguments: arguments)
        } catch {
            throw DiskCleanSubprocessError.launchFailed(
                path: executablePath,
                message: error.localizedDescription
            )
        }

        let lifecycle = DiskCleanSubprocessLifecycle()
        let processGroup = DiskCleanProcessGroupBox(
            processID: launch.processID,
            lifecycle: lifecycle
        )
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            processGroup.requestTimeout()
        }

        // A blocked read(2) and waitid(2) ignore Swift task cancellation. Keep the
        // cancellation handler installed until the leader is reaped and group signal
        // ownership is released.
        let (output, status, leaderExitWasObserved) = await withTaskCancellationHandler {
            async let leaderExitObservation: Bool = Self.observeExitWithoutReaping(
                processID: launch.processID,
                lifecycle: lifecycle,
                processGroup: processGroup,
                waitForExit: waitForLeaderExitWithoutReaping
            )
            let output = await Self.drain(
                fileDescriptor: launch.outputDescriptor,
                lifecycle: lifecycle
            )
            onOutputDrained()
            let leaderExitWasObserved = await leaderExitObservation
            await processGroup.finishAndTerminateRemainingDescendants()
            let status = Self.waitForExit(processID: launch.processID)
            processGroup.releaseOwnership()
            timeoutTask.cancel()
            close(launch.outputDescriptor)
            return (output, status, leaderExitWasObserved)
        } onCancel: {
            processGroup.requestCancellation()
        }

        guard leaderExitWasObserved else {
            throw DiskCleanSubprocessError.launchFailed(
                path: executablePath,
                message: "Unable to observe subprocess exit safely."
            )
        }

        switch lifecycle.outcome {
        case .timedOut:
            throw DiskCleanSubprocessError.timedOut(path: executablePath)
        case .cancelled:
            throw CancellationError()
        case .completed:
            return DiskCleanSubprocessResult(
                exitCode: Self.exitCode(from: status),
                standardOutput: output
            )
        case .running:
            assertionFailure("Subprocess lifecycle did not reach a terminal outcome")
            throw DiskCleanSubprocessError.launchFailed(
                path: executablePath,
                message: "Subprocess lifecycle did not complete."
            )
        }
    }

    private static func drain(
        fileDescriptor: Int32,
        lifecycle: DiskCleanSubprocessLifecycle
    ) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var output = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes {
                        read(fileDescriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        let remainingCapacity = max(0, maximumOutputBytes + 1 - output.count)
                        if remainingCapacity > 0 {
                            output.append(contentsOf: buffer[0..<min(count, remainingCapacity)])
                        }
                        continue
                    }
                    if count < 0 && errno == EINTR {
                        continue
                    }
                    break
                }
                lifecycle.recordDrainFinished()
                continuation.resume(returning: output)
            }
        }
    }

    private static func observeExitWithoutReaping(
        processID: pid_t,
        lifecycle: DiskCleanSubprocessLifecycle,
        processGroup: DiskCleanProcessGroupBox,
        waitForExit: @escaping @Sendable (pid_t) -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let observed = waitForExit(processID)
                if observed {
                    lifecycle.recordLeaderExited()
                } else {
                    processGroup.revokeGroupSignalOwnership()
                }
                continuation.resume(returning: observed)
            }
        }
    }

    private static func waitForLeaderExitWithoutReaping(processID: pid_t) -> Bool {
        var information = siginfo_t()
        var result: Int32
        repeat {
            result = waitid(P_PID, id_t(processID), &information, WEXITED | WNOWAIT)
        } while result < 0 && errno == EINTR
        return result == 0
    }

    private struct LaunchResult {
        let processID: pid_t
        let outputDescriptor: Int32
    }

    private static func spawn(executablePath: String, arguments: [String]) throws -> LaunchResult {
        var outputPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { throw POSIXError(.EIO) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            close(outputPipe[0])
            close(outputPipe[1])
            throw POSIXError(.EIO)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        guard posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe[1]) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            close(outputPipe[0])
            close(outputPipe[1])
            throw POSIXError(.EIO)
        }

        var processID: pid_t = 0
        let spawnArguments = [executablePath] + arguments
        let environmentEntries = ProcessInfo.processInfo.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let spawnResult = withDiskCleanCStringArray(spawnArguments) { argv in
            withDiskCleanCStringArray(environmentEntries) { environment in
                posix_spawn(
                    &processID,
                    executablePath,
                    &actions,
                    &attributes,
                    argv,
                    environment
                )
            }
        }
        guard spawnResult == 0 else {
            close(outputPipe[0])
            close(outputPipe[1])
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO)
        }
        close(outputPipe[1])
        return LaunchResult(processID: processID, outputDescriptor: outputPipe[0])
    }

    private static func waitForExit(processID: pid_t) -> Int32 {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(processID, &status, 0)
        } while result < 0 && errno == EINTR
        return result == processID ? status : 1 << 8
    }

    private static func exitCode(from status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

}

/// Arbitrates natural completion, timeout, and cancellation under one lock. Natural
/// completion requires both leader exit and pipe EOF because descendants can inherit
/// stdout after the leader exits.
final class DiskCleanSubprocessLifecycle: @unchecked Sendable {
    enum Outcome: Equatable, Sendable {
        case running
        case completed
        case timedOut
        case cancelled
    }

    private struct State: Sendable {
        var leaderExited = false
        var drainFinished = false
        var outcome: Outcome = .running
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var outcome: Outcome {
        state.withLock { $0.outcome }
    }

    func recordLeaderExited() {
        state.withLock { state in
            state.leaderExited = true
            completeIfReady(&state)
        }
    }

    func recordDrainFinished() {
        state.withLock { state in
            state.drainFinished = true
            completeIfReady(&state)
        }
    }

    func claimTimeout() -> Bool {
        claim(.timedOut)
    }

    func claimCancellation() -> Bool {
        claim(.cancelled)
    }

    private func claim(_ outcome: Outcome) -> Bool {
        state.withLock { state in
            completeIfReady(&state)
            guard state.outcome == .running else { return false }
            state.outcome = outcome
            return true
        }
    }

    private func completeIfReady(_ state: inout State) {
        guard state.outcome == .running,
              state.leaderExited,
              state.drainFinished else {
            return
        }
        state.outcome = .completed
    }
}

/// Owns process-group escalation until the leader is reaped. Holding the leader as a
/// zombie reserves its PID/PGID, so no TERM or KILL can target a reused process group.
final class DiskCleanProcessGroupBox: @unchecked Sendable {
    typealias SignalGroup = @Sendable (_ processID: pid_t, _ signal: Int32) -> Void
    typealias WaitForGrace = @Sendable () async -> Void

    private struct State: Sendable {
        var escalationTask: Task<Void, Never>?
        var ownsGroupSignals = true
        var ownershipReleased = false
    }

    private let processID: pid_t
    private let lifecycle: DiskCleanSubprocessLifecycle
    private let signalGroup: SignalGroup
    private let waitForGrace: WaitForGrace
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        processID: pid_t,
        lifecycle: DiskCleanSubprocessLifecycle,
        signalGroup: @escaping SignalGroup = { processID, signal in
            _ = Darwin.kill(-processID, signal)
        },
        waitForGrace: @escaping WaitForGrace = {
            try? await Task.sleep(for: .milliseconds(250))
        }
    ) {
        self.processID = processID
        self.lifecycle = lifecycle
        self.signalGroup = signalGroup
        self.waitForGrace = waitForGrace
    }

    func requestTimeout() {
        guard lifecycle.claimTimeout() else { return }
        _ = escalationTask()
    }

    func requestCancellation() {
        guard lifecycle.claimCancellation() else { return }
        _ = escalationTask()
    }

    func finishAndTerminateRemainingDescendants() async {
        await escalationTask().value
    }

    func revokeGroupSignalOwnership() {
        state.withLock { state in
            state.ownsGroupSignals = false
        }
    }

    func releaseOwnership() {
        state.withLock { state in
            precondition(state.escalationTask != nil)
            state.ownsGroupSignals = false
            state.ownershipReleased = true
        }
    }

    private func escalationTask() -> Task<Void, Never> {
        state.withLock { state in
            if let escalationTask = state.escalationTask {
                return escalationTask
            }
            precondition(!state.ownershipReleased)
            let waitForGrace = self.waitForGrace
            let escalationTask = Task.detached(priority: .utility) { [weak self] in
                self?.signalIfOwned(SIGTERM)
                await waitForGrace()
                self?.signalIfOwned(SIGKILL)
            }
            state.escalationTask = escalationTask
            return escalationTask
        }
    }

    private func signalIfOwned(_ signal: Int32) {
        state.withLock { state in
            guard state.ownsGroupSignals, !state.ownershipReleased else { return }
            signalGroup(processID, signal)
        }
    }
}

private func withDiskCleanCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.compactMap { $0 }.forEach { free($0) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}

// MARK: - Version number

/// Version directory name. Only accepts names that start with a digit, are `.`-segmented, and each segment starts with a digit,
/// so `Current`, `ch-0`, `crx_cache`, and `prefs.json` are never treated as versions.
struct DiskCleanVersionNumber: Comparable, Equatable, Sendable {
    let components: [Int]
    let rawName: String

    init?(_ rawName: String) {
        guard let first = rawName.first, first.isNumber else { return nil }
        var components: [Int] = []
        for segment in rawName.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = segment.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            components.append(value)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
        self.rawName = rawName
    }

    static func < (lhs: DiskCleanVersionNumber, rhs: DiskCleanVersionNumber) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        // When numeric components are equal, sort by name for stable, testable order.
        return lhs.rawName < rhs.rawName
    }
}

// MARK: - Version directory provider

/// Version directory comparison: keep the newest N version subdirs under a container; the rest become candidates (design §5.5).
///
/// Three safety constraints:
/// 1. Only accept **real directories**; never take symlinks or regular files.
/// 2. Versions pointed to by a sibling symlink (`Current`, `latest`, …) are considered in use and never candidates.
/// 3. If version count is below `keepNewestCount + 1`, return empty—never empty a directory that only has one or two versions.
struct DiskCleanVersionDirectoryRuleProvider: DiskCleanDynamicRuleProviding {
    /// Container directory globs. Only **direct children** of expanded containers enter version comparison (the container itself is never a candidate).
    let containerGlobs: [String]
    let keepNewestCount: Int
    let fileSystem: DiskCleanFileSystemProviding

    init(
        containerGlobs: [String],
        keepNewestCount: Int = 1,
        fileSystem: DiskCleanFileSystemProviding = LocalDiskCleanFileSystem()
    ) {
        self.containerGlobs = containerGlobs
        self.keepNewestCount = max(keepNewestCount, 1)
        self.fileSystem = fileSystem
    }

    func expand() async throws -> [DiskCleanFileItem] {
        var items: [DiskCleanFileItem] = []
        for containerGlob in containerGlobs {
            let containers: [DiskCleanFileItem]
            do {
                containers = try fileSystem.expandPathPattern(containerGlob)
            } catch {
                throw DiskCleanDynamicRuleError.directoryUnreadable(path: containerGlob)
            }
            for container in containers where container.isDirectory && !container.isSymlink {
                items += try obsoleteVersions(in: container.path)
            }
        }
        return items
    }

    private func obsoleteVersions(in containerPath: String) throws -> [DiskCleanFileItem] {
        let children: [DiskCleanFileItem]
        do {
            children = try fileSystem.expandPathPattern(containerPath + "/*")
        } catch {
            throw DiskCleanDynamicRuleError.directoryUnreadable(path: containerPath)
        }

        let pinnedNames = Set(children.compactMap(Self.pinnedVersionName))
        var versions: [(version: DiskCleanVersionNumber, item: DiskCleanFileItem)] = []
        for child in children where child.isDirectory && !child.isSymlink {
            let name = (child.path as NSString).lastPathComponent
            guard !pinnedNames.contains(name), let version = DiskCleanVersionNumber(name) else { continue }
            versions.append((version, child))
        }

        guard versions.count > keepNewestCount else { return [] }
        return versions
            .sorted { $0.version > $1.version }
            .dropFirst(keepNewestCount)
            .map(\.item)
    }

    /// Version name pinned by a sibling symlink (`Current -> 152.0.7933.0`). Relative and absolute targets both use only the last component.
    private static func pinnedVersionName(for item: DiskCleanFileItem) -> String? {
        guard item.isSymlink, let target = item.resolvedSymlinkTarget else { return nil }
        let name = (target as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

// MARK: - Unavailable simulator provider

/// Device directories from `xcrun simctl list devices -j` with `isAvailable == false` (design §5.5).
///
/// Device paths are always built as `devicesRootPath + udid`; never trust `dataPath`/`logPath` from JSON—
/// candidate paths must fall under this target's declared reserved roots, not wherever an external command points.
struct DiskCleanUnavailableSimulatorRuleProvider: DiskCleanDynamicRuleProviding {
    let devicesRootPath: String
    let executablePath: String
    let timeout: Duration
    let subprocessRunner: any DiskCleanSubprocessRunning
    let fileSystem: DiskCleanFileSystemProviding

    init(
        devicesRootPath: String = "~/Library/Developer/CoreSimulator/Devices",
        executablePath: String = "/usr/bin/xcrun",
        timeout: Duration = DiskCleanDynamicRuleProviders.subprocessTimeout,
        subprocessRunner: any DiskCleanSubprocessRunning = LocalDiskCleanSubprocessRunner(),
        fileSystem: DiskCleanFileSystemProviding = LocalDiskCleanFileSystem()
    ) {
        self.devicesRootPath = devicesRootPath
        self.executablePath = executablePath
        self.timeout = timeout
        self.subprocessRunner = subprocessRunner
        self.fileSystem = fileSystem
    }

    func expand() async throws -> [DiskCleanFileItem] {
        let result: DiskCleanSubprocessResult
        do {
            result = try await subprocessRunner.run(
                executablePath: executablePath,
                arguments: ["simctl", "list", "devices", "-j"],
                timeout: timeout
            )
        } catch DiskCleanSubprocessError.executableUnavailable {
            return []
        }

        // A non-zero exit usually means simctl is unavailable (without Xcode, xcrun says "unable to find utility");
        // by design treat that as "no simulators" and return empty, not a failure.
        guard result.exitCode == 0 else { return [] }

        var items: [DiskCleanFileItem] = []
        for udid in try Self.unavailableDeviceUDIDs(from: result.standardOutput) {
            guard let item = try? fileSystem.itemInfo(at: devicesRootPath + "/" + udid) else {
                continue
            }
            items.append(item)
        }
        return items
    }

    /// Parse UDIDs of devices with `isAvailable == false`. UDID must be a valid UUID to block path injection such as `../`.
    static func unavailableDeviceUDIDs(from output: Data) throws -> [String] {
        guard
            let root = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
            let devicesByRuntime = root["devices"] as? [String: Any]
        else {
            throw DiskCleanDynamicRuleError.malformedOutput(command: "simctl list devices -j")
        }

        var udids: [String] = []
        for runtime in devicesByRuntime.keys.sorted() {
            guard let devices = devicesByRuntime[runtime] as? [[String: Any]] else { continue }
            for device in devices {
                guard device["isAvailable"] as? Bool == false else { continue }
                guard let udid = device["udid"] as? String, UUID(uuidString: udid) != nil else { continue }
                udids.append(udid)
            }
        }
        return udids
    }
}

// MARK: - Default provider instances

/// Default provider instances referenced by the rule catalog. Container paths must match each target's `reservedRootPaths`.
enum DiskCleanDynamicRuleProviders {
    /// Shared subprocess timeout (design §5.5).
    static let subprocessTimeout: Duration = .seconds(2)

    static let unavailableSimulators: any DiskCleanDynamicRuleProviding =
        DiskCleanUnavailableSimulatorRuleProvider()

    /// JetBrains Toolbox: `apps/<IDE>/ch-<n>/<build>` (Toolbox 1.x) and `apps/<IDE>/<build>` (newer layout).
    /// Scan both layers; non-version intermediate dirs (`ch-0`) are naturally rejected by version parsing.
    static let jetbrainsToolboxOldVersions: any DiskCleanDynamicRuleProviding =
        DiskCleanVersionDirectoryRuleProvider(containerGlobs: [
            "~/Library/Application Support/JetBrains/Toolbox/apps/*/ch-*",
            "~/Library/Application Support/JetBrains/Toolbox/apps/*"
        ])

    /// Multi-version install dirs for AI coding tools. Missing directories are silently skipped.
    static let aiAgentOldVersions: any DiskCleanDynamicRuleProviding =
        DiskCleanVersionDirectoryRuleProvider(containerGlobs: [
            "~/.local/share/claude/versions",
            "~/.claude/versions",
            "~/.codex/versions",
            "~/.local/share/opencode/versions"
        ])

    /// Historical version dirs kept by Chromium-family updaters (`GoogleUpdater/<version>` + `Current` symlink).
    static let oldBrowserVersions: any DiskCleanDynamicRuleProviding =
        DiskCleanVersionDirectoryRuleProvider(containerGlobs: [
            "~/Library/Application Support/Google/GoogleUpdater",
            "~/Library/Application Support/Microsoft/EdgeUpdater",
            "~/Library/Application Support/BraveSoftware/BraveUpdater"
        ])
}
