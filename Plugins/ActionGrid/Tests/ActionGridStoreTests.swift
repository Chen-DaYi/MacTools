import MacToolsPluginKit
import XCTest
@testable import ActionGridPlugin

@MainActor
final class ActionGridStoreTests: XCTestCase {
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
            present: { _ in true }
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
}
