import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class AutomationControllerTests: XCTestCase {
    func testEnabledWorkflowPublishesStableOrdinaryActionAndDisabledWorkflowDisappears() throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = AutomationControllerTestProvider()
        registry.synchronize([provider.registration])
        let executor = ActionExecutor(registry: registry)
        let store = WorkflowStore(userDefaults: defaults)
        let controller = AutomationController(store: store, registry: registry, executor: executor)
        let workflow = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: workflow.id, reference: provider.reference)

        let enabledRegistration = controller.actionRegistration()
        XCTAssertEqual(enabledRegistration.definitions.map(\.key), [workflow.actionKey])
        XCTAssertEqual(enabledRegistration.catalogEntries.map(\.reference), [workflow.actionReference])
        XCTAssertEqual(enabledRegistration.definitions.first?.externalInvocationPolicy, .allowed)
        XCTAssertTrue(
            enabledRegistration.definitions.first?.capabilities.contains(.cancellable) == true
        )

        controller.setWorkflowEnabled(false, id: workflow.id)
        XCTAssertTrue(controller.actionRegistration().definitions.isEmpty)
        XCTAssertNotNil(controller.workflows.first { $0.id == workflow.id })
    }

    func testPublishedActionExecutesThroughSharedExecutorAndRecordsSource() async throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = AutomationControllerTestProvider()
        let executor = ActionExecutor(registry: registry)
        let store = WorkflowStore(userDefaults: defaults)
        let controller = AutomationController(store: store, registry: registry, executor: executor)
        let workflow = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: workflow.id, reference: provider.reference)
        registry.synchronize([provider.registration, controller.actionRegistration()])

        let outcome = await executor.execute(
            ActionInvocation(
                reference: workflow.actionReference,
                source: .globalShortcut,
                mode: .foreground
            )
        )

        XCTAssertEqual(outcome, .completed(.succeeded()))
        XCTAssertEqual(provider.invocationCount, 1)
        XCTAssertEqual(
            store.history(workflowID: workflow.id).first?.source,
            .publishedAction(.globalShortcut)
        )
    }
}

@MainActor
private final class AutomationControllerTestProvider {
    let reference = ActionReference(
        key: ActionKey(providerID: "automation-controller-tests", actionID: "run")
    )
    private(set) var invocationCount = 0

    var registration: ActionProviderRegistration {
        let definition = ActionDefinition(
            key: reference.key,
            title: "运行",
            description: "",
            systemImage: "bolt",
            externalInvocationPolicy: .allowed,
            capabilities: [.background, .foregroundInteractive]
        )
        return ActionProviderRegistration(
            providerID: reference.key.providerID,
            identity: ObjectIdentifier(self),
            definitions: [definition],
            catalogEntries: [ActionCatalogEntry(reference: reference, title: "运行")],
            availability: { _ in .available },
            begin: { [weak self] _ in
                self?.invocationCount += 1
                return .success(ActionExecutionHandle(operation: { .succeeded() }))
            }
        )
    }
}
