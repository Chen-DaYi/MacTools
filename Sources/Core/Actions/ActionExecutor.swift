import Foundation
import MacToolsPluginKit

protocol ActionConfirmationRequesting: AnyObject, Sendable {
    @MainActor
    func confirm(_ request: ActionConfirmationRequest) async -> Bool
}

struct ActionConfirmationRequest: Equatable, Sendable {
    let reference: ActionReference
    let confirmation: ActionConfirmation
    let source: ActionExecutionSource
}

@MainActor
final class RejectingActionConfirmationService: ActionConfirmationRequesting {
    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        false
    }
}

@MainActor
final class ApprovedActionConfirmationService: ActionConfirmationRequesting {
    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        true
    }
}

@MainActor
final class MatchingApprovedActionConfirmationService: ActionConfirmationRequesting {
    private let expectedRequest: ActionConfirmationRequest

    init(expectedRequest: ActionConfirmationRequest) {
        self.expectedRequest = expectedRequest
    }

    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        request == expectedRequest
    }
}

@MainActor
final class ActionConfirmationRouter: ActionConfirmationRequesting {
    typealias Handler = @MainActor @Sendable (ActionConfirmationRequest) async -> Bool

    private var handler: Handler?

    func setHandler(_ handler: Handler?) {
        self.handler = handler
    }

    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        guard let handler else {
            return false
        }
        return await handler(request)
    }
}

enum ActionExecutionRejection: Error, Equatable {
    case unknownAction(ActionKey)
    case invalidParameters(String)
    case unavailable(String?)
    case backgroundExecutionUnsupported
    case foregroundExecutionUnsupported
    case externalInvocationUnavailable
    case systemExposureUnavailable
    case confirmationUnavailable
    case confirmationDenied
    case confirmationTimedOut
    case providerChanged
    case providerFailure(String)
    case executionTimedOut
}

enum ActionExecutionOutcome: Equatable {
    case completed(ActionExecutionResult)
    case rejected(ActionExecutionRejection)
}

enum ContinuingActionStartOutcome: Equatable {
    case started
    case cancelled
    case rejected(ActionExecutionRejection)
}

struct ContinuingActionStartResult {
    let outcome: ContinuingActionStartOutcome
    let completion: Task<Void, Never>?
}

@MainActor
final class ActionExecutor {
    @MainActor
    private final class Race<Value: Sendable> {
        private var resolution: Value?
        private var continuation: CheckedContinuation<Value, Never>?
        private var tasks: [Task<Void, Never>] = []

        func add(_ task: Task<Void, Never>) {
            guard resolution == nil else {
                task.cancel()
                return
            }
            tasks.append(task)
        }

        func resolve(_ value: Value) {
            guard resolution == nil else {
                return
            }
            resolution = value
            continuation?.resume(returning: value)
            continuation = nil
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
        }

