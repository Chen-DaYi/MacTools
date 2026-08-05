import Foundation
import MacToolsPluginKit

@MainActor
protocol WorkflowSleeping: AnyObject {
    func sleep(seconds: Double) async throws
}

@MainActor
final class SystemWorkflowSleeper: WorkflowSleeping {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

@MainActor
final class WorkflowRunner {
    static let maximumExecutionDepth = 8

    private let store: WorkflowStore
    private let registry: ActionRegistry
    private let executor: ActionExecutor
    private let sleeper: any WorkflowSleeping
    private let now: () -> Date
    private var cancelledRunIDs: Set<UUID> = []
    private(set) var activeRunIDs: Set<UUID> = []
    private var executionHandles: [UUID: ActionExecutionHandle] = [:]

    var onRunChange: (() -> Void)?

    init(
        store: WorkflowStore,
        registry: ActionRegistry,
        executor: ActionExecutor,
        sleeper: any WorkflowSleeping = SystemWorkflowSleeper(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.registry = registry
        self.executor = executor
        self.sleeper = sleeper
        self.now = now
    }

    func makeExecutionHandle(
        workflowID: UUID,
        source: WorkflowRunSource,
        mode: ActionExecutionMode
    ) -> Result<WorkflowExecutionHandle, WorkflowStartError> {
        guard let workflow = store.workflow(id: workflowID) else {
            return .failure(.workflowNotFound)
        }
        guard workflow.isEnabled || source == .test else {
            return .failure(.workflowDisabled)
        }
        guard !workflow.steps.isEmpty else {
            return .failure(.emptyWorkflow)
        }

        let runID = UUID()
        let actionHandle = ActionExecutionHandle(
            operation: { [weak self] in
                guard let self else {
                    return .failed(message: FeatureL10n.string("工作流运行器不可用。"))
                }
                return await self.execute(
                    runID: runID,
                    workflowID: workflowID,
                    source: source,
                    mode: mode
                )
            },
            cancel: { [weak self] in
                self?.cancelledRunIDs.insert(runID)
            }
        )
        executionHandles[runID] = actionHandle
        return .success(WorkflowExecutionHandle(runID: runID, actionHandle: actionHandle))
    }

    func cancel(runID: UUID) {
        cancelledRunIDs.insert(runID)
        executionHandles[runID]?.cancel()
    }

    private func execute(
        runID: UUID,
        workflowID: UUID,
        source: WorkflowRunSource,
        mode: ActionExecutionMode
    ) async -> ActionExecutionResult {
        defer {
            cancelledRunIDs.remove(runID)
            executionHandles.removeValue(forKey: runID)
        }
        guard let workflow = store.workflow(id: workflowID) else {
            return .failed(message: FeatureL10n.string("找不到工作流。"))
        }
        let stack = WorkflowExecutionContext.workflowStack
        if stack.contains(workflowID) {
            recordRejectedRun(
                runID: runID,
                workflow: workflow,
                source: source,
                summaryLocalizationKey: .recursiveInvocation
            )
            return .failed(message: FeatureL10n.string("检测到递归工作流调用。"))
        }
        if stack.count >= Self.maximumExecutionDepth {
            recordRejectedRun(
                runID: runID,
                workflow: workflow,
                source: source,
                summaryLocalizationKey: .maximumDepthExceeded
            )
            return .failed(message: FeatureL10n.string("工作流嵌套层级已达上限。"))
        }

        return await WorkflowExecutionContext.$workflowStack.withValue(stack + [workflowID]) {
            await executeSteps(
                runID: runID,
                workflow: workflow,
                source: source,
                mode: mode
            )
        }
    }

    private func executeSteps(
        runID: UUID,
        workflow: WorkflowDefinition,
        source: WorkflowRunSource,
        mode: ActionExecutionMode
    ) async -> ActionExecutionResult {
        activeRunIDs.insert(runID)
        var run = WorkflowRun(
            id: runID,
            workflowID: workflow.id,
            workflowName: workflow.name,
            source: source,
            startedAt: now()
        )
        _ = store.record(run)
        onRunChange?()

        defer {
            activeRunIDs.remove(runID)
            onRunChange?()
        }

        var hadFailure = false
        for (index, originalStep) in workflow.steps.enumerated() {
            if isCancelled(runID: runID) {
                appendCancelledAndSkipped(
                    currentStep: originalStep,
                    remainingSteps: workflow.steps.dropFirst(index + 1),
                    to: &run
                )
                finish(&run, status: .cancelled, summaryLocalizationKey: .workflowCancelled)
                return .cancelled
            }

            if originalStep.delaySeconds > 0 {
                do {
                    try await sleeper.sleep(seconds: originalStep.delaySeconds)
                } catch {
                    appendCancelledAndSkipped(
                        currentStep: originalStep,
                        remainingSteps: workflow.steps.dropFirst(index + 1),
                        to: &run
                    )
                    finish(&run, status: .cancelled, summaryLocalizationKey: .workflowCancelled)
                    return .cancelled
                }
            }

            let stepStart = now()
            let reference: ActionReference
            switch registry.migrate(originalStep.reference) {
            case let .success(migrated):
                reference = migrated
            case .failure:
                let result = stepResult(
                    for: originalStep,
                    startedAt: stepStart,
                    status: .unavailable,
                    messageLocalizationKey: .actionVersionUnavailable
                )
                run.stepResults.append(result)
                _ = store.record(run)
                onRunChange?()
                hadFailure = true
                if originalStep.errorPolicy == .stop {
                    appendSkipped(workflow.steps.dropFirst(index + 1), to: &run)
                    finish(&run, status: .failed, summaryLocalizationKey: .requiredActionUnavailable)
                    return .failed(message: FeatureL10n.string("必需操作不可用。"))
                }
                continue
            }

            let stepMode = executionMode(for: reference, requestedMode: mode)
            let outcome = await executor.execute(
                ActionInvocation(reference: reference, source: .workflow, mode: stepMode)
            )
            let result = stepResult(
                for: originalStep,
                startedAt: stepStart,
                outcome: outcome
            )
            run.stepResults.append(result)
            _ = store.record(run)
            onRunChange?()

            switch result.status {
            case .succeeded:
                continue
            case .cancelled:
                appendSkipped(workflow.steps.dropFirst(index + 1), to: &run)
                finish(&run, status: .cancelled, summaryLocalizationKey: .workflowCancelled)
                return .cancelled
            case .failed, .timedOut, .unavailable, .skipped:
                hadFailure = true
                if originalStep.errorPolicy == .stop {
                    appendSkipped(workflow.steps.dropFirst(index + 1), to: &run)
                    finish(&run, status: .failed, summaryLocalizationKey: .stoppedAtFailedStep)
                    return .failed(message: FeatureL10n.string("工作流在失败步骤处停止。"))
                }
            }
        }

        if hadFailure {
            finish(&run, status: .failed, summaryLocalizationKey: .completedWithFailures)
            return .failed(message: FeatureL10n.string("部分步骤失败。"))
        }
        finish(&run, status: .succeeded, summaryLocalizationKey: .completed)
        return .succeeded()
    }

    private func executionMode(
        for reference: ActionReference,
        requestedMode: ActionExecutionMode
    ) -> ActionExecutionMode {
        guard requestedMode == .foreground,
              let definition = registry.definition(for: reference.key),
              definition.capabilities.contains(.foregroundInteractive) else {
            return .background
        }
        return .foreground
    }

    private func stepResult(
        for step: WorkflowStep,
        startedAt: Date,
        outcome: ActionExecutionOutcome
    ) -> WorkflowStepRunResult {
        switch outcome {
        case .completed(.succeeded):
            return stepResult(for: step, startedAt: startedAt, status: .succeeded)
        case .completed(.failed):
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .failed,
                messageLocalizationKey: .actionFailed
            )
        case .completed(.cancelled):
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .cancelled,
                messageLocalizationKey: .actionCancelled
            )
        case .rejected(.executionTimedOut), .rejected(.confirmationTimedOut):
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .timedOut,
                messageLocalizationKey: .actionTimedOut
            )
        case .rejected(.unknownAction), .rejected(.unavailable),
             .rejected(.backgroundExecutionUnsupported),
             .rejected(.foregroundExecutionUnsupported),
             .rejected(.externalInvocationUnavailable),
             .rejected(.providerChanged):
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .unavailable,
                messageLocalizationKey: .actionUnavailable
            )
        case .rejected:
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .failed,
                messageLocalizationKey: .actionDidNotStart
            )
        }
    }

    private func stepResult(
        for step: WorkflowStep,
        startedAt: Date?,
        status: WorkflowStepRunStatus,
        message: String? = nil,
        messageLocalizationKey: WorkflowHistoryLocalizationKey? = nil
    ) -> WorkflowStepRunResult {
        WorkflowStepRunResult(
            stepID: step.id,
            actionKey: step.reference.key,
            title: step.label?.isEmpty == false ? step.label! : actionTitle(for: step.reference),
            titleSource: step.label?.isEmpty == false ? .custom : .action,
            actionReference: ActionReference(
                key: step.reference.key,
                schemaVersion: step.reference.schemaVersion
            ),
            startedAt: startedAt,
            finishedAt: now(),
            status: status,
            message: message,
            messageLocalizationKey: messageLocalizationKey
        )
    }

    private func actionTitle(for reference: ActionReference) -> String {
        guard case let .success(action) = registry.registeredAction(for: reference) else {
            return reference.key.id
        }
        let parametersByID = Dictionary(
            uniqueKeysWithValues: action.definition.parameters.map { ($0.id, $0) }
        )
        if reference.parameters.entries.contains(where: {
            parametersByID[$0.name]?.privacy == .sensitive
        }) {
            return action.definition.title
        }
        return action.catalogEntry?.title ?? action.definition.title
    }

    private func appendCancelledAndSkipped(
        currentStep: WorkflowStep,
        remainingSteps: ArraySlice<WorkflowStep>,
        to run: inout WorkflowRun
    ) {
        run.stepResults.append(
            stepResult(
                for: currentStep,
                startedAt: nil,
                status: .cancelled,
                messageLocalizationKey: .workflowCancelled
            )
        )
        appendSkipped(remainingSteps, to: &run)
    }

    private func appendSkipped(
        _ steps: ArraySlice<WorkflowStep>,
        to run: inout WorkflowRun
    ) {
        for step in steps {
            run.stepResults.append(
                stepResult(
                    for: step,
                    startedAt: nil,
                    status: .skipped,
                    messageLocalizationKey: .notRun
                )
            )
        }
    }

    private func finish(
        _ run: inout WorkflowRun,
        status: WorkflowRunStatus,
        summaryLocalizationKey: WorkflowHistoryLocalizationKey
    ) {
        run.status = status
        run.finishedAt = now()
        run.summary = summaryLocalizationKey.localizedText
        run.summaryLocalizationKey = summaryLocalizationKey
        _ = store.record(run)
        onRunChange?()
    }

    private func recordRejectedRun(
        runID: UUID,
        workflow: WorkflowDefinition,
        source: WorkflowRunSource,
        summaryLocalizationKey: WorkflowHistoryLocalizationKey
    ) {
        let timestamp = now()
        _ = store.record(
            WorkflowRun(
                id: runID,
                workflowID: workflow.id,
                workflowName: workflow.name,
                source: source,
                startedAt: timestamp,
                finishedAt: timestamp,
                status: .failed,
                summaryLocalizationKey: summaryLocalizationKey
            )
        )
        onRunChange?()
    }

    private func isCancelled(runID: UUID) -> Bool {
        Task.isCancelled || cancelledRunIDs.contains(runID)
    }
}
