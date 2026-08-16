import XCTest
@testable import AppleShortcutsPlugin

final class AppleShortcutsCommandParserTests: XCTestCase {
    func testParsesUnicodeParenthesesAndNormalizesUUIDCase() throws {
        let id = UUID()
        let item = try XCTUnwrap(AppleShortcutsListParser.parseLine(
            "晨间（工作） Report (\(id.uuidString.lowercased()))"
        ))

        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.name, "晨间（工作） Report")
        XCTAssertEqual(item.actionID, "run.\(id.uuidString.lowercased())")
    }

    func testDuplicateNamesRemainDistinct() throws {
        let first = UUID()
        let second = UUID()
        let output = """
        Same (\(first.uuidString))
        Same (\(second.uuidString))
        """

        let parsed = try AppleShortcutsListParser.parse(output)

        XCTAssertEqual(parsed.map(\.id), [first, second])
        XCTAssertEqual(parsed.map(\.name), ["Same", "Same"])
    }

    func testDuplicateIdentifiersAreRejected() {
        let id = UUID()
        let output = "Same (\(id.uuidString))\nRenamed (\(id.uuidString))"

        XCTAssertThrowsError(try AppleShortcutsListParser.parse(output)) { error in
            XCTAssertEqual(error as? AppleShortcutsListParser.ParseError, .duplicateIdentifier(id))
        }
    }

    func testMalformedEmptyOversizedAndNonUUIDLinesAreIgnored() throws {
        let oversized = String(repeating: "x", count: AppleShortcutsListParser.maximumLineByteCount + 1)
        let output = ["", "No identifier", "Name(not separated)", "Name (not-a-uuid)", oversized]
            .joined(separator: "\n")

        XCTAssertTrue(try AppleShortcutsListParser.parse(output).isEmpty)
    }
}
