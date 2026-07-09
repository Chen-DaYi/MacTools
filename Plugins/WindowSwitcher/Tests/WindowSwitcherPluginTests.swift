import Carbon.HIToolbox
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import WindowSwitcherPlugin

@MainActor
private final class WindowSwitcherMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? {
        values[key]
    }

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func stringArray(forKey key: String) -> [String]? {
        values[key] as? [String]
    }

    func integer(forKey key: String) -> Int {
        values[key] as? Int ?? 0
    }

    func bool(forKey key: String) -> Bool {
        values[key] as? Bool ?? false
    }

    func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
final class WindowSwitcherPluginTests: XCTestCase {
    func testMetadataIdentifiesPlugin() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "window-switcher")
        XCTAssertEqual(plugin.metadata.title, "窗口切换")
        XCTAssertNil(plugin.primaryPanel)
    }

    func testDefaultConfigurationIsEnabledKeyWindowMode() {
        let store = WindowSwitcherStore(storage: WindowSwitcherMemoryStorage())

        XCTAssertTrue(store.configuration.isEnabled)
        XCTAssertEqual(store.configuration.mode, .keyWindow)
        XCTAssertEqual(store.configuration.sortMode, .recentUse)
    }

    func testModePersists() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)

        store.setMode(.directCycle)

        let loaded = WindowSwitcherStore(storage: storage)
        XCTAssertEqual(loaded.configuration.mode, .directCycle)
    }

    func testSortModePersists() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)

        store.setSortMode(.fixed)

        let loaded = WindowSwitcherStore(storage: storage)
        XCTAssertEqual(loaded.configuration.sortMode, .fixed)
    }

    func testLegacyConfigurationDefaultsToEnabled() throws {
        let storage = WindowSwitcherMemoryStorage()
        let data = try XCTUnwrap(#"{"mode":"directCycle"}"#.data(using: .utf8))
        storage.set(data, forKey: "configuration")

        let store = WindowSwitcherStore(storage: storage)

        XCTAssertTrue(store.configuration.isEnabled)
        XCTAssertEqual(store.configuration.mode, .directCycle)
        XCTAssertEqual(store.configuration.sortMode, .recentUse)
    }

    func testEnabledStatePersists() {
        let storage = WindowSwitcherMemoryStorage()
        let store = WindowSwitcherStore(storage: storage)

        store.setEnabled(false)

        let loaded = WindowSwitcherStore(storage: storage)
        XCTAssertFalse(loaded.configuration.isEnabled)
    }

    func testShortcutDefinitionDefaultsToCommandTab() {
        let plugin = makePlugin()
        let definition = plugin.shortcutDefinitions.first

        XCTAssertEqual(definition?.id, "switcher")
        XCTAssertEqual(definition?.defaultBinding?.keyCode, UInt16(kVK_Tab))
        XCTAssertEqual(definition?.defaultBinding?.modifiers, .command)
        XCTAssertEqual(definition?.isRequired, true)
    }

    func testShortcutDefinitionUsesEventTapScope() throws {
        let plugin = makePlugin()
        let definition = try XCTUnwrap(plugin.shortcutDefinitions.first)

        switch definition.scope {
        case .whilePluginActive:
            break
        case .global:
            XCTFail("WindowSwitcher uses its event tap for shortcut handling.")
        }
    }

    func testPermissionRequirementUsesAccessibility() {
        let plugin = makePlugin(accessibilityTrusted: false)

        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility"])
        XCTAssertFalse(plugin.permissionState(for: "accessibility").isGranted)
    }

    func testShortcutAssignmentUsesSingleKeysBeforeTwoKeySequences() {
        let entries = (0..<28).map { index in
            makeEntry(index: index, appName: "\(index)")
        }

        let assigned = WindowSwitcherShortcutAssignment.assignShortcuts(to: entries)

        XCTAssertEqual(assigned[0].shortcutToken, "f")
        XCTAssertEqual(assigned[1].shortcutToken, "j")
        XCTAssertEqual(assigned[25].shortcutToken, "y")
        XCTAssertEqual(assigned[26].shortcutToken, "ff")
        XCTAssertEqual(assigned[27].shortcutToken, "fj")
    }

    func testShortcutAssignmentPrefersApplicationInitials() {
        let entries = [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Finder", bundleIdentifier: "com.apple.finder"),
        ]

        let assigned = WindowSwitcherShortcutAssignment.assignShortcuts(to: entries)

        XCTAssertEqual(assigned[0].shortcutToken, "s")
        XCTAssertEqual(assigned[1].shortcutToken, "f")
    }

    func testShortcutAssignmentKeepsStoredTokensAcrossOrderChanges() {
        let entries = [
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
            makeEntry(index: 1, appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"),
        ]
        let first = WindowSwitcherShortcutAssignment.assignShortcuts(to: entries, storedAssignments: [:])
        let reordered = [
            makeEntry(index: 1, appName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"),
            makeEntry(index: 0, appName: "Safari", bundleIdentifier: "com.apple.Safari"),
        ]

        let second = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: reordered,
            storedAssignments: first.assignments
        )

        XCTAssertEqual(first.entries[0].shortcutToken, "s")
        XCTAssertEqual(first.entries[1].shortcutToken, "f")
        XCTAssertEqual(second.entries[0].shortcutToken, "f")
        XCTAssertEqual(second.entries[1].shortcutToken, "s")
    }

    func testShortcutAssignmentReleasesAbsentApplicationTokens() {
        let entries = [
            makeEntry(index: 0, appName: "Sketch", bundleIdentifier: "com.bohemiancoding.sketch3"),
        ]
        let stored = ["bundle:com.apple.Safari": "s"]

        let result = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            storedAssignments: stored
        )

        XCTAssertEqual(result.entries[0].shortcutToken, "s")
        XCTAssertNil(result.assignments["bundle:com.apple.Safari"])
        XCTAssertEqual(result.assignments["bundle:com.bohemiancoding.sketch3"], "s")
    }

    func testShortcutAssignmentKeepsTwoKeyStoredTokenWhenListShrinks() {
        let entries = [
            makeEntry(index: 0, appName: "Numbers", bundleIdentifier: "com.apple.Numbers"),
        ]
        let stored = ["bundle:com.apple.Numbers": "ff"]

        let result = WindowSwitcherShortcutAssignment.assignShortcuts(
            to: entries,
            storedAssignments: stored
        )

        XCTAssertEqual(result.entries[0].shortcutToken, "ff")
        XCTAssertEqual(result.assignments["bundle:com.apple.Numbers"], "ff")
    }

    private func makePlugin(accessibilityTrusted: Bool = true) -> WindowSwitcherPlugin {
        WindowSwitcherPlugin(
            context: PluginRuntimeContext(
                pluginID: "window-switcher",
                storage: WindowSwitcherMemoryStorage()
            ),
            accessibilityTrusted: { accessibilityTrusted },
            requestAccessibilityTrust: { _ in accessibilityTrusted }
        )
    }

    private func makeEntry(
        index: Int,
        appName: String,
        bundleIdentifier: String? = nil
    ) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(
            id: "app-\(index)",
            processIdentifier: pid_t(index + 100),
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            windowTitle: nil,
            icon: nil,
            windowElement: nil,
            isMinimized: false,
            shortcutToken: nil
        )
    }
}
