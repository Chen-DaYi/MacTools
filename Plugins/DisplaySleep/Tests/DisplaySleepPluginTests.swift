import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DisplaySleepPlugin

@MainActor
final class DisplaySleepPluginTests: XCTestCase {
    func testMetadataIdentifiesDisplaySleepPlugin() {
        let plugin = DisplaySleepPlugin()

        XCTAssertEqual(plugin.metadata.id, "display-sleep")
        XCTAssertEqual(plugin.metadata.title, "显示器休眠")
    }

    func testControlStyleIsButton() {
        let plugin = DisplaySleepPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.buttonTitle, "休眠")
    }

    func testInitialStateIsOffAndEnabled() {
        let plugin = DisplaySleepPlugin()

        let state = plugin.primaryPanelState
        XCTAssertFalse(state.isOn)
        XCTAssertTrue(state.isEnabled)
    }

    func testPermissionRequirementsIsEmpty() {
        let plugin = DisplaySleepPlugin()

        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testMenuActionBehaviorDismissesBeforeHandling() {
        let plugin = DisplaySleepPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.menuActionBehavior, .dismissBeforeHandling)
    }

    func testPluginHostIncludesDisplaySleepWhenProvided() {
        let host = makePluginHostForTests(plugins: [DisplaySleepPlugin()])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "display-sleep" })
    }

    func testPluginDescriptionMatches() {
        let plugin = DisplaySleepPlugin()

        XCTAssertEqual(plugin.metadata.defaultDescription, "立即让显示器休眠")
    }

    func testHandleUnknownActionDoesNothing() {
        let plugin = DisplaySleepPlugin()

        plugin.handleAction(.setSwitch(true))
    }

    func testCommandDefinitionsFollowRuntimeLanguageWithoutRecreatingPlugin() throws {
        let preferenceKey = PluginRuntimeLocalization.preferenceUserDefaultsKey
        let originalPreference = UserDefaults.standard.string(forKey: preferenceKey)
        let bundleURL = try makeCommandLocalizationBundle()
        defer {
            try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent())
            restoreRuntimePreference(originalPreference, key: preferenceKey)
        }
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        setRuntimePreference("en", key: preferenceKey)
        let plugin = DisplaySleepPlugin(localization: PluginLocalization(bundle: bundle))
        XCTAssertEqual(plugin.commandDefinitions.first?.title, "Display Sleep")
        XCTAssertEqual(plugin.commandDefinitions.first?.description, "Sleep displays now")

        setRuntimePreference("zh-Hans", key: preferenceKey)
        XCTAssertEqual(plugin.commandDefinitions.first?.title, "显示器休眠")
        XCTAssertEqual(plugin.commandDefinitions.first?.description, "立即让显示器休眠")
    }

    private func makeCommandLocalizationBundle() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("DisplaySleepTests.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let translations = [
            "en": ("Display Sleep", "Sleep displays now"),
            "zh-Hans": ("显示器休眠", "立即让显示器休眠"),
        ]
        for (language, values) in translations {
            let languageURL = bundleURL.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: languageURL, withIntermediateDirectories: true)
            let strings = """
            "metadata.title" = "\(values.0)";
            "metadata.description" = "\(values.1)";
            """
            try strings.write(
                to: languageURL.appendingPathComponent("Localizable.strings"),
                atomically: true,
                encoding: .utf8
            )
        }

        return bundleURL
    }

    private func setRuntimePreference(_ preference: String, key: String) {
        UserDefaults.standard.set(preference, forKey: key)
        PluginRuntimeLocalization.source.setPreference(preference)
    }

    private func restoreRuntimePreference(_ preference: String?, key: String) {
        if let preference {
            UserDefaults.standard.set(preference, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        PluginRuntimeLocalization.source.setPreference(preference)
    }
}
