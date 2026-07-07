import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class PluginPackageStoreTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private let suiteName = "PluginPackageStoreTests"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginPackageStoreTests-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        temporaryRoot = nil
    }

    func testInstallCopiesPackageIntoInstalledDirectoryAndEnablesPlugin() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()

        let record = try store.installPackage(from: sourceURL)

        XCTAssertEqual(record.id, "com.example.demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.packageURL.path))
        XCTAssertEqual(store.installedRecords().map(\.id), ["com.example.demo"])
        XCTAssertEqual(store.installedRecords().first?.state, .enabled)
    }

    func testDisableRemovesPluginFromEnabledRecordsButKeepsFiles() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)

        store.setEnabled(false, for: "com.example.demo")

        let record = try XCTUnwrap(store.installedRecords().first)
        XCTAssertEqual(record.state, .disabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.packageURL.path))
        XCTAssertTrue(record.requiresRestartToFullyUnload)
    }

    func testReenableClearsPendingRestartWarning() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)

        store.setEnabled(false, for: "com.example.demo")
        store.setEnabled(true, for: "com.example.demo")

        let record = try XCTUnwrap(store.installedRecords().first)
        XCTAssertEqual(record.state, .enabled)
        XCTAssertFalse(record.requiresRestartToFullyUnload)
    }

    func testInstallRejectsPreviousPluginKitPackage() throws {
        let sourceURL = try makePackage(
            id: "com.example.demo",
            pluginKitVersion: 1
        )
        let store = makeStore()

        XCTAssertThrowsError(try store.installPackage(from: sourceURL)) { error in
            XCTAssertEqual(error as? PluginPackageManifestError, .unsupportedPluginKitVersion(1))
        }
    }

    func testExistingPreviousPluginKitPackageIsMarkedIncompatible() throws {
        let sourceURL = try makePackage(
            id: "com.example.demo",
            pluginKitVersion: 1
        )
        let store = makeStore()
        let installedURL = store.installedDirectory
            .appendingPathComponent("com.example.demo", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        try FileManager.default.copyItem(at: sourceURL, to: installedURL)

        let record = try XCTUnwrap(store.installedRecords().first)

        XCTAssertEqual(
            record.state,
            .incompatible(
                AppL10n.pluginsFormat(
                    "plugin.error.store.installedSDKIncompatibleFormat",
                    defaultValue: "插件 SDK 版本不兼容，已安装版本为 %d，当前支持版本为 %d。请更新插件。",
                    1,
                    PluginPackageManifestLoader.supportedPluginKitVersion
                )
            )
        )
    }

    func testUninstallDeletesPackageAndCanRemoveStorage() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let storage = UserDefaultsPluginStorage(pluginID: "com.example.demo", userDefaults: defaults)
        storage.set("value", forKey: "setting")

        try store.uninstall(pluginID: "com.example.demo", removeData: true)

        XCTAssertTrue(store.installedRecords().isEmpty)
        XCTAssertNil(defaults.object(forKey: "plugin.com.example.demo.setting"))
    }

    func testFailedUpdateRestoresExistingPackage() throws {
        let sourceURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let invalidUpdateURL = try makePackage(id: "com.example.demo", version: "2.0.0", bundleRelativePath: "Missing.bundle")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)

        do {
            _ = try store.updatePackage(from: invalidUpdateURL)
            XCTFail("Expected update failure")
        } catch {
            // Expected path.
        }

        let record = try XCTUnwrap(store.installedRecords().first)
        XCTAssertEqual(record.manifest.version, "1.0.0")
        XCTAssertEqual(record.state, .enabled)
    }

    func testUpdateKeepsDisabledPluginDisabled() throws {
        let sourceURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let updateURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        store.setEnabled(false, for: "com.example.demo")

        _ = try store.updatePackage(from: updateURL)

        let record = try XCTUnwrap(store.installedRecords().first)
        XCTAssertEqual(record.manifest.version, "2.0.0")
        XCTAssertEqual(record.state, .disabled)
    }

    func testDefaultRootDirectoryUsesCurrentApplicationSupportScope() {
        let rootDirectory = PluginPackageStore.defaultRootDirectory(fileManager: .default)

        XCTAssertEqual(rootDirectory.lastPathComponent, "Plugins")
        XCTAssertEqual(
            rootDirectory.deletingLastPathComponent().lastPathComponent,
            AppStorageScope.applicationSupportDirectoryName
        )
    }

    private func makeStore() -> PluginPackageStore {
        PluginPackageStore(
            rootDirectory: temporaryRoot,
            userDefaults: defaults,
            hostVersion: "1.0.0"
        )
    }

    private func makePackage(
        id: String,
        version: String = "1.0.0",
        bundleRelativePath: String = "Demo.bundle",
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion
    ) throws -> URL {
        let packageURL = temporaryRoot
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent("\(id)-\(version)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = packageURL.appendingPathComponent(bundleRelativePath, isDirectory: true)

        if bundleRelativePath == "Demo.bundle" {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        }

        let manifest = PluginPackageManifest(
            id: id,
            displayName: "Demo",
            version: version,
            minHostVersion: "0.1.0",
            pluginKitVersion: pluginKitVersion,
            bundleRelativePath: bundleRelativePath
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("plugin.json"))

        return packageURL
    }
}
