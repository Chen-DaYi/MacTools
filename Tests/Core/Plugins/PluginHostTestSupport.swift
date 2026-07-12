import Foundation
import MacToolsPluginKit
@testable import MacTools

@MainActor
func makePluginHostForTests(
    plugins: [any MacToolsPlugin],
    suiteName: String = "PluginHostTestSupport-\(UUID().uuidString)"
) -> PluginHost {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    return PluginHost(
        plugins: plugins,
        shortcutStore: ShortcutStore(userDefaults: defaults),
        pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
        preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
        globalShortcutManager: GlobalShortcutManager()
    )
}
