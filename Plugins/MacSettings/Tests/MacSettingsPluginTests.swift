import XCTest
@testable import MacSettingsPlugin
import MacToolsPluginKit

@MainActor
final class MacSettingsPluginTests: XCTestCase {
    func testFullDiskAccessPermissionDerivesAffectedSettingsAndRoutesActions() throws {
        let protectedFirst = makeTestRecord(
            id: "protected.first",
            title: "First Protected Setting",
            requirements: .init(requiredPermissionID: MacSettingsPermission.fullDiskAccess),
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let ordinary = makeTestRecord(
            id: "ordinary",
            title: "Ordinary Setting",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let protectedSecond = makeTestRecord(
            id: "protected.second",
            title: "Second Protected Setting",
            requirements: .init(requiredPermissionID: MacSettingsPermission.fullDiskAccess),
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([protectedFirst, ordinary, protectedSecond]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore(),
            environment: SystemSettingEnvironment(
                systemVersion: .init(14),
                availableHardware: [],
                grantedPermissionIDs: [],
                availableProviderIDs: []
            )
        )
        var openedURLs: [URL] = []
        let plugin = MacSettingsPlugin(
            controller: controller,
            openSystemSettings: { openedURLs.append($0) }
        )

        let requirement = try XCTUnwrap(plugin.permissionRequirements.first)
        XCTAssertEqual(requirement.id, MacSettingsPermission.fullDiskAccess)
        XCTAssertTrue(requirement.description.contains(protectedFirst.definition.title))
        XCTAssertTrue(requirement.description.contains(protectedSecond.definition.title))
        XCTAssertFalse(requirement.description.contains(ordinary.definition.title))
        let state = plugin.permissionState(for: requirement.id)
        XCTAssertFalse(state.isGranted)
        XCTAssertNotNil(state.footnote)

        plugin.handlePermissionAction(id: requirement.id)
        controller.openSystemSettings(for: protectedFirst.id)
        XCTAssertEqual(openedURLs.count, 2)
        XCTAssertTrue(openedURLs.allSatisfy {
            $0.absoluteString.contains("Privacy_AllFiles")
        })
    }

    func testPluginDefaultsToAllSettingsAndPublishesFeaturePanelFavorites() throws {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let record = makeTestRecord(id: "favorite", title: "Favorite", adapter: adapter)
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)

        XCTAssertEqual(controller.destination, .all)
        XCTAssertEqual(plugin.metadata.id, "mac-settings")
        XCTAssertEqual(plugin.settingsPage?.body.layout, .workspace)
        controller.toggleFavorite(record.id)
        plugin.handleAction(.setDisclosureExpanded(true))
        XCTAssertEqual(plugin.primaryPanelState.detail?.controls.count, 2)
        XCTAssertEqual(plugin.primaryPanelState.detail?.controls.first?.actionTitle, "Favorite · 关")
    }

    func testSearchActionKeepsResultsInControllableWorkspace() async throws {
        let record = makeTestRecord(
            id: "finder.extension",
            title: "Show Extensions",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        var presentationCount = 0
        plugin.requestSettingsPresentation = { presentationCount += 1 }
        let reference = ActionReference(
            key: ActionKey(providerID: "mac-settings", actionID: "search"),
            parameters: try ActionParameterSet(["query": .string("extensions")])
        )

        let result = try plugin.beginAction(.init(
            reference: reference,
            source: .test,
            mode: .foreground
        ))
        let executionResult = await result.result()
        XCTAssertEqual(executionResult, .succeeded())
        XCTAssertEqual(controller.destination, .all)
        XCTAssertEqual(controller.searchText, "extensions")
        XCTAssertEqual(controller.visibleRecords.map(\.id), [record.id])
        XCTAssertEqual(presentationCount, 1)
    }

    func testSettingDeepLinkOpensTheExactControllableRow() async throws {
        let record = makeTestRecord(
            id: "finder.extension",
            title: "Show Extensions",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        var presentationCount = 0
        plugin.requestSettingsPresentation = { presentationCount += 1 }
        let reference = ActionReference(
            key: ActionKey(providerID: "mac-settings", actionID: "open-setting"),
            parameters: try ActionParameterSet(["setting-id": .string(record.id.rawValue)])
        )

        let handle = try plugin.beginAction(.init(
            reference: reference,
            source: .test,
            mode: .foreground
        ))

        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(controller.searchText, record.definition.title)
        XCTAssertEqual(controller.visibleRecords.map(\.id), [record.id])
        XCTAssertEqual(presentationCount, 1)
    }

    func testParameterizedBooleanActionUsesSameVerifiedAdapterPath() async throws {
        let adapter = DeterministicSystemSettingAdapter(value: .boolean(false))
        let record = makeTestRecord(id: "toggle", title: "Toggle", adapter: adapter)
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        let reference = ActionReference(
            key: ActionKey(providerID: "mac-settings", actionID: "set-boolean"),
            parameters: try ActionParameterSet([
                "setting-id": .string(record.id.rawValue),
                "enabled": .boolean(true),
            ])
        )
        XCTAssertEqual(plugin.actionAvailability(for: reference), .available)

        let result = try plugin.beginAction(.init(
            reference: reference,
            source: .test,
            mode: .background
        ))
        let executionResult = await result.result()
        XCTAssertEqual(executionResult, .succeeded())
        XCTAssertEqual(adapter.value, .boolean(true))
        XCTAssertEqual(controller.rowStates[record.id]?.verification, .verified)
    }

    func testDeactivationCancelsRefreshAndExternalObservers() {
        let controller = MacSettingsController(
            catalog: makeTestCatalog([]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        let plugin = MacSettingsPlugin(controller: controller)
        plugin.activate(context: .init(pluginID: "mac-settings"))
        plugin.deactivate(reason: .disabled)
        XCTAssertFalse(controller.isRefreshing)
    }

    func testProfileActionBackupRequiresItsPortableProfilePayload() throws {
        let record = makeTestRecord(
            id: "known",
            title: "Known",
            adapter: DeterministicSystemSettingAdapter(value: .boolean(false))
        )
        let controller = MacSettingsController(
            catalog: makeTestCatalog([record]),
            storage: MacSettingsTestStorage(),
            historyStore: InMemorySystemSettingChangeHistoryStore(),
            profileStore: InMemorySystemSettingsProfileStore()
        )
        var draft = controller.makeDraft()
        draft.name = "Portable"
        draft.setDesiredValue(.boolean(true), for: record.id)
        XCTAssertTrue(controller.saveDraft(draft))
        let plugin = MacSettingsPlugin(controller: controller)
        let payload = try XCTUnwrap(plugin.makePortablePreferencesBackup())
        let references = try XCTUnwrap(plugin.actionReferences(inPortablePreferences: payload))
        let reference = try XCTUnwrap(references.first)

        XCTAssertEqual(reference.key.actionID, "apply-profile")
        XCTAssertEqual(plugin.backupDisposition(for: reference), .requiresPluginPreferences)
        XCTAssertEqual(
            plugin.backupDisposition(for: ActionReference(
                key: ActionKey(providerID: "mac-settings", actionID: "undo-most-recent-change")
            )),
            .excluded
        )
    }
}
