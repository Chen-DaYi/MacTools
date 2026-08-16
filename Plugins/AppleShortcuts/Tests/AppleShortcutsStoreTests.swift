import MacToolsPluginKit
import XCTest
@testable import AppleShortcutsPlugin

@MainActor
final class AppleShortcutsStoreTests: XCTestCase {
    func testIndividualEnableRenameMissingRetentionAndDisable() throws {
        let storage = AppleShortcutsTestStorage()
        let store = AppleShortcutsStore(storage: storage)
        let id = UUID()
        let original = AppleShortcutItem(id: id, name: "Original")

        try store.setShortcutEnabled(true, item: original).get()
        try store.reconcile(AppleShortcutsDiscovery(
            shortcuts: [AppleShortcutItem(id: id, name: "Renamed")],
            folders: [],
            folderMemberships: [:],
            failedFolderIDs: []
        )).get()
        XCTAssertEqual(store.record(id: id)?.lastKnownName, "Renamed")

        try store.reconcile(.empty).get()
        XCTAssertTrue(store.isEnabled(id))
        XCTAssertEqual(store.record(id: id)?.lastKnownName, "Renamed")

        try store.setShortcutEnabled(false, item: original).get()
        XCTAssertFalse(store.isEnabled(id))
        XCTAssertNil(store.record(id: id))
    }

    func testFolderSyncExclusionAndMissingFolderRetention() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let folder = AppleShortcutFolder(id: UUID(), name: "Home")
        let first = AppleShortcutItem(id: UUID(), name: "Lights", folderIDs: [folder.id])
        let second = AppleShortcutItem(id: UUID(), name: "Door", folderIDs: [folder.id])

        try store.setFolderSynced(true, folder: folder, members: [first, second]).get()
        try store.setShortcutEnabled(false, item: first).get()
        XCTAssertFalse(store.isEnabled(first.id))
        XCTAssertTrue(store.isEnabled(second.id))

        try store.reconcile(.empty).get()
        XCTAssertTrue(store.isFolderSynced(folder.id))
        XCTAssertTrue(store.isEnabled(second.id))

