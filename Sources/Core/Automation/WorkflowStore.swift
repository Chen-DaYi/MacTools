import Foundation
import MacToolsPluginKit

@MainActor
final class WorkflowStore {
    private struct WorkflowEnvelope: Codable {
        let formatVersion: Int
        let workflows: [WorkflowDefinition]
    }

    private struct HistoryEnvelope: Codable {
        let formatVersion: Int
        let runs: [WorkflowRun]
    }

    private struct PortableWorkflowEnvelope: Codable {
        let formatVersion: Int
        let workflow: WorkflowDefinition
    }

    private enum DefaultsKey {
        static let workflows = "automation.workflows.v1"
        static let history = "automation.history.v1"
    }

    static let maximumWorkflowCount = 128
    static let maximumHistoryCount = 256
    static let maximumPayloadByteCount = 2 * 1_024 * 1_024

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var workflowLoadError: String?
    private(set) var historyLoadError: String?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        recoverInterruptedRuns()
    }

    func workflows() -> [WorkflowDefinition] {
        guard let data = userDefaults.data(forKey: DefaultsKey.workflows) else {
            workflowLoadError = nil
            return []
        }
        guard data.count <= Self.maximumPayloadByteCount else {
            workflowLoadError = "workflow-payload-too-large"
            return []
        }
        do {
            let envelope = try decoder.decode(WorkflowEnvelope.self, from: data)
            guard envelope.formatVersion == WorkflowDefinition.currentFormatVersion,
                  validate(envelope.workflows) == nil else {
                workflowLoadError = "invalid-workflow-format"
                return []
            }
            workflowLoadError = nil
            return envelope.workflows
        } catch {
            workflowLoadError = "invalid-workflow-payload"
            return []
        }
    }

    func workflow(id: UUID) -> WorkflowDefinition? {
        workflows().first { $0.id == id }
    }

    @discardableResult
    func create(name: String = FeatureL10n.string("新建工作流")) -> Result<WorkflowDefinition, WorkflowStoreError> {
        var stored = workflows()
        guard stored.count < Self.maximumWorkflowCount else {
            return .failure(.maximumWorkflowCountReached)
        }
        let workflow = WorkflowDefinition(name: name)
        stored.append(workflow)
        guard replaceWorkflows(stored) else {
            return .failure(.persistenceFailed)
        }
        return .success(workflow)
    }

    @discardableResult
    func upsert(_ workflow: WorkflowDefinition) -> Result<WorkflowDefinition, WorkflowStoreError> {
        if let failure = validate(workflow) {
            return .failure(.invalidWorkflow(failure))
        }
        var stored = workflows()
        var updated = workflow
        updated.updatedAt = .now
        if let index = stored.firstIndex(where: { $0.id == workflow.id }) {
            stored[index] = updated
        } else {
            guard stored.count < Self.maximumWorkflowCount else {
                return .failure(.maximumWorkflowCountReached)
            }
            stored.append(updated)
        }
        guard replaceWorkflows(stored) else {
            return .failure(.persistenceFailed)
        }
        return .success(updated)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        var stored = workflows()
        let oldCount = stored.count
        stored.removeAll { $0.id == id }
        return stored.count != oldCount && replaceWorkflows(stored)
    }

    func duplicate(id: UUID) -> Result<WorkflowDefinition, WorkflowStoreError> {
        guard let source = workflow(id: id) else {
            return .failure(.workflowNotFound)
        }
        var copy = WorkflowDefinition(
            name: byteLimited(
                source.name + FeatureL10n.string(" 副本"),
                maximumByteCount: WorkflowDefinition.maximumNameByteCount
            ),
            systemImage: source.systemImage,
            isEnabled: source.isEnabled,
            steps: source.steps.map {
                WorkflowStep(
                    reference: $0.reference,
                    label: $0.label,
                    delaySeconds: $0.delaySeconds,
                    errorPolicy: $0.errorPolicy
                )
            }
        )
        copy.updatedAt = .now
        return upsert(copy)
    }

    @discardableResult
    func move(id: UUID, offset: Int) -> Bool {
        var stored = workflows()
        guard let source = stored.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let destination = source + offset
        guard stored.indices.contains(destination) else {
            return false
        }
        let workflow = stored.remove(at: source)
        stored.insert(workflow, at: destination)
        return replaceWorkflows(stored)
    }

    private func byteLimited(_ value: String, maximumByteCount: Int) -> String {
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumByteCount else {
                break
            }
            result = candidate
        }
        return result
    }

    @discardableResult
    func replaceWorkflows(_ workflows: [WorkflowDefinition]) -> Bool {
        guard validate(workflows) == nil else {
            return false
        }
        do {
            let data = try encoder.encode(
                WorkflowEnvelope(
                    formatVersion: WorkflowDefinition.currentFormatVersion,
                    workflows: workflows
                )
            )
            guard data.count <= Self.maximumPayloadByteCount else {
                return false
            }
            userDefaults.set(data, forKey: DefaultsKey.workflows)
            return userDefaults.data(forKey: DefaultsKey.workflows) == data
        } catch {
            return false
        }
    }

    @discardableResult
    func migrateReferences(using registry: ActionRegistry) -> Bool {
        var stored = workflows()
        var changed = false
        for workflowIndex in stored.indices {
            for stepIndex in stored[workflowIndex].steps.indices {
                let reference = stored[workflowIndex].steps[stepIndex].reference
                guard case let .success(migrated) = registry.migrate(reference),
                      migrated != reference else {
                    continue
                }
                stored[workflowIndex].steps[stepIndex].reference = migrated
                stored[workflowIndex].updatedAt = .now
                changed = true
            }
        }
        guard changed else {
            return false
        }
        return replaceWorkflows(stored)
    }

    func history(workflowID: UUID? = nil) -> [WorkflowRun] {
        guard let data = userDefaults.data(forKey: DefaultsKey.history) else {
            historyLoadError = nil
            return []
        }
        guard data.count <= Self.maximumPayloadByteCount else {
            historyLoadError = "history-payload-too-large"
            return []
        }
        do {
            let envelope = try decoder.decode(HistoryEnvelope.self, from: data)
            guard envelope.formatVersion == WorkflowRun.currentFormatVersion,
                  envelope.runs.count <= Self.maximumHistoryCount,
                  Set(envelope.runs.map(\.id)).count == envelope.runs.count,
                  envelope.runs.allSatisfy({ $0.formatVersion == WorkflowRun.currentFormatVersion })
            else {
                historyLoadError = "invalid-history-format"
                return []
            }
            historyLoadError = nil
            let runs = migrateLegacyHistory(envelope.runs)
            if runs != envelope.runs {
                _ = replaceHistory(runs)
            }
            if let workflowID {
                return runs.filter { $0.workflowID == workflowID }
            }
            return runs
        } catch {
            historyLoadError = "invalid-history-payload"
            return []
        }
    }

    @discardableResult
    func record(_ run: WorkflowRun) -> Bool {
        let sanitizedRun = migrateLegacyHistory([run])[0]
        var runs = history()
        runs.removeAll { $0.id == sanitizedRun.id }
        runs.insert(sanitizedRun, at: 0)
        if runs.count > Self.maximumHistoryCount {
            runs.removeLast(runs.count - Self.maximumHistoryCount)
        }
        return replaceHistory(runs)
    }

    func exportWorkflow(
        id: UUID,
        registry: ActionRegistry
    ) -> Result<Data, WorkflowStoreError> {
        guard let workflow = workflow(id: id) else {
            return .failure(.workflowNotFound)
        }
        for step in workflow.steps {
            guard case let .success(action) = registry.registeredAction(for: step.reference) else {
                return .failure(.unsafeForExport)
            }
            let schemas = Dictionary(
                uniqueKeysWithValues: action.definition.parameters.map { ($0.id, $0) }
            )
            guard step.reference.parameters.entries.allSatisfy({ entry in
                schemas[entry.name]?.privacy == .publicValue
                    && schemas[entry.name]?.portability == .portable
            }) else {
                return .failure(.unsafeForExport)
            }
        }
        do {
            let data = try encoder.encode(
                PortableWorkflowEnvelope(
                    formatVersion: WorkflowDefinition.currentFormatVersion,
                    workflow: workflow
                )
            )
            guard data.count <= Self.maximumPayloadByteCount else {
                return .failure(.invalidWorkflow("payload-too-large"))
            }
            return .success(data)
        } catch {
            return .failure(.persistenceFailed)
        }
    }

    func importWorkflow(_ data: Data) -> Result<WorkflowDefinition, WorkflowStoreError> {
        guard data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(PortableWorkflowEnvelope.self, from: data),
              envelope.formatVersion == WorkflowDefinition.currentFormatVersion,
              validate(envelope.workflow) == nil else {
            return .failure(.invalidImport)
        }
        let imported = WorkflowDefinition(
            name: envelope.workflow.name,
            systemImage: envelope.workflow.systemImage,
            isEnabled: envelope.workflow.isEnabled,
            steps: envelope.workflow.steps.map {
                WorkflowStep(
                    reference: $0.reference,
                    label: $0.label,
                    delaySeconds: $0.delaySeconds,
                    errorPolicy: $0.errorPolicy
                )
            }
        )
        return upsert(imported)
    }

    private func replaceHistory(_ runs: [WorkflowRun]) -> Bool {
        do {
            let data = try encoder.encode(
                HistoryEnvelope(
                    formatVersion: WorkflowRun.currentFormatVersion,
                    runs: runs
                )
            )
            guard data.count <= Self.maximumPayloadByteCount else {
                return false
            }
            userDefaults.set(data, forKey: DefaultsKey.history)
            return userDefaults.data(forKey: DefaultsKey.history) == data
        } catch {
            return false
        }
    }

    private func recoverInterruptedRuns() {
        var runs = history()
        var changed = false
        for index in runs.indices where runs[index].status == .running {
            runs[index].status = .interrupted
            runs[index].finishedAt = .now
            runs[index].summaryLocalizationKey = .interruptedByExit
            runs[index].summary = WorkflowHistoryLocalizationKey.interruptedByExit.localizedText
            changed = true
        }
        if changed {
            _ = replaceHistory(runs)
        }
    }

    private func migrateLegacyHistory(_ storedRuns: [WorkflowRun]) -> [WorkflowRun] {
        let currentStepsByWorkflowID = Dictionary(
            uniqueKeysWithValues: workflows().map { workflow in
                (
                    workflow.id,
                    Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
                )
            }
        )
        var runs = storedRuns
        for runIndex in runs.indices {
            if runs[runIndex].summaryLocalizationKey == nil,
               let summary = runs[runIndex].summary,
               let key = WorkflowHistoryLocalizationKey(rawValue: summary) {
                runs[runIndex].summaryLocalizationKey = key
            }
            for resultIndex in runs[runIndex].stepResults.indices {
                let currentStep = currentStepsByWorkflowID[runs[runIndex].workflowID]?[
                    runs[runIndex].stepResults[resultIndex].stepID
                ]
                let currentLabel = currentStep?.label
                runs[runIndex].stepResults[resultIndex].titleSource =
                    currentLabel?.isEmpty == false
                        && runs[runIndex].stepResults[resultIndex].title == currentLabel
                            ? .custom
                            : .action
                let existingReference = runs[runIndex].stepResults[resultIndex].actionReference
                let presentationReference = ActionReference(
                    key: runs[runIndex].stepResults[resultIndex].actionKey,
                    schemaVersion: existingReference?.schemaVersion
                        ?? currentStep?.reference.schemaVersion
                        ?? 1
                )
                if existingReference != presentationReference {
                    runs[runIndex].stepResults[resultIndex].actionReference = presentationReference
                }
                if runs[runIndex].stepResults[resultIndex].titleSource == .action,
                   runs[runIndex].stepResults[resultIndex].title
                    != runs[runIndex].stepResults[resultIndex].actionKey.id {
                    runs[runIndex].stepResults[resultIndex].title =
                        runs[runIndex].stepResults[resultIndex].actionKey.id
                }
                if runs[runIndex].stepResults[resultIndex].messageLocalizationKey == nil,
                   let message = runs[runIndex].stepResults[resultIndex].message,
                   let key = WorkflowHistoryLocalizationKey(rawValue: message) {
                    runs[runIndex].stepResults[resultIndex].messageLocalizationKey = key
                }
            }
        }
        return runs
    }

    private func validate(_ workflows: [WorkflowDefinition]) -> String? {
        guard workflows.count <= Self.maximumWorkflowCount,
              Set(workflows.map(\.id)).count == workflows.count else {
            return "workflow-count-or-id"
        }
        return workflows.lazy.compactMap(validate).first
    }

    private func validate(_ workflow: WorkflowDefinition) -> String? {
        let trimmedName = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard workflow.formatVersion == WorkflowDefinition.currentFormatVersion,
              !trimmedName.isEmpty,
              workflow.name.utf8.count <= WorkflowDefinition.maximumNameByteCount,
              !workflow.systemImage.isEmpty,
              workflow.systemImage.utf8.count <= 128,
              workflow.steps.count <= WorkflowDefinition.maximumStepCount,
              Set(workflow.steps.map(\.id)).count == workflow.steps.count else {
            return "workflow-fields"
        }
        for step in workflow.steps {
            guard step.delaySeconds.isFinite,
                  (0 ... WorkflowStep.maximumDelaySeconds).contains(step.delaySeconds),
                  (step.label?.utf8.count ?? 0) <= WorkflowStep.maximumLabelByteCount else {
                return "step-fields"
            }
        }
        return nil
    }
}
