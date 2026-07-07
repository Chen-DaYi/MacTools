import AppKit
import XCTest
@testable import TranslatorPlugin

@MainActor
final class PasteboardSnapshotTests: XCTestCase {
    func testRestoresStringContents() {
        let pasteboard = NSPasteboard(name: uniquePasteboardName())
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("changed", forType: .string)
        let didRestore = snapshot.restore(to: pasteboard)

        XCTAssertTrue(didRestore)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testRestoresEmptyPasteboardToEmpty() {
        let pasteboard = NSPasteboard(name: uniquePasteboardName())
        pasteboard.clearContents()
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.setString("changed", forType: .string)
        let didRestore = snapshot.restore(to: pasteboard)

        XCTAssertTrue(didRestore)
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    func testRestoresMultiplePasteboardTypesAndItems() {
        let pasteboard = NSPasteboard(name: uniquePasteboardName())
        pasteboard.clearContents()

        let firstItem = NSPasteboardItem()
        firstItem.setString("plain", forType: .string)
        firstItem.setData(Data("html".utf8), forType: .html)

        let secondItem = NSPasteboardItem()
        secondItem.setString("file", forType: .fileURL)

        pasteboard.writeObjects([firstItem, secondItem])
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("changed", forType: .string)
        let didRestore = snapshot.restore(to: pasteboard)

        XCTAssertTrue(didRestore)
        let items = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "plain")
        XCTAssertEqual(items[0].data(forType: .html), Data("html".utf8))
        XCTAssertEqual(items[1].string(forType: .fileURL), "file")
    }

    private func uniquePasteboardName() -> NSPasteboard.Name {
        NSPasteboard.Name("translator.tests.\(UUID().uuidString)")
    }
}
