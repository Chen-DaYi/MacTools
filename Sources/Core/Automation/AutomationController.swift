import Combine
import Foundation
import MacToolsPluginKit

@MainActor
final class AutomationController: ObservableObject {
    nonisolated static let providerID = "automation"

    @Published private(set) var workflows: [WorkflowDefinition] = []
    @Published private(set) var rules: [AutomationRule] = []
    @Published private(set) var history: [WorkflowRun] = []
    @Published private(set) var activeRunIDs: Set<UUID> = []
    @Published private(set) var lastErrorMessage: String?

    private let store: WorkflowStore
    private let ruleStore: AutomationRuleStore
    private let registry: ActionRegistry
    private let runner: WorkflowRunner
    private var runtime: AutomationRuntime?
    private let calendarProvider: SystemCalendarAutomationTriggerProvider?
    private var startedHandles: [UUID: ActionExecutionHandle] = [:]

    var onCatalogChange: (() -> Void)?

    init(
        store: WorkflowStore,
        ruleStore: AutomationRuleStore = AutomationRuleStore(),
        registry: ActionRegistry,
        executor: ActionExecutor,
        runner: WorkflowRunner? = nil,
        systemServices: SystemAutomationServices? = nil
    ) {
        self.store = store
        self.ruleStore = ruleStore
        self.registry = registry
        self.runner = runner ?? WorkflowRunner(
            store: store,
            registry: registry,
            executor: executor
        )
        self.calendarProvider = systemServices?.calendarProvider
        if let systemServices {
            self.runtime = AutomationRuntime(
                ruleStore: ruleStore,
                workflowStore: store,
                workflowStarter: self.runner,
                snapshotProvider: systemServices.snapshotProvider,
                providers: systemServices.providers
            )
        }
        self.runner.onRunChange = { [weak self] in
            self?.reloadRuntimeSnapshots()
        }
        self.runtime?.onChange = { [weak self] in
            self?.reloadRuntimeSnapshots()
        }
        reloadAll()
    }

    func startAutomaticRules() {
        runtime?.start()
    }

    func stopAutomaticRules() {
        runtime?.stop()
    }

    @discardableResult
    func createWorkflow() -> WorkflowDefinition? {
        switch store.create() {
        case let .success(workflow):
            finishDefinitionMutation()
            return workflow
        case let .failure(error):
            record(error)
            return nil
        }
    }

    @discardableResult
    func duplicateWorkflow(id: UUID) -> WorkflowDefinition? {
        switch store.duplicate(id: id) {
        case let .success(workflow):
            finishDefinitionMutation()
            return workflow
        case let .failure(error):
            record(error)
            return nil
        }
    }

    @discardableResult
    func deleteWorkflow(id: UUID) -> Bool {
        let existingRules = ruleStore.rules()
        let retainedRules = existingRules.filter { $0.workflowID != id }
        guard retainedRules == existingRules || ruleStore.replace(retainedRules) else {
            lastErrorMessage = "无法删除相关自动规则。"
            return false
        }
        guard store.delete(id: id) else {
            if retainedRules != existingRules {
                _ = ruleStore.replace(existingRules)
            }
            lastErrorMessage = "无法删除工作流。"
            return false
        }
        finishDefinitionMutation()
        return true
    }

    func moveWorkflow(id: UUID, offset: Int) {
        guard store.move(id: id, offset: offset) else {
            lastErrorMessage = "无法调整工作流顺序。"
            return
        }
        finishDefinitionMutation()
    }

    @discardableResult
    func createRule(workflowID: UUID) -> AutomationRule? {
        switch ruleStore.create(workflowID: workflowID) {
        case let .success(rule):
            finishRuleMutation()
            return rule
        case let .failure(error):
            record(error)
            return nil
        }
    }

    @discardableResult
    func duplicateRule(id: UUID) -> AutomationRule? {
        switch ruleStore.duplicate(id: id) {
        case let .success(rule):
            finishRuleMutation()
            return rule
        case let .failure(error):
            record(error)
            return nil
        }
    }

    func deleteRule(id: UUID) {
        guard ruleStore.delete(id: id) else { return }
        finishRuleMutation()
    }

    func saveRule(_ rule: AutomationRule) {
        switch ruleStore.upsert(rule) {
        case .success:
            finishRuleMutation()
        case let .failure(error):
            record(error)
        }
    }

    func rules(workflowID: UUID) -> [AutomationRule] {
        rules.filter { $0.workflowID == workflowID }
    }

    func triggerAvailability(for kind: AutomationTriggerKind) -> AutomationTriggerAvailability {
        runtime?.availability(for: kind) ?? .unavailable("触发器服务未启动。")
    }

    func requestCalendarAccess() async {
        _ = await calendarProvider?.requestAccess()
        runtime?.refreshProviders()
        objectWillChange.send()
    }

    func setWorkflowEnabled(_ isEnabled: Bool, id: UUID) {
        mutateWorkflow(id: id) { $0.isEnabled = isEnabled }
    }

