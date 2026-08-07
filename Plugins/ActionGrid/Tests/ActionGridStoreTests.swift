import MacToolsPluginKit
import XCTest
@testable import ActionGridPlugin

@MainActor
final class ActionGridStoreTests: XCTestCase {
    func testDragPayloadRoundTripsOnlyNamespacedEntryIdentifiers() {
        let entryID = UUID()

        XCTAssertEqual(
            ActionGridDragPayload.decode(ActionGridDragPayload.encode(entryID)),
            entryID
        )
        XCTAssertNil(ActionGridDragPayload.decode(entryID.uuidString))
        XCTAssertNil(ActionGridDragPayload.decode("mactools-action-grid:not-a-uuid"))
        XCTAssertNil(ActionGridDragPayload.decode(nil))
    }

    func testAddReplaceClearAndReorderAreBoundedAndPersistent() {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        let references = (0 ..< 10).map {
            ActionReference(key: ActionKey(providerID: "provider", actionID: "action-\($0)"))
        }

        for reference in references.prefix(9) {
            XCTAssertTrue(store.add(reference: reference))
        }
        XCTAssertFalse(store.add(reference: references[9]))
        XCTAssertFalse(store.add(reference: references[0]))

        let firstID = store.entries[0].id
        XCTAssertTrue(store.move(fromOffsets: [0], toOffset: 9))
        XCTAssertEqual(store.entries.last?.id, firstID)
        XCTAssertTrue(store.replace(id: firstID, reference: references[9]))
        XCTAssertTrue(store.remove(id: store.entries[0].id))

        let reloaded = ActionGridStore(storage: storage)
        XCTAssertEqual(reloaded.entries, store.entries)
        XCTAssertEqual(reloaded.entries.count, 8)
    }

    func testMissingActionsRemainStoredAndMigrateWhenProviderReturns() {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        let old = ActionReference(
            key: ActionKey(providerID: "missing", actionID: "versioned"),
            schemaVersion: 1
        )
        XCTAssertTrue(store.add(reference: old))
        var providerIsAvailable = false
        let context = ActionGridHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { reference in
                providerIsAvailable
                    ? ActionReference(key: reference.key, schemaVersion: 2, parameters: reference.parameters)
                    : nil
            },
            canPresent: { true },
            present: { _, _ in true }
        )

