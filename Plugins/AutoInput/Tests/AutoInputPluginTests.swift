import AppKit
import XCTest
import MacToolsPluginKit
@testable import AutoInputPlugin

@MainActor
final class AutoInputStoreTests: XCTestCase {
    func testDefaultsAndPersistence() {
        let storage = AutoInputMemoryStorage()
        let store = AutoInputStore(storage: storage)
        XCTAssertTrue(store.isEnabled)
        XCTAssertTrue(store.remembersLastInputSource)
        XCTAssertFalse(store.showsSwitchHUD)

        store.setEnabled(false)
        store.setRemembersLastInputSource(false)
        store.setShowsSwitchHUD(true)
        store.upsertRule(makeRule(bundleID: "com.example.editor", sourceID: "zh"))
        store.remember(inputSourceID: "en", for: "com.example.terminal")

        let reloaded = AutoInputStore(storage: storage)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertFalse(reloaded.remembersLastInputSource)
        XCTAssertTrue(reloaded.showsSwitchHUD)
        XCTAssertEqual(reloaded.rule(for: "com.example.editor")?.inputSourceID, "zh")
        XCTAssertEqual(reloaded.rememberedInputSourceID(for: "com.example.terminal"), "en")
    }

    func testUpsertKeepsOneRulePerBundleIdentifier() {
        let store = AutoInputStore(storage: AutoInputMemoryStorage())
        store.upsertRule(makeRule(bundleID: "com.example.app", sourceID: "en"))
        store.upsertRule(makeRule(bundleID: "com.example.app", sourceID: "zh"))

        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules[0].inputSourceID, "zh")
    }
}

final class AutoInputIndicatorTests: XCTestCase {
    func testShortLabelUsesFirstVisibleCharacter() {
        XCTAssertEqual(AutoInputIndicatorFormatter.shortLabel(for: "ABC输入法"), "A")
        XCTAssertEqual(AutoInputIndicatorFormatter.shortLabel(for: " 微信输入法 "), "微")
        XCTAssertEqual(AutoInputIndicatorFormatter.shortLabel(for: "🀄️输入法"), "🀄️")
        XCTAssertEqual(AutoInputIndicatorFormatter.shortLabel(for: "  \n"), "?")
    }

    func testAnchorPrefersValidCaretFrame() {
        let caret = NSRect(x: 80, y: 120, width: 2, height: 18)

        XCTAssertEqual(
            AutoInputIndicatorAnchorResolver.anchor(
                caretFrame: caret,
                mouseLocation: NSPoint(x: 300, y: 400)
            ),
            caret
        )
    }

    func testAnchorFallsBackToMouseForMissingOrInvalidCaret() {
        let mouse = NSPoint(x: 300, y: 400)
        let expected = NSRect(x: 300, y: 400, width: 1, height: 1)

        XCTAssertEqual(
            AutoInputIndicatorAnchorResolver.anchor(caretFrame: nil, mouseLocation: mouse),
            expected
        )
        XCTAssertEqual(
            AutoInputIndicatorAnchorResolver.anchor(caretFrame: .zero, mouseLocation: mouse),
            expected
        )
    }

    func testPresentationRetriesCaretBeforeUsingMouseFallback() {
        XCTAssertEqual(AutoInputIndicatorPresentationPolicy.initialDelay, 0.08)
        XCTAssertEqual(AutoInputIndicatorPresentationPolicy.retryDelay, 0.08)
        XCTAssertTrue(AutoInputIndicatorPresentationPolicy.shouldRetryCaret(after: 0))
        XCTAssertTrue(AutoInputIndicatorPresentationPolicy.shouldRetryCaret(after: 2))
        XCTAssertFalse(AutoInputIndicatorPresentationPolicy.shouldRetryCaret(after: 3))
    }

    func testPreferredPositionIsCaretBottomRight() {
        let origin = AutoInputIndicatorGeometry.origin(
            anchor: NSRect(x: 100, y: 100, width: 2, height: 18),
            panelSize: NSSize(width: 32, height: 32),
            visibleFrame: NSRect(x: 0, y: 0, width: 500, height: 500)
        )

        XCTAssertEqual(origin, NSPoint(x: 108, y: 62))
    }

