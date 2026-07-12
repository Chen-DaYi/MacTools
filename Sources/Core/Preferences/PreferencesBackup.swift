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

    init(application: ApplicationPreferences, pluginDisplay: PluginDisplayPreferencesBackup, shortcutCustomizations: [String: ShortcutCustomization], exportedAt: Date = .now) {
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
        guard Self.appearancePreferenceValues.contains(application.appearancePreference),
              Self.languagePreferenceValues.contains(application.languagePreference),
              Self.menuBarClickBehaviorValues.contains(application.menuBarClickBehavior)
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

    private static let appearancePreferenceValues: Set<String> = ["system", "dark", "light"]
    private static let languagePreferenceValues: Set<String> = ["system", "zh-Hans", "zh-Hant", "en", "es", "fr", "ru", "pt", "de", "ja", "ko", "ar"]
    private static let menuBarClickBehaviorValues: Set<String> = ["standard", "swapped"]
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
    let installablePlugins: [PreferencesImportInstallablePlugin]

    static func make(backup: PreferencesBackup, availablePluginIDs: Set<String>, availableShortcutIDs: Set<String>, pluginManagementItems: [PluginManagementItem]) throws -> PreferencesImportPreview {
        try backup.validate()
        let backedUpPluginIDs = Set(backup.pluginDisplay.orderedPluginIDs).union(backup.pluginDisplay.hiddenPluginIDs)
        let missingPluginIDs = backedUpPluginIDs.subtracting(availablePluginIDs)
        let managementItemsByID = Dictionary(pluginManagementItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let installablePlugins = missingPluginIDs.compactMap { pluginID -> PreferencesImportInstallablePlugin? in
            guard let item = managementItemsByID[pluginID], item.canInstall else { return nil }
            return PreferencesImportInstallablePlugin(id: item.id, title: item.title, summary: item.summary, version: item.version)
        }
        let installablePluginIDs = Set(installablePlugins.map(\.id))
        let backedUpShortcutIDs = Set(backup.shortcutCustomizations.keys)
        return PreferencesImportPreview(
            pluginCount: backedUpPluginIDs.intersection(availablePluginIDs).count,
            unavailablePluginIDs: missingPluginIDs.subtracting(installablePluginIDs).sorted(),
            shortcutCount: backedUpShortcutIDs.intersection(availableShortcutIDs).count,
            unavailableShortcutIDs: backedUpShortcutIDs.subtracting(availableShortcutIDs).sorted(),
            installablePlugins: installablePlugins.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        )
    }
}

struct PreferencesImportInstallablePlugin: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String?
    let version: String
}

struct PreferencesImportResult: Equatable {
    let installedPluginIDs: [String]
    let pluginInstallationFailures: [String: String]
    let shortcutErrors: [String: String]
}

enum PreferencesBackupError: Error, Equatable {
    case unsupportedFormatVersion(Int)
    case invalidApplicationPreferences
}

@MainActor
protocol PreferencesBackupApplicationStoring: AnyObject {
    func applicationPreferences() -> PreferencesBackup.ApplicationPreferences
    func apply(_ preferences: PreferencesBackup.ApplicationPreferences)
}

@MainActor
final class UserDefaultsPreferencesBackupStore: PreferencesBackupApplicationStoring {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func applicationPreferences() -> PreferencesBackup.ApplicationPreferences {
        PreferencesBackup.ApplicationPreferences(
            appearancePreference: userDefaults.string(forKey: "app.appearancePreference") ?? "system",
            languagePreference: userDefaults.string(forKey: "app.languagePreference") ?? "system",
            menuBarClickBehavior: userDefaults.string(forKey: "menuBar.clickBehaviorPreference") ?? "standard"
        )
    }

    func apply(_ preferences: PreferencesBackup.ApplicationPreferences) {
        userDefaults.set(preferences.appearancePreference, forKey: "app.appearancePreference")
        userDefaults.set(preferences.languagePreference, forKey: "app.languagePreference")
        userDefaults.set(preferences.menuBarClickBehavior, forKey: "menuBar.clickBehaviorPreference")
    }
}
