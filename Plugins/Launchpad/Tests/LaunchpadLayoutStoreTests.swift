import XCTest
@testable import LaunchpadPlugin

@MainActor
final class LaunchpadLayoutStoreTests: XCTestCase {
    private let a = "/Applications/Alpha.app"
    private let b = "/Applications/Bravo.app"
    private let c = "/Applications/Charlie.app"

    func testEmptyStorageYieldsNilLayout() {
        let store = LaunchpadLayoutStore(storage: FakePluginStorage())

        XCTAssertNil(store.layout)
    }

    func testCorruptOrUnsupportedLayoutFallsBackToNil() throws {
        let corruptStorage = FakePluginStorage()
        corruptStorage.values["customLayout"] = Data("not json".utf8)
        XCTAssertNil(LaunchpadLayoutStore(storage: corruptStorage).layout)

        let futureStorage = FakePluginStorage()
        let futureLayout = LaunchpadLayout(
            version: LaunchpadLayout.currentVersion + 1,
            nodes: [.app(LaunchpadAppRef(id: a, name: "Alpha"))]
        )
        futureStorage.values["customLayout"] = try JSONEncoder().encode(futureLayout)
        XCTAssertNil(LaunchpadLayoutStore(storage: futureStorage).layout)
    }

    func testMaterializePersistsAlphabeticalSnapshot() {
        let storage = FakePluginStorage()
        let store = LaunchpadLayoutStore(storage: storage)

        store.materializeIfNeeded(from: sampleApps())

        XCTAssertEqual(ids(store.layout), [a, b, c])
        XCTAssertNotNil(storage.values["customLayout"] as? Data)
    }

    func testMoveBeforeUpdatesLayout() {
        let store = LaunchpadLayoutStore(storage: FakePluginStorage())
        store.materializeIfNeeded(from: sampleApps())

        store.move(id: c, before: a)

        XCTAssertEqual(ids(store.layout), [c, a, b])
    }

    func testFolderRoundTripSurvivesPersistence() {
        let storage = FakePluginStorage()
        let store = LaunchpadLayoutStore(storage: storage)
        store.materializeIfNeeded(from: sampleApps())

        store.makeFolder(target: a, dragged: b, name: "工具", id: "F1")
        let reloaded = LaunchpadLayoutStore(storage: storage)

        guard case .folder(let id, let name, let children)? = reloaded.layout?.nodes.first else {
            return XCTFail("Expected persisted folder")
        }
        XCTAssertEqual(id, "F1")
        XCTAssertEqual(name, "工具")
        XCTAssertEqual(children.map(\.id), [a, b])
    }

    func testResetToAlphabeticalClearsLayout() {
        let storage = FakePluginStorage()
        let store = LaunchpadLayoutStore(storage: storage)
        store.materializeIfNeeded(from: sampleApps())

        store.resetToAlphabetical()

        XCTAssertNil(store.layout)
        XCTAssertNil(storage.values["customLayout"])
    }

    private func app(_ path: String, _ name: String) -> LaunchpadAppItem {
        LaunchpadAppItem(id: path, name: name, url: URL(fileURLWithPath: path))
    }

    private func sampleApps() -> [LaunchpadAppItem] {
        [app(a, "Alpha"), app(b, "Bravo"), app(c, "Charlie")]
    }

    private func ids(_ layout: LaunchpadLayout?) -> [String] {
        (layout?.nodes ?? []).map(\.rootID)
    }
}
