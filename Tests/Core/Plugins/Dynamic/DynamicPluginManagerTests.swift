import Foundation
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class DynamicPluginManagerTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private let suiteName = "DynamicPluginManagerTests"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicPluginManagerTests-\(UUID().uuidString)", isDirectory: true)
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

    func testDisablingLoadedPluginRemovesItAndDefersReloadUntilRestart() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])

        manager.setPluginEnabled(false, pluginID: "com.example.demo")

        XCTAssertEqual(plugin.deactivationReasons, [.disabled])
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .disabled)
        XCTAssertEqual(
            manager.pluginManagementItems.first?.detailText,
            AppL10n.plugins(
                "plugin.detail.restartRequiredAfterRemoval",
                defaultValue: "已移出界面，重启后彻底释放已加载代码。"
            )
        )
    }

    func testReloadKeepsExistingLoadedPluginInstances() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])
        XCTAssertEqual(loader.receivedRecordIDBatches, [["com.example.demo"]])

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])

        XCTAssertEqual(loader.receivedRecordIDBatches, [["com.example.demo"]])
        XCTAssertTrue(plugin.deactivationReasons.isEmpty)
    }

    func testUpdatingLoadedPluginInstallsFilesButDoesNotReloadNativeCodeUntilRestart() throws {
        let firstPackageURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let updatePackageURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: firstPackageURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])

        try manager.updatePluginPackage(from: updatePackageURL)

        XCTAssertEqual(plugin.deactivationReasons, [.updating])
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        XCTAssertEqual(store.installedRecords().first?.manifest.version, "2.0.0")
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .restartRequired)
        XCTAssertEqual(
            manager.pluginManagementItems.first?.detailText,
            AppL10n.plugins(
                "plugin.detail.restartRequiredAfterUpdate",
                defaultValue: "新版本将在重启后启用，旧代码将在重启后彻底释放。"
            )
        )
    }

    func testBatchUpdatingLoadedPluginsReloadsOnlyOnce() throws {
        let firstAlphaURL = try makePackage(id: "com.example.alpha", version: "1.0.0", displayName: "Alpha")
        let firstBetaURL = try makePackage(id: "com.example.beta", version: "1.0.0", displayName: "Beta")
        let updateAlphaURL = try makePackage(id: "com.example.alpha", version: "2.0.0", displayName: "Alpha")
        let updateBetaURL = try makePackage(id: "com.example.beta", version: "2.0.0", displayName: "Beta")
        let store = makeStore()
        _ = try store.installPackage(from: firstAlphaURL)
        _ = try store.installPackage(from: firstBetaURL)
        let alphaPlugin = MockDynamicPlugin(id: "com.example.alpha")
        let betaPlugin = MockDynamicPlugin(id: "com.example.beta")
        let pluginsByID = [
            "com.example.alpha": alphaPlugin,
            "com.example.beta": betaPlugin,
        ]
        let loader = StubDynamicPluginLoader { records in
            records.compactMap { record in
                guard let plugin = pluginsByID[record.id] else {
                    return nil
                }

                return DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        var pluginChangeBatches: [[String]] = []
        manager.onPluginsChanged = { plugins in
            pluginChangeBatches.append(plugins.map(\.metadata.id))
        }

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.alpha", "com.example.beta"])

        let failures = manager.updatePluginPackages([
            (sourceURL: updateAlphaURL, catalogEntry: makeCatalogEntry(id: "com.example.alpha", version: "2.0.0")),
            (sourceURL: updateBetaURL, catalogEntry: makeCatalogEntry(id: "com.example.beta", version: "2.0.0")),
        ])

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(loader.receivedRecordIDBatches, [
            ["com.example.alpha", "com.example.beta"],
        ])
        XCTAssertEqual(pluginChangeBatches, [[]])
        XCTAssertEqual(alphaPlugin.deactivationReasons, [.updating])
        XCTAssertEqual(betaPlugin.deactivationReasons, [.updating])
        XCTAssertEqual(
            store.installedRecords().map { "\($0.id):\($0.manifest.version)" },
            [
                "com.example.alpha:2.0.0",
                "com.example.beta:2.0.0",
            ]
        )
        XCTAssertTrue(manager.pluginManagementItems.allSatisfy { item in
            if case .restartRequired = item.state {
                return true
            }

            return false
        })
    }

    func testUninstallingLoadedPluginDeletesPackageAndRemovesManagementItem() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(record: record, plugins: [plugin], errorMessage: nil)
            }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertEqual(manager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])

        try manager.uninstallPlugin(pluginID: "com.example.demo")

        XCTAssertEqual(plugin.deactivationReasons, [.uninstalling])
        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        XCTAssertTrue(manager.pluginManagementItems.isEmpty)
        XCTAssertTrue(store.installedRecords().isEmpty)
    }

    func testCatalogEntryAddsAvailableManagementItem() throws {
        let store = makeStore()
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: StubDynamicPluginLoader { _ in [] })
        let snapshot = makeCatalogSnapshot(entries: [makeCatalogEntry(id: "com.example.demo", version: "1.0.0")])

        manager.rebuildManagementItems(catalogSnapshot: snapshot)

        XCTAssertEqual(manager.pluginManagementItems.map(\.id), ["com.example.demo"])
        XCTAssertEqual(manager.pluginManagementItems.first?.state, .available)
        XCTAssertEqual(manager.pluginManagementItems.first?.canInstall, true)
    }

    func testInstalledCatalogItemsUseSummaryAsDetailText() throws {
        let sourceURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let store = makeStore()
        let installedRecord = try store.installPackage(from: sourceURL)
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: StubDynamicPluginLoader { _ in [] })
        let snapshot = makeCatalogSnapshot(entries: [makeCatalogEntry(id: "com.example.demo", version: "1.0.0")])

        manager.rebuildManagementItems(catalogSnapshot: snapshot)

        let item = try XCTUnwrap(manager.pluginManagementItems.first)
        XCTAssertEqual(item.state, .enabled)
        XCTAssertEqual(item.detailText, "示例插件")
        XCTAssertNotEqual(item.detailText, installedRecord.packageURL.path)
    }

    func testInstalledItemDetailKeepsStatusSpecificMessages() {
        let packageURL = URL(fileURLWithPath: "/tmp/Demo.mactoolsplugin", isDirectory: true)
        let enabledItem = makeManagementItem(state: .enabled, packageURL: packageURL)
        let disabledItem = makeManagementItem(state: .disabled, packageURL: packageURL)
        let restartingItem = makeManagementItem(
            state: .enabled,
            packageURL: packageURL,
            requiresRestartToFullyUnload: true
        )
        let updatingItem = makeManagementItem(
            state: .updateAvailable(installedVersion: "1.0.0", catalogVersion: "2.0.0"),
            packageURL: packageURL
        )

        XCTAssertEqual(enabledItem.detailText, "示例插件")
        XCTAssertEqual(disabledItem.detailText, "示例插件")
        XCTAssertNotEqual(enabledItem.detailText, packageURL.path)
        XCTAssertNotEqual(disabledItem.detailText, packageURL.path)
        XCTAssertEqual(
            restartingItem.detailText,
            AppL10n.plugins(
                "plugin.detail.restartRequiredAfterUpdate",
                defaultValue: "新版本将在重启后启用，旧代码将在重启后彻底释放。"
            )
        )
        XCTAssertEqual(
            updatingItem.detailText,
            AppL10n.pluginsFormat(
                "plugin.detail.updateAvailableFormat",
                defaultValue: "已安装 %@，可更新到 %@。",
                "1.0.0",
                "2.0.0"
            )
        )
    }

    func testManagementItemsCarryReleaseChannelFromManifestAndCatalog() throws {
        let sourceURL = try makePackage(id: "com.example.demo", releaseChannel: "beta")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: StubDynamicPluginLoader { _ in [] })
        let snapshot = makeCatalogSnapshot(
            entries: [makeCatalogEntry(id: "com.example.demo", version: "1.0.0", releaseChannel: "beta")]
        )

        manager.rebuildManagementItems(catalogSnapshot: snapshot)

        XCTAssertEqual(manager.pluginManagementItems.first?.releaseChannel, "beta")
        XCTAssertEqual(manager.installedReleaseChannelsByID()["com.example.demo"] ?? nil, "beta")
    }

    func testCatalogEntryShowsUpdateWhenNewerThanInstalledVersion() throws {
        let sourceURL = try makePackage(id: "com.example.demo", version: "1.0.0")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: StubDynamicPluginLoader { _ in [] })
        _ = manager.loadInstalledPlugins()
        let snapshot = makeCatalogSnapshot(entries: [makeCatalogEntry(id: "com.example.demo", version: "2.0.0")])

        manager.rebuildManagementItems(catalogSnapshot: snapshot)

        XCTAssertEqual(
            manager.pluginManagementItems.first?.state,
            .updateAvailable(installedVersion: "1.0.0", catalogVersion: "2.0.0")
        )
        XCTAssertEqual(manager.pluginManagementItems.first?.canUpdate, true)
    }

    func testLocalDevelopmentCatalogEntryUsesLocalDevelopmentState() throws {
        let store = makeStore()
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: StubDynamicPluginLoader { _ in [] })
        let snapshot = makeCatalogSnapshot(
            entries: [makeCatalogEntry(id: "com.example.demo", version: "1.0.0")],
            sourceKind: .localDevelopment
        )

        manager.rebuildManagementItems(catalogSnapshot: snapshot)

        XCTAssertEqual(manager.pluginManagementItems.first?.state, .localDevelopment)
        XCTAssertEqual(manager.pluginManagementItems.first?.canInstall, true)
    }

    func testPreviousPluginKitPackageIsNotPassedToLoader() throws {
        let sourceURL = try makePackage(
            id: "com.example.demo",
            version: "1.0.0",
            pluginKitVersion: 1
        )
        let store = makeStore()
        let installedURL = store.installedDirectory
            .appendingPathComponent("com.example.demo", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        try FileManager.default.copyItem(at: sourceURL, to: installedURL)
        let loader = StubDynamicPluginLoader { _ in
            XCTFail("Incompatible plugin packages must not be passed to the dynamic loader.")
            return []
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)

        XCTAssertTrue(manager.loadInstalledPlugins().isEmpty)
        XCTAssertTrue(loader.receivedRecordIDBatches.isEmpty)
        XCTAssertTrue(manager.installedCapabilitiesByID().isEmpty)
        XCTAssertEqual(
            manager.pluginManagementItems.first?.state,
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

    func testResumePluginReactivatesWithPackageScopedContext() throws {
        let sourceURL = try makePackage(id: "com.example.demo")
        let store = makeStore()
        _ = try store.installPackage(from: sourceURL)
        let plugin = MockDynamicPlugin(id: "com.example.demo")
        let loader = StubDynamicPluginLoader { records in
            records.map { DynamicPluginLoadResult(record: $0, plugins: [plugin], errorMessage: nil) }
        }
        let manager = DynamicPluginManager(packageStore: store, pluginLoader: loader)
        _ = manager.loadInstalledPlugins()

        manager.pausePlugin("com.example.demo")
        manager.resumePlugin("com.example.demo")

        // Resume must re-activate with the package-scoped context (support
        // directory etc.), not a bare nil-directory PluginRuntimeContext(pluginID:).
        let expected = store.runtimeContext(for: store.installedRecords().first!)
        XCTAssertNotNil(expected.supportDirectory)
        XCTAssertEqual(plugin.activationContexts.last?.supportDirectory, expected.supportDirectory)
        XCTAssertEqual(plugin.deactivationReasons, [.disabled])
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
        displayName: String = "Demo",
        bundleRelativePath: String = "Demo.bundle",
        pluginKitVersion: Int = PluginPackageManifestLoader.supportedPluginKitVersion,
        releaseChannel: String? = nil
    ) throws -> URL {
        let packageURL = temporaryRoot
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent("\(id)-\(version)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = packageURL.appendingPathComponent(bundleRelativePath, isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PluginPackageManifest(
            id: id,
            displayName: displayName,
            version: version,
            minHostVersion: "0.1.0",
            pluginKitVersion: pluginKitVersion,
            bundleRelativePath: bundleRelativePath,
            releaseChannel: releaseChannel
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("plugin.json"))

        return packageURL
    }

    private func makeCatalogEntry(
        id: String,
        version: String,
        releaseChannel: String? = nil
    ) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id,
            displayName: "Demo",
            summary: "示例插件",
            version: version,
            minimumHostVersion: "0.1.0",
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/Demo.mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            ),
            releaseChannel: releaseChannel
        )
    }

    private func makeManagementItem(
        state: PluginManagementItem.State,
        packageURL: URL,
        requiresRestartToFullyUnload: Bool = false
    ) -> PluginManagementItem {
        PluginManagementItem(
            id: "com.example.demo",
            title: "Demo",
            summary: "示例插件",
            version: "1.0.0",
            state: state,
            packageURL: packageURL,
            requiresRestartToFullyUnload: requiresRestartToFullyUnload,
            releaseNotesURL: nil
        )
    }

    private func makeCatalogSnapshot(
        entries: [PluginCatalogEntry],
        sourceKind: PluginCatalogSnapshot.SourceKind = .production
    ) -> PluginCatalogSnapshot {
        PluginCatalogSnapshot(
            catalog: PluginCatalog(
                catalogID: "com.example.catalog",
                generatedAt: Date(timeIntervalSince1970: 0),
                minimumHostVersion: "0.1.0",
                plugins: entries
            ),
            sourceURL: URL(string: "https://example.com/catalog.json")!,
            sourceKind: sourceKind,
            loadedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@MainActor
private final class StubDynamicPluginLoader: DynamicPluginLoading {
    private let handler: ([PluginPackageRecord]) -> [DynamicPluginLoadResult]
    private(set) var receivedRecordIDBatches: [[String]] = []

    init(handler: @escaping ([PluginPackageRecord]) -> [DynamicPluginLoadResult]) {
        self.handler = handler
    }

    func loadInstalledPlugins(from records: [PluginPackageRecord]) -> [DynamicPluginLoadResult] {
        receivedRecordIDBatches.append(records.map(\.id))
        return handler(records)
    }
}

@MainActor
private final class MockDynamicPlugin: MacToolsPlugin {
    let metadata: PluginMetadata
    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    private(set) var deactivationReasons: [PluginDeactivationReason] = []
    private(set) var activationContexts: [PluginRuntimeContext] = []

    init(id: String) {
        self.metadata = PluginMetadata(
            id: id,
            title: "Demo",
            iconName: "shippingbox",
            iconTint: .blue,
            order: 1,
            defaultDescription: "Demo"
        )
    }

    func activate(context: PluginRuntimeContext) {
        activationContexts.append(context)
    }

    func deactivate(reason: PluginDeactivationReason) {
        deactivationReasons.append(reason)
    }
}
