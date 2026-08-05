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
                    return .failed(message: "工作流运行器不可用。")
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
        return .success(WorkflowExecutionHandle(runID: runID, actionHandle: actionHandle))
    }

    func cancel(runID: UUID) {
        cancelledRunIDs.insert(runID)
    }

    private func execute(
        runID: UUID,
        workflowID: UUID,
        source: WorkflowRunSource,
        mode: ActionExecutionMode
    ) async -> ActionExecutionResult {
        guard let workflow = store.workflow(id: workflowID) else {
            return .failed(message: "找不到工作流。")
        }
        let stack = WorkflowExecutionContext.workflowStack
        if stack.contains(workflowID) {
            recordRejectedRun(
                runID: runID,
                workflow: workflow,
                source: source,
                summary: "检测到递归工作流调用。"
            )
            return .failed(message: "检测到递归工作流调用。")
        }
        if stack.count >= Self.maximumExecutionDepth {
            recordRejectedRun(
                runID: runID,
                workflow: workflow,
                source: source,
                summary: "工作流嵌套层级已达上限。"
            )
            return .failed(message: "工作流嵌套层级已达上限。")
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
            cancelledRunIDs.remove(runID)
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
                finish(&run, status: .cancelled, summary: "工作流已取消。")
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
                    finish(&run, status: .cancelled, summary: "工作流已取消。")
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
                    message: "操作版本不可用。"
                )
                run.stepResults.append(result)
                _ = store.record(run)
                onRunChange?()
                hadFailure = true
                if originalStep.errorPolicy == .stop {
                    appendSkipped(workflow.steps.dropFirst(index + 1), to: &run)
                    finish(&run, status: .failed, summary: "必需操作不可用。")
                    return .failed(message: "必需操作不可用。")
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
                finish(&run, status: .cancelled, summary: "工作流已取消。")
                return .cancelled
            case .failed, .timedOut, .unavailable, .skipped:
                hadFailure = true
                if originalStep.errorPolicy == .stop {
                    appendSkipped(workflow.steps.dropFirst(index + 1), to: &run)
                    finish(&run, status: .failed, summary: "工作流在失败步骤处停止。")
                    return .failed(message: "工作流在失败步骤处停止。")
                }
            }
        }

        if hadFailure {
            finish(&run, status: .failed, summary: "工作流已完成，但部分步骤失败。")
            return .failed(message: "部分步骤失败。")
        }
        finish(&run, status: .succeeded, summary: "工作流已完成。")
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
                message: "操作未能完成。"
            )
        case .completed(.cancelled):
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .cancelled,
                message: "操作已取消。"
            )
        case .rejected(.executionTimedOut), .rejected(.confirmationTimedOut):
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .timedOut,
                message: "操作超时。"
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
                message: "操作当前不可用。"
            )
        case .rejected:
            return stepResult(
                for: step,
                startedAt: startedAt,
                status: .failed,
                message: "操作未能开始。"
            )
        }
    }

    private func stepResult(
        for step: WorkflowStep,
        startedAt: Date?,
        status: WorkflowStepRunStatus,
        message: String? = nil
    ) -> WorkflowStepRunResult {
        WorkflowStepRunResult(
            stepID: step.id,
            actionKey: step.reference.key,
            title: step.label?.isEmpty == false ? step.label! : actionTitle(for: step.reference),
            startedAt: startedAt,
            finishedAt: now(),
            status: status,
            message: message
        )
    }

    private func actionTitle(for reference: ActionReference) -> String {
        guard case let .success(action) = registry.registeredAction(for: reference) else {
            return reference.key.id
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
                message: "工作流已取消。"
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
                    message: "未执行。"
                )
            )
        }
    }

    private func finish(
        _ run: inout WorkflowRun,
        status: WorkflowRunStatus,
        summary: String
    ) {
        run.status = status
        run.finishedAt = now()
        run.summary = summary
        _ = store.record(run)
        onRunChange?()
    }

    private func recordRejectedRun(
        runID: UUID,
        workflow: WorkflowDefinition,
        source: WorkflowRunSource,
        summary: String
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
                summary: summary
            )
        )
        onRunChange?()
    }

    private func isCancelled(runID: UUID) -> Bool {
        Task.isCancelled || cancelledRunIDs.contains(runID)
    }
}
