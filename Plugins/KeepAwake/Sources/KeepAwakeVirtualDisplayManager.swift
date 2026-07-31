import Foundation
import OSLog
import MacToolsPluginKit

@MainActor
protocol KeepAwakeVirtualDisplayManaging: AnyObject {
    var isAvailable: Bool { get }
    var isActive: Bool { get }
    var onUnexpectedTermination: (() -> Void)? { get set }

    func start() async throws
    func stop()
}

@MainActor
final class KeepAwakeVirtualDisplayManager: KeepAwakeVirtualDisplayManaging {
    private enum Timing {
        static let startupTimeout: DispatchTimeInterval = .seconds(5)
    }

    private enum ManagerError: LocalizedError {
        case helperUnavailable(PluginLocalization)
        case launchFailed(String, PluginLocalization)
        case startupFailed(String, PluginLocalization)
        case startupTimedOut(PluginLocalization)

        var errorDescription: String? {
            switch self {
            case let .helperUnavailable(localization):
                return localization.string(
                    "error.virtualDisplay.unavailable",
                    defaultValue: "此版本的阻止休眠插件不支持软件显示器。"
                )
            case let .launchFailed(detail, localization):
                return localization.format(
                    "error.virtualDisplay.launchFailedFormat",
                    defaultValue: "无法启动软件显示器：%@",
                    detail
                )
            case let .startupFailed(detail, localization):
                return localization.format(
                    "error.virtualDisplay.startupFailedFormat",
                    defaultValue: "无法创建软件显示器：%@",
                    detail
                )
            case let .startupTimedOut(localization):
                return localization.string(
                    "error.virtualDisplay.startupTimedOut",
                    defaultValue: "创建软件显示器超时。"
                )
            }
        }
    }

    private final class Handshake: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var output = Data()
        private var errorOutput = Data()
        private var result: Result<String, Error>?

        func appendOutput(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }

            guard result == nil else { return }
            output.append(data)

            guard let newlineIndex = output.firstIndex(of: 0x0A) else {
                return
            }

            let lineData = output[..<newlineIndex]
            let line = String(data: lineData, encoding: .utf8) ?? ""
            result = .success(line)
            semaphore.signal()
        }

        func appendError(_ data: Data) {
            lock.lock()
            errorOutput.append(data)
            lock.unlock()
        }

        func processExited() {
            lock.lock()
            defer { lock.unlock() }

            guard result == nil else { return }
            let detail = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result = .failure(
                HelperExitedError(detail: detail?.isEmpty == false ? detail : nil)
            )
            semaphore.signal()
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }

            guard result == nil else { return }
            result = .failure(CancellationError())
            semaphore.signal()
        }

        func wait() -> Result<String, Error>? {
            guard semaphore.wait(timeout: .now() + Timing.startupTimeout) == .success else {
                return nil
            }

            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private struct HelperExitedError: LocalizedError {
        let detail: String?

        var errorDescription: String? {
            detail ?? "The virtual display helper exited unexpectedly."
        }
    }

    private struct RunningHelper {
        let id: UUID
        let process: Process
        let standardOutput: Pipe
        let standardError: Pipe
        let handshake: Handshake
    }

    var onUnexpectedTermination: (() -> Void)?

    var isAvailable: Bool {
        guard let helperURL else { return false }
        return FileManager.default.isExecutableFile(atPath: helperURL.path)
    }

    var isActive: Bool {
        runningHelper?.process.isRunning == true
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "KeepAwakeVirtualDisplay"
    )
    private let helperURL: URL?
    private let localization: PluginLocalization
    private var runningHelper: RunningHelper?

    init(helperURL: URL?, localization: PluginLocalization) {
        self.helperURL = helperURL
        self.localization = localization
    }

    deinit {
        runningHelper?.process.terminate()
    }

    func start() async throws {
        try Task.checkCancellation()

        if isActive {
            return
        }

        guard let helperURL, isAvailable else {
            throw ManagerError.helperUnavailable(localization)
        }

        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let handshake = Handshake()
        let helperID = UUID()

        process.executableURL = helperURL
        process.standardOutput = standardOutput
        process.standardError = standardError

        standardOutput.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty {
                handshake.appendOutput(data)
            }
        }
        standardError.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty {
                handshake.appendError(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            handshake.processExited()
            Task { @MainActor [weak self] in
                self?.handleTermination(of: process, helperID: helperID)
            }
        }

        do {
            try process.run()
        } catch {
            clearReadabilityHandlers(standardOutput: standardOutput, standardError: standardError)
            throw ManagerError.launchFailed(error.localizedDescription, localization)
        }

        runningHelper = RunningHelper(
            id: helperID,
            process: process,
            standardOutput: standardOutput,
            standardError: standardError,
            handshake: handshake
        )

        let result = await Task.detached(priority: .userInitiated) {
            handshake.wait()
        }.value

        if Task.isCancelled {
            stop(helperID: helperID)
            throw CancellationError()
        }
        guard runningHelper?.id == helperID else {
            throw CancellationError()
        }

        guard let result else {
            stop(helperID: helperID)
            throw ManagerError.startupTimedOut(localization)
        }

        switch result {
        case let .success(line):
            guard line.hasPrefix("READY ") else {
                stop(helperID: helperID)
                throw ManagerError.startupFailed(line, localization)
            }
            standardOutput.fileHandleForReading.readabilityHandler = nil
            logger.info("software display helper started")
        case let .failure(error):
            stop(helperID: helperID)
            if error is CancellationError {
                throw error
            }
            throw ManagerError.startupFailed(error.localizedDescription, localization)
        }
    }

    func stop() {
        stop(helperID: nil)
    }

    private func stop(helperID: UUID?) {
        guard let runningHelper else {
            return
        }
        guard helperID == nil || runningHelper.id == helperID else {
            return
        }

        self.runningHelper = nil
        runningHelper.handshake.cancel()
        clearReadabilityHandlers(
            standardOutput: runningHelper.standardOutput,
            standardError: runningHelper.standardError
        )
        runningHelper.process.terminationHandler = nil

        if runningHelper.process.isRunning {
            runningHelper.process.terminate()
        }
        logger.info("software display helper stopped")
    }

    private func handleTermination(of process: Process, helperID: UUID) {
        guard runningHelper?.id == helperID else {
            return
        }

        let standardOutput = runningHelper?.standardOutput
        let standardError = runningHelper?.standardError
        runningHelper = nil

        if let standardOutput, let standardError {
            clearReadabilityHandlers(
                standardOutput: standardOutput,
                standardError: standardError
            )
        }

        logger.error(
            "software display helper exited status=\(process.terminationStatus, privacy: .public)"
        )
        onUnexpectedTermination?()
    }

    private func clearReadabilityHandlers(standardOutput: Pipe, standardError: Pipe) {
        standardOutput.fileHandleForReading.readabilityHandler = nil
        standardError.fileHandleForReading.readabilityHandler = nil
    }
}