    func testPositionFlipsAtBottomRightScreenEdge() {
        let panelSize = NSSize(width: 32, height: 32)
        let visibleFrame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let origin = AutoInputIndicatorGeometry.origin(
            anchor: NSRect(x: 190, y: 2, width: 2, height: 18),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )

        XCTAssertTrue(visibleFrame.contains(NSRect(origin: origin, size: panelSize)))
        XCTAssertLessThan(origin.x, 190)
        XCTAssertGreaterThan(origin.y, 2)
    }

    func testOversizedSpacingResultIsClampedIntoVisibleFrame() {
        let panelSize = NSSize(width: 32, height: 32)
        let visibleFrame = NSRect(x: 10, y: 20, width: 100, height: 100)
        let origin = AutoInputIndicatorGeometry.origin(
            anchor: NSRect(x: 55, y: 65, width: 1, height: 1),
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            spacing: 500
        )

        XCTAssertTrue(visibleFrame.contains(NSRect(origin: origin, size: panelSize)))
    }
}

@MainActor
final class AutoInputControllerTests: XCTestCase {
    func testFixedRuleTakesPriorityOverRememberedSource() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))
        fixture.store.remember(inputSourceID: "en", for: fixture.app.bundleIdentifier)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.controller.target(for: fixture.app.bundleIdentifier)?.reason, .fixedRule)
    }

    func testRememberedSourceIsRestoredWithoutFixedRule() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.remember(inputSourceID: "zh", for: fixture.app.bundleIdentifier)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
        XCTAssertEqual(fixture.controller.target(for: fixture.app.bundleIdentifier)?.reason, .remembered)
    }

    func testUnavailableFixedRuleFallsBackToRememberedSource() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "missing"))
        fixture.store.remember(inputSourceID: "zh", for: fixture.app.bundleIdentifier)

        fixture.controller.start()

        XCTAssertEqual(fixture.sources.selectedIDs, ["zh"])
    }

    func testDisabledPluginDoesNotSwitchOrRemember() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))
        fixture.store.setEnabled(false)

        fixture.controller.start()
        fixture.sources.currentSourceID = "zh"
        fixture.sources.emitChange()

        XCTAssertTrue(fixture.sources.selectedIDs.isEmpty)
        XCTAssertNil(fixture.store.rememberedInputSourceID(for: fixture.app.bundleIdentifier))
        XCTAssertTrue(fixture.hud.names.isEmpty)
    }

    func testSourceChangeRemembersCurrentInputSourceForFrontmostApp() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.controller.start()

        fixture.sources.currentSourceID = "zh"
        fixture.sources.emitChange()

        XCTAssertEqual(fixture.store.rememberedInputSourceID(for: fixture.app.bundleIdentifier), "zh")
    }

    func testActivationRemembersOutgoingAppsCurrentSource() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.controller.start()
        let nextApp = AutoInputApplication(
            bundleIdentifier: "com.example.chat",
            displayName: "Chat",
            bundleURL: nil
        )

        fixture.sources.currentSourceID = "zh"
        fixture.applications.activate(nextApp)

        XCTAssertEqual(fixture.store.rememberedInputSourceID(for: fixture.app.bundleIdentifier), "zh")
    }

    func testSelectionFailurePublishesErrorWithoutHUD() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.sources.selectionError = AutoInputSourceError.selectionFailed(-1)
        fixture.store.setShowsSwitchHUD(true)
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))

        fixture.controller.start()

        XCTAssertEqual(fixture.controller.errorMessage, "无法切换输入法")
        XCTAssertTrue(fixture.hud.names.isEmpty)
    }

    func testSuccessfulSwitchShowsHUDOnlyWhenEnabled() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.store.setShowsSwitchHUD(true)
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))

        fixture.controller.start()

        XCTAssertEqual(fixture.hud.names, ["中文"])
    }

    func testStopRemovesObserversAndHidesHUD() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.controller.start()
        fixture.controller.stop()

        XCTAssertEqual(fixture.sources.stopCount, 1)
        XCTAssertEqual(fixture.applications.stopCount, 1)
        XCTAssertEqual(fixture.hud.hideCount, 1)
    }

    private func makeFixture(currentSourceID: String) -> AutoInputFixture {
        let storage = AutoInputMemoryStorage()
        let store = AutoInputStore(storage: storage)
        let sources = FakeAutoInputSourceController(
            sources: [
                AutoInputSource(id: "en", name: "ABC"),
                AutoInputSource(id: "zh", name: "中文")
            ],
            currentSourceID: currentSourceID
        )
        let app = AutoInputApplication(
            bundleIdentifier: "com.example.editor",
            displayName: "Editor",
            bundleURL: URL(fileURLWithPath: "/Applications/Editor.app")
        )
        let applications = FakeAutoInputApplicationMonitor(frontmostApplication: app)
        let hud = FakeAutoInputHUDPresenter()
        let controller = AutoInputController(
            store: store,
            sourceController: sources,
            applicationMonitor: applications,
            hudPresenter: hud
        )
        return AutoInputFixture(
            store: store,
            sources: sources,
            applications: applications,
            hud: hud,
            controller: controller,
            app: app
        )
    }
}

