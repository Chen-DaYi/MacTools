import Foundation
import MacToolsPluginKit

struct PreferencesBackup: Codable, Equatable {
    static let currentFormatVersion = 1

    struct ApplicationPreferences: Codable, Equatable {
        let appearancePreference: String
        let languagePreference: String
        let menuBarClickBehavior: String
    }

    let formatVersion: Int
    let exportedAt: Date
    let application: ApplicationPreferences
    let pluginDisplay: PluginDisplayPreferencesBackup
    let shortcutCustomizations: [String: ShortcutCustomization]

    init(
        application: ApplicationPreferences,
        pluginDisplay: PluginDisplayPreferencesBackup,
        shortcutCustomizations: [String: ShortcutCustomization],
        exportedAt: Date = .now
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.application = application
        self.pluginDisplay = pluginDisplay
        self.shortcutCustomizations = shortcutCustomizations
    }

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw PreferencesBackupError.unsupportedFormatVersion(formatVersion)
        }

        guard AppAppearancePreference(rawValue: application.appearancePreference) != nil,
              AppLanguagePreference(rawValue: application.languagePreference) != nil,
              MenuBarClickBehaviorPreference(rawValue: application.menuBarClickBehavior) != nil
        else {
            throw PreferencesBackupError.invalidApplicationPreferences
        }
    }

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decodeJSON(_ data: Data) throws -> PreferencesBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(PreferencesBackup.self, from: data)
        try backup.validate()
        return backup
    }
}

struct PluginDisplayPreferencesBackup: Codable, Equatable {
    let orderedPluginIDs: [String]
    let hiddenPluginIDs: [String]
}

struct PreferencesImportPreview: Equatable {
    let pluginCount: Int
    let unavailablePluginIDs: [String]
    let shortcutCount: Int
    let unavailableShortcutIDs: [String]

    var applicationSummary: String {
        "应用外观、语言和状态栏点击行为"
    }
}

enum PreferencesBackupError: LocalizedError {
    case unsupportedFormatVersion(Int)
    case invalidApplicationPreferences

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormatVersion(version):
            return "不支持的偏好设置备份版本（\(version)）。"
        case .invalidApplicationPreferences:
            return "备份中的应用偏好设置无效。"
        }
    }
}

@MainActor
final class PreferencesBackupStore {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func applicationPreferences() -> PreferencesBackup.ApplicationPreferences {
        PreferencesBackup.ApplicationPreferences(
            appearancePreference: AppAppearancePreference.stored(in: userDefaults).rawValue,
            languagePreference: AppLanguagePreference.stored(in: userDefaults).rawValue,
            menuBarClickBehavior: MenuBarClickBehaviorPreference.current(userDefaults).rawValue
        )
    }

    func apply(_ preferences: PreferencesBackup.ApplicationPreferences) {
        guard let appearance = AppAppearancePreference(rawValue: preferences.appearancePreference),
              let language = AppLanguagePreference(rawValue: preferences.languagePreference),
              let clickBehavior = MenuBarClickBehaviorPreference(rawValue: preferences.menuBarClickBehavior)
        else {
            return
        }

        userDefaults.set(appearance.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
        appearance.apply()
        language.store(in: userDefaults)
        userDefaults.set(clickBehavior.rawValue, forKey: MenuBarClickBehaviorPreference.userDefaultsKey)
    }
}
