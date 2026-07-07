import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import LaunchControlPlugin

@MainActor
final class LaunchControlNotesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LaunchControlNotesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> LaunchControlNotesStore {
        LaunchControlNotesStore(userDefaults: defaults)
    }

    func testNoteIsEmptyByDefault() {
        let store = makeStore()
        XCTAssertEqual(store.note(for: "com.example.agent"), "")
        XCTAssertTrue(store.allNotes().isEmpty)
    }

    func testSetAndGetNote() {
        let store = makeStore()
        store.setNote("夜间重建索引", for: "com.example.agent")
        XCTAssertEqual(store.note(for: "com.example.agent"), "夜间重建索引")
    }

    func testNoteIsTrimmedOnSave() {
        let store = makeStore()
        store.setNote("  有空格  ", for: "x")
        XCTAssertEqual(store.note(for: "x"), "有空格")
    }

    func testWhitespaceOnlyNoteClearsEntry() {
        let store = makeStore()
        store.setNote("保留", for: "x")
        store.setNote("   \n  ", for: "x")
        XCTAssertEqual(store.note(for: "x"), "")
        XCTAssertNil(store.allNotes()["x"])
    }

    func testEmptyStringClearsNote() {
        let store = makeStore()
        store.setNote("note", for: "z")
        store.setNote("", for: "z")
        XCTAssertEqual(store.note(for: "z"), "")
        XCTAssertTrue(store.allNotes().isEmpty)
    }

    func testNotesPersistAcrossInstances() {
        makeStore().setNote("持久化", for: "y")
        // A fresh store backed by the same defaults must read the saved note.
        XCTAssertEqual(makeStore().note(for: "y"), "持久化")
    }

    func testMultipleNotesAreIndependent() {
        let store = makeStore()
        store.setNote("a-note", for: "a")
        store.setNote("b-note", for: "b")
        XCTAssertEqual(store.note(for: "a"), "a-note")
        XCTAssertEqual(store.note(for: "b"), "b-note")
        XCTAssertEqual(store.allNotes().count, 2)
    }
}