    func renameWorkflow(id: UUID, name: String) {
        mutateWorkflow(id: id) { $0.name = name }
    }

    func setWorkflowIcon(id: UUID, systemImage: String) {
        mutateWorkflow(id: id) { $0.systemImage = systemImage }
    }

    func addStep(workflowID: UUID, reference: ActionReference) {
        mutateWorkflow(id: workflowID) { workflow in
            guard workflow.steps.count < WorkflowDefinition.maximumStepCount else {
                return
            }
            workflow.steps.append(WorkflowStep(reference: reference))
        }
    }

    func replaceStepReference(
        workflowID: UUID,
        stepID: UUID,
        reference: ActionReference
    ) {
        mutateStep(workflowID: workflowID, stepID: stepID) { step in
            step.reference = reference
        }
    }

    func updateStep(
        workflowID: UUID,
        stepID: UUID,
        label: String?,
        delaySeconds: Double,
        errorPolicy: WorkflowStepErrorPolicy
    ) {
        mutateStep(workflowID: workflowID, stepID: stepID) { step in
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            step.label = trimmed?.isEmpty == false ? trimmed : nil
            step.delaySeconds = min(
                max(0, delaySeconds),
                WorkflowStep.maximumDelaySeconds
            )
            step.errorPolicy = errorPolicy
        }
    }

    func removeStep(workflowID: UUID, stepID: UUID) {
        mutateWorkflow(id: workflowID) { workflow in
            workflow.steps.removeAll { $0.id == stepID }
        }
    }

    func moveStep(workflowID: UUID, stepID: UUID, offset: Int) {
        mutateWorkflow(id: workflowID) { workflow in
            guard let source = workflow.steps.firstIndex(where: { $0.id == stepID }) else {
                return
            }
            let destination = source + offset
            guard workflow.steps.indices.contains(destination) else {
                return
            }
            let step = workflow.steps.remove(at: source)
            workflow.steps.insert(step, at: destination)
        }
    }

    @discardableResult
    func startWorkflow(
        id: UUID,
        test: Bool = false,
        mode: ActionExecutionMode = .foreground
    ) -> UUID? {
        let source: WorkflowRunSource = test ? .test : .manual
        switch runner.makeExecutionHandle(workflowID: id, source: source, mode: mode) {
        case let .success(execution):
            startedHandles[execution.runID] = execution.actionHandle
            Task { @MainActor [weak self] in
                _ = await execution.actionHandle.result()
                self?.startedHandles.removeValue(forKey: execution.runID)
                self?.reloadRuntimeSnapshots()
            }
            reloadRuntimeSnapshots()
            return execution.runID
        case let .failure(error):
            lastErrorMessage = message(for: error)
            return nil
        }
    }

    func cancel(runID: UUID) {
        runner.cancel(runID: runID)
    }

    func activeRunIDs(for workflowID: UUID) -> [UUID] {
        history.compactMap { run in
            run.workflowID == workflowID && activeRunIDs.contains(run.id) ? run.id : nil
        }
    }

    func recentRuns(workflowID: UUID, limit: Int = 20) -> [WorkflowRun] {
        Array(history.lazy.filter { $0.workflowID == workflowID }.prefix(max(0, limit)))
    }

    func definition(for reference: ActionReference) -> ActionDefinition? {
        registry.definition(for: reference.key)
    }

    func catalogEntry(for reference: ActionReference) -> ActionCatalogEntry? {
        guard case let .success(action) = registry.registeredAction(for: reference) else {
            return nil
        }
        return action.catalogEntry
    }

    func availability(for reference: ActionReference) -> ActionAvailability {
        registry.availability(for: reference)
    }

    func actionRegistration() -> ActionProviderRegistration {
        let enabled = workflows.filter(\.isEnabled)
        let definitions = enabled.map { workflow in
            ActionDefinition(
                key: workflow.actionKey,
                title: "运行“\(workflow.name)”",
                description: "依次执行 \(workflow.steps.count) 个工作流步骤。",
                keywords: ["工作流", "自动化", workflow.name],
                systemImage: workflow.systemImage,
                externalInvocationPolicy: .allowed,
                capabilities: [.background, .foregroundInteractive, .cancellable],
                executionTimeoutSeconds: nil
            )
        }
        let catalogEntries = enabled.map { workflow in
            ActionCatalogEntry(
                reference: workflow.actionReference,
                title: "运行“\(workflow.name)”",
                subtitle: "自动化 · \(workflow.steps.count) 个步骤"
            )
        }
        return ActionProviderRegistration(
            providerID: Self.providerID,
            identity: ObjectIdentifier(self),
            definitions: definitions,
            catalogEntries: catalogEntries,
            availability: { [weak self] reference in
                self?.workflowActionAvailability(reference)
                    ?? .unavailable("自动化服务不可用。")
            },
            begin: { [weak self] invocation in
                guard let self,
                      let workflowID = self.workflowID(for: invocation.reference.key) else {
                    return .failure(.providerFailure("找不到工作流。"))
                }
                let source = WorkflowRunSource.publishedAction(invocation.source)
                switch self.runner.makeExecutionHandle(
                    workflowID: workflowID,
                    source: source,
                    mode: invocation.mode
                ) {
                case let .success(execution):
                    return .success(execution.actionHandle)
                case let .failure(error):
                    return .failure(.providerFailure(self.message(for: error)))
                }
            }
        )
    }

