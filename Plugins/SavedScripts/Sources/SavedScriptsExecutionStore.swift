import Combine
import Foundation

@MainActor
final class SavedScriptsExecutionStore: ObservableObject {
    @Published private(set) var recordsByScriptID: [UUID: SavedScriptRunRecord] = [:]
    @Published var selectedScriptID: UUID?

    func record(for scriptID: UUID) -> SavedScriptRunRecord? {
        recordsByScriptID[scriptID]
    }

    func isRunning(_ scriptID: UUID) -> Bool {
        recordsByScriptID[scriptID]?.status == .running
    }

    var isRunningAnyScript: Bool {
        recordsByScriptID.values.contains { $0.status == .running }
    }

    var mostRecentRecord: SavedScriptRunRecord? {
        guard let selectedScriptID else { return nil }
        return recordsByScriptID[selectedScriptID]
    }

    @discardableResult
    func begin(_ script: SavedScript, now: Date = .now) -> UUID {
        let runID = UUID()
        recordsByScriptID[script.id] = SavedScriptRunRecord(
            id: runID,
            scriptID: script.id,
            scriptName: script.name,
            startedAt: now,
            finishedAt: nil,
            status: .running,
            exitCode: nil,
            standardOutput: "",
            standardError: "",
            message: nil,
            outputWasTruncated: false
        )
        selectedScriptID = script.id
        return runID
    }

    func finish(
        scriptID: UUID,
        runID: UUID,
        status: SavedScriptRunStatus,
        result: SavedScriptProcessResult? = nil,
        message: String? = nil,
        now: Date = .now
    ) {
        guard var record = recordsByScriptID[scriptID], record.id == runID else { return }
        record.finishedAt = now
        record.status = status
        record.exitCode = result?.exitCode
        record.standardOutput = result?.standardOutput ?? ""
        record.standardError = result?.standardError ?? ""
        record.message = message
        record.outputWasTruncated = result?.outputWasTruncated ?? false
        recordsByScriptID[scriptID] = record
        selectedScriptID = scriptID
    }

    func removeRecord(for scriptID: UUID) {
        recordsByScriptID.removeValue(forKey: scriptID)
        if selectedScriptID == scriptID { selectedScriptID = nil }
    }
}
