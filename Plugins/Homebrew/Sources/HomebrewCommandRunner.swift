import Darwin
import Foundation
import MacToolsPluginKit

public enum HomebrewExecutableValidator {
    public static let standardPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/opt/workbrew/bin/brew"
    ]

    public static func validatedPath(
        for rawPath: String,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = (trimmed as NSString).expandingTildeInPath
        if (candidate as NSString).lastPathComponent != "brew" {
            candidate = (candidate as NSString).appendingPathComponent("brew")
        }

        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL
        guard isValidBrewExecutable(at: standardized.path, fileManager: fileManager) else {
            return nil
        }
        return standardized.path
    }

    public static func isValidBrewExecutable(
        at path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == "brew",
              url.deletingLastPathComponent().lastPathComponent == "bin" else {
            return false
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isExecutableFile(atPath: url.path) else {
            return false
        }

        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        var resolvedIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &resolvedIsDirectory),
              !resolvedIsDirectory.boolValue,
              fileManager.isExecutableFile(atPath: resolvedURL.path) else {
            return false
        }

        return looksLikeHomebrewExecutable(at: resolvedURL)
            || looksLikeHomebrewExecutable(at: url)
    }

    private static func looksLikeHomebrewExecutable(at url: URL) -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? fileHandle.close() }

        guard let data = try? fileHandle.read(upToCount: 16_384),
              let sample = String(data: data, encoding: .utf8) else {
            return false
        }

        return sample.contains("HOMEBREW")
            || sample.contains("Homebrew")
            || sample.contains("brew.rb")
    }
}

public protocol HomebrewCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        onOutput: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async throws -> Int32
    
    func cancel() async
}

