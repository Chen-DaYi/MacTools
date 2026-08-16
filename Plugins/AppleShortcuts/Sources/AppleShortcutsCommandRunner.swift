import Darwin
import Foundation
import MacToolsPluginKit

struct AppleShortcutsCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let outputWasTruncated: Bool
}

enum AppleShortcutsCommandError: Error, Equatable {
    case executableUnavailable
    case timedOut
    case malformedOutput
    case launchFailed(Int32)
    case nonzeroExit(AppleShortcutsCommandResult)
}

protocol AppleShortcutsCommandRunning: Sendable {
    var isExecutableAvailable: Bool { get }
    func listShortcuts() async throws -> [AppleShortcutItem]
    func listFolders() async throws -> [AppleShortcutFolder]
    func listShortcuts(inFolder id: UUID) async throws -> [AppleShortcutItem]
    func runShortcut(id: UUID) async throws -> AppleShortcutsCommandResult
    func viewShortcut(name: String) async throws
}

struct ProcessAppleShortcutsCommandRunner: AppleShortcutsCommandRunning {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    static let maximumCapturedByteCount = 64 * 1_024
    static let discoveryTimeout: TimeInterval = 15
    static let runTimeout: TimeInterval = 300
    static let actionExecutionTimeoutGraceSeconds: TimeInterval = 1

    private let commandURL: URL
    private let discoveryDeadline: TimeInterval
    private let runDeadline: TimeInterval
    private let maximumCapturedByteCount: Int
    private let beforeProcessLaunch: (@Sendable () -> Void)?
    private let onProcessStopRequested: (@Sendable () -> Void)?

    init(
        commandURL: URL = Self.executableURL,
        discoveryTimeout: TimeInterval = Self.discoveryTimeout,
        runTimeout: TimeInterval = Self.runTimeout,
        maximumCapturedByteCount: Int = Self.maximumCapturedByteCount,
        beforeProcessLaunch: (@Sendable () -> Void)? = nil,
        onProcessStopRequested: (@Sendable () -> Void)? = nil
    ) {
        self.commandURL = commandURL
        discoveryDeadline = discoveryTimeout
        runDeadline = runTimeout
        self.maximumCapturedByteCount = maximumCapturedByteCount
        self.beforeProcessLaunch = beforeProcessLaunch
        self.onProcessStopRequested = onProcessStopRequested
    }

    var isExecutableAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: commandURL.path)
    }

    func listShortcuts() async throws -> [AppleShortcutItem] {
        let result = try await execute(["list", "--show-identifiers"], timeout: discoveryDeadline)
        return try parsedShortcuts(result)
    }

    func listFolders() async throws -> [AppleShortcutFolder] {
        let result = try await execute(
            ["list", "--folders", "--show-identifiers"],
            timeout: discoveryDeadline
        )
        guard !result.outputWasTruncated else {
            throw AppleShortcutsCommandError.malformedOutput
        }
        let folders: [AppleShortcutFolder]
        do {
            folders = try AppleShortcutsListParser.parseFolders(result.standardOutput)
        } catch {
            throw AppleShortcutsCommandError.malformedOutput
        }
        guard result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !folders.isEmpty else {
            throw AppleShortcutsCommandError.malformedOutput
        }
        return folders
    }

    func listShortcuts(inFolder id: UUID) async throws -> [AppleShortcutItem] {
        let result = try await execute(
            ["list", "--folder-name", id.uuidString, "--show-identifiers"],
            timeout: discoveryDeadline
        )
        return try parsedShortcuts(result)
    }

    func runShortcut(id: UUID) async throws -> AppleShortcutsCommandResult {
        try await execute(["run", id.uuidString], timeout: runDeadline)
    }

    func viewShortcut(name: String) async throws {
        _ = try await execute(["view", "--", name], timeout: discoveryDeadline)
    }

    private func parsedShortcuts(_ result: AppleShortcutsCommandResult) throws -> [AppleShortcutItem] {
        guard !result.outputWasTruncated else {
            throw AppleShortcutsCommandError.malformedOutput
        }
        let shortcuts: [AppleShortcutItem]
        do {
            shortcuts = try AppleShortcutsListParser.parse(result.standardOutput)
        } catch {
            throw AppleShortcutsCommandError.malformedOutput
        }
        guard result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !shortcuts.isEmpty else {
            throw AppleShortcutsCommandError.malformedOutput
        }
        return shortcuts
    }

    private func execute(
        _ arguments: [String],
        timeout: TimeInterval
    ) async throws -> AppleShortcutsCommandResult {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: commandURL.path) else {
            throw AppleShortcutsCommandError.executableUnavailable
        }
        let result = try await AppleShortcutsProcessExecution(
            executableURL: commandURL,
            arguments: arguments,
            environment: safeEnvironment(),
            timeout: timeout,
            maximumCapturedByteCount: maximumCapturedByteCount,
            beforeLaunchClaim: beforeProcessLaunch,
            onStopRequested: onProcessStopRequested
        ).run()
        guard result.exitCode == 0 else {
            throw AppleShortcutsCommandError.nonzeroExit(result)
        }
        return result
    }

    private func safeEnvironment() -> [String: String] {
        var environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["LANG", "LC_ALL", "USER", "LOGNAME"] {
            if let value = inherited[key] { environment[key] = value }
        }
        return environment
    }
}

