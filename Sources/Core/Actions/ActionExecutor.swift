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
    private enum ConfirmationRace: Sendable {
        case response(Bool)
        case timedOut
    }

    private enum ExecutionRace: Sendable {
        case result(ActionExecutionResult)
        case timedOut
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
            }
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

        guard let seconds = revalidated.definition.executionTimeoutSeconds else {
            return .completed(await handle.result())
        }

        switch await executionResult(handle: handle, timeout: .seconds(seconds)) {
        case let .result(result):
            return .completed(result)
        case .timedOut:
            handle.cancel()
            return .rejected(.executionTimedOut)
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
        return await withTaskGroup(of: ConfirmationRace.self) { group in
            group.addTask {
                .response(await confirmationService.confirm(request))
            }
            group.addTask { [confirmationTimeout] in
                try? await Task.sleep(for: confirmationTimeout)
                return .timedOut
            }
            let result = await group.next() ?? .timedOut
            group.cancelAll()
            return result
        }
    }

    private func executionResult(
        handle: ActionExecutionHandle,
        timeout: Duration
    ) async -> ExecutionRace {
        return await withTaskGroup(of: ExecutionRace.self) { group in
            group.addTask {
                .result(await handle.result())
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let result = await group.next() ?? .timedOut
            if case .timedOut = result {
                handle.cancel()
            }
            group.cancelAll()
            return result
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
