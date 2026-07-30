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

/// Real implementation: pipe drain races the timeout—timeout kills the process; process exit yields EOF so the reader returns.
struct LocalDiskCleanSubprocessRunner: DiskCleanSubprocessRunning {
    /// Output cap. Stop reading past it so JSON parsing fails as `malformedOutput` instead of unbounded memory use.
    static let maximumOutputBytes = 8 * 1024 * 1024

    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> DiskCleanSubprocessResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw DiskCleanSubprocessError.executableUnavailable(path: executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let box = ProcessBox(process: process)
        do {
            try process.run()
        } catch {
            throw DiskCleanSubprocessError.launchFailed(
                path: executablePath,
                message: error.localizedDescription
            )
        }

        let readDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            box.terminate(markingTimeout: true)
        }

        // Caller cancel also terminates the subprocess: a blocked read(2) ignores task cancel; only process exit closes the pipe.
        let output = await withTaskCancellationHandler {
            await Self.drain(fileDescriptor: readDescriptor)
        } onCancel: {
            box.terminate(markingTimeout: false)
        }

        box.waitUntilExit()
        timeoutTask.cancel()
        try? outputPipe.fileHandleForReading.close()

        if box.didTimeOut {
            throw DiskCleanSubprocessError.timedOut(path: executablePath)
        }
        return DiskCleanSubprocessResult(exitCode: box.terminationStatus, standardOutput: output)
    }

    private static func drain(fileDescriptor: Int32) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var output = Data()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while output.count < maximumOutputBytes {
                    let count = buffer.withUnsafeMutableBytes {
                        read(fileDescriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        output.append(contentsOf: buffer[0..<count])
                        continue
                    }
                    if count < 0 && errno == EINTR {
                        continue
                    }
                    break
                }
                continuation.resume(returning: output)
            }
        }
    }

    /// `Process` is not `Sendable`, but `terminate()`/`isRunning` may be called across threads.
    /// A lock serializes "terminate + mark timeout" and ensures an already-exited process is not misread as timed out.
    private final class ProcessBox: @unchecked Sendable {
        private struct Flags: Sendable {
            var timedOut = false
        }

        private let process: Process
        private let flags = OSAllocatedUnfairLock(initialState: Flags())

        init(process: Process) {
            self.process = process
        }

        func terminate(markingTimeout: Bool) {
            flags.withLock { flags in
                guard process.isRunning else { return }
                if markingTimeout {
                    flags.timedOut = true
                }
                process.terminate()
            }
        }

        func waitUntilExit() {
            process.waitUntilExit()
        }

        var terminationStatus: Int32 {
            process.terminationStatus
        }

        var didTimeOut: Bool {
            flags.withLock { $0.timedOut }
        }
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
