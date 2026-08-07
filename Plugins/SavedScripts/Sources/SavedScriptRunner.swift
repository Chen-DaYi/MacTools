import Foundation

struct SavedScriptProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let outputWasTruncated: Bool
}

enum SavedScriptProcessError: Error, Equatable {
    case executableUnavailable
    case invalidWorkingDirectory
    case timedOut
}

protocol SavedScriptRunning: Sendable {
    func run(_ script: SavedScript) async throws -> SavedScriptProcessResult
}

struct ProcessSavedScriptRunner: SavedScriptRunning {
    static let maximumCapturedByteCount = 64 * 1_024

    private let temporaryDirectory: URL

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }

    func run(_ script: SavedScript) async throws -> SavedScriptProcessResult {
        guard FileManager.default.isExecutableFile(atPath: script.kind.executableURL.path) else {
            throw SavedScriptProcessError.executableUnavailable
        }

        let workingDirectory = try resolvedWorkingDirectory(script.workingDirectory)
        let sourceURL = try writeTemporarySource(for: script)
        let processBox = SavedScriptProcessBox()
        let timeoutNanoseconds = UInt64(script.timeoutSeconds) * 1_000_000_000
        let timeoutTask = Task.detached {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            processBox.terminate(reason: .timedOut)
        }
        defer {
            timeoutTask.cancel()
            try? FileManager.default.removeItem(at: sourceURL)
        }

        return try await withTaskCancellationHandler {
            try await launch(
                script: script,
                sourceURL: sourceURL,
                workingDirectory: workingDirectory,
                processBox: processBox
            )
        } onCancel: {
            processBox.terminate(reason: .cancelled)
        }
    }

    private func launch(
        script: SavedScript,
        sourceURL: URL,
        workingDirectory: URL,
        processBox: SavedScriptProcessBox
    ) async throws -> SavedScriptProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBuffer = SavedScriptOutputBuffer(maximumByteCount: Self.maximumCapturedByteCount)
        let errorBuffer = SavedScriptOutputBuffer(maximumByteCount: Self.maximumCapturedByteCount)
        let resumeState = SavedScriptResumeState()

        process.executableURL = script.kind.executableURL
        process.arguments = [sourceURL.path]
        process.currentDirectoryURL = workingDirectory
        process.environment = safeEnvironment()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { outputBuffer.append(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errorBuffer.append(data) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                outputBuffer.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
                errorBuffer.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
                let stopReason = processBox.clear(terminatedProcess)

                resumeState.resume {
                    switch stopReason {
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .timedOut:
                        continuation.resume(throwing: SavedScriptProcessError.timedOut)
                    case nil:
                        continuation.resume(returning: SavedScriptProcessResult(
                            exitCode: terminatedProcess.terminationStatus,
                            standardOutput: outputBuffer.string,
                            standardError: errorBuffer.string,
                            outputWasTruncated: outputBuffer.wasTruncated || errorBuffer.wasTruncated
                        ))
                    }
                }
            }

            processBox.install(process)
            do {
                try process.run()
                processBox.terminateIfRequested()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                _ = processBox.clear(process)
                resumeState.resume {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resolvedWorkingDirectory(_ rawPath: String) throws -> URL {
        guard !rawPath.isEmpty else {
            return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SavedScriptProcessError.invalidWorkingDirectory
        }
        return url
    }

    private func writeTemporarySource(for script: SavedScript) throws -> URL {
        let directory = temporaryDirectory
            .appendingPathComponent("SavedScripts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(script.kind.fileExtension)
        try Data(script.source.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func safeEnvironment() -> [String: String] {
        var environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["LANG", "LC_ALL", "USER", "LOGNAME"] {
            if let value = inherited[key] { environment[key] = value }
        }
        return environment
    }
}

private enum SavedScriptStopReason {
    case cancelled
    case timedOut
}

private final class SavedScriptProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var requestedStopReason: SavedScriptStopReason?

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func terminateIfRequested() {
        lock.lock()
        let process = self.process
        let shouldTerminate = requestedStopReason != nil
        lock.unlock()
        if shouldTerminate, process?.isRunning == true { process?.terminate() }
    }

    func terminate(reason: SavedScriptStopReason) {
        lock.lock()
        if requestedStopReason == nil { requestedStopReason = reason }
        let process = self.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    func clear(_ process: Process) -> SavedScriptStopReason? {
        lock.lock()
        defer { lock.unlock() }
        if self.process === process { self.process = nil }
        return requestedStopReason
    }
}

private final class SavedScriptResumeState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        operation()
    }
}

private final class SavedScriptOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumByteCount: Int
    private var data = Data()
    private var truncated = false

    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
    }

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, maximumByteCount - data.count)
        if newData.count > remaining { truncated = true }
        if remaining > 0 { data.append(newData.prefix(remaining)) }
    }

    var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
