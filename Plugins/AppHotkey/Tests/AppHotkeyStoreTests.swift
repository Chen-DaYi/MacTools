import XCTest
import MacToolsPluginKit
@testable import AppHotkeyPlugin

@MainActor
final class AppHotkeyStoreTests: XCTestCase {
    func testAddUpdateDeleteAndPersistEntries() {
        let storage = InMemoryPluginStorage()
        let store = AppHotkeyStore(storage: storage)
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari"
        )
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])

        store.addEntry(entry)
        store.updateShortcut(id: entry.id, shortcut: binding)

        let reloaded = AppHotkeyStore(storage: storage)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.displayName, "Safari")
        XCTAssertEqual(reloaded.entries.first?.shortcut, binding)

        reloaded.deleteEntry(id: entry.id)
        XCTAssertTrue(AppHotkeyStore(storage: storage).entries.isEmpty)
    }

    func testConflictDetectionIgnoresExcludedEntry() {
        let store = AppHotkeyStore(storage: InMemoryPluginStorage())
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .control])
        let first = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/A.app"),
            displayName: "A",
            shortcut: binding
        )
        let second = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/B.app"),
            displayName: "B"
        )

        store.addEntry(first)
        store.addEntry(second)

        XCTAssertEqual(store.conflictEntry(for: binding, excludingID: second.id)?.id, first.id)
        XCTAssertNil(store.conflictEntry(for: binding, excludingID: first.id))
    }

    func testShortcutEntryCodableRoundTrip() throws {
        let entry = AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
            displayName: "Xcode",
            shortcut: ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        )

        let decoded = try JSONDecoder().decode(AppShortcutEntry.self, from: JSONEncoder().encode(entry))

        XCTAssertEqual(decoded, entry)
    }
}

@MainActor
final class AppHotkeyPluginTests: XCTestCase {
    func testDefaultStateAndMetadata() {
        let plugin = makePlugin()

        XCTAssertEqual(plugin.metadata.id, "app-hotkey")
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "暂无绑定，前往设置配置")
    }

    func testSubtitleCountsOnlyBoundEntriesAndReflectsDisabledState() {
        let storage = InMemoryPluginStorage()
        let store = AppHotkeyStore(storage: storage)
        store.addEntry(AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            displayName: "Safari",
            shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command])
        ))
        store.addEntry(AppShortcutEntry(
            bundleURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
            displayName: "Xcode"
        ))
        let plugin = makePlugin(storage: storage)

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 个快捷键已启用")

        plugin.handleAction(.setSwitch(false))

        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "快捷键已暂停")
        XCTAssertFalse(storage.bool(forKey: "isEnabled"))
    }

    private func makePlugin() -> AppHotkeyPlugin {
        makePlugin(storage: InMemoryPluginStorage())
    }

    private func makePlugin(storage: InMemoryPluginStorage) -> AppHotkeyPlugin {
        AppHotkeyPlugin(context: PluginRuntimeContext(pluginID: "app-hotkey", storage: storage))
    }
}

@MainActor
private final class InMemoryPluginStorage: PluginStorage {
    private var store: [String: Any] = [:]

    func object(forKey key: String) -> Any? { store[key] }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func string(forKey key: String) -> String? { store[key] as? String }
    func stringArray(forKey key: String) -> [String]? { store[key] as? [String] }
    func integer(forKey key: String) -> Int { store[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard store[key] == nil, let value = store[legacyKey] else { return }
        store[key] = value
        store.removeValue(forKey: legacyKey)
    }
}