        func wait() async -> Value {
            if let resolution {
                return resolution
            }
            return await withCheckedContinuation { continuation in
                if let resolution {
                    continuation.resume(returning: resolution)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    private enum ConfirmationRace: Sendable {
        case response(Bool)
        case timedOut
        case cancelled
    }

    private enum ExecutionRace: Sendable {
        case result(ActionExecutionResult)
        case timedOut
        case cancelled
    }

    private struct PreparedExecution {
        let definition: ActionDefinition
        let handle: ActionExecutionHandle
    }

    private enum PreparationOutcome {
        case prepared(PreparedExecution)
        case completed(ActionExecutionResult)
        case rejected(ActionExecutionRejection)
    }

    private let registry: ActionRegistry
    private let confirmationService: any ActionConfirmationRequesting
    private let confirmationTimeout: Duration
    private let presentationPreparation: @MainActor @Sendable () -> Void
    private var continuingExecutionTasks: [UUID: Task<Void, Never>] = [:]

    init(
        registry: ActionRegistry,
        confirmationService: any ActionConfirmationRequesting = RejectingActionConfirmationService(),
        confirmationTimeout: Duration = .seconds(60),
        presentationPreparation: @escaping @MainActor @Sendable () -> Void = {
            PluginPresentationSafety.prepareForWindowOrdering()
        }
    ) {
        self.registry = registry
        self.confirmationService = confirmationService
        self.confirmationTimeout = confirmationTimeout
        self.presentationPreparation = presentationPreparation
    }

    func execute(
        _ invocation: ActionInvocation,
        confirmationService overrideConfirmationService: (any ActionConfirmationRequesting)? = nil
    ) async -> ActionExecutionOutcome {
        switch await prepare(
            invocation,
            confirmationService: overrideConfirmationService,
            expectedDefinition: nil
        ) {
        case let .prepared(execution):
            return await executionOutcome(for: execution)
        case let .completed(result):
            return .completed(result)
        case let .rejected(rejection):
            return .rejected(rejection)
        }
    }

    /// Starts an action whose provider owns durable progress and cancellation UI.
    /// Validation and confirmation finish before this returns `.started`; the
    /// provider result then outlives cancellation of the invoking surface task.
    func startContinuing(
        _ invocation: ActionInvocation,
        expectedDefinition: ActionDefinition,
        confirmationService overrideConfirmationService: (any ActionConfirmationRequesting)? = nil
    ) async -> ContinuingActionStartOutcome {
        await startContinuingTrackingCompletion(
            invocation,
            expectedDefinition: expectedDefinition,
            confirmationService: overrideConfirmationService
        ).outcome
    }

    /// Starts a durable action and also returns a task that completes when the provider does.
    /// Callers may use that task to retain recursion/capacity bookkeeping without awaiting it.
    func startContinuingTrackingCompletion(
        _ invocation: ActionInvocation,
        expectedDefinition: ActionDefinition,
        confirmationService overrideConfirmationService: (any ActionConfirmationRequesting)? = nil
    ) async -> ContinuingActionStartResult {
        guard expectedDefinition.capabilities.contains(.reportsProgress) else {
            return ContinuingActionStartResult(
                outcome: .rejected(.providerChanged),
                completion: nil
            )
        }
        switch await prepare(
            invocation,
            confirmationService: overrideConfirmationService,
            expectedDefinition: expectedDefinition
        ) {
        case let .prepared(execution):
            guard execution.definition.capabilities.contains(.reportsProgress) else {
                execution.handle.cancel()
                return ContinuingActionStartResult(
                    outcome: .rejected(.providerChanged),
                    completion: nil
                )
            }
            let executionID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    execution.handle.cancel()
                    return
                }
                _ = await executionOutcome(for: execution)
                continuingExecutionTasks[executionID] = nil
            }
            continuingExecutionTasks[executionID] = task
            return ContinuingActionStartResult(outcome: .started, completion: task)
        case .completed(.cancelled):
            return ContinuingActionStartResult(outcome: .cancelled, completion: nil)
        case .completed:
            return ContinuingActionStartResult(outcome: .cancelled, completion: nil)
        case let .rejected(rejection):
            return ContinuingActionStartResult(
                outcome: .rejected(rejection),
                completion: nil
            )
        }
    }

    var continuingExecutionCountForTests: Int {
        continuingExecutionTasks.count
    }

    private func prepare(
        _ invocation: ActionInvocation,
        confirmationService overrideConfirmationService: (any ActionConfirmationRequesting)?,
        expectedDefinition: ActionDefinition?
    ) async -> PreparationOutcome {
        guard !Task.isCancelled else {
            return .completed(.cancelled)
        }
        let initial: RegisteredAction
        switch registry.registeredAction(for: invocation.reference) {
        case let .success(action):
            initial = action
        case let .failure(error):
            return .rejected(Self.rejection(for: error))
        }
        if let expectedDefinition, initial.definition != expectedDefinition {
            return .rejected(.providerChanged)
        }

        if let rejection = policyRejection(for: initial.definition, invocation: invocation) {
            return .rejected(rejection)
        }
        if let rejection = exposureRejection(for: invocation) {
            return .rejected(rejection)
        }
        let availability = registry.availability(for: invocation.reference)
        guard availability.isAvailable else {
            return .rejected(.unavailable(availability.reason))
        }

        let needsConfirmation = initial.definition.risk == .confirmationRequired
            || (invocation.source == .runLink
                && initial.definition.externalInvocationPolicy == .confirmAlways)
        if needsConfirmation {
            guard let confirmation = initial.definition.confirmation else {
                return .rejected(.confirmationUnavailable)
            }
            switch await confirmationResponse(
                ActionConfirmationRequest(
                    reference: invocation.reference,
                    confirmation: confirmation,
                    source: invocation.source
                ),
                using: overrideConfirmationService ?? confirmationService
            ) {
            case .response(true):
                break
            case .response(false):
                return .rejected(.confirmationDenied)
            case .timedOut:
                return .rejected(.confirmationTimedOut)
            case .cancelled:
                return .completed(.cancelled)
            }
        }

        guard !Task.isCancelled else {
            return .completed(.cancelled)
        }

        let revalidated: RegisteredAction
        switch registry.registeredAction(for: invocation.reference) {
        case let .success(action):
            revalidated = action
        case let .failure(error):
            return .rejected(Self.rejection(for: error))
        }
        guard revalidated.providerGeneration == initial.providerGeneration,
              revalidated.definition == initial.definition else {
            return .rejected(.providerChanged)
        }
        let currentAvailability = registry.availability(for: invocation.reference)
        guard currentAvailability.isAvailable else {
            return .rejected(.unavailable(currentAvailability.reason))
        }
        if let rejection = exposureRejection(for: invocation) {
            return .rejected(rejection)
        }

        if revalidated.definition.capabilities.contains(.changesDisplayConfiguration) {
            presentationPreparation()
        }

        let handle: ActionExecutionHandle
        switch registry.begin(
            invocation,
            expectedProviderGeneration: revalidated.providerGeneration
        ) {
        case let .success(value):
            handle = value
        case let .failure(error):
            return .rejected(Self.rejection(for: error))
        }

        return .prepared(PreparedExecution(definition: revalidated.definition, handle: handle))
    }

    private func executionOutcome(
        for execution: PreparedExecution
    ) async -> ActionExecutionOutcome {
        let isCancellable = execution.definition.capabilities.contains(.cancellable)
        let timeout = isCancellable
            ? execution.definition.executionTimeoutSeconds.map(Duration.seconds)
            : nil
        switch await executionResult(
            handle: execution.handle,
            timeout: timeout,
            isCancellable: isCancellable
        ) {
        case let .result(result):
            return .completed(result)
        case .timedOut:
            execution.handle.cancel()
            return .rejected(.executionTimedOut)
        case .cancelled:
            execution.handle.cancel()
            return .completed(.cancelled)
        }
    }

    private func policyRejection(
        for definition: ActionDefinition,
        invocation: ActionInvocation
    ) -> ActionExecutionRejection? {
        switch invocation.mode {
        case .background where !definition.capabilities.contains(.background):
            return .backgroundExecutionUnsupported
        case .foreground where !definition.capabilities.contains(.foregroundInteractive):
            return .foregroundExecutionUnsupported
        default:
            break
        }

        if invocation.source == .runLink {
            guard definition.externalInvocationPolicy != .unavailable,
                  !ActionRegistry.containsSensitiveParameters(
                      invocation.reference,
                      for: definition
                  ) else {
                return .externalInvocationUnavailable
            }
        }
        return nil
    }

    private func exposureRejection(
        for invocation: ActionInvocation
    ) -> ActionExecutionRejection? {
        let surface: ActionExposureSurface
        switch invocation.source {
        case .appIntent:
            surface = .appIntents
        default:
            return nil
        }

        guard registry.exposurePolicy(for: invocation.reference, on: surface) != .excluded else {
            return .systemExposureUnavailable
        }
        return nil
    }

    private func confirmationResponse(
        _ request: ActionConfirmationRequest,
        using confirmationService: any ActionConfirmationRequesting
    ) async -> ConfirmationRace {
        let race = Race<ConfirmationRace>()
        race.add(Task { @MainActor in
            let response = await confirmationService.confirm(request)
            race.resolve(.response(response))
        })
        race.add(Task { @MainActor [confirmationTimeout] in
            do {
                try await Task.sleep(for: confirmationTimeout)
                race.resolve(.timedOut)
            } catch {}
        })
        return await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            Task { @MainActor in race.resolve(.cancelled) }
        }
    }

    private func executionResult(
        handle: ActionExecutionHandle,
        timeout: Duration?,
        isCancellable: Bool
    ) async -> ExecutionRace {
        let race = Race<ExecutionRace>()
        race.add(Task { @MainActor in
            race.resolve(.result(await handle.result()))
        })
        if let timeout {
            race.add(Task { @MainActor in
                do {
                    try await Task.sleep(for: timeout)
                    race.resolve(.timedOut)
                } catch {}
            })
        }
        return await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            guard isCancellable else { return }
            Task { @MainActor in race.resolve(.cancelled) }
        }
    }

    private static func rejection(for error: ActionRegistryError) -> ActionExecutionRejection {
        switch error {
        case let .unknownAction(key):
            return .unknownAction(key)
        case .schemaVersionMismatch, .migrationUnavailable, .invalidMigration:
            return .invalidParameters("action-schema-version")
        case let .invalidParameters(reason):
            return .invalidParameters(reason)
        case .providerChanged:
            return .providerChanged
        case let .providerFailure(message):
            return .providerFailure(message)
        }
    }
}
