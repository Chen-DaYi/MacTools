import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class WorkflowStoreTests: XCTestCase {
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "WorkflowStoreTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCreateUpdateDuplicateAndDeletePreserveStableReferences() throws {
        let store = try makeStore()
        let created = try store.create(name: "演示模式").get()
        let step = WorkflowStep(
            reference: ActionReference(
                key: ActionKey(providerID: "keep-awake", actionID: "set-enabled"),
                parameters: try ActionParameterSet(["enabled": .boolean(true)])
            ),
            delaySeconds: 1.5,
            errorPolicy: .continueRunning
        )
        var updated = created
        updated.steps = [step]
        updated.name = "演示模式 2"

        let saved = try store.upsert(updated).get()
        let duplicate = try store.duplicate(id: saved.id).get()

        XCTAssertEqual(store.workflow(id: saved.id)?.steps, [step])
        XCTAssertNotEqual(duplicate.id, saved.id)
        XCTAssertNotEqual(duplicate.steps.first?.id, step.id)
        XCTAssertEqual(duplicate.steps.first?.reference, step.reference)
        XCTAssertTrue(store.delete(id: saved.id))
        XCTAssertNil(store.workflow(id: saved.id))
        XCTAssertNotNil(store.workflow(id: duplicate.id))
    }

    func testWorkflowOrderMovesAndPersistsAcrossReload() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let first = try store.create(name: "第一").get()
        let second = try store.create(name: "第二").get()
        let third = try store.create(name: "第三").get()

        XCTAssertTrue(store.move(id: third.id, offset: -1))
        XCTAssertEqual(store.workflows().map(\.id), [first.id, third.id, second.id])
        XCTAssertFalse(store.move(id: first.id, offset: -1))

        let reloaded = WorkflowStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.workflows().map(\.id), [first.id, third.id, second.id])
    }

    func testInvalidAndCorruptPayloadsFailClosedWithoutDeletingStoredBytes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = "automation.workflows.v1"
        let store = WorkflowStore(userDefaults: defaults)

        var invalid = WorkflowDefinition(name: "无效")
        invalid.steps = [
            WorkflowStep(
                reference: ActionReference(
                    key: ActionKey(providerID: "test-provider", actionID: "run")
                ),
                delaySeconds: WorkflowStep.maximumDelaySeconds + 1
            ),
        ]
        XCTAssertEqual(
            store.upsert(invalid),
            .failure(.invalidWorkflow("step-fields"))
        )

        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: key)
        XCTAssertTrue(store.workflows().isEmpty)
        XCTAssertEqual(store.workflowLoadError, "invalid-workflow-payload")
        XCTAssertEqual(defaults.data(forKey: key), corrupt)
    }

    func testUnavailableReferencesRemainStoredAndMigrateWhenProviderReturns() throws {
        let store = try makeStore()
        let key = ActionKey(providerID: "test-provider", actionID: "versioned")
        let legacy = ActionReference(key: key, schemaVersion: 1)
        let workflow = WorkflowDefinition(
            name: "迁移",
            steps: [WorkflowStep(reference: legacy)]
        )
        _ = try store.upsert(workflow).get()
        let registry = ActionRegistry()

        XCTAssertFalse(store.migrateReferences(using: registry))
        XCTAssertEqual(store.workflow(id: workflow.id)?.steps.first?.reference, legacy)

        let provider = WorkflowStoreTestProvider()
        let current = ActionReference(key: key, schemaVersion: 2)
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [
                    ActionDefinition(
                        key: key,
                        parameterSchemaVersion: 2,
                        title: "版本操作",
                        description: "",
                        systemImage: "bolt"
                    ),
                ],
                catalogEntries: [ActionCatalogEntry(reference: current, title: "版本操作")],
                availability: { _ in .available },
                migrate: { reference, version in
                    ActionReference(
                        key: reference.key,
                        schemaVersion: version,
                        parameters: reference.parameters
                    )
                },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])

        XCTAssertTrue(store.migrateReferences(using: registry))
        XCTAssertEqual(store.workflow(id: workflow.id)?.steps.first?.reference, current)
    }

    func testHistoryIsBoundedPrivacySafeAndRunningRecordsRecoverAsInterrupted() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let workflowID = UUID()
        let running = WorkflowRun(
            workflowID: workflowID,
            workflowName: "未完成",
            source: .manual,
            startedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertTrue(store.record(running))

        let recovered = WorkflowStore(userDefaults: defaults)
        let run = try XCTUnwrap(recovered.history().first)

        XCTAssertEqual(run.status, .interrupted)
        XCTAssertNotNil(run.finishedAt)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(run), as: UTF8.self).contains("secret")
        )

        for index in 0..<(WorkflowStore.maximumHistoryCount + 5) {
            _ = recovered.record(
                WorkflowRun(
                    workflowID: workflowID,
                    workflowName: "记录 \(index)",
                    source: .manual
                )
            )
        }
        XCTAssertEqual(recovered.history().count, WorkflowStore.maximumHistoryCount)
    }

    func testLegacyChineseHistoryRelocalizesAfterSwitchAndRelaunch() throws {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        let store = try makeStore()
        let reference = ActionReference(
            key: ActionKey(providerID: "localized-parameterized", actionID: "show-grid"),
            parameters: try ActionParameterSet(["enabled": .boolean(true)])
        )
        let step = WorkflowStep(reference: reference)
        let workflow = try store.upsert(
            WorkflowDefinition(name: "Legacy", steps: [step])
        ).get()
        XCTAssertTrue(
            store.record(
                WorkflowRun(
                    workflowID: workflow.id,
                    workflowName: workflow.name,
                    source: .manual,
                    finishedAt: .now,
                    status: .failed,
                    stepResults: [
                        WorkflowStepRunResult(
                            stepID: step.id,
                            actionKey: reference.key,
                            title: "操作网格",
                            startedAt: .now,
                            finishedAt: .now,
                            status: .failed,
                            message: "操作未能完成。"
                        ),
                    ],
                    summary: "工作流已完成，但部分步骤失败。"
                )
            )
        )

        PluginRuntimeLocalization.source.setPreference("en")
        let reloaded = WorkflowStore(
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
        )
        let run = try XCTUnwrap(reloaded.history().first)
        let provider = WorkflowStoreTestProvider()
        let registry = ActionRegistry()
        synchronizeLocalizedParameterizedAction(
            provider: provider,
            reference: reference,
            registry: registry
        )
        XCTAssertEqual(run.stepResults.first?.titleSource, .action)
        XCTAssertEqual(
            run.stepResults.first?.actionReference,
            ActionReference(key: reference.key, schemaVersion: reference.schemaVersion)
        )
        XCTAssertEqual(
            WorkflowHistoryPresentation.actionTitle(
                for: try XCTUnwrap(run.stepResults.first),
                registry: registry
            ),
            "Action Grid"
        )
        XCTAssertEqual(run.stepResults.first?.localizedMessage, "The action could not be completed.")
        XCTAssertEqual(run.localizedSummary, "The workflow completed, but some steps failed.")

        PluginRuntimeLocalization.source.setPreference("ar")
        synchronizeLocalizedParameterizedAction(
            provider: provider,
            reference: reference,
            registry: registry
        )
        let relaunchedInArabic = WorkflowStore(
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
        )
        let arabicRun = try XCTUnwrap(relaunchedInArabic.history().first)
        XCTAssertEqual(arabicRun.stepResults.first?.localizedMessage, "لا يمكن إكمال العملية.")
        XCTAssertEqual(
            WorkflowHistoryPresentation.actionTitle(
                for: try XCTUnwrap(arabicRun.stepResults.first),
                registry: registry
            ),
            "شبكة الإجراءات"
        )
    }

    func testHistoryMigrationRedactsPreviouslyPersistedSensitiveReference() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let secret = "history-migration-secret-\(UUID().uuidString)"
        let reference = ActionReference(
            key: ActionKey(providerID: "sensitive-history", actionID: "authenticate"),
            parameters: try ActionParameterSet(["token": .string(secret)])
        )
        let step = WorkflowStep(reference: reference)
        let workflow = try store.upsert(
            WorkflowDefinition(name: "Sensitive", steps: [step])
        ).get()
        let legacyRun = WorkflowRun(
            workflowID: workflow.id,
            workflowName: workflow.name,
            source: .manual,
            finishedAt: .now,
            status: .succeeded,
            stepResults: [
                WorkflowStepRunResult(
                    stepID: step.id,
                    actionKey: reference.key,
                    title: "Authenticate \(secret)",
                    titleSource: .action,
                    actionReference: reference,
                    startedAt: .now,
                    finishedAt: .now,
                    status: .succeeded
                ),
            ]
        )
        defaults.set(
            try JSONEncoder().encode(
                WorkflowHistoryEnvelopeFixture(
                    formatVersion: WorkflowRun.currentFormatVersion,
                    runs: [legacyRun]
                )
            ),
            forKey: "automation.history.v1"
        )
        XCTAssertTrue(
            String(
                decoding: try XCTUnwrap(defaults.data(forKey: "automation.history.v1")),
                as: UTF8.self
            ).contains(secret)
        )

        let migratedStore = WorkflowStore(userDefaults: defaults)
        let migratedRun = try XCTUnwrap(migratedStore.history().first)
        XCTAssertEqual(
            migratedRun.stepResults.first?.actionReference,
            ActionReference(key: reference.key, schemaVersion: reference.schemaVersion)
        )
        XCTAssertEqual(migratedRun.stepResults.first?.title, reference.key.id)
        XCTAssertFalse(
            String(
                decoding: try XCTUnwrap(defaults.data(forKey: "automation.history.v1")),
                as: UTF8.self
            ).contains(secret)
        )
    }

    func testOrphanedLegacyHistoryRedactsUnknownTitleAndUsesSafeDefinitionPresentation() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secret = "orphaned-history-secret-\(UUID().uuidString)"
        let key = ActionKey(providerID: "orphaned-history", actionID: "authenticate")
        let legacyRun = WorkflowRun(
            workflowID: UUID(),
            workflowName: "Deleted workflow",
            source: .manual,
            finishedAt: .now,
            status: .succeeded,
            stepResults: [
                WorkflowStepRunResult(
                    stepID: UUID(),
                    actionKey: key,
                    title: "Authenticate \(secret)",
                    titleSource: .custom,
                    startedAt: .now,
                    finishedAt: .now,
                    status: .succeeded
                ),
            ]
        )
        defaults.set(
            try JSONEncoder().encode(
                WorkflowHistoryEnvelopeFixture(
                    formatVersion: WorkflowRun.currentFormatVersion,
                    runs: [legacyRun]
                )
            ),
            forKey: "automation.history.v1"
        )

        let store = WorkflowStore(userDefaults: defaults)
        let run = try XCTUnwrap(store.history().first)
        let result = try XCTUnwrap(run.stepResults.first)
        XCTAssertEqual(result.titleSource, .action)
        XCTAssertEqual(result.title, key.id)
        XCTAssertEqual(result.actionReference, ActionReference(key: key))
        XCTAssertFalse(
            String(
                decoding: try XCTUnwrap(defaults.data(forKey: "automation.history.v1")),
                as: UTF8.self
            ).contains(secret)
        )

        let provider = WorkflowStoreTestProvider()
        let registry = ActionRegistry()
        let liveReference = ActionReference(
            key: key,
            parameters: try ActionParameterSet(["token": .string("live-only-secret")])
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [
                    ActionDefinition(
                        key: key,
                        title: "Authenticate",
                        description: "",
                        systemImage: "key",
                        parameters: [
                            ActionParameterDefinition(
                                id: "token",
                                title: "Token",
                                kind: .string,
                                privacy: .sensitive
                            ),
                        ]
                    ),
                ],
                catalogEntries: [
                    ActionCatalogEntry(reference: liveReference, title: "Sensitive preset"),
                ],
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        XCTAssertEqual(
            WorkflowHistoryPresentation.actionTitle(for: result, registry: registry),
            "Authenticate"
        )
    }

    func testLegacyHistoryTrustsOnlyTitleMatchingSurvivingCustomLabel() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let key = ActionKey(providerID: "custom-label-history", actionID: "run")
        let step = WorkflowStep(reference: ActionReference(key: key), label: "Safe custom label")
        let workflow = try store.upsert(
            WorkflowDefinition(name: "Custom labels", steps: [step])
        ).get()
        let matching = WorkflowStepRunResult(
            stepID: step.id,
            actionKey: key,
            title: "Safe custom label",
            titleSource: .custom,
            startedAt: .now,
            finishedAt: .now,
            status: .succeeded
        )
        let mismatched = WorkflowStepRunResult(
            stepID: step.id,
            actionKey: key,
            title: "parameter-derived-title",
            titleSource: .custom,
            startedAt: .now,
            finishedAt: .now,
            status: .succeeded
        )
        defaults.set(
            try JSONEncoder().encode(
                WorkflowHistoryEnvelopeFixture(
                    formatVersion: WorkflowRun.currentFormatVersion,
                    runs: [
                        WorkflowRun(
                            workflowID: workflow.id,
                            workflowName: workflow.name,
                            source: .manual,
                            finishedAt: .now,
                            status: .succeeded,
                            stepResults: [matching, mismatched]
                        ),
                    ]
                )
            ),
            forKey: "automation.history.v1"
        )

        let migrated = try XCTUnwrap(WorkflowStore(userDefaults: defaults).history().first)
        XCTAssertEqual(migrated.stepResults[0].titleSource, .custom)
        XCTAssertEqual(migrated.stepResults[0].title, "Safe custom label")
        XCTAssertEqual(migrated.stepResults[1].titleSource, .action)
        XCTAssertEqual(migrated.stepResults[1].title, key.id)
        XCTAssertFalse(
            String(
                decoding: try XCTUnwrap(defaults.data(forKey: "automation.history.v1")),
                as: UTF8.self
            ).contains("parameter-derived-title")
        )
    }

    func testHistoryMigrationScopesDuplicateStepIDsToTheirWorkflow() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = WorkflowStore(userDefaults: defaults)
        let sharedStepID = UUID()
        let firstKey = ActionKey(providerID: "duplicate-step-history", actionID: "first")
        let secondKey = ActionKey(providerID: "duplicate-step-history", actionID: "second")
        let firstStep = WorkflowStep(
            id: sharedStepID,
            reference: ActionReference(key: firstKey),
            label: "First label"
        )
        let secondStep = WorkflowStep(
            id: sharedStepID,
            reference: ActionReference(key: secondKey),
            label: "Second label"
        )
        _ = try store.upsert(
            WorkflowDefinition(name: "First workflow", steps: [firstStep])
        ).get()
        let secondWorkflow = try store.upsert(
            WorkflowDefinition(name: "Second workflow", steps: [secondStep])
        ).get()
        let run = WorkflowRun(
            workflowID: secondWorkflow.id,
            workflowName: secondWorkflow.name,
            source: .manual,
            finishedAt: .now,
            status: .succeeded,
            stepResults: [
                WorkflowStepRunResult(
                    stepID: sharedStepID,
                    actionKey: secondKey,
                    title: "Second label",
                    titleSource: .custom,
                    startedAt: .now,
                    finishedAt: .now,
                    status: .succeeded
                ),
            ]
        )
        defaults.set(
            try JSONEncoder().encode(
                WorkflowHistoryEnvelopeFixture(
                    formatVersion: WorkflowRun.currentFormatVersion,
                    runs: [run]
                )
            ),
            forKey: "automation.history.v1"
        )

        let migrated = try XCTUnwrap(WorkflowStore(userDefaults: defaults).history().first)
        XCTAssertEqual(migrated.stepResults.first?.titleSource, .custom)
        XCTAssertEqual(migrated.stepResults.first?.title, "Second label")
        XCTAssertEqual(migrated.stepResults.first?.actionReference, ActionReference(key: secondKey))
    }

    func testPortableExportRejectsSensitiveAndLocalOnlyParameters() throws {
        let store = try makeStore()
        let registry = ActionRegistry()
        let provider = WorkflowStoreTestProvider()
        let key = ActionKey(providerID: "test-provider", actionID: "portable")
        let definition = ActionDefinition(
            key: key,
            title: "导出",
            description: "",
            systemImage: "square.and.arrow.up",
            parameters: [
                ActionParameterDefinition(
                    id: "value",
                    title: "值",
                    kind: .string,
                    privacy: .sensitive,
                    portability: .localOnly
                ),
            ]
        )
        let reference = ActionReference(
            key: key,
            parameters: try ActionParameterSet(["value": .string("secret")])
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: "导出")],
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let workflow = try store.upsert(
            WorkflowDefinition(name: "敏感", steps: [WorkflowStep(reference: reference)])
        ).get()

        XCTAssertEqual(store.exportWorkflow(id: workflow.id, registry: registry), .failure(.unsafeForExport))
    }

    func testPortableWorkflowRoundTripCreatesFreshStableIdentity() throws {
        let store = try makeStore()
        let registry = ActionRegistry()
        let provider = WorkflowStoreTestProvider()
        let key = ActionKey(providerID: "test-provider", actionID: "portable")
        let definition = ActionDefinition(
            key: key,
            title: "导出",
            description: "",
            systemImage: "square.and.arrow.up",
            parameters: [
                ActionParameterDefinition(id: "value", title: "值", kind: .string),
            ]
        )
        let reference = ActionReference(
            key: key,
            parameters: try ActionParameterSet(["value": .string("public")])
        )
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: "导出")],
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let original = try store.upsert(
            WorkflowDefinition(name: "便携", steps: [WorkflowStep(reference: reference)])
        ).get()
        let data = try store.exportWorkflow(id: original.id, registry: registry).get()

        let imported = try store.importWorkflow(data).get()

        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertNotEqual(imported.steps.first?.id, original.steps.first?.id)
        XCTAssertEqual(imported.steps.first?.reference, original.steps.first?.reference)
        XCTAssertEqual(store.workflows().count, 2)
    }

    func testPortableWorkflowImportPreservesIdentityWhenThereIsNoCollision() throws {
        let sourceStore = try makeStore()
        let registry = ActionRegistry()
        let provider = WorkflowStoreTestProvider()
        let key = ActionKey(providerID: "test-provider", actionID: "portable")
        let definition = ActionDefinition(
            key: key,
            title: "Export",
            description: "",
            systemImage: "square.and.arrow.up"
        )
        let reference = ActionReference(key: key)
        registry.synchronize([
            ActionProviderRegistration(
                providerID: key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [definition],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: "Export")],
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
        let original = try sourceStore.upsert(
            WorkflowDefinition(name: "Portable", steps: [WorkflowStep(reference: reference)])
        ).get()
        let data = try sourceStore.exportWorkflow(id: original.id, registry: registry).get()

        let destinationDefaults = try XCTUnwrap(UserDefaults(suiteName: "\(suiteName).destination"))
        destinationDefaults.removePersistentDomain(forName: "\(suiteName).destination")
        defer { destinationDefaults.removePersistentDomain(forName: "\(suiteName).destination") }
        let destinationStore = WorkflowStore(userDefaults: destinationDefaults)
        let imported = try destinationStore.importWorkflow(data).get()

        XCTAssertEqual(imported.id, original.id)
        XCTAssertEqual(imported.actionReference, original.actionReference)
        XCTAssertEqual(imported.steps.map(\.id), original.steps.map(\.id))
    }

    func testDuplicateTruncatesMultibyteNameByUTF8Bytes() throws {
        let store = try makeStore()
        let original = try store.create(name: String(repeating: "工", count: 26)).get()

        let duplicate = try store.duplicate(id: original.id).get()

        XCTAssertLessThanOrEqual(duplicate.name.utf8.count, WorkflowDefinition.maximumNameByteCount)
        XCTAssertFalse(duplicate.name.isEmpty)
    }

    private func makeStore() throws -> WorkflowStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return WorkflowStore(userDefaults: defaults)
    }

    private func synchronizeLocalizedParameterizedAction(
        provider: WorkflowStoreTestProvider,
        reference: ActionReference,
        registry: ActionRegistry
    ) {
        let title = FeatureL10n.string("操作网格")
        registry.synchronize([
            ActionProviderRegistration(
                providerID: reference.key.providerID,
                identity: ObjectIdentifier(provider),
                definitions: [
                    ActionDefinition(
                        key: reference.key,
                        title: title,
                        description: title,
                        systemImage: "square.grid.2x2",
                        parameters: [
                            ActionParameterDefinition(
                                id: "enabled",
                                title: FeatureL10n.string("启用"),
                                kind: .boolean
                            ),
                        ]
                    ),
                ],
                catalogEntries: [ActionCatalogEntry(reference: reference, title: title)],
                availability: { _ in .available },
                begin: { _ in
                    .success(ActionExecutionHandle(operation: { .succeeded() }))
                }
            ),
        ])
    }

    private struct WorkflowHistoryEnvelopeFixture: Encodable {
        let formatVersion: Int
        let runs: [WorkflowRun]
    }
}

@MainActor
private final class WorkflowStoreTestProvider {}
