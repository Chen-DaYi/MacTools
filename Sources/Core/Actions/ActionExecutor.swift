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

    private let registry: ActionRegistry
    private let confirmationService: any ActionConfirmationRequesting
    private let confirmationTimeout: Duration

    init(
        registry: ActionRegistry,
        confirmationService: any ActionConfirmationRequesting = RejectingActionConfirmationService(),
        confirmationTimeout: Duration = .seconds(60)
    ) {
        self.registry = registry
        self.confirmationService = confirmationService
        self.confirmationTimeout = confirmationTimeout
    }

    func execute(
        _ invocation: ActionInvocation,
        confirmationService overrideConfirmationService: (any ActionConfirmationRequesting)? = nil
    ) async -> ActionExecutionOutcome {
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

        if let rejection = policyRejection(for: initial.definition, invocation: invocation) {
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

        let isCancellable = revalidated.definition.capabilities.contains(.cancellable)
        let timeout = isCancellable
            ? revalidated.definition.executionTimeoutSeconds.map(Duration.seconds)
            : nil
        switch await executionResult(
            handle: handle,
            timeout: timeout,
            isCancellable: isCancellable
        ) {
        case let .result(result):
            return .completed(result)
        case .timedOut:
            handle.cancel()
            return .rejected(.executionTimedOut)
        case .cancelled:
            handle.cancel()
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

        if invocation.source == .runLink,
           definition.externalInvocationPolicy == .unavailable {
            return .externalInvocationUnavailable
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