@MainActor
final class AutoInputPluginPanelTests: XCTestCase {
    func testPanelReflectsDefaultsRulesAndPause() {
        let storage = AutoInputMemoryStorage()
        let sourceController = FakeAutoInputSourceController(sources: [], currentSourceID: nil)
        let appMonitor = FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: sourceController,
            applicationMonitor: appMonitor,
            hudPresenter: FakeAutoInputHUDPresenter()
        )

        XCTAssertEqual(plugin.metadata.id, "auto-input")
        XCTAssertEqual(plugin.metadata.iconName, "keyboard")
        XCTAssertEqual(NSColor(plugin.metadata.iconTint), .systemBlue)
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "自动记忆已开启")

        AutoInputStore(storage: storage).upsertRule(makeRule(bundleID: "com.example.app", sourceID: "en"))
        let pluginWithRule = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: sourceController,
            applicationMonitor: appMonitor,
            hudPresenter: FakeAutoInputHUDPresenter()
        )
        XCTAssertEqual(pluginWithRule.primaryPanelState.subtitle, "1 条固定规则")

        pluginWithRule.handleAction(.setSwitch(false))
        XCTAssertFalse(pluginWithRule.primaryPanelState.isOn)
        XCTAssertEqual(pluginWithRule.primaryPanelState.subtitle, "已暂停")
    }
}

private func makeRule(bundleID: String, sourceID: String) -> AutoInputRule {
    AutoInputRule(
        bundleIdentifier: bundleID,
        displayName: bundleID,
        bundleURL: nil,
        inputSourceID: sourceID
    )
}

@MainActor
private struct AutoInputFixture {
    let store: AutoInputStore
    let sources: FakeAutoInputSourceController
    let applications: FakeAutoInputApplicationMonitor
    let hud: FakeAutoInputHUDPresenter
    let controller: AutoInputController
    let app: AutoInputApplication
}

@MainActor
private final class FakeAutoInputSourceController: AutoInputSourceControlling {
    var onSourcesChanged: (() -> Void)?
    var sources: [AutoInputSource]
    var currentSourceID: String?
    var selectedIDs: [String] = []
    var stopCount = 0
    var selectionError: Error?

    init(sources: [AutoInputSource], currentSourceID: String?) {
        self.sources = sources
        self.currentSourceID = currentSourceID
    }

    func start() {}
    func stop() { stopCount += 1 }
    func refresh() {}

    func selectSource(id: String) throws {
        if let selectionError { throw selectionError }
        selectedIDs.append(id)
        currentSourceID = id
    }

    func emitChange() {
        onSourcesChanged?()
    }
}

@MainActor
private final class FakeAutoInputApplicationMonitor: AutoInputApplicationMonitoring {
    var onApplicationActivated: ((AutoInputApplication) -> Void)?
    var frontmostApplication: AutoInputApplication?
    var stopCount = 0

    init(frontmostApplication: AutoInputApplication?) {
        self.frontmostApplication = frontmostApplication
    }

    func start() {}
    func stop() { stopCount += 1 }

    func activate(_ application: AutoInputApplication) {
        frontmostApplication = application
        onApplicationActivated?(application)
    }
}

@MainActor
private final class FakeAutoInputHUDPresenter: AutoInputHUDPresenting {
    var names: [String] = []
    var hideCount = 0

    func show(inputSourceName: String) {
        names.append(inputSourceName)
    }

    func hide() {
        hideCount += 1
    }
}

@MainActor
private final class AutoInputMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
