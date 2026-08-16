import Combine
import Foundation

@MainActor
final class AppleShortcutsExecutionStore: ObservableObject {
    @Published private(set) var recordsByShortcutID: [UUID: AppleShortcutRunRecord] = [:]

    func record(for shortcutID: UUID) -> AppleShortcutRunRecord? {
        recordsByShortcutID[shortcutID]
    }

    func isRunning(_ shortcutID: UUID) -> Bool {
        recordsByShortcutID[shortcutID]?.status == .running
    }

    @discardableResult
    func begin(shortcutID: UUID, name: String, now: Date = .now) -> UUID {
        let runID = UUID()
        recordsByShortcutID[shortcutID] = AppleShortcutRunRecord(
            id: runID,
            shortcutID: shortcutID,
            shortcutName: name,
            startedAt: now,
            finishedAt: nil,
            status: .running,
            exitCode: nil,
            standardOutput: "",
            standardError: "",
            message: nil,
            outputWasTruncated: false
        )
        return runID
    }

    func finish(
        shortcutID: UUID,
        runID: UUID,
        status: AppleShortcutRunStatus,
        result: AppleShortcutsCommandResult? = nil,
        message: String? = nil,
        now: Date = .now
    ) {
        guard var record = recordsByShortcutID[shortcutID], record.id == runID else { return }
        record.finishedAt = now
        record.status = status
        record.exitCode = result?.exitCode
        record.standardOutput = result?.standardOutput ?? ""
        record.standardError = result?.standardError ?? ""
        record.message = message
        record.outputWasTruncated = result?.outputWasTruncated ?? false
        recordsByShortcutID[shortcutID] = record
    }

    func clear() {
        recordsByShortcutID.removeAll()
    }
}
