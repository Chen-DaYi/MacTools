import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ActionExecutorTests: XCTestCase {
    func testExecutorAppliesAvailabilityModeAndExternalPoliciesBeforeBegin() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let foregroundOnly = makeActionDefinition(
            externalPolicy: .unavailable,
            capabilities: [.foregroundInteractive]
        )
        registry.synchronize([provider.registration(definition: foregroundOnly)])
        let executor = ActionExecutor(registry: registry)
        let reference = ActionReference(key: foregroundOnly.key)

        let backgroundOutcome = await executor.execute(
            ActionInvocation(reference: reference, source: .workflow, mode: .background)
        )
        XCTAssertEqual(backgroundOutcome, .rejected(.backgroundExecutionUnsupported))

        let runLinkOutcome = await executor.execute(
            ActionInvocation(reference: reference, source: .runLink, mode: .foreground)
        )
        XCTAssertEqual(runLinkOutcome, .rejected(.externalInvocationUnavailable))

        provider.availability = .unavailable("未连接显示器")
        let unavailableOutcome = await executor.execute(
            ActionInvocation(reference: reference, source: .unifiedSearch, mode: .foreground)
        )
        XCTAssertEqual(unavailableOutcome, .rejected(.unavailable("未连接显示器")))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testRunLinkRejectsSuppliedSensitiveParameterBeforeProviderBegins() async throws {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(parameters: [
            ActionParameterDefinition(
                id: "token",
                title: "Token",
                kind: .string,
                privacy: .sensitive
            ),
        ])
        registry.synchronize([provider.registration(definition: definition)])
        let reference = ActionReference(
            key: definition.key,
            parameters: try ActionParameterSet(["token": .string("secret")])
        )

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(reference: reference, source: .runLink, mode: .foreground)
        )

        XCTAssertEqual(outcome, .rejected(.externalInvocationUnavailable))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testExecutorConfirmsThenRevalidatesProviderGeneration() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "确认",
                message: "继续操作？",
                confirmButtonTitle: "继续"
            )
        )
        registry.synchronize([provider.registration(definition: definition)])

        let confirmation = ActionExecutorConfirmationService {
            let changed = ActionDefinition(
                key: definition.key,
                title: "已变化",
                description: definition.description,
                systemImage: definition.systemImage,
                externalInvocationPolicy: .allowed,
                capabilities: [.background, .foregroundInteractive]
            )
            registry.synchronize([provider.registration(definition: changed)])
            return true
        }
        let executor = ActionExecutor(registry: registry, confirmationService: confirmation)

        let outcome = await executor.execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .unifiedSearch,
                mode: .foreground
            )
        )
        XCTAssertEqual(outcome, .rejected(.providerChanged))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testConfirmationAndExecutionUseIndependentTimeouts() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let confirmationDefinition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "确认",
                message: "继续操作？",
                confirmButtonTitle: "继续"
            )
        )
        registry.synchronize([provider.registration(definition: confirmationDefinition)])
        let slowConfirmation = ActionExecutorConfirmationService {
            try? await Task.sleep(for: .seconds(5))
            return true
        }
        let confirmationExecutor = ActionExecutor(
            registry: registry,
            confirmationService: slowConfirmation,
            confirmationTimeout: .milliseconds(10)
        )

        let confirmationOutcome = await confirmationExecutor.execute(
            ActionInvocation(
                reference: ActionReference(key: confirmationDefinition.key),
                source: .manual,
                mode: .foreground
            )
        )
        XCTAssertEqual(confirmationOutcome, .rejected(.confirmationTimedOut))

        let shortAction = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive, .cancellable],
            timeout: 0.01
        )
        provider.operation = {
            try? await Task.sleep(for: .seconds(5))
            return .succeeded()
        }
        registry.synchronize([provider.registration(definition: shortAction)])
        let executionExecutor = ActionExecutor(registry: registry)
        let executionOutcome = await executionExecutor.execute(
            ActionInvocation(
                reference: ActionReference(key: shortAction.key),
                source: .workflow,
                mode: .background
            )
        )
        XCTAssertEqual(executionOutcome, .rejected(.executionTimedOut))
        XCTAssertTrue(provider.didCancel)
    }

    func testSuccessfulExecutionReturnsProviderResult() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        provider.operation = { .succeeded(message: "完成") }
        let definition = makeActionDefinition()
        registry.synchronize([provider.registration(definition: definition)])

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .actionGrid,
                mode: .foreground
            )
        )

        XCTAssertEqual(outcome, .completed(.succeeded(message: "完成")))
        XCTAssertEqual(provider.beginCount, 1)
    }

    func testDisplayChangingActionPreparesPresentationBeforeProviderBegin() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        var didPrepare = false
        provider.onBegin = {
            XCTAssertTrue(didPrepare)
        }
        let definition = makeActionDefinition(
            capabilities: [
                .background,
                .foregroundInteractive,
                .changesDisplayConfiguration,
            ]
        )
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(
            registry: registry,
            presentationPreparation: { didPrepare = true }
        )

        let outcome = await executor.execute(ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .workflow,
            mode: .background
        ))

        XCTAssertEqual(outcome, .completed(.succeeded()))
        XCTAssertTrue(didPrepare)
    }

    func testOrdinaryBackgroundActionDoesNotInterruptActiveEditing() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        var preparationCount = 0
        let definition = makeActionDefinition(capabilities: [.background])
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(
            registry: registry,
            presentationPreparation: { preparationCount += 1 }
        )

        _ = await executor.execute(ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .workflow,
            mode: .background
        ))

        XCTAssertEqual(preparationCount, 0)
    }

    func testPerInvocationConfirmationServiceCannotSkipExecutorRevalidation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "确认",
                message: "继续操作？",
                confirmButtonTitle: "继续"
            )
        )
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let invocation = ActionInvocation(
            reference: ActionReference(key: definition.key),
            source: .unifiedSearch,
            mode: .foreground
        )

        let rejected = await executor.execute(invocation)
        let approved = await executor.execute(
            invocation,
            confirmationService: ApprovedActionConfirmationService()
        )

        XCTAssertEqual(rejected, .rejected(.confirmationDenied))
        XCTAssertEqual(approved, .completed(.succeeded()))
        XCTAssertEqual(provider.beginCount, 1)
    }

    func testMatchingApprovalRejectsAChangedConfirmation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let reference = ActionReference(key: makeActionDefinition().key)
        let firstConfirmation = ActionConfirmation(
            title: "First",
            message: "Approve the first action",
            confirmButtonTitle: "First"
        )
        let changedDefinition = makeActionDefinition(
            risk: .confirmationRequired,
            confirmation: ActionConfirmation(
                title: "Changed",
                message: "Approve the changed action",
                confirmButtonTitle: "Changed"
            )
        )
        registry.synchronize([provider.registration(definition: changedDefinition)])
        let service = MatchingApprovedActionConfirmationService(
            expectedRequest: ActionConfirmationRequest(
                reference: reference,
                confirmation: firstConfirmation,
                source: .unifiedSearch
            )
        )

        let outcome = await ActionExecutor(registry: registry).execute(
            ActionInvocation(
                reference: reference,
                source: .unifiedSearch,
                mode: .foreground
            ),
            confirmationService: service
        )

        XCTAssertEqual(outcome, .rejected(.confirmationDenied))
        XCTAssertEqual(provider.beginCount, 0)
    }

    func testCancellationReturnsPromptlyForNonCooperativeOperation() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive, .cancellable],
            timeout: nil
        )
        provider.operation = {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    continuation.resume(returning: .succeeded())
                }
            }
        }
        registry.synchronize([provider.registration(definition: definition)])
        let executor = ActionExecutor(registry: registry)
        let task = Task { @MainActor in
            await executor.execute(
                ActionInvocation(
                    reference: ActionReference(key: definition.key),
                    source: .workflow,
                    mode: .background
                )
            )
        }
        await Task.yield()

        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .completed(.cancelled))
        XCTAssertTrue(provider.didCancel)
    }

    func testNonCancellableActionFinishesBeforeCancellationIsReported() async {
        let registry = ActionRegistry()
        let provider = ActionExecutorTestProvider()
        let definition = makeActionDefinition(
            capabilities: [.background, .foregroundInteractive],
            timeout: 0.001
        )
        provider.operation = {
            try? await Task.sleep(for: .milliseconds(40))
            return .succeeded(message: "finished")
        }
        registry.synchronize([provider.registration(definition: definition)])
        let task = Task { @MainActor in
            await ActionExecutor(registry: registry).execute(
                ActionInvocation(
                    reference: ActionReference(key: definition.key),
                    source: .workflow,
                    mode: .background
                )
            )
        }
        await Task.yield()

        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .completed(.succeeded(message: "finished")))
        XCTAssertFalse(provider.didCancel)
    }

    func testExecutionHandleLatchesCancellationBeforeStartingAndOnlyCancelsOnce() async {
        var startCount = 0
        var cancelCount = 0
        let handle = ActionExecutionHandle(
            operation: {
                startCount += 1
                return .succeeded()
            },
            cancel: { cancelCount += 1 }
        )

        handle.cancel()
        handle.cancel()
        let result = await handle.result()

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(cancelCount, 1)
    }

    func testExecutionHandleKeepsCancellationLatchedWhenOperationIgnoresTaskCancellation() async {
        let handle = ActionExecutionHandle {
            try? await Task.sleep(for: .milliseconds(20))
            return .succeeded(message: "late success")
        }
        let resultTask = Task { @MainActor in await handle.result() }
        await Task.yield()

        handle.cancel()

        let result = await resultTask.value
        XCTAssertEqual(result, .cancelled)
    }
}

