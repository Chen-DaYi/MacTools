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

        store.setEnabled(false)
        store.setRemembersLastInputSource(false)
        store.upsertRule(makeRule(bundleID: "com.example.editor", sourceID: "zh"))
        store.remember(inputSourceID: "en", for: "com.example.terminal")

        let reloaded = AutoInputStore(storage: storage)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertFalse(reloaded.remembersLastInputSource)
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

    func testSelectionFailurePublishesError() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.sources.selectionError = AutoInputSourceError.selectionFailed(-1)
        fixture.store.upsertRule(makeRule(bundleID: fixture.app.bundleIdentifier, sourceID: "zh"))

        fixture.controller.start()

        XCTAssertEqual(fixture.controller.errorMessage, "无法切换输入法")
    }

    func testStopRemovesObservers() {
        let fixture = makeFixture(currentSourceID: "en")
        fixture.controller.start()
        fixture.controller.stop()

        XCTAssertEqual(fixture.sources.stopCount, 1)
        XCTAssertEqual(fixture.applications.stopCount, 1)
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
        let controller = AutoInputController(
            store: store,
            sourceController: sources,
            applicationMonitor: applications
        )
        return AutoInputFixture(
            store: store,
            sources: sources,
            applications: applications,
            controller: controller,
            app: app
        )
    }
}

@MainActor
final class AutoInputApplicationMonitorTests: XCTestCase {
    func testWorkspaceActivationHopsSafelyToMainActor() async {
        let notificationCenter = NotificationCenter()
        let monitor = WorkspaceAutoInputApplicationMonitor(
            notificationCenter: notificationCenter
        )
        let activated = expectation(description: "application activation delivered")
        monitor.onApplicationActivated = { application in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(application.bundleIdentifier, NSRunningApplication.current.bundleIdentifier)
            activated.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }

        notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [
                NSWorkspace.applicationUserInfoKey: NSRunningApplication.current,
            ]
        )

        await fulfillment(of: [activated], timeout: 1)
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
            applicationMonitor: appMonitor
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
            applicationMonitor: appMonitor
        )
        XCTAssertEqual(pluginWithRule.primaryPanelState.subtitle, "1 条固定规则")

        pluginWithRule.handleAction(.setSwitch(false))
        XCTAssertFalse(pluginWithRule.primaryPanelState.isOn)
        XCTAssertEqual(pluginWithRule.primaryPanelState.subtitle, "已暂停")
    }

    func testCanonicalActionCanPauseAutoInput() async throws {
        let storage = AutoInputMemoryStorage()
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: FakeAutoInputSourceController(sources: [], currentSourceID: nil),
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.last?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertFalse(plugin.primaryPanelState.isOn)
    }

    func testAdaptiveActionReflectsAndTogglesCurrentState() async throws {
        let storage = AutoInputMemoryStorage()
        let plugin = AutoInputPlugin(
            context: PluginRuntimeContext(pluginID: "auto-input", storage: storage),
            sourceController: FakeAutoInputSourceController(sources: [], currentSourceID: nil),
            applicationMonitor: FakeAutoInputApplicationMonitor(frontmostApplication: nil)
        )

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), ["toggle", "set-enabled"])
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .active)
        let reference = try XCTUnwrap(plugin.actionCatalogEntries.first?.reference)

        let result = try await plugin.beginAction(
            ActionInvocation(reference: reference, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.actionCatalogEntries.first?.presentationState, .inactive)
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