        XCTAssertFalse(store.migrate(using: context))
        XCTAssertEqual(store.entries.first?.reference, old)
        providerIsAvailable = true
        XCTAssertTrue(store.migrate(using: context))
        XCTAssertEqual(store.entries.first?.reference.schemaVersion, 2)
    }

    func testCorruptPayloadFailsClosedWithoutDeletingBytesAndPortableBackupRoundTrips() throws {
        let storage = ActionGridTestStorage()
        let corrupt = Data("not-json".utf8)
        storage.values["layout.v1"] = corrupt
        let failed = ActionGridStore(storage: storage)

        XCTAssertTrue(failed.entries.isEmpty)
        XCTAssertEqual(failed.loadError, "invalid-grid-layout")
        XCTAssertEqual(storage.data(forKey: "layout.v1"), corrupt)

        let sourceStorage = ActionGridTestStorage()
        let source = ActionGridStore(storage: sourceStorage)
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        XCTAssertTrue(source.add(reference: reference))
        let backup = try XCTUnwrap(source.portableBackup())
        let destination = ActionGridStore(storage: ActionGridTestStorage())
        XCTAssertTrue(destination.restorePortableBackup(backup))
        XCTAssertEqual(destination.entries.map(\.reference), [reference])
        XCTAssertNotEqual(destination.entries.first?.id, nil)
    }

    func testNestedFoldersPersistReorderAndRespectDepthLimit() throws {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        XCTAssertTrue(store.addFolder(title: "System", in: nil))
        let systemID = try XCTUnwrap(store.entries.first?.id)
        XCTAssertTrue(store.addFolder(title: "Display", in: systemID))
        let displayID = try XCTUnwrap(store.entries(in: systemID).first?.id)
        XCTAssertTrue(store.addFolder(title: "Power", in: displayID))
        let powerID = try XCTUnwrap(store.entries(in: displayID).first?.id)

        let sleep = ActionReference(
            key: ActionKey(providerID: "display-sleep", actionID: "sleep")
        )
        let lock = ActionReference(
            key: ActionKey(providerID: "lock-screen", actionID: "lock")
        )
        XCTAssertTrue(store.add(reference: sleep, in: powerID))
        XCTAssertTrue(store.add(reference: lock, in: powerID))
        XCTAssertTrue(store.move(entryID: lockID(in: store, folderID: powerID), toIndex: 0, in: powerID))
        XCTAssertEqual(store.entries(in: powerID).map(\.reference), [lock, sleep])

        XCTAssertFalse(store.addFolder(title: "Too Deep", in: powerID))
        let reloaded = ActionGridStore(storage: storage)
        XCTAssertEqual(reloaded.entries(in: powerID).map(\.reference), [lock, sleep])

        let backup = try XCTUnwrap(reloaded.portableBackup())
        let restored = ActionGridStore(storage: ActionGridTestStorage())
        XCTAssertTrue(restored.restorePortableBackup(backup))
        XCTAssertEqual(restored.entries, reloaded.entries)
    }

    func testRequestedSlotsPreserveEmptyCellsAcrossReloadAndMove() throws {
        let storage = ActionGridTestStorage()
        let store = ActionGridStore(storage: storage)
        let first = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "first")
        )
        let last = ActionReference(
            key: ActionKey(providerID: "provider", actionID: "last")
        )

        XCTAssertTrue(store.add(reference: first, in: nil, at: 0))
        XCTAssertTrue(store.add(reference: last, in: nil, at: 8))
        XCTAssertEqual(store.entries.map(\.slot), [0, 8])
        XCTAssertNil(store.entry(at: 4, in: nil))
        XCTAssertEqual(store.entry(at: 8, in: nil)?.reference, last)
        XCTAssertEqual(store.firstAvailableSlot(in: nil), 1)

        let lastID = try XCTUnwrap(store.entry(at: 8, in: nil)?.id)
        XCTAssertTrue(store.move(entryID: lastID, toIndex: 4, in: nil))
        XCTAssertEqual(store.entries.map(\.slot), [0, 4])

        let reloaded = ActionGridStore(storage: storage)
        XCTAssertEqual(reloaded.entries.map(\.slot), [0, 4])
        XCTAssertEqual(reloaded.entry(at: 4, in: nil)?.reference, last)
    }

    func testFolderCanBeCreatedInRequestedSlot() throws {
        let store = ActionGridStore(storage: ActionGridTestStorage())

        XCTAssertTrue(store.addFolder(title: "System", in: nil, at: 6))
        let folder = try XCTUnwrap(store.entry(at: 6, in: nil))
        XCTAssertEqual(folder.customTitle, "System")
        XCTAssertNotNil(folder.folder)
        XCTAssertNil(store.entry(at: 0, in: nil))
    }

    func testVersionTwoOrderedLayoutMigratesToExplicitSlots() throws {
        struct LegacyEntry: Encodable {
            let id: UUID
            let reference: ActionReference
            let customTitle: String?
            let folder: LegacyFolder?
        }
        struct LegacyFolder: Encodable {
            let systemImage: String
            let entries: [LegacyEntry]
        }
        struct LegacyEnvelope: Encodable {
            let formatVersion: Int
            let entries: [LegacyEntry]
        }

        let storage = ActionGridTestStorage()
        let references = (0 ..< 3).map {
            ActionReference(key: ActionKey(providerID: "provider", actionID: "legacy-\($0)"))
        }
        storage.values["layout.v1"] = try JSONEncoder().encode(
            LegacyEnvelope(
                formatVersion: 2,
                entries: references.map {
                    LegacyEntry(id: UUID(), reference: $0, customTitle: nil, folder: nil)
                }
            )
        )

        let store = ActionGridStore(storage: storage)

        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.entries.map(\.slot), [0, 1, 2])
        XCTAssertEqual(store.entries.map(\.reference), references)
    }

    private func lockID(in store: ActionGridStore, folderID: UUID) -> UUID {
        store.entries(in: folderID)[1].id
    }
}
