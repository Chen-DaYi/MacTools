import Combine
import Foundation
import MacToolsPluginKit

enum XcodeCleanPhase: Equatable, Sendable {
    case idle
    case scanning
    case scanned
    case cleaning
    case completed
}

struct XcodeCleanSnapshot: Equatable, Sendable {
    let phase: XcodeCleanPhase
    let selectedCategories: Set<XcodeCleanCategory>
    let scanResult: XcodeCleanScanResult?
    let executionResult: XcodeCleanExecutionResult?
    let isResultStale: Bool
    let isXcodeRunning: Bool
    let errorMessage: String?
    let scanLogEntries: [XcodeCleanScanLogEntry]

    init(
        phase: XcodeCleanPhase,
        selectedCategories: Set<XcodeCleanCategory>,
        scanResult: XcodeCleanScanResult?,
        executionResult: XcodeCleanExecutionResult?,
        isResultStale: Bool,
        isXcodeRunning: Bool,
        errorMessage: String?,
        scanLogEntries: [XcodeCleanScanLogEntry] = []
    ) {
        self.phase = phase
        self.selectedCategories = selectedCategories
        self.scanResult = scanResult
        self.executionResult = executionResult
        self.isResultStale = isResultStale
        self.isXcodeRunning = isXcodeRunning
        self.errorMessage = errorMessage
        self.scanLogEntries = scanLogEntries
    }

    var isBusy: Bool {
        phase == .scanning || phase == .cleaning
    }

    var canScan: Bool {
        !isXcodeRunning && !isBusy && !selectedCategories.isEmpty
    }

    var canClean: Bool {
        !isXcodeRunning
            && phase == .scanned
            && !isResultStale
            && scanResult?.cleanableCandidates.isEmpty == false
    }

    static let initial = XcodeCleanSnapshot(
        phase: .idle,
        selectedCategories: Set(XcodeCleanCategory.allCases),
        scanResult: nil,
        executionResult: nil,
        isResultStale: false,
        isXcodeRunning: false,
        errorMessage: nil
    )
}

@MainActor
protocol XcodeCleanControlling: AnyObject {
    var onStateChange: (() -> Void)? { get set }
    var snapshot: XcodeCleanSnapshot { get }

    func setCategory(_ category: XcodeCleanCategory, isSelected: Bool)
    func scan()
    func cleanSelected(candidateIDs: Set<XcodeCleanCandidate.ID>)
    func cancelCurrentOperation()
    func updateXcodeRunningState(_ isRunning: Bool)
}

@MainActor
final class XcodeCleanController: ObservableObject, XcodeCleanControlling {
    private static let scanLogFlushIntervalNanoseconds: UInt64 = 100_000_000
    private static let maxLogEntries = 500

    var onStateChange: (() -> Void)?

    @Published private(set) var snapshot: XcodeCleanSnapshot {
        didSet { onStateChange?() }
    }

    private let scanner: XcodeCleanScanning
    private let executor: XcodeCleanExecuting
    private let localization: PluginLocalization

    private var currentTask: Task<Void, Never>?
    private var currentOperationID: UUID?
    private var scanLogFlushTask: Task<Void, Never>?
    private var nextLogEntryID = 1

    init(
        scanner: XcodeCleanScanning = XcodeCleanScanner(),
        executor: XcodeCleanExecuting = XcodeCleanExecutor(),
        initialSnapshot: XcodeCleanSnapshot = .initial,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.scanner = scanner
        self.executor = executor
        self.localization = localization
        snapshot = initialSnapshot
    }

    deinit {
        currentTask?.cancel()
        scanLogFlushTask?.cancel()
    }

    func setCategory(_ category: XcodeCleanCategory, isSelected: Bool) {
        var next = snapshot.selectedCategories
        if isSelected {
            next.insert(category)
        } else {
            next.remove(category)
        }

        snapshot = XcodeCleanSnapshot(
            phase: snapshot.phase,
            selectedCategories: next,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: isStale(scanResult: snapshot.scanResult, selectedCategories: next),
            isXcodeRunning: snapshot.isXcodeRunning,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: snapshot.scanLogEntries
        )
    }

    func updateXcodeRunningState(_ isRunning: Bool) {
        guard snapshot.isXcodeRunning != isRunning else { return }

        if isRunning {
            cancelTaskOnly()
            snapshot = XcodeCleanSnapshot(
                phase: .idle,
                selectedCategories: snapshot.selectedCategories,
                scanResult: nil,
                executionResult: nil,
                isResultStale: false,
                isXcodeRunning: true,
                errorMessage: nil,
                scanLogEntries: appendLogs(
                    [
                        XcodeCleanScanLogMessage(
                            text: localization.string(
                                "scanLog.xcodeStarted",
                                defaultValue: "Xcode 已启动，操作已中断"
                            ),
                            tone: .warning
                        )
                    ],
                    to: snapshot.scanLogEntries
                )
            )
        } else {
            snapshot = XcodeCleanSnapshot(
                phase: snapshot.phase,
                selectedCategories: snapshot.selectedCategories,
                scanResult: snapshot.scanResult,
                executionResult: snapshot.executionResult,
                isResultStale: snapshot.isResultStale,
                isXcodeRunning: false,
                errorMessage: snapshot.errorMessage,
                scanLogEntries: snapshot.scanLogEntries
            )
        }
    }

