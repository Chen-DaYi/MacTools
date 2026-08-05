import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class ActionGridOverlayControllerTests: XCTestCase {
    private let preferenceKey = PluginRuntimeLocalization.preferenceUserDefaultsKey
    private var originalPreference: String?

    override func setUp() {
        super.setUp()
        originalPreference = UserDefaults.standard.string(forKey: preferenceKey)
        PluginRuntimeLocalization.source.setPreference("en")
    }

    override func tearDown() {
        PluginRuntimeLocalization.source.setPreference(originalPreference)
        originalPreference = nil
        super.tearDown()
    }

    func testGeometryClampsGridToPointerDisplayVisibleFrame() {
        let visible = CGRect(x: 1_000, y: 200, width: 700, height: 500)
        let frame = ActionGridOverlayGeometry.targetFrame(
            pointer: CGPoint(x: 1_680, y: 210),
            visibleFrame: visible,
            itemCount: 9
        )

        XCTAssertTrue(visible.insetBy(dx: 9, dy: 9).contains(frame))
        XCTAssertEqual(ActionGridOverlayGeometry.columnCount(for: 6), 2)
        XCTAssertEqual(ActionGridOverlayGeometry.columnCount(for: 7), 3)
    }

    func testKeyboardNavigationUsesStableRowMajorPositions() {
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 0, direction: .left, itemCount: 6, columns: 2), 0)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 0, direction: .right, itemCount: 6, columns: 2), 1)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 1, direction: .right, itemCount: 6, columns: 2), 1)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 1, direction: .down, itemCount: 6, columns: 2), 3)
        XCTAssertEqual(ActionGridKeyboardNavigation.nextIndex(from: 5, direction: .down, itemCount: 6, columns: 2), 5)
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 53, characters: nil), .dismiss)
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 36, characters: nil), .activateSelected)
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 123, characters: nil), .move(.left))
        XCTAssertEqual(ActionGridKeyCommand.resolve(keyCode: 0, characters: "7"), .select(7))
        XCTAssertNil(ActionGridKeyCommand.resolve(keyCode: 0, characters: "0"))
    }

    func testAccessibilityLabelIncludesOwnerAvailabilityAndDisabledReason() {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        let available = ResolvedActionGridEntry(
            id: "available",
            reference: reference,
            title: "运行",
            ownerTitle: "测试插件",
            systemImage: "bolt",
            availability: .available
        )
        let unavailable = ResolvedActionGridEntry(
            id: "unavailable",
            reference: reference,
            title: "运行",
            ownerTitle: "测试插件",
            systemImage: "bolt",
            availability: .unavailable("需要权限。")
        )

        XCTAssertEqual(available.accessibilityLabel, "运行, 测试插件, and Available")
        XCTAssertEqual(unavailable.accessibilityLabel, "运行, 测试插件, and 需要权限。")
    }

    func testRepeatedPresentationReusesOneOverlayPanel() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }
        let entry = ActionGridPresentationEntry(
            id: "one",
            reference: ActionReference(key: ActionKey(providerID: "missing", actionID: "run"))
        )

        XCTAssertTrue(controller.present(entries: [entry]))
        XCTAssertTrue(
            controller.present(
                entries: [
                    ActionGridPresentationEntry(
                        id: "replacement",
                        reference: ActionReference(
                            key: ActionKey(providerID: "missing", actionID: "replacement")
                        )
                    ),
                ]
            )
        )
        XCTAssertEqual(controller.presentedEntryIDs, ["one"])
        XCTAssertEqual(
            NSApp.windows.filter { $0.identifier == ActionGridOverlayController.panelIdentifier }.count,
            1
        )
    }

    func testPresentedPanelSupportsSpacesAndEscapeDismissal() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }

        XCTAssertTrue(controller.present(entries: [testEntry()]))
        let behavior = try XCTUnwrap(controller.presentedPanelCollectionBehavior)
        XCTAssertTrue(behavior.contains(.moveToActiveSpace))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.transient))
        XCTAssertTrue(behavior.contains(.ignoresCycle))

        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )
        XCTAssertTrue(controller.processKeyEvent(escape))
        XCTAssertFalse(controller.isShown)
    }

    func testPointerDismissalKeepsInsideClickAndClosesForOutsideClick() throws {
        let host = makePluginHostForTests(plugins: [])
        let controller = ActionGridOverlayController(pluginHost: host)
        defer { controller.close(restoringFocus: false) }

        XCTAssertTrue(controller.present(entries: [testEntry()]))
        let frame = try XCTUnwrap(controller.presentedPanelFrame)
        controller.dismissIfPointerIsOutside(
            CGPoint(x: frame.midX, y: frame.midY)
        )
        XCTAssertTrue(controller.isShown)

        controller.dismissIfPointerIsOutside(
            CGPoint(x: frame.maxX + 1, y: frame.maxY + 1)
        )
        XCTAssertFalse(controller.isShown)
    }

    func testAccessibilityPolicyHonorsReducedMotionAndTransparency() {
        let standard = ActionGridOverlayAccessibilityPolicy(
            reduceMotion: false,
            reduceTransparency: false
        )
        XCTAssertTrue(standard.animatesSelection)
        XCTAssertTrue(standard.usesMaterialBackground)

        let reduced = ActionGridOverlayAccessibilityPolicy(
            reduceMotion: true,
            reduceTransparency: true
        )
        XCTAssertFalse(reduced.animatesSelection)
        XCTAssertFalse(reduced.usesMaterialBackground)
    }

    func testOverlayRootUsesSelectedLocaleDirection() {
        XCTAssertEqual(
            ActionGridOverlayRootView.layoutDirection(for: Locale(identifier: "ar")),
            .rightToLeft
        )
        XCTAssertEqual(
            ActionGridOverlayRootView.layoutDirection(for: Locale(identifier: "de")),
            .leftToRight
        )
    }

    func testModelReresolvesVisibleEntriesAfterRuntimeLanguageChange() {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        var title = "English"
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: title,
                    ownerTitle: "Owner",
                    systemImage: "bolt",
                    availability: .available
                )
            },
            executor: { _ in .completed(.succeeded()) }
        )
        model.update([ActionGridPresentationEntry(id: "entry", reference: reference)])
        XCTAssertEqual(model.entries.first?.title, "English")

        title = "العربية"
        model.refreshLocalization()

        XCTAssertEqual(model.entries.first?.title, "العربية")
    }

    func testUnavailableEntryKeepsGridOpenAndSuccessfulExecutionRequestsDismissal() async {
        let reference = ActionReference(key: ActionKey(providerID: "provider", actionID: "run"))
        var executionCount = 0
        var dismissed = false
        let model = ActionGridOverlayModel(
            resolver: { entry in
                ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: "运行",
                    ownerTitle: "测试",
                    systemImage: "bolt",
                    availability: entry.id == "available" ? .available : .unavailable("当前不可用。")
                )
            },
            executor: { _ in
                executionCount += 1
                return .completed(.succeeded())
            }
        )
        model.onSuccessfulExecution = { dismissed = true }
        model.update([
            ActionGridPresentationEntry(id: "unavailable", reference: reference),
            ActionGridPresentationEntry(id: "available", reference: reference),
        ])

        model.activateSelected()
        XCTAssertEqual(model.feedback, "当前不可用。")
        XCTAssertEqual(executionCount, 0)
        XCTAssertFalse(dismissed)

        model.select(number: 2)
        for _ in 0 ..< 20 where model.isExecuting {
            await Task.yield()
        }
        XCTAssertEqual(executionCount, 1)
        XCTAssertTrue(dismissed)
    }

    private func testEntry() -> ActionGridPresentationEntry {
        ActionGridPresentationEntry(
            id: "one",
            reference: ActionReference(
                key: ActionKey(providerID: "missing", actionID: "run")
            )
        )
    }
}