        try store.setFolderSynced(false, folder: folder, members: []).get()
        XCTAssertFalse(store.isEnabled(second.id))
    }

    func testFolderExclusionSurvivesLeaveAndReentry() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let folder = AppleShortcutFolder(id: UUID(), name: "Synced")
        let item = AppleShortcutItem(id: UUID(), name: "Excluded", folderIDs: [folder.id])
        try store.setFolderSynced(true, folder: folder, members: [item]).get()
        try store.setShortcutEnabled(false, item: item).get()

        try store.reconcile(AppleShortcutsDiscovery(
            shortcuts: [AppleShortcutItem(id: item.id, name: item.name)],
            folders: [folder],
            folderMemberships: [folder.id: []],
            failedFolderIDs: []
        )).get()
        XCTAssertTrue(store.state.excludedIDs.contains(item.id))

        try store.reconcile(AppleShortcutsDiscovery(
            shortcuts: [item],
            folders: [folder],
            folderMemberships: [folder.id: [item.id]],
            failedFolderIDs: []
        )).get()
        XCTAssertFalse(store.isEnabled(item.id))
        XCTAssertTrue(store.state.excludedIDs.contains(item.id))
    }

    func testFolderExclusionSurvivesStoppingUnrelatedSyncWhileItemIsAbsent() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let retainedFolder = AppleShortcutFolder(id: UUID(), name: "Retained")
        let stoppedFolder = AppleShortcutFolder(id: UUID(), name: "Stopped")
        let item = AppleShortcutItem(
            id: UUID(),
            name: "Excluded",
            folderIDs: [retainedFolder.id]
        )
        try store.setFolderSynced(true, folder: retainedFolder, members: [item]).get()
        try store.setFolderSynced(true, folder: stoppedFolder, members: []).get()
        try store.setShortcutEnabled(false, item: item).get()
        try store.reconcile(AppleShortcutsDiscovery(
            shortcuts: [AppleShortcutItem(id: item.id, name: item.name)],
            folders: [retainedFolder, stoppedFolder],
            folderMemberships: [retainedFolder.id: [], stoppedFolder.id: []],
            failedFolderIDs: []
        )).get()

        try store.setFolderSynced(false, folder: stoppedFolder, members: []).get()
        XCTAssertTrue(store.state.excludedIDs.contains(item.id))

        try store.reconcile(AppleShortcutsDiscovery(
            shortcuts: [item],
            folders: [retainedFolder],
            folderMemberships: [retainedFolder.id: [item.id]],
            failedFolderIDs: []
        )).get()

        XCTAssertFalse(store.isEnabled(item.id))
        XCTAssertTrue(store.state.excludedIDs.contains(item.id))
    }

    func testMissingSyncedFolderRemainsInTrackedSourceMetadata() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let folder = AppleShortcutFolder(id: UUID(), name: "Cloud Folder")
        let item = AppleShortcutItem(id: UUID(), name: "Still Global", folderIDs: [folder.id])
        try store.setFolderSynced(true, folder: folder, members: [item]).get()

        try store.reconcile(AppleShortcutsDiscovery(
            shortcuts: [AppleShortcutItem(id: item.id, name: item.name)],
            folders: [],
            folderMemberships: [:],
            failedFolderIDs: []
        )).get()

        XCTAssertEqual(store.record(id: item.id)?.lastKnownFolderIDs, [folder.id])
        XCTAssertEqual(store.state.syncedFolders[folder.id]?.lastKnownName, "Cloud Folder")
    }

    func testMoveOutOfPresentFolderDisablesFolderOnlyShortcut() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let folder = AppleShortcutFolder(id: UUID(), name: "Synced")
        let item = AppleShortcutItem(id: UUID(), name: "Moved", folderIDs: [folder.id])
        try store.setFolderSynced(true, folder: folder, members: [item]).get()

        try store.reconcile(AppleShortcutsDiscovery(
            shortcuts: [AppleShortcutItem(id: item.id, name: item.name)],
            folders: [folder],
            folderMemberships: [folder.id: []],
            failedFolderIDs: []
        )).get()

        XCTAssertFalse(store.isEnabled(item.id))
        XCTAssertNil(store.record(id: item.id))
    }

    func testGloballyMissingFolderMemberRetainsUnavailableActionRecord() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let folder = AppleShortcutFolder(id: UUID(), name: "Present Folder")
        let item = AppleShortcutItem(id: UUID(), name: "Cloud Gap", folderIDs: [folder.id])
        try store.setFolderSynced(true, folder: folder, members: [item]).get()

        try store.reconcile(AppleShortcutsDiscovery(
            shortcuts: [],
            folders: [folder],
            folderMemberships: [folder.id: []],
            failedFolderIDs: []
        )).get()

        XCTAssertTrue(store.isEnabled(item.id))
        XCTAssertEqual(store.record(id: item.id)?.lastKnownName, "Cloud Gap")
        XCTAssertEqual(store.state.syncedFolders[folder.id]?.memberIDs, [item.id])
    }

    func testFolderSyncPreviewReportsExactAdditionsExclusionsAndLimit() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let folder = AppleShortcutFolder(id: UUID(), name: "Preview")
        let enabled = AppleShortcutItem(id: UUID(), name: "Enabled", folderIDs: [folder.id])
        let excluded = AppleShortcutItem(id: UUID(), name: "Excluded", folderIDs: [folder.id])
        try store.setShortcutEnabled(true, item: enabled).get()
        try store.setFolderSynced(true, folder: folder, members: [excluded]).get()
        try store.setShortcutEnabled(false, item: excluded).get()
        let addition = AppleShortcutItem(id: UUID(), name: "Addition", folderIDs: [folder.id])

        let preview = store.folderSyncPreview(members: [enabled, excluded, addition])

        XCTAssertEqual(preview.additionIDs, [addition.id])
        XCTAssertEqual(preview.excludedIDs, [excluded.id])
        XCTAssertEqual(preview.projectedTrackedCount, 3)
        XCTAssertFalse(preview.exceedsLimit)

        let overflowMembers = [enabled, excluded, addition] + (0 ..< 511).map {
            AppleShortcutItem(id: UUID(), name: "Overflow \($0)", folderIDs: [folder.id])
        }
        XCTAssertTrue(store.folderSyncPreview(members: overflowMembers).exceedsLimit)
    }

    func testStoppingFolderSyncCountsOnlyCurrentlyPublishedExclusiveMembers() throws {
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        let folder = AppleShortcutFolder(id: UUID(), name: "Primary")
        let alternateFolder = AppleShortcutFolder(id: UUID(), name: "Alternate")
        let exclusive = AppleShortcutItem(id: UUID(), name: "Exclusive", folderIDs: [folder.id])
        let excluded = AppleShortcutItem(id: UUID(), name: "Excluded", folderIDs: [folder.id])
        let explicit = AppleShortcutItem(id: UUID(), name: "Explicit", folderIDs: [folder.id])
        let shared = AppleShortcutItem(
            id: UUID(),
            name: "Shared",
            folderIDs: [folder.id, alternateFolder.id]
        )
        try store.setFolderSynced(
            true,
            folder: folder,
            members: [exclusive, excluded, explicit, shared]
        ).get()
        try store.setShortcutEnabled(false, item: excluded).get()
        try store.setShortcutEnabled(true, item: explicit).get()
        try store.setFolderSynced(true, folder: alternateFolder, members: [shared]).get()

        XCTAssertEqual(store.disappearingShortcutCount(whenStoppingSync: folder.id), 1)
    }

    func testActionIDParserRejectsNoncanonicalCase() throws {
        let id = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        XCTAssertEqual(
            AppleShortcutsStore.shortcutID(fromActionID: AppleShortcutsStore.actionID(for: id)),
            id
        )
        XCTAssertNil(AppleShortcutsStore.shortcutID(fromActionID: "run.\(id.uuidString)"))
    }

    func testPortableBackupOmitsNamesAndEnumeratesExactActions() throws {
        let id = UUID()
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        try store.setShortcutEnabled(true, item: AppleShortcutItem(id: id, name: "Private Name")).get()
        try store.setAllowsRunLink(true, for: id).get()

        let backup = try XCTUnwrap(store.portableBackup())
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("Private Name"))
        XCTAssertEqual(store.actionIDs(inPortableBackup: backup), [AppleShortcutsStore.actionID(for: id)])

        let restored = AppleShortcutsStore(storage: AppleShortcutsTestStorage())
        XCTAssertTrue(restored.restorePortableBackup(backup))
        XCTAssertTrue(restored.isEnabled(id))
        XCTAssertTrue(restored.policy(for: id).allowsRunLink)
        XCTAssertEqual(restored.record(id: id)?.lastKnownName, "")
    }

    func testPolicyWriteFailuresStayAtomicAndCanBePresented() throws {
        let storage = AppleShortcutsTestStorage()
        let store = AppleShortcutsStore(storage: storage)
        let item = AppleShortcutItem(id: UUID(), name: "Protected")
        try store.setShortcutEnabled(true, item: item).get()
        let controller = AppleShortcutsController(
            store: store,
            runner: AppleShortcutsRunnerStub(),
            localization: PluginLocalization(bundle: .main)
        )
        storage.blocksWrites = true

        let confirmationResult = store.setRequiresConfirmation(false, for: item.id)
        guard case let .failure(confirmationError) = confirmationResult else {
            return XCTFail("Expected confirmation persistence failure")
        }
        controller.presentStoreError(confirmationError)
        XCTAssertEqual(confirmationError, .persistenceFailed)
        XCTAssertTrue(store.policy(for: item.id).requiresConfirmation)
        XCTAssertNotNil(controller.snapshot.errorMessage)

        let runLinkResult = store.setAllowsRunLink(true, for: item.id)
        guard case let .failure(runLinkError) = runLinkResult else {
            return XCTFail("Expected Run Link persistence failure")
        }
        controller.presentStoreError(runLinkError)
        XCTAssertEqual(runLinkError, .persistenceFailed)
        XCTAssertFalse(store.policy(for: item.id).allowsRunLink)
        XCTAssertNotNil(controller.snapshot.errorMessage)
    }

    func testDefaultConfirmationCanBeDisabledAndPersists() throws {
        let storage = AppleShortcutsTestStorage()
        let store = AppleShortcutsStore(storage: storage)
        let item = AppleShortcutItem(id: UUID(), name: "Optional Confirmation")
        try store.setShortcutEnabled(true, item: item).get()

        XCTAssertTrue(store.policy(for: item.id).requiresConfirmation)
        try store.setRequiresConfirmation(false, for: item.id).get()
        XCTAssertFalse(store.policy(for: item.id).requiresConfirmation)

        let reloaded = AppleShortcutsStore(storage: storage)
        XCTAssertFalse(reloaded.policy(for: item.id).requiresConfirmation)
    }

    func testTrackedLimitRejectsFolderSyncAtomically() {
        let storage = AppleShortcutsTestStorage()
        let store = AppleShortcutsStore(storage: storage)
        let folder = AppleShortcutFolder(id: UUID(), name: "Too Large")
        let members = (0 ... AppleShortcutsStore.maximumTrackedShortcutCount).map {
            AppleShortcutItem(id: UUID(), name: "Item \($0)", folderIDs: [folder.id])
        }

        let result = store.setFolderSynced(true, folder: folder, members: members)

        guard case let .failure(error) = result else {
            return XCTFail("Expected limit failure")
        }
        XCTAssertEqual(error, .tooManyTrackedShortcuts)
        XCTAssertTrue(store.trackedRecords.isEmpty)
        XCTAssertNil(storage.object(forKey: AppleShortcutsStore.storageKey))
    }

    func testRetainedIdentityLimitIsAtomicAcrossExclusionsAndExplicitItems() throws {
        let storage = AppleShortcutsTestStorage()
        let store = AppleShortcutsStore(storage: storage)
        let folder = AppleShortcutFolder(id: UUID(), name: "Excluded Source")
        let excluded = AppleShortcutItem(id: UUID(), name: "Excluded", folderIDs: [folder.id])
        try store.setFolderSynced(true, folder: folder, members: [excluded]).get()
        try store.setShortcutEnabled(false, item: excluded).get()

        for index in 0 ..< AppleShortcutsStore.maximumTrackedShortcutCount - 1 {
            try store.setShortcutEnabled(
                true,
                item: AppleShortcutItem(id: UUID(), name: "Enabled \(index)")
            ).get()
        }
        let overflow = AppleShortcutItem(id: UUID(), name: "Overflow")
        let result = store.setShortcutEnabled(true, item: overflow)

        guard case let .failure(error) = result else {
            return XCTFail("Expected retained identity limit failure")
        }
        XCTAssertEqual(error, .tooManyTrackedShortcuts)
        XCTAssertFalse(store.isEnabled(overflow.id))
        XCTAssertEqual(
            store.state.effectiveEnabledIDs.count,
            AppleShortcutsStore.maximumTrackedShortcutCount - 1
        )
        XCTAssertEqual(store.state.excludedIDs, [excluded.id])
    }

    func testPortableRestoreRejectsCrossCategoryIdentityOverflow() throws {
        let explicitIDs = (0 ..< AppleShortcutsStore.maximumTrackedShortcutCount).map { _ in UUID() }
        let excludedID = UUID()
        let folderID = UUID()
        let payload: [String: Any] = [
            "formatVersion": AppleShortcutsStore.currentFormatVersion,
            "explicitlyEnabledIDs": explicitIDs.map(\.uuidString),
            "syncedFolders": [[
                "id": folderID.uuidString,
                "memberIDs": [excludedID.uuidString],
            ]],
            "excludedIDs": [excludedID.uuidString],
            "policies": [String: Any](),
            "trackedActionIDs": explicitIDs.map(AppleShortcutsStore.actionID(for:)),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())

        XCTAssertFalse(store.restorePortableBackup(data))
        XCTAssertTrue(store.state.effectiveEnabledIDs.isEmpty)
    }

    func testPortableRestoreRejectsExplicitExcludedOverlap() throws {
        let itemID = UUID()
        let folderID = UUID()
        let payload: [String: Any] = [
            "formatVersion": AppleShortcutsStore.currentFormatVersion,
            "explicitlyEnabledIDs": [itemID.uuidString],
            "syncedFolders": [[
                "id": folderID.uuidString,
                "memberIDs": [itemID.uuidString],
            ]],
            "excludedIDs": [itemID.uuidString],
            "policies": [String: Any](),
            "trackedActionIDs": [AppleShortcutsStore.actionID(for: itemID)],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())

        XCTAssertFalse(store.restorePortableBackup(data))
        XCTAssertTrue(store.state.effectiveEnabledIDs.isEmpty)
    }

    func testPortableRestoreRejectsExclusionsWithoutSyncedFolders() throws {
        let payload: [String: Any] = [
            "formatVersion": AppleShortcutsStore.currentFormatVersion,
            "explicitlyEnabledIDs": [String](),
            "syncedFolders": [Any](),
            "excludedIDs": [UUID().uuidString],
            "policies": [String: Any](),
            "trackedActionIDs": [String](),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let store = AppleShortcutsStore(storage: AppleShortcutsTestStorage())

        XCTAssertFalse(store.restorePortableBackup(data))
        XCTAssertTrue(store.state.effectiveEnabledIDs.isEmpty)
    }

    func testInvalidStoredPayloadIsPreservedAndEditsFailClosed() {
        let storage = AppleShortcutsTestStorage()
        let original = Data("invalid".utf8)
        storage.values[AppleShortcutsStore.storageKey] = original

        let store = AppleShortcutsStore(storage: storage)
        let result = store.setShortcutEnabled(
            true,
            item: AppleShortcutItem(id: UUID(), name: "Ignored")
        )

        XCTAssertEqual(store.loadError, "invalid-apple-shortcuts-settings")
        guard case let .failure(error) = result else {
            return XCTFail("Expected recovery failure")
        }
        XCTAssertEqual(error, .recoveryRequired)
        XCTAssertEqual(storage.data(forKey: AppleShortcutsStore.storageKey), original)
    }

    func testSemanticallyInconsistentStoredPayloadFailsClosed() throws {
        let storage = AppleShortcutsTestStorage()
        let id = UUID()
        let validStore = AppleShortcutsStore(storage: storage)
        try validStore.setShortcutEnabled(
            true,
            item: AppleShortcutItem(id: id, name: "Tracked")
        ).get()
        let validData = try XCTUnwrap(storage.data(forKey: AppleShortcutsStore.storageKey))
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        var state = try XCTUnwrap(root["state"] as? [String: Any])
        state["trackedRecords"] = [Any]()
        root["state"] = state
        let corruptData = try JSONSerialization.data(withJSONObject: root)
        storage.values[AppleShortcutsStore.storageKey] = corruptData

        let reloaded = AppleShortcutsStore(storage: storage)

        XCTAssertEqual(reloaded.loadError, "invalid-apple-shortcuts-settings")
        XCTAssertTrue(reloaded.trackedRecords.isEmpty)
        XCTAssertEqual(storage.data(forKey: AppleShortcutsStore.storageKey), corruptData)
    }

    func testStoredPayloadRejectsExplicitExcludedOverlap() throws {
        let storage = AppleShortcutsTestStorage()
        let folder = AppleShortcutFolder(id: UUID(), name: "Folder")
        let item = AppleShortcutItem(id: UUID(), name: "Item", folderIDs: [folder.id])
        let validStore = AppleShortcutsStore(storage: storage)
        try validStore.setFolderSynced(true, folder: folder, members: [item]).get()
        try validStore.setShortcutEnabled(true, item: item).get()
        let validData = try XCTUnwrap(storage.data(forKey: AppleShortcutsStore.storageKey))
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        var state = try XCTUnwrap(root["state"] as? [String: Any])
        state["excludedIDs"] = [item.id.uuidString]
        root["state"] = state
        let corruptData = try JSONSerialization.data(withJSONObject: root)
        storage.values[AppleShortcutsStore.storageKey] = corruptData

        let reloaded = AppleShortcutsStore(storage: storage)

        XCTAssertEqual(reloaded.loadError, "invalid-apple-shortcuts-settings")
        XCTAssertTrue(reloaded.trackedRecords.isEmpty)
        XCTAssertEqual(storage.data(forKey: AppleShortcutsStore.storageKey), corruptData)
    }
}