@MainActor
final class ActionExecutorConfirmationService: ActionConfirmationRequesting {
    let operation: @MainActor @Sendable () async -> Bool

    init(operation: @escaping @MainActor @Sendable () async -> Bool) {
        self.operation = operation
    }

    func confirm(_ request: ActionConfirmationRequest) async -> Bool {
        await operation()
    }
}

@MainActor
final class ActionExecutorTestProvider {
    var availability: ActionAvailability = .available
    var operation: @MainActor @Sendable () async -> ActionExecutionResult = { .succeeded() }
    var beginCount = 0
    var didCancel = false
    var onBegin: (() -> Void)?

    func registration(definition: ActionDefinition) -> ActionProviderRegistration {
        ActionProviderRegistration(
            providerID: definition.key.providerID,
            identity: ObjectIdentifier(self),
            definitions: [definition],
            catalogEntries: [
                ActionCatalogEntry(
                    reference: ActionReference(key: definition.key),
                    title: definition.title
                ),
            ],
            availability: { [weak self] _ in
                self?.availability ?? .unavailable("missing")
            },
            begin: { [weak self] _ in
                guard let self else {
                    return .failure(.providerFailure("missing"))
                }
                self.onBegin?()
                self.beginCount += 1
                let operation = self.operation
                return .success(
                    ActionExecutionHandle(
                        operation: operation,
                        cancel: { [weak self] in self?.didCancel = true }
                    )
                )
            }
        )
    }
}