public actor HomebrewCommandRunner: HomebrewCommandRunning {
    private struct ActiveExecution: Sendable {
        let id: UUID
        let lease: PluginProcessGroupLease
    }

    private var activeExecution: ActiveExecution?
    private var cancelledExecutionIDs: Set<UUID> = []
    private var cancellationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Runs a command asynchronously, streaming output and error chunks to the provided handlers.
    /// Returns the termination status (exit code).
    public func run(
        executable: String,
        arguments: [String],
        onOutput: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async throws -> Int32 {
        if activeExecution != nil {
            throw NSError(
                domain: "HomebrewCommandRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "A process is already running."]
            )
        }

        guard let validatedExecutable = HomebrewExecutableValidator.validatedPath(for: executable) else {
            throw NSError(
                domain: "HomebrewCommandRunner",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The configured Homebrew executable is invalid."]
            )
        }

        // Setup environment path, ensuring homebrew binaries are visible
        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        let brewPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        var pathComponents = path.components(separatedBy: ":")
        for p in brewPaths {
            if !pathComponents.contains(p) {
                pathComponents.insert(p, at: 0)
            }
        }
        env["PATH"] = pathComponents.joined(separator: ":")
        env["HOMEBREW_NO_EMOJI"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        let launch = try spawn(
            executable: validatedExecutable,
            arguments: arguments,
            environment: env
        )
        let execution = ActiveExecution(
            id: UUID(),
            lease: PluginProcessGroupLease(processID: launch.processID)
        )
        activeExecution = execution
        let outputHandle = FileHandle(
            fileDescriptor: launch.outputDescriptor,
            closeOnDealloc: true
        )
        let errorHandle = FileHandle(
            fileDescriptor: launch.errorDescriptor,
            closeOnDealloc: true
        )

        let group = DispatchGroup()

        // Attach readability handlers to stream output in real-time
        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let string = String(data: data, encoding: .utf8) {
                group.enter()
                Task { @MainActor in
                    onOutput(string)
                    group.leave()
                }
            }
        }

        errorHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let string = String(data: data, encoding: .utf8) {
                group.enter()
                Task { @MainActor in
                    onError(string)
                    group.leave()
                }
            }
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let observedExit = execution.lease.waitForLeaderExit()

                // Homebrew may leave build or installer children running after the
                // command leader exits. A normal completion must wait for the whole
                // dedicated process group instead of terminating those children.
                let processGroupExited = observedExit && Self.waitForProcessGroupToExit(
                    lease: execution.lease
                )
                let status = execution.lease.reapLeader()

                outputHandle.readabilityHandler = nil
                errorHandle.readabilityHandler = nil
                let drainGroup = DispatchGroup()
                drainGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = outputHandle.readDataToEndOfFile()
                    if let string = String(data: data, encoding: .utf8), !string.isEmpty {
                        group.enter()
                        Task { @MainActor in
                            onOutput(string)
                            group.leave()
                        }
                    }
                    drainGroup.leave()
                }
                drainGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = errorHandle.readDataToEndOfFile()
                    if let string = String(data: data, encoding: .utf8), !string.isEmpty {
                        group.enter()
                        Task { @MainActor in
                            onError(string)
                            group.leave()
                        }
                    }
                    drainGroup.leave()
                }
                drainGroup.wait()
                group.wait()
                try? outputHandle.close()
                try? errorHandle.close()

                Task { [weak self] in
                    let wasCancelled = await self?.finishProcess(
                        executionID: execution.id
                    ) ?? false
                    let leaderExitCode = status.map(Self.exitCode(from:)) ?? 1
                    let exitCode: Int32
                    if !processGroupExited {
                        exitCode = 1
                    } else if wasCancelled, leaderExitCode == 0 {
                        exitCode = 128 + SIGTERM
                    } else {
                        exitCode = leaderExitCode
                    }
                    continuation.resume(returning: exitCode)
                }
            }
        }
    }

    public func cancel() async {
        guard let execution = activeExecution else { return }
        cancelledExecutionIDs.insert(execution.id)
        execution.lease.signal(SIGTERM)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.forceKill(executionID: execution.id)
        }
        await withCheckedContinuation { continuation in
            cancellationWaiters[execution.id, default: []].append(continuation)
        }
    }

    private struct LaunchResult {
        let processID: pid_t
        let outputDescriptor: Int32
        let errorDescriptor: Int32
    }

    private func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> LaunchResult {
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { throw POSIXError(.EIO) }
        guard pipe(&errorPipe) == 0 else {
            close(outputPipe[0]); close(outputPipe[1])
            throw POSIXError(.EIO)
        }

        func closePipes() {
            outputPipe.filter { $0 >= 0 }.forEach { close($0) }
            errorPipe.filter { $0 >= 0 }.forEach { close($0) }
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            closePipes()
            throw POSIXError(.EIO)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        guard posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, errorPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, errorPipe[1]) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            closePipes()
            throw POSIXError(.EIO)
        }

        var processID: pid_t = 0
        let spawnArguments = [executable] + arguments
        let environmentEntries = environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let result = withHomebrewCStringArray(spawnArguments) { argv in
            withHomebrewCStringArray(environmentEntries) { environmentPointer in
                posix_spawn(
                    &processID,
                    executable,
                    &actions,
                    &attributes,
                    argv,
                    environmentPointer
                )
            }
        }
        guard result == 0 else {
            closePipes()
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }

        close(outputPipe[1]); outputPipe[1] = -1
        close(errorPipe[1]); errorPipe[1] = -1
        return LaunchResult(
            processID: processID,
            outputDescriptor: outputPipe[0],
            errorDescriptor: errorPipe[0]
        )
    }

    private func forceKill(executionID: UUID) {
        guard let activeExecution, activeExecution.id == executionID else { return }
        activeExecution.lease.signal(SIGKILL)
    }

    private func finishProcess(executionID: UUID) -> Bool {
        let wasCancelled = cancelledExecutionIDs.remove(executionID) != nil
        if activeExecution?.id == executionID {
            activeExecution = nil
        }
        cancellationWaiters.removeValue(forKey: executionID)?.forEach { $0.resume() }
        return wasCancelled
    }

    private nonisolated static func waitForProcessGroupToExit(
        lease: PluginProcessGroupLease
    ) -> Bool {
        while true {
            guard let members = lease.remainingMemberPIDs() else {
                // An indeterminate membership query must not release the retained
                // leader without first terminating the still-owned group.
                _ = lease.signal(SIGTERM)
                usleep(250_000)
                _ = lease.signal(SIGKILL)
                usleep(25_000)
                return false
            }
            if !members.isEmpty {
                usleep(25_000)
                continue
            }
            return true
        }
    }

    private nonisolated static func exitCode(from status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

private func withHomebrewCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.compactMap { $0 }.forEach { free($0) } }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
