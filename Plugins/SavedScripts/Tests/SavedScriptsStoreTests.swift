import XCTest
@testable import SavedScriptsPlugin

@MainActor
final class SavedScriptsStoreTests: XCTestCase {
    func testSaveNormalizesSortsAndPersistsStableIdentifiers() throws {
        let storage = SavedScriptsTestStorage()
        let store = SavedScriptsStore(storage: storage)
        let firstID = UUID()

        let first = try XCTUnwrap(store.save(SavedScript(
            id: firstID,
            name: "  Zebra  ",
            kind: .zsh,
            source: "echo zebra",
            workingDirectory: "  ~/Projects  "
        )).get())
        _ = try store.save(SavedScript(
            name: "Alpha",
            kind: .appleScript,
            source: "return 1"
        )).get()

        XCTAssertEqual(first.name, "Zebra")
        XCTAssertEqual(first.workingDirectory, "~/Projects")
        XCTAssertEqual(store.scripts.map(\.name), ["Alpha", "Zebra"])

        let reloaded = SavedScriptsStore(storage: storage)
        XCTAssertEqual(reloaded.scripts.map(\.name), ["Alpha", "Zebra"])
        XCTAssertEqual(reloaded.script(id: firstID)?.actionID, "run.\(firstID.uuidString.lowercased())")
    }

    func testPortableBackupIncludesOnlyOptedInSourceAndRemovesWorkingDirectory() throws {
        let source = SavedScriptsStore(storage: SavedScriptsTestStorage())
        let included = try source.save(SavedScript(
            name: "Portable",
            kind: .bash,
            source: "printf portable",
            workingDirectory: "/private/example",
            includeSourceInBackup: true
        )).get()
        _ = try source.save(SavedScript(
            name: "Private",
            kind: .zsh,
            source: "printf private",
            includeSourceInBackup: false
        )).get()

        let backup = try XCTUnwrap(source.portableBackup())
        let restored = SavedScriptsStore(storage: SavedScriptsTestStorage())
        XCTAssertTrue(restored.restorePortableBackup(backup))
        XCTAssertEqual(restored.scripts.count, 1)
        XCTAssertEqual(restored.scripts.first?.id, included.id)
        XCTAssertEqual(restored.scripts.first?.source, "printf portable")
        XCTAssertEqual(restored.scripts.first?.workingDirectory, "")
    }

    func testPortableRestoreReplacesScriptsAbsentFromBackup() throws {
        let source = SavedScriptsStore(storage: SavedScriptsTestStorage())
        let included = try source.save(SavedScript(
            name: "Portable",
            kind: .bash,
            source: "printf portable",
            includeSourceInBackup: true
        )).get()
        let backup = try XCTUnwrap(source.portableBackup())

        let destination = SavedScriptsStore(storage: SavedScriptsTestStorage())
        let localOnly = try destination.save(SavedScript(
            name: "Local Only",
            kind: .zsh,
            source: "printf local"
        )).get()

        XCTAssertTrue(destination.restorePortableBackup(backup))
        XCTAssertEqual(destination.scripts.map(\.id), [included.id])
        XCTAssertNil(destination.script(id: localOnly.id))
    }

    func testCorruptPayloadFailsClosedWithoutDeletingOriginalBytes() {
        let storage = SavedScriptsTestStorage()
        let corrupt = Data("not-json".utf8)
        storage.values["library.v1"] = corrupt

        let store = SavedScriptsStore(storage: storage)

        XCTAssertTrue(store.scripts.isEmpty)
        XCTAssertEqual(store.loadError, "invalid-saved-scripts-library")
        XCTAssertEqual(storage.data(forKey: "library.v1"), corrupt)
    }

    func testValidationRejectsEmptyOversizedAndOutOfRangeScripts() {
        let store = SavedScriptsStore(storage: SavedScriptsTestStorage())
        XCTAssertThrowsError(try store.save(SavedScript(
            name: " ",
            kind: .zsh,
            source: "echo"
        )).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .emptyName)
        }
        XCTAssertThrowsError(try store.save(SavedScript(
            name: "Timeout",
            kind: .zsh,
            source: "echo",
            timeoutSeconds: 301
        )).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .invalidTimeout)
        }
        XCTAssertThrowsError(try store.save(SavedScript(
            name: "Large",
            kind: .zsh,
            source: String(repeating: "x", count: SavedScript.maximumSourceByteCount + 1)
        )).get()) { error in
            XCTAssertEqual(error as? SavedScriptValidationError, .sourceTooLong)
        }
    }

    func testDuplicateGetsANewStableIdentifierAndLocalizedSuffix() throws {
        let store = SavedScriptsStore(storage: SavedScriptsTestStorage())
        let original = try store.save(SavedScript(
            name: "Report",
            kind: .sh,
            source: "echo report"
        )).get()

        let copy = try store.duplicate(id: original.id, copySuffix: "副本").get()

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, "Report 副本")
        XCTAssertEqual(copy.source, original.source)
        XCTAssertNotEqual(copy.actionID, original.actionID)
    }
}
