import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PreferencesBackupTests: XCTestCase {
    private let suiteName = "PreferencesBackupTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testExportContainsOnlyPortableHostAndKnownPluginPreferences() throws {
        let defaults = makeDefaults()
        defaults.set(AppAppearancePreference.dark.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
        defaults.set(AppLanguagePreference.en.rawValue, forKey: AppLanguagePreference.userDefaultsKey)
        defaults.set(MenuBarClickBehaviorPreference.swapped.rawValue, forKey: MenuBarClickBehaviorPreference.userDefaultsKey)
        defaults.set("api-key-value", forKey: "translator.apiKey")

        let firstPlugin = BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle")
        let secondPlugin = BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
        let host = makeHost(plugins: [firstPlugin, secondPlugin], defaults: defaults)
        host.setFeatureVisibility(false, for: firstPlugin.metadata.id)
        host.moveFeatureManagementItem(id: secondPlugin.metadata.id, by: -1)
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command, .shift]),
            for: "first.shortcut.toggle"
        )

        let backup = host.makePreferencesBackup()
        let decodedBackup = try PreferencesBackup.decodeJSON(backup.encodedJSON())

        XCTAssertEqual(decodedBackup.formatVersion, PreferencesBackup.currentFormatVersion)
        XCTAssertEqual(decodedBackup.application, backup.application)
        XCTAssertEqual(decodedBackup.pluginDisplay, backup.pluginDisplay)
        XCTAssertEqual(decodedBackup.shortcutCustomizations, backup.shortcutCustomizations)
        XCTAssertEqual(backup.application.appearancePreference, AppAppearancePreference.dark.rawValue)
        XCTAssertEqual(backup.application.languagePreference, AppLanguagePreference.en.rawValue)
        XCTAssertEqual(backup.application.menuBarClickBehavior, MenuBarClickBehaviorPreference.swapped.rawValue)
        XCTAssertEqual(backup.pluginDisplay.orderedPluginIDs, ["second", "first"])
        XCTAssertEqual(backup.pluginDisplay.hiddenPluginIDs, ["first"])
        XCTAssertEqual(
            backup.shortcutCustomizations["first.shortcut.toggle"],
            .custom(ShortcutBinding(keyCode: 12, modifiers: [.command, .shift]))
        )
        XCTAssertNil(backup.shortcutCustomizations["second.shortcut.open"])
        XCTAssertFalse(try XCTUnwrap(String(data: backup.encodedJSON(), encoding: .utf8)).contains("api-key-value"))
    }

    func testPreviewReportsUnavailablePluginAndShortcutSettings() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [BackupTestPlugin(id: "available", order: 1, shortcutID: "toggle")],
            defaults: defaults
        )
        let backup = PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: AppAppearancePreference.system.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["available", "unavailable"],
                hiddenPluginIDs: ["unavailable"]
            ),
            shortcutCustomizations: [
                "available.shortcut.toggle": .cleared,
                "unavailable.shortcut.toggle": .cleared
            ]
        )

        let preview = try host.preferencesImportPreview(for: backup)

        XCTAssertEqual(preview.pluginCount, 1)
        XCTAssertEqual(preview.unavailablePluginIDs, ["unavailable"])
        XCTAssertEqual(preview.shortcutCount, 1)
        XCTAssertEqual(preview.unavailableShortcutIDs, ["unavailable.shortcut.toggle"])
    }

    func testPreviewOffersOnlyCatalogInstallableMissingPlugins() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["available", "installable", "incompatible"],
                hiddenPluginIDs: []
            ),
            shortcutCustomizations: [:]
        )
        let preview = try PreferencesImportPreview.make(
            backup: backup,
            availablePluginIDs: ["available"],
            availableShortcutIDs: [],
            pluginManagementItems: [
                PluginManagementItem(
                    id: "installable",
                    title: "Installable",
                    summary: "Available from the verified catalog.",
                    version: "1.0.0",
                    state: .available,
                    packageURL: nil,
                    requiresRestartToFullyUnload: false,
                    releaseNotesURL: nil
                ),
                PluginManagementItem(
                    id: "incompatible",
                    title: "Incompatible",
                    summary: nil,
                    version: "1.0.0",
                    state: .incompatible("Requires a newer MacTools version."),
                    packageURL: nil,
                    requiresRestartToFullyUnload: false,
                    releaseNotesURL: nil
                )
            ]
        )

        XCTAssertEqual(preview.installablePlugins.map(\.id), ["installable"])
        XCTAssertEqual(preview.unavailablePluginIDs, ["incompatible"])
    }

    func testImportRestoresDisplayPreferencesAndShortcutCustomizations() throws {
        let defaults = makeDefaults()
        let host = makeHost(
            plugins: [
                BackupTestPlugin(id: "first", order: 1, shortcutID: "toggle"),
                BackupTestPlugin(id: "second", order: 2, shortcutID: "open")
            ],
            defaults: defaults
        )
        host.setShortcutBinding(
            ShortcutBinding(keyCode: 12, modifiers: [.command]),
            for: "first.shortcut.toggle"
        )
        let backup = PreferencesBackup(
            application: PreferencesBackup.ApplicationPreferences(
                appearancePreference: AppAppearancePreference.system.rawValue,
                languagePreference: AppLanguagePreference.system.rawValue,
                menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
            ),
            pluginDisplay: PluginDisplayPreferencesBackup(
                orderedPluginIDs: ["second", "unavailable", "first"],
                hiddenPluginIDs: ["first", "unavailable"]
            ),
            shortcutCustomizations: [
                "second.shortcut.open": .cleared,
                "unavailable.shortcut.toggle": .cleared
            ]
        )

        try host.importPreferences(backup)

        XCTAssertEqual(host.featureManagementItems.map(\.id), ["second", "first"])
        XCTAssertFalse(host.featureManagementItems.first(where: { $0.id == "first" })?.isVisible ?? true)
        XCTAssertFalse(host.shortcutItems.first(where: { $0.id == "second.shortcut.open" })?.canClear ?? true)
        XCTAssertTrue(host.shortcutItems.first(where: { $0.id == "first.shortcut.toggle" })?.usesDefaultValue ?? false)
    }

    func testDecodeRejectsUnsupportedFormatVersion() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        json["formatVersion"] = 2

        XCTAssertThrowsError(try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))) { error in
            guard case PreferencesBackupError.unsupportedFormatVersion(2) = error else {
                return XCTFail("Expected unsupported format version error, got \(error)")
            }
        }
    }

    func testDecodeRejectsInvalidApplicationPreferences() throws {
        let backup = PreferencesBackup(
            application: validApplicationPreferences,
            pluginDisplay: PluginDisplayPreferencesBackup(orderedPluginIDs: [], hiddenPluginIDs: []),
            shortcutCustomizations: [:]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: backup.encodedJSON()) as? [String: Any])
        var application = try XCTUnwrap(json["application"] as? [String: Any])
        application["languagePreference"] = "unsupported-language"
        json["application"] = application

        XCTAssertThrowsError(try PreferencesBackup.decodeJSON(JSONSerialization.data(withJSONObject: json))) { error in
            guard case PreferencesBackupError.invalidApplicationPreferences = error else {
                return XCTFail("Expected invalid application preferences error, got \(error)")
            }
        }
    }

    private var validApplicationPreferences: PreferencesBackup.ApplicationPreferences {
        PreferencesBackup.ApplicationPreferences(
            appearancePreference: AppAppearancePreference.system.rawValue,
            languagePreference: AppLanguagePreference.system.rawValue,
            menuBarClickBehavior: MenuBarClickBehaviorPreference.standard.rawValue
        )
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeHost(
        plugins: [any MacToolsPlugin],
        defaults: UserDefaults
    ) -> PluginHost {
        PluginHost(
            plugins: plugins,
            shortcutStore: ShortcutStore(userDefaults: defaults),
            pluginDisplayPreferencesStore: PluginDisplayPreferencesStore(userDefaults: defaults),
            preferencesBackupStore: PreferencesBackupStore(userDefaults: defaults),
            globalShortcutManager: GlobalShortcutManager()
        )
    }
}

@MainActor
private final class BackupTestPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    let shortcutDefinitions: [PluginShortcutDefinition]
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    init(id: String, order: Int, shortcutID: String) {
        metadata = PluginMetadata(
            id: id,
            title: id,
            iconName: "gearshape",
            iconTint: .blue,
            order: order,
            defaultDescription: id
        )
        shortcutDefinitions = [
            PluginShortcutDefinition(
                id: shortcutID,
                title: shortcutID,
                description: shortcutID,
                actionID: shortcutID,
                scope: .global,
                defaultBinding: nil,
                isRequired: false
            )
        ]
    }
}
