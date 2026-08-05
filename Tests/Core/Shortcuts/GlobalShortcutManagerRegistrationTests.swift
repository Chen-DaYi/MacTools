import Carbon
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class GlobalShortcutManagerRegistrationTests: XCTestCase {
    func testSharedBindingRegistersOnceAndReportsEveryOwner() {
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let binding = ShortcutBinding(keyCode: 14, modifiers: [.command, .option])

        let statuses = manager.updateBindings([
            .init(shortcutID: "first", binding: binding),
            .init(shortcutID: "second", binding: binding),
        ])

        XCTAssertEqual(registrar.registeredBindings, [binding])
        XCTAssertEqual(statuses, ["first": .registered, "second": .registered])
    }

    func testSystemRegistrationFailureIsReportedWithoutLosingDesiredState() {
        let registrar = FakeCarbonHotKeyRegistrar()
        let manager = GlobalShortcutManager(registrar: registrar)
        let binding = ShortcutBinding(keyCode: 15, modifiers: [.command, .shift])
        registrar.failures[binding] = -1234

        XCTAssertEqual(
            manager.updateBindings([.init(shortcutID: "failed", binding: binding)]),
            ["failed": .failed(.system(-1234))]
        )
        XCTAssertEqual(
            manager.debugRegistrationsForTests,
            [.init(shortcutID: "failed", binding: binding)]
        )

        registrar.failures.removeAll()
        XCTAssertEqual(
            manager.updateBindings([.init(shortcutID: "failed", binding: binding)]),
            ["failed": .registered]
        )
    }
}
