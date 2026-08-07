import AppKit
import XCTest
import MacToolsPluginKit
@testable import ClipboardClearPlugin

@MainActor
final class ClipboardClearPluginTests: XCTestCase {
    func testCanonicalActionRequiresConfirmationAndClearsThePasteboard() async throws {
        let pasteboard = NSPasteboard(name: .init("ClipboardClearPluginTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("private test value", forType: .string)
        let plugin = ClipboardClearPlugin(pasteboard: pasteboard)
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        XCTAssertEqual(definition.risk, .confirmationRequired)
        XCTAssertEqual(definition.externalInvocationPolicy, .confirmAlways)
        XCTAssertTrue(plugin.actionAvailability(for: reference).isAvailable)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertFalse(plugin.actionAvailability(for: reference).isAvailable)
    }
}
