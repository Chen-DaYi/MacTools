import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class AutomationControllerTests: XCTestCase {
    func testRuleSummariesUseCompleteMessagesAcrossLocales() {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        let calendar = AutomationTrigger.calendar(
            CalendarAutomationTrigger(phase: .starts)
        )
        let display = AutomationTrigger.display(
            DisplayAutomationTrigger(event: .disconnected)
        )
        let expectations: [(String, String, String)] = [
            (
                "en",
                "When Calendar event starts · Run Demo",
                "When Display disconnected and conditions match (2) · Run Demo"
            ),
            (
                "de",
                "Wenn Kalenderereignis beginnt · Demo ausführen",
                "Wenn Monitor getrennt und Bedingungen erfüllt sind (2) · Demo ausführen"
            ),
            (
                "ar",
                "عند بدء حدث التقويم · تشغيل Demo",
                "عند قطع اتصال الشاشة مع استيفاء الشروط (2) · تشغيل Demo"
            ),
        ]

        for (language, calendarSummary, displaySummary) in expectations {
            PluginRuntimeLocalization.source.setPreference(language)
            XCTAssertEqual(
                withoutBidirectionalIsolation(AutomationRuleSummaryFormatter.summary(
                    trigger: calendar,
                    conditionCount: 0,
                    workflowName: "Demo"
                )),
                calendarSummary
            )
            XCTAssertEqual(
                withoutBidirectionalIsolation(AutomationRuleSummaryFormatter.summary(
                    trigger: display,
                    conditionCount: 2,
                    workflowName: "Demo"
                )),
                displaySummary
            )
        }
    }

    private func withoutBidirectionalIsolation(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{2068}", with: "")
            .replacingOccurrences(of: "\u{2069}", with: "")
    }

    func testExistingErrorRelocalizesOnSameControllerInstance() throws {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let controller = AutomationController(
            store: WorkflowStore(userDefaults: defaults),
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )

        PluginRuntimeLocalization.source.setPreference("zh-Hans")
        controller.renameWorkflow(id: UUID(), name: "Missing")
        XCTAssertEqual(controller.lastErrorMessage, "找不到工作流。")

        PluginRuntimeLocalization.source.setPreference("en")
        XCTAssertEqual(controller.lastErrorMessage, "The workflow could not be found.")

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(controller.lastErrorMessage, "لا يمكن العثور على سير العمل.")
    }

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

    func testRuleManagementKeepsMultipleIndependentRulesForWorkflow() throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let executor = ActionExecutor(registry: registry)
        let workflowStore = WorkflowStore(userDefaults: defaults)
        let ruleStore = AutomationRuleStore(userDefaults: defaults)
        let controller = AutomationController(
            store: workflowStore,
            ruleStore: ruleStore,
            registry: registry,
            executor: executor
        )
        let workflow = try XCTUnwrap(controller.createWorkflow())
        let first = try XCTUnwrap(controller.createRule(workflowID: workflow.id))
        let second = try XCTUnwrap(controller.duplicateRule(id: first.id))
        var updated = second
        updated.name = "接入显示器"
        updated.trigger = .display(DisplayAutomationTrigger(event: .connected))
        updated.conditions = [.power(PowerAutomationCondition(source: .adapter))]

        controller.saveRule(updated)

        XCTAssertEqual(controller.rules(workflowID: workflow.id).count, 2)
        XCTAssertEqual(controller.rules(workflowID: workflow.id).last?.name, "接入显示器")
        controller.deleteRule(id: first.id)
        XCTAssertEqual(controller.rules(workflowID: workflow.id).map(\.id), [second.id])
    }

    func testDeletingWorkflowAlsoDeletesItsRulesAcrossRelaunch() throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let executor = ActionExecutor(registry: registry)
        let workflowStore = WorkflowStore(userDefaults: defaults)
        let ruleStore = AutomationRuleStore(userDefaults: defaults)
        let controller = AutomationController(
            store: workflowStore,
            ruleStore: ruleStore,
            registry: registry,
            executor: executor
        )
        let deleted = try XCTUnwrap(controller.createWorkflow())
        let retained = try XCTUnwrap(controller.createWorkflow())
        _ = try XCTUnwrap(controller.createRule(workflowID: deleted.id))
        let retainedRule = try XCTUnwrap(controller.createRule(workflowID: retained.id))

        controller.deleteWorkflow(id: deleted.id)

        XCTAssertNil(workflowStore.workflow(id: deleted.id))
        XCTAssertEqual(ruleStore.rules().map(\.id), [retainedRule.id])
        let reloadedRules = AutomationRuleStore(userDefaults: defaults).rules()
        XCTAssertEqual(reloadedRules.map(\.id), [retainedRule.id])
    }

    func testMoveWorkflowUpdatesPublishedOrderAndPersists() throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let controller = AutomationController(
            store: WorkflowStore(userDefaults: defaults),
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let first = try XCTUnwrap(controller.createWorkflow())
        let second = try XCTUnwrap(controller.createWorkflow())

        controller.moveWorkflow(id: second.id, offset: -1)

        XCTAssertEqual(controller.workflows.map(\.id), [second.id, first.id])
        XCTAssertEqual(
            WorkflowStore(userDefaults: defaults).workflows().map(\.id),
            [second.id, first.id]
        )
    }

    func testActiveRunCanBeCancelledThroughControllerSurface() async throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = CancellableAutomationControllerTestProvider()
        registry.synchronize([provider.registration])
        let controller = AutomationController(
            store: WorkflowStore(userDefaults: defaults),
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let workflow = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: workflow.id, reference: provider.reference)
        let runID = try XCTUnwrap(controller.startWorkflow(id: workflow.id))

        for _ in 0 ..< 100 where controller.activeRunIDs(for: workflow.id).isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(controller.activeRunIDs(for: workflow.id), [runID])

        controller.cancel(runID: runID)
        for _ in 0 ..< 100 where controller.activeRunIDs.contains(runID) {
            await Task.yield()
        }

        XCTAssertFalse(controller.activeRunIDs.contains(runID))
        XCTAssertEqual(controller.recentRuns(workflowID: workflow.id).first?.status, .cancelled)
        XCTAssertEqual(provider.cancelCount, 1)
    }

    func testDeletingActiveWorkflowCancelsProviderAndFinalizesRun() async throws {
        let suite = "AutomationControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ActionRegistry()
        let provider = CancellableAutomationControllerTestProvider()
        registry.synchronize([provider.registration])
        let controller = AutomationController(
            store: WorkflowStore(userDefaults: defaults),
            registry: registry,
            executor: ActionExecutor(registry: registry)
        )
        let workflow = try XCTUnwrap(controller.createWorkflow())
        controller.addStep(workflowID: workflow.id, reference: provider.reference)
        let runID = try XCTUnwrap(controller.startWorkflow(id: workflow.id))
        for _ in 0 ..< 100 where controller.activeRunIDs(for: workflow.id).isEmpty {
            await Task.yield()
        }

        XCTAssertTrue(controller.deleteWorkflow(id: workflow.id))
        for _ in 0 ..< 100 where controller.activeRunIDs.contains(runID) {
            await Task.yield()
        }

        XCTAssertNil(controller.workflows.first { $0.id == workflow.id })
        XCTAssertEqual(provider.cancelCount, 1)
        XCTAssertEqual(
            controller.history.first { $0.id == runID }?.status,
            .cancelled
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

@MainActor
private final class CancellableAutomationControllerTestProvider {
    let reference = ActionReference(
        key: ActionKey(providerID: "automation-controller-tests", actionID: "wait")
    )
    private(set) var cancelCount = 0

    var registration: ActionProviderRegistration {
        let definition = ActionDefinition(
            key: reference.key,
            title: "等待",
            description: "",
            systemImage: "hourglass",
            capabilities: [.background, .foregroundInteractive, .cancellable]
        )
        return ActionProviderRegistration(
            providerID: reference.key.providerID,
            identity: ObjectIdentifier(self),
            definitions: [definition],
            catalogEntries: [ActionCatalogEntry(reference: reference, title: "等待")],
            availability: { _ in .available },
            begin: { [weak self] _ in
                .success(
                    ActionExecutionHandle(
                        operation: {
                            do {
                                try await Task.sleep(for: .seconds(60))
                                return .succeeded()
                            } catch {
                                return .cancelled
                            }
                        },
                        cancel: { self?.cancelCount += 1 }
                    )
                )
            }
        )
    }
}
