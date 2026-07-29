import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import LockScreenPlugin

@MainActor
final class LockScreenPluginTests: XCTestCase {
    func testMetadataIdentifiesLockScreenPlugin() {
        let plugin = LockScreenPlugin()

        XCTAssertEqual(plugin.metadata.id, "lock-screen")
        XCTAssertEqual(plugin.metadata.title, "锁定屏幕")
    }

    func testControlStyleIsButton() {
        let plugin = LockScreenPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .button)
        XCTAssertEqual(plugin.primaryPanelDescriptor.buttonTitle, "锁定")
    }

    func testInitialStateIsOffAndEnabled() {
        let plugin = LockScreenPlugin()

        let state = plugin.primaryPanelState
        XCTAssertFalse(state.isOn)
        XCTAssertTrue(state.isEnabled)
    }

    func testPermissionRequirementsIsEmpty() {
        let plugin = LockScreenPlugin()

        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testMenuActionBehaviorDismissesBeforeHandling() {
        let plugin = LockScreenPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.menuActionBehavior, .dismissBeforeHandling)
    }

    func testPluginHostIncludesLockScreenWhenProvided() {
        let host = makePluginHostForTests(plugins: [LockScreenPlugin()])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "lock-screen" })
    }

    func testPluginDescriptionMatches() {
        let plugin = LockScreenPlugin()

        XCTAssertEqual(plugin.metadata.defaultDescription, "立即锁定屏幕")
    }

    func testHandleUnknownActionDoesNothing() {
        let plugin = LockScreenPlugin()

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
        let plugin = LockScreenPlugin(localization: PluginLocalization(bundle: bundle))
        XCTAssertEqual(plugin.commandDefinitions.first?.title, "Lock Screen")
        XCTAssertEqual(plugin.commandDefinitions.first?.description, "Lock the screen now")

        setRuntimePreference("zh-Hans", key: preferenceKey)
        XCTAssertEqual(plugin.commandDefinitions.first?.title, "锁定屏幕")
        XCTAssertEqual(plugin.commandDefinitions.first?.description, "立即锁定屏幕")
    }

    private func makeCommandLocalizationBundle() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = directory.appendingPathComponent("LockScreenTests.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let translations = [
            "en": ("Lock Screen", "Lock the screen now"),
            "zh-Hans": ("锁定屏幕", "立即锁定屏幕"),
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
