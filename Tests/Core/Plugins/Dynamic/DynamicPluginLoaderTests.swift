import XCTest
import SwiftUI
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class DynamicPluginLoaderTests: XCTestCase {
    func testValidateLoadedPluginsAcceptsSinglePluginMatchingManifestID() throws {
        let record = makeRecord(id: "com.example.demo")
        let plugin = MockLoadedPlugin(id: "com.example.demo")

        XCTAssertNoThrow(try DynamicPluginLoader.validateLoadedPlugins([plugin], for: record))
    }

    func testValidateLoadedPluginsRejectsEmptyPluginList() {
        let record = makeRecord(id: "com.example.demo")

        XCTAssertThrowsError(try DynamicPluginLoader.validateLoadedPlugins([], for: record)) { error in
            XCTAssertEqual(
                error as? DynamicPluginLoaderError,
                .invalidPluginCount(expected: "com.example.demo", actual: 0)
            )
        }
    }

    func testValidateLoadedPluginsRejectsMultiplePluginsFromOnePackage() {
        let record = makeRecord(id: "com.example.demo")
        let plugins = [
            MockLoadedPlugin(id: "com.example.demo"),
            MockLoadedPlugin(id: "com.example.extra")
        ]

        XCTAssertThrowsError(try DynamicPluginLoader.validateLoadedPlugins(plugins, for: record)) { error in
            XCTAssertEqual(
                error as? DynamicPluginLoaderError,
                .invalidPluginCount(expected: "com.example.demo", actual: 2)
            )
        }
    }

    func testValidateLoadedPluginsRejectsRuntimeIdentifierMismatch() {
        let record = makeRecord(id: "com.example.demo")
        let plugin = MockLoadedPlugin(id: "com.example.other")

        XCTAssertThrowsError(try DynamicPluginLoader.validateLoadedPlugins([plugin], for: record)) { error in
            XCTAssertEqual(
                error as? DynamicPluginLoaderError,
                .pluginIdentifierMismatch(expected: "com.example.demo", actual: "com.example.other")
            )
        }
    }

    func testFailedLoadTeardownRequiresCleanupOfPartialExternalSession() {
        let plugin = MockLoadedPlugin(id: "com.example.demo", externalSessionIsActive: true)

        DynamicPluginLoader.deactivateAfterFailedLoad(
            [plugin],
            recordID: "com.example.demo"
        )

        XCTAssertEqual(plugin.deactivationReasons, [.disabled])
        XCTAssertFalse(plugin.externalSessionIsActive)
    }

    private func makeRecord(id: String) -> PluginPackageRecord {
        let packageURL = URL(fileURLWithPath: "/tmp/\(id).mactoolsplugin", isDirectory: true)
        return PluginPackageRecord(
            id: id,
            manifest: PluginPackageManifest(
                id: id,
                displayName: "Demo",
                version: "1.0.0",
                minHostVersion: "0.15.2",
                bundleRelativePath: "Demo.bundle"
            ),
            packageURL: packageURL,
            bundleURL: packageURL.appendingPathComponent("Demo.bundle", isDirectory: true),
            state: .installed,
            requiresRestartToFullyUnload: false
        )
    }
}

@MainActor
private final class MockLoadedPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var deactivationReasons: [PluginDeactivationReason] = []
    private(set) var externalSessionIsActive: Bool

    init(id: String, externalSessionIsActive: Bool = false) {
        self.externalSessionIsActive = externalSessionIsActive
        metadata = PluginMetadata(
            id: id,
            title: "Demo",
            iconName: "shippingbox",
            iconTint: .blue,
            order: 1,
            defaultDescription: "Demo"
        )
    }

    func deactivate(reason: PluginDeactivationReason) {
        deactivationReasons.append(reason)
        if reason.requiresStateCleanup {
            externalSessionIsActive = false
        }
    }
}