    @discardableResult
    func migrateReferencesIfNeeded() -> Bool {
        guard store.migrateReferences(using: registry) else {
            return false
        }
        workflows = store.workflows()
        objectWillChange.send()
        return true
    }

    func exportWorkflow(id: UUID) -> Result<Data, WorkflowStoreError> {
        store.exportWorkflow(id: id, registry: registry)
    }

    @discardableResult
    func importWorkflow(_ data: Data) -> WorkflowDefinition? {
        switch store.importWorkflow(data) {
        case let .success(workflow):
            finishDefinitionMutation()
            return workflow
        case let .failure(error):
            record(error)
            return nil
        }
    }

    private func mutateWorkflow(
        id: UUID,
        mutation: (inout WorkflowDefinition) -> Void
    ) {
        guard var workflow = store.workflow(id: id) else {
            lastErrorMessage = "找不到工作流。"
            return
        }
        mutation(&workflow)
        switch store.upsert(workflow) {
        case .success:
            finishDefinitionMutation()
        case let .failure(error):
            record(error)
        }
    }

    private func mutateStep(
        workflowID: UUID,
        stepID: UUID,
        mutation: (inout WorkflowStep) -> Void
    ) {
        mutateWorkflow(id: workflowID) { workflow in
            guard let index = workflow.steps.firstIndex(where: { $0.id == stepID }) else {
                return
            }
            mutation(&workflow.steps[index])
        }
    }

    private func finishDefinitionMutation() {
        lastErrorMessage = nil
        reloadAll()
        onCatalogChange?()
    }

    private func finishRuleMutation() {
        lastErrorMessage = nil
        rules = ruleStore.rules()
        runtime?.refreshProviders()
    }

    private func reloadAll() {
        workflows = store.workflows()
        rules = ruleStore.rules()
        reloadRuntimeSnapshots()
    }

    private func reloadRuntimeSnapshots() {
        history = store.history()
        activeRunIDs = runner.activeRunIDs
    }

    private func workflowActionAvailability(_ reference: ActionReference) -> ActionAvailability {
        guard let currentWorkflowID = workflowID(for: reference.key),
              let workflow = store.workflow(id: currentWorkflowID),
              workflow.isEnabled else {
            return .unavailable("工作流已停用或不存在。")
        }
        guard !workflow.steps.isEmpty else {
            return .unavailable("工作流尚未添加步骤。")
        }
        for step in workflow.steps {
            if step.reference.key == workflow.actionKey {
                return .unavailable("工作流不能调用自身。")
            }
            if step.reference.key.providerID == Self.providerID {
                guard let nestedID = workflowID(for: step.reference.key),
                      let nested = store.workflow(id: nestedID),
                      nested.isEnabled,
                      !nested.steps.isEmpty else {
                    return .unavailable("嵌套工作流不可用。")
                }
                continue
            }
            guard case let .success(reference) = registry.migrate(step.reference),
                  case .success = registry.registeredAction(for: reference) else {
                return .unavailable("工作流包含不可用操作。")
            }
            let availability = registry.availability(for: reference)
            if !availability.isAvailable {
                return .unavailable(availability.reason ?? "工作流包含不可用操作。")
            }
        }
        return .available
    }

    private func workflowID(for key: ActionKey) -> UUID? {
        guard key.providerID == Self.providerID,
              key.actionID.hasPrefix("workflow.") else {
            return nil
        }
        return UUID(uuidString: String(key.actionID.dropFirst("workflow.".count)))
    }

    private func record(_ error: WorkflowStoreError) {
        lastErrorMessage = switch error {
        case let .invalidWorkflow(reason): "工作流无效：\(reason)"
        case .workflowNotFound: "找不到工作流。"
        case .maximumWorkflowCountReached: "工作流数量已达上限。"
        case .persistenceFailed: "无法保存工作流。"
        case .unsafeForExport: "工作流包含不可安全导出的参数。"
        case .invalidImport: "工作流文件无效。"
        }
    }

    private func record(_ error: AutomationRuleStoreError) {
        lastErrorMessage = switch error {
        case let .invalidRule(reason): "自动规则无效：\(reason)"
        case .ruleNotFound: "找不到自动规则。"
        case .maximumRuleCountReached: "自动规则数量已达上限。"
        case .persistenceFailed: "无法保存自动规则。"
        }
    }

    private func message(for error: WorkflowStartError) -> String {
        switch error {
        case .workflowNotFound: "找不到工作流。"
        case .workflowDisabled: "工作流已停用。"
        case .emptyWorkflow: "工作流尚未添加步骤。"
        case .recursiveInvocation: "检测到递归工作流调用。"
        case .maximumDepthExceeded: "工作流嵌套层级已达上限。"
        }
    }
}
