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
}
