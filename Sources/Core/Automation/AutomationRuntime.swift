import Foundation
import MacToolsPluginKit

@MainActor
protocol AutomationTriggerProviding: AnyObject {
    var kind: AutomationTriggerKind { get }
    var availability: AutomationTriggerAvailability { get }
    func start(handler: @escaping @MainActor (AutomationTriggerEvent) -> Void)
    func stop()
    func refresh(rules: [AutomationRule])
}

extension AutomationTriggerProviding {
    func refresh(rules: [AutomationRule]) {}
}

@MainActor
protocol AutomationEnvironmentSnapshotProviding: AnyObject {
    func snapshot(at date: Date) -> AutomationEnvironmentSnapshot
}

@MainActor
protocol WorkflowStarting: AnyObject {
    func makeExecutionHandle(
        workflowID: UUID,
        source: WorkflowRunSource,
        mode: ActionExecutionMode
    ) -> Result<WorkflowExecutionHandle, WorkflowStartError>
}

extension WorkflowRunner: WorkflowStarting {}

@MainActor
final class AutomationRuntime {
    static let defaultDeduplicationInterval: TimeInterval = 2

    private let ruleStore: AutomationRuleStore
    private let workflowStore: WorkflowStore
    private let workflowStarter: any WorkflowStarting
    private let snapshotProvider: any AutomationEnvironmentSnapshotProviding
    private let providers: [any AutomationTriggerProviding]
    private let evaluator: AutomationRuleEvaluator
    private let now: () -> Date
    private let deduplicationInterval: TimeInterval

    private var lastDelivery: [String: Date] = [:]
    private var activeRuleIDs: Set<UUID> = []
    private var activeHandles: [UUID: ActionExecutionHandle] = [:]
    private(set) var isStarted = false

    var onChange: (() -> Void)?

    init(
        ruleStore: AutomationRuleStore,
        workflowStore: WorkflowStore,
        workflowStarter: any WorkflowStarting,
        snapshotProvider: any AutomationEnvironmentSnapshotProviding,
        providers: [any AutomationTriggerProviding],
        evaluator: AutomationRuleEvaluator = AutomationRuleEvaluator(),
        now: @escaping () -> Date = Date.init,
        deduplicationInterval: TimeInterval = defaultDeduplicationInterval
    ) {
        self.ruleStore = ruleStore
        self.workflowStore = workflowStore
        self.workflowStarter = workflowStarter
        self.snapshotProvider = snapshotProvider
        self.providers = providers
        self.evaluator = evaluator
        self.now = now
        self.deduplicationInterval = deduplicationInterval
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        for provider in providers {
            provider.start { [weak self] event in
                self?.receive(event)
            }
        }
        refreshProviders()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        providers.forEach { $0.stop() }
        activeHandles.values.forEach { $0.cancel() }
        activeHandles.removeAll()
        activeRuleIDs.removeAll()
    }

    func refreshProviders() {
        let rules = ruleStore.rules().filter(\.isEnabled)
        providers.forEach { provider in
            provider.refresh(rules: rules.filter { $0.trigger.kind == provider.kind })
        }
    }

    func availability(for kind: AutomationTriggerKind) -> AutomationTriggerAvailability {
        providers.first { $0.kind == kind }?.availability
            ?? .unavailable(FeatureL10n.string("触发器服务未启动。"))
    }

    func receive(_ event: AutomationTriggerEvent) {
        guard isStarted else { return }
        let eventDate = event.date
        let matchingRules = ruleStore.rules().filter {
            $0.isEnabled
                && $0.trigger.kind == event.kind
                && evaluator.triggerMatches($0.trigger, event: event)
        }
        for rule in matchingRules {
            evaluateAndRun(rule, event: event, eventDate: eventDate)
        }
    }

    private func evaluateAndRun(
        _ rule: AutomationRule,
        event: AutomationTriggerEvent,
        eventDate: Date
    ) {
        let key = "\(rule.id.uuidString):\(event.deduplicationKey)"
        if let previous = lastDelivery[key],
           eventDate.timeIntervalSince(previous) >= 0,
           eventDate.timeIntervalSince(previous) < deduplicationInterval {
            return
        }
        lastDelivery[key] = eventDate
        pruneDeliveries(referenceDate: eventDate)

        guard let workflow = workflowStore.workflow(id: rule.workflowID) else {
            recordSkipped(
                rule: rule,
                event: event,
                workflowName: FeatureL10n.string("不可用工作流"),
                reason: .workflowDoesNotExist
            )
            return
        }
        guard workflow.isEnabled else {
            recordSkipped(
                rule: rule,
                event: event,
                workflowName: workflow.name,
                reason: .workflowDisabled
            )
            return
        }
        guard !activeRuleIDs.contains(rule.id) else {
            recordSkipped(
                rule: rule,
                event: event,
                workflowName: workflow.name,
                reason: .previousRunActive
            )
            return
        }

        let evaluation = evaluator.evaluate(
            conditions: rule.conditions,
            snapshot: snapshotProvider.snapshot(at: eventDate)
        )
        guard evaluation.isSatisfied else {
            recordSkipped(
                rule: rule,
                event: event,
                workflowName: workflow.name,
                reason: evaluation.failureReason ?? .conditionsNotMet
            )
            return
        }

        let source = WorkflowRunSource.automatic(
            ruleID: rule.id,
            triggerKind: event.kind.rawValue
        )
        switch workflowStarter.makeExecutionHandle(
            workflowID: workflow.id,
            source: source,
            mode: .background
        ) {
        case let .success(execution):
            activeRuleIDs.insert(rule.id)
            activeHandles[rule.id] = execution.actionHandle
            Task { @MainActor [weak self] in
                _ = await execution.actionHandle.result()
                self?.activeRuleIDs.remove(rule.id)
                self?.activeHandles.removeValue(forKey: rule.id)
                self?.onChange?()
            }
            onChange?()
        case let .failure(error):
            recordSkipped(
                rule: rule,
                event: event,
                workflowName: workflow.name,
                reason: startErrorMessage(error)
            )
        }
    }

    private func recordSkipped(
        rule: AutomationRule,
        event: AutomationTriggerEvent,
        workflowName: String,
        reason: AutomationRunSkipReason
    ) {
        let timestamp = now()
        _ = workflowStore.record(
            WorkflowRun(
                workflowID: rule.workflowID,
                workflowName: workflowName,
                source: .automatic(ruleID: rule.id, triggerKind: event.kind.rawValue),
                startedAt: timestamp,
                finishedAt: timestamp,
                status: .skipped,
                automationSkippedSummary: AutomationSkippedRunSummary(
                    ruleName: rule.name,
                    reason: reason
                )
            )
        )
        onChange?()
    }

    private func pruneDeliveries(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-max(60, deduplicationInterval * 4))
        lastDelivery = lastDelivery.filter { $0.value >= cutoff }
    }

    private func startErrorMessage(_ error: WorkflowStartError) -> AutomationRunSkipReason {
        switch error {
        case .workflowNotFound: .workflowNotFound
        case .workflowDisabled: .workflowDisabled
        case .emptyWorkflow: .emptyWorkflow
        case .recursiveInvocation: .recursiveInvocation
        case .maximumDepthExceeded: .maximumDepthExceeded
        }
    }
}