    func scan() {
        guard snapshot.canScan else { return }

        cancelTaskOnly()

        let categories = snapshot.selectedCategories
        let operationID = UUID()
        currentOperationID = operationID
        nextLogEntryID = 1
        let buffer = XcodeCleanScanLogBuffer()

        let initialLogs = appendLogs(
            [XcodeCleanScanLogMessage(
                text: localization.format(
                    "scanLog.started",
                    defaultValue: "开始扫描：%@",
                    selectedCategoryTitles(categories)
                ),
                tone: .info
            )],
            to: []
        )

        snapshot = XcodeCleanSnapshot(
            phase: .scanning,
            selectedCategories: categories,
            scanResult: nil,
            executionResult: nil,
            isResultStale: false,
            isXcodeRunning: snapshot.isXcodeRunning,
            errorMessage: nil,
            scanLogEntries: initialLogs
        )
        startScanLogFlushLoop(operationID: operationID, buffer: buffer)

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await scanner.scan(categories: categories) { message in
                    await buffer.append(message)
                }
                guard isCurrentOperation(operationID) else { return }
                await flushLogs(operationID: operationID, buffer: buffer)
                snapshot = XcodeCleanSnapshot(
                    phase: .scanned,
                    selectedCategories: categories,
                    scanResult: result,
                    executionResult: nil,
                    isResultStale: false,
                    isXcodeRunning: snapshot.isXcodeRunning,
                    errorMessage: nil,
                    scanLogEntries: snapshot.scanLogEntries
                )
                finishOperation(operationID)
            } catch is CancellationError {
                guard isCurrentOperation(operationID) else { return }
                await flushLogs(operationID: operationID, buffer: buffer)
                snapshot = XcodeCleanSnapshot(
                    phase: .idle,
                    selectedCategories: categories,
                    scanResult: nil,
                    executionResult: nil,
                    isResultStale: false,
                    isXcodeRunning: snapshot.isXcodeRunning,
                    errorMessage: nil,
                    scanLogEntries: snapshot.scanLogEntries
                )
                finishOperation(operationID)
            } catch {
                guard isCurrentOperation(operationID) else { return }
                await flushLogs(operationID: operationID, buffer: buffer)
                let message = Self.userFacingMessage(for: error)
                snapshot = XcodeCleanSnapshot(
                    phase: .idle,
                    selectedCategories: categories,
                    scanResult: nil,
                    executionResult: nil,
                    isResultStale: false,
                    isXcodeRunning: snapshot.isXcodeRunning,
                    errorMessage: message,
                    scanLogEntries: appendLogs(
                        [
                            XcodeCleanScanLogMessage(
                                text: localization.format(
                                    "scanLog.failed",
                                    defaultValue: "扫描失败：%@",
                                    message
                                ),
                                tone: .error
                            )
                        ],
                        to: snapshot.scanLogEntries
                    )
                )
                finishOperation(operationID)
            }
        }
    }

    func cleanSelected(candidateIDs: Set<XcodeCleanCandidate.ID>) {
        guard snapshot.canClean, let scanResult = snapshot.scanResult else { return }

        cancelTaskOnly()

        let categories = snapshot.selectedCategories
        let operationID = UUID()
        currentOperationID = operationID

        snapshot = XcodeCleanSnapshot(
            phase: .cleaning,
            selectedCategories: categories,
            scanResult: scanResult,
            executionResult: nil,
            isResultStale: false,
            isXcodeRunning: snapshot.isXcodeRunning,
            errorMessage: nil,
            scanLogEntries: snapshot.scanLogEntries
        )

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let executionResult = try await executor.clean(
                    candidates: scanResult.candidates,
                    selectedCandidateIDs: candidateIDs
                )
                guard isCurrentOperation(operationID) else { return }
                snapshot = XcodeCleanSnapshot(
                    phase: .completed,
                    selectedCategories: categories,
                    scanResult: scanResult,
                    executionResult: executionResult,
                    isResultStale: false,
                    isXcodeRunning: snapshot.isXcodeRunning,
                    errorMessage: nil,
                    scanLogEntries: snapshot.scanLogEntries
                )
                finishOperation(operationID)
            } catch is CancellationError {
                guard isCurrentOperation(operationID) else { return }
                snapshot = XcodeCleanSnapshot(
                    phase: .scanned,
                    selectedCategories: categories,
                    scanResult: scanResult,
                    executionResult: nil,
                    isResultStale: false,
                    isXcodeRunning: snapshot.isXcodeRunning,
                    errorMessage: nil,
                    scanLogEntries: snapshot.scanLogEntries
                )
                finishOperation(operationID)
            } catch {
                guard isCurrentOperation(operationID) else { return }
                snapshot = XcodeCleanSnapshot(
                    phase: .scanned,
                    selectedCategories: categories,
                    scanResult: scanResult,
                    executionResult: nil,
                    isResultStale: false,
                    isXcodeRunning: snapshot.isXcodeRunning,
                    errorMessage: Self.userFacingMessage(for: error),
                    scanLogEntries: snapshot.scanLogEntries
                )
                finishOperation(operationID)
            }
        }
    }

    func cancelCurrentOperation() {
        let phase = snapshot.phase
        let categories = snapshot.selectedCategories
        let scanResult = snapshot.scanResult
        let isResultStale = snapshot.isResultStale
        let logs = snapshot.scanLogEntries

        cancelTaskOnly()

        switch phase {
        case .scanning:
            snapshot = XcodeCleanSnapshot(
                phase: .idle,
                selectedCategories: categories,
                scanResult: nil,
                executionResult: nil,
                isResultStale: false,
                isXcodeRunning: snapshot.isXcodeRunning,
                errorMessage: nil,
                scanLogEntries: appendLogs(
                    [
                        XcodeCleanScanLogMessage(
                            text: localization.string("scanLog.stopped", defaultValue: "扫描已停止"),
                            tone: .warning
                        )
                    ],
                    to: logs
                )
            )
        case .cleaning:
            snapshot = XcodeCleanSnapshot(
                phase: .scanned,
                selectedCategories: categories,
                scanResult: scanResult,
                executionResult: nil,
                isResultStale: isResultStale,
                isXcodeRunning: snapshot.isXcodeRunning,
                errorMessage: nil,
                scanLogEntries: logs
            )
        case .idle, .scanned, .completed:
            break
        }
    }

    // MARK: - Private

    private func cancelTaskOnly() {
        currentTask?.cancel()
        currentTask = nil
        currentOperationID = nil
        scanLogFlushTask?.cancel()
        scanLogFlushTask = nil
    }

    private func finishOperation(_ operationID: UUID) {
        guard isCurrentOperation(operationID) else { return }
        currentTask = nil
        currentOperationID = nil
        scanLogFlushTask?.cancel()
        scanLogFlushTask = nil
    }

    private func startScanLogFlushLoop(operationID: UUID, buffer: XcodeCleanScanLogBuffer) {
        scanLogFlushTask?.cancel()
        scanLogFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.scanLogFlushIntervalNanoseconds)
                } catch {
                    break
                }
                await self?.flushLogs(operationID: operationID, buffer: buffer)
            }
        }
    }

    private func flushLogs(operationID: UUID, buffer: XcodeCleanScanLogBuffer) async {
        let messages = await buffer.drain()
        guard isCurrentOperation(operationID), !messages.isEmpty else { return }

        snapshot = XcodeCleanSnapshot(
            phase: snapshot.phase,
            selectedCategories: snapshot.selectedCategories,
            scanResult: snapshot.scanResult,
            executionResult: snapshot.executionResult,
            isResultStale: snapshot.isResultStale,
            isXcodeRunning: snapshot.isXcodeRunning,
            errorMessage: snapshot.errorMessage,
            scanLogEntries: appendLogs(messages, to: snapshot.scanLogEntries)
        )
    }

    private func appendLogs(
        _ messages: [XcodeCleanScanLogMessage],
        to existing: [XcodeCleanScanLogEntry]
    ) -> [XcodeCleanScanLogEntry] {
        guard !messages.isEmpty else { return existing }
        var entries = existing
        entries.reserveCapacity(min(existing.count + messages.count, Self.maxLogEntries))
        for message in messages {
            let entry = XcodeCleanScanLogEntry(
                id: nextLogEntryID,
                text: message.text,
                tone: message.tone
            )
            nextLogEntryID += 1
            entries.append(entry)
        }
        if entries.count > Self.maxLogEntries {
            entries.removeFirst(entries.count - Self.maxLogEntries)
        }
        return entries
    }

    private func isCurrentOperation(_ operationID: UUID) -> Bool {
        currentOperationID == operationID
    }

    private func isStale(
        scanResult: XcodeCleanScanResult?,
        selectedCategories: Set<XcodeCleanCategory>
    ) -> Bool {
        guard let scanResult else { return false }
        return scanResult.categories != selectedCategories
    }

    private func selectedCategoryTitles(_ categories: Set<XcodeCleanCategory>) -> String {
        XcodeCleanCategory.allCases
            .filter { categories.contains($0) }
            .map { $0.title(localization: localization) }
            .joined(separator: "、")
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

private actor XcodeCleanScanLogBuffer {
    private var messages: [XcodeCleanScanLogMessage] = []

    func append(_ message: XcodeCleanScanLogMessage) {
        messages.append(message)
    }

    func drain() -> [XcodeCleanScanLogMessage] {
        defer { messages.removeAll(keepingCapacity: true) }
        return messages
    }
}