private enum AppleShortcutsStopReason {
    case cancelled
    case timedOut
}

private final class AppleShortcutsProcessExecution: @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<AppleShortcutsCommandResult, Error>

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let outputBuffer: AppleShortcutsOutputBuffer
    private let errorBuffer: AppleShortcutsOutputBuffer
    private let beforeLaunchClaim: (@Sendable () -> Void)?
    private let onStopRequested: (@Sendable () -> Void)?
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "cc.ggbond.mactools.apple-shortcuts.io")
    private let controlQueue = DispatchQueue(label: "cc.ggbond.mactools.apple-shortcuts.control")

    private var continuation: Continuation?
    private var processLease: PluginProcessGroupLease?
    private var outputDescriptor: Int32 = -1
    private var errorDescriptor: Int32 = -1
    private var outputSource: DispatchSourceRead?
    private var errorSource: DispatchSourceRead?
    private var timeoutWorkItem: DispatchWorkItem?
    private var killWorkItem: DispatchWorkItem?
    private var completionWorkItem: DispatchWorkItem?
    private var requestedStopReason: AppleShortcutsStopReason?
    private var launchState = LaunchState.pending
    private var didFinish = false

    private enum LaunchState: Equatable {
        case pending
        case launching
        case launched
        case finished
    }

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        maximumCapturedByteCount: Int,
        beforeLaunchClaim: (@Sendable () -> Void)?,
        onStopRequested: (@Sendable () -> Void)?
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.beforeLaunchClaim = beforeLaunchClaim
        self.onStopRequested = onStopRequested
        outputBuffer = AppleShortcutsOutputBuffer(maximumByteCount: maximumCapturedByteCount)
        errorBuffer = AppleShortcutsOutputBuffer(maximumByteCount: maximumCapturedByteCount)
    }

    func run() async throws -> AppleShortcutsCommandResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation)
            }
        } onCancel: {
            requestStop(.cancelled)
        }
    }

    private func start(continuation: Continuation) {
        lock.withLock { self.continuation = continuation }
        beforeLaunchClaim?()
        let claimedLaunch = lock.withLock { () -> Bool in
            guard !didFinish,
                  launchState == .pending,
                  requestedStopReason == nil else { return false }
            launchState = .launching
            return true
        }
        guard claimedLaunch else {
            finish(throwing: CancellationError())
            return
        }
        do {
            let launch = try spawn()
            let lease = PluginProcessGroupLease(processID: launch.processID)
            lock.withLock {
                launchState = .launched
                processLease = lease
                outputDescriptor = launch.outputDescriptor
                errorDescriptor = launch.errorDescriptor
            }
            startReading(descriptor: launch.outputDescriptor, stream: .standardOutput)
            startReading(descriptor: launch.errorDescriptor, stream: .standardError)
            scheduleTimeout()
            if lock.withLock({ requestedStopReason }) != nil {
                lease.signal(SIGTERM)
                scheduleForcedKill()
            }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let observedExit = lease.waitForLeaderExit()
                self.lock.withLock {
                    self.timeoutWorkItem?.cancel()
                    self.timeoutWorkItem = nil
                }
                self.controlQueue.async { [weak self] in
                    self?.processDidExit(lease: lease, observedExit: observedExit)
                }
            }
        } catch {
            if let error = error as? POSIXError {
                finish(throwing: AppleShortcutsCommandError.launchFailed(error.code.rawValue))
            } else {
                finish(throwing: error)
            }
        }
    }

    private enum Stream { case standardOutput, standardError }
    private struct LaunchResult {
        let processID: pid_t
        let outputDescriptor: Int32
        let errorDescriptor: Int32
    }

    private func spawn() throws -> LaunchResult {
        var outputPipe: [Int32] = [-1, -1]
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else { throw POSIXError(.EIO) }
        guard pipe(&errorPipe) == 0 else {
            close(outputPipe[0])
            close(outputPipe[1])
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

        var pid: pid_t = 0
        let argv = [executableURL.path] + arguments
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let spawnResult = withCStringArray(argv) { argvPointer in
            withCStringArray(env) { environmentPointer in
                posix_spawn(
                    &pid,
                    executableURL.path,
                    &actions,
                    &attributes,
                    argvPointer,
                    environmentPointer
                )
            }
        }
        guard spawnResult == 0 else {
            closePipes()
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO)
        }

        close(outputPipe[1])
        outputPipe[1] = -1
        close(errorPipe[1])
        errorPipe[1] = -1
        for descriptor in [outputPipe[0], errorPipe[0]] {
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        }
        return LaunchResult(
            processID: pid,
            outputDescriptor: outputPipe[0],
            errorDescriptor: errorPipe[0]
        )
    }

    private func startReading(descriptor: Int32, stream: Stream) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.drain(descriptor: descriptor, stream: stream)
        }
        source.resume()
        lock.withLock {
            switch stream {
            case .standardOutput: outputSource = source
            case .standardError: errorSource = source
            }
        }
    }

    private func drain(descriptor: Int32, stream: Stream) {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
        for _ in 0 ..< 16 {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                let data = Data(bytes.prefix(count))
                switch stream {
                case .standardOutput: outputBuffer.append(data)
                case .standardError: errorBuffer.append(data)
                }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }
    }

    private func scheduleTimeout() {
        let item = DispatchWorkItem { [weak self] in self?.requestStop(.timedOut) }
        lock.withLock { timeoutWorkItem = item }
        controlQueue.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    private func requestStop(_ reason: AppleShortcutsStopReason) {
        let stop = lock.withLock { () -> (PluginProcessGroupLease?, Bool) in
            guard !didFinish else { return (nil, false) }
            let didRecord = requestedStopReason == nil
            if didRecord { requestedStopReason = reason }
            return (processLease, didRecord)
        }
        if stop.1 { onStopRequested?() }
        guard let lease = stop.0 else { return }
        lease.signal(SIGTERM)
        scheduleForcedKill()
    }

    private func scheduleForcedKill() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.processLease }?.signal(SIGKILL)
        }
        let shouldSchedule = lock.withLock { () -> Bool in
            guard killWorkItem == nil else { return false }
            killWorkItem = item
            return true
        }
        if shouldSchedule { controlQueue.asyncAfter(deadline: .now() + 0.25, execute: item) }
    }

    private func processDidExit(lease: PluginProcessGroupLease, observedExit: Bool) {
        guard observedExit else {
            _ = lease.reapLeader()
            lock.withLock { if processLease === lease { processLease = nil } }
            completeAfterExit(status: nil)
            return
        }
        lease.signal(SIGTERM)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            lease.signal(SIGKILL)
            let status = lease.reapLeader()
            self.lock.withLock { if self.processLease === lease { self.processLease = nil } }
            self.completeAfterExit(status: status)
        }
        lock.withLock { completionWorkItem = item }
        controlQueue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func completeAfterExit(status: Int32?) {
        ioQueue.sync {
            drain(descriptor: outputDescriptor, stream: .standardOutput)
            drain(descriptor: errorDescriptor, stream: .standardError)
            closeStreams()
        }
        switch lock.withLock({ requestedStopReason }) {
        case .cancelled:
            finish(throwing: CancellationError())
        case .timedOut:
            finish(throwing: AppleShortcutsCommandError.timedOut)
        case nil:
            guard let status else {
                finish(throwing: POSIXError(.ECHILD))
                return
            }
            finish(returning: AppleShortcutsCommandResult(
                exitCode: Self.exitCode(from: status),
                standardOutput: outputBuffer.string,
                standardError: errorBuffer.string,
                outputWasTruncated: outputBuffer.wasTruncated || errorBuffer.wasTruncated
            ))
        }
    }

    private func closeStreams() {
        let resources = lock.withLock { () -> (DispatchSourceRead?, DispatchSourceRead?, Int32, Int32) in
            let resources = (outputSource, errorSource, outputDescriptor, errorDescriptor)
            outputSource = nil
            errorSource = nil
            outputDescriptor = -1
            errorDescriptor = -1
            return resources
        }
        resources.0?.cancel()
        resources.1?.cancel()
        if resources.2 >= 0 { close(resources.2) }
        if resources.3 >= 0 { close(resources.3) }
    }

    private func finish(returning result: AppleShortcutsCommandResult) {
        takeContinuation()?.resume(returning: result)
    }

    private func finish(throwing error: Error) {
        closeStreams()
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> Continuation? {
        lock.withLock {
            guard !didFinish else { return nil }
            didFinish = true
            launchState = .finished
            timeoutWorkItem?.cancel()
            killWorkItem?.cancel()
            completionWorkItem?.cancel()
            let continuation = continuation
            self.continuation = nil
            return continuation
        }
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.compactMap { $0 }.forEach { free($0) } }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}

private final class AppleShortcutsOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumByteCount: Int
    private var data = Data()
    private var truncated = false

    init(maximumByteCount: Int) { self.maximumByteCount = maximumByteCount }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.withLock {
            let remaining = max(0, maximumByteCount - data.count)
            if newData.count > remaining { truncated = true }
            if remaining > 0 { data.append(newData.prefix(remaining)) }
        }
    }

    var wasTruncated: Bool { lock.withLock { truncated } }
    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
