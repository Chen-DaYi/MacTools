import Foundation
import MacToolsPluginKit

enum AppL10n {
    static func string(
        _ key: String,
        defaultValue: String,
        table: String = "Localizable",
        bundle: Bundle = .main
    ) -> String {
        PluginRuntimeLocalization.string(
            key,
            defaultValue: defaultValue,
            table: table,
            bundle: bundle
        )
    }

    static func settings(_ key: String, defaultValue: String) -> String {
        string(key, defaultValue: defaultValue, table: "Settings")
    }

    static func plugins(_ key: String, defaultValue: String) -> String {
        string(key, defaultValue: defaultValue, table: "Plugins")
    }

    static func search(_ key: String, defaultValue: String) -> String {
        string(key, defaultValue: defaultValue, table: "Search")
    }

    static func preferencesBackup(_ key: String, defaultValue: String) -> String {
        string(key, defaultValue: defaultValue, table: "PreferencesBackup")
    }

    static func settingsFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: settings(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    static func pluginsFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: plugins(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    static func searchFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: search(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    static func searchPluralFormat(
        _ key: String,
        defaultValue: String,
        count: Int
    ) -> String {
        String(
            format: search(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: [count]
        )
    }

    static func preferencesBackupFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: preferencesBackup(key, defaultValue: defaultValue),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
