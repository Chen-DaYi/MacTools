import Foundation
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PluginCatalogManagerTests: XCTestCase {
    private var temporaryRoot: URL!
    private var defaults: UserDefaults!
    private let suiteName = "PluginCatalogManagerTests"

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginCatalogManagerTests-\(UUID().uuidString)", isDirectory: true)
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

    func testAutomaticUpdatePlanOnlyIncludesInstalledPluginsWithNewerCatalogVersions() async throws {
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "com.example.installed", version: "1.0.0"))
        _ = try store.installPackage(from: makePackage(id: "com.example.current", version: "2.0.0"))
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "com.example.installed", version: "2.0.0"),
            makeCatalogEntry(id: "com.example.current", version: "2.0.0"),
            makeCatalogEntry(id: "com.example.available", version: "1.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [:]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )

        await manager.refreshCatalog()

        XCTAssertEqual(
            manager.automaticUpdatePlanForInstalledPlugins().updateableInstalledPluginIDs,
            ["com.example.installed"]
        )
    }

    func testAutomaticUpdateBeforeLoadingInstallsLatestPackageWithoutCallingLoader() async throws {
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "com.example.demo", version: "1.0.0"))
        let updatePackageURL = try makePackage(id: "com.example.demo", version: "2.0.0")
        let loader = StubDynamicPluginLoader { records in
            records.map { record in
                DynamicPluginLoadResult(
                    record: record,
                    plugins: [MockDynamicPlugin(id: record.id)],
                    errorMessage: nil
                )
            }
        }
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: loader
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "com.example.demo", version: "2.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "com.example.demo": updatePackageURL,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )

        await manager.refreshCatalog()
        try await manager.updateInstalledPluginsToLatestBeforeLoading()

        XCTAssertEqual(store.installedRecords().first?.manifest.version, "2.0.0")
        XCTAssertTrue(loader.receivedRecordIDBatches.isEmpty)

        XCTAssertEqual(dynamicManager.loadInstalledPlugins().map(\.metadata.id), ["com.example.demo"])
        XCTAssertEqual(loader.receivedRecordIDBatches, [["com.example.demo"]])
    }

    func testAvailablePluginUpdateReportsCompletedAndTotalProgress() async throws {
        let store = makeStore()
        _ = try store.installPackage(from: makePackage(id: "com.example.alpha", version: "1.0.0"))
        _ = try store.installPackage(from: makePackage(id: "com.example.beta", version: "1.0.0"))
        let updateAlphaURL = try makePackage(id: "com.example.alpha", version: "2.0.0")
        let updateBetaURL = try makePackage(id: "com.example.beta", version: "2.0.0")
        let dynamicManager = DynamicPluginManager(
            packageStore: store,
            pluginLoader: StubDynamicPluginLoader { _ in [] }
        )
        dynamicManager.prepareInstalledPluginsWithoutLoading()
        let snapshot = makeCatalogSnapshot(entries: [
            makeCatalogEntry(id: "com.example.alpha", version: "2.0.0"),
            makeCatalogEntry(id: "com.example.beta", version: "2.0.0"),
        ])
        let manager = PluginCatalogManager(
            catalogProvider: StubPluginCatalogProvider(snapshot: snapshot),
            packageResolver: StubPluginPackageResolver(packagesByID: [
                "com.example.alpha": updateAlphaURL,
                "com.example.beta": updateBetaURL,
            ]),
            dynamicPluginManager: dynamicManager,
            source: .production(snapshot.sourceURL)
        )
        var progressEvents: [PluginCatalogUpdateProgress] = []

        await manager.refreshCatalog()
        try await manager.updateAvailablePlugins { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(
            progressEvents,
            [
                PluginCatalogUpdateProgress(completedCount: 0, totalCount: 2),
                PluginCatalogUpdateProgress(completedCount: 1, totalCount: 2),
                PluginCatalogUpdateProgress(completedCount: 2, totalCount: 2),
            ]
        )
        XCTAssertEqual(
            store.installedRecords().map { "\($0.id):\($0.manifest.version)" },
            [
                "com.example.alpha:2.0.0",
                "com.example.beta:2.0.0",
            ]
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
        displayName: String = "Demo",
        bundleRelativePath: String = "Demo.bundle"
    ) throws -> URL {
        let packageURL = temporaryRoot
            .appendingPathComponent("Source", isDirectory: true)
            .appendingPathComponent("\(id)-\(version)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("mactoolsplugin")
        let bundleURL = packageURL.appendingPathComponent(bundleRelativePath, isDirectory: true)

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = PluginPackageManifest(
            id: id,
            displayName: displayName,
            version: version,
            minHostVersion: "0.1.0",
            bundleRelativePath: bundleRelativePath
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: packageURL.appendingPathComponent("plugin.json"))

        return packageURL
    }

    private func makeCatalogEntry(id: String, version: String) -> PluginCatalogEntry {
        PluginCatalogEntry(
            id: id,
            displayName: "Demo",
            summary: "示例插件",
            version: version,
            minimumHostVersion: "0.1.0",
            package: PluginCatalogPackage(
                url: URL(fileURLWithPath: "/tmp/\(id).mactoolsplugin"),
                sha256: String(repeating: "a", count: 64),
                size: 42
            )
        )
    }

    private func makeCatalogSnapshot(entries: [PluginCatalogEntry]) -> PluginCatalogSnapshot {
        PluginCatalogSnapshot(
            catalog: PluginCatalog(
                catalogID: "com.example.catalog",
                generatedAt: Date(timeIntervalSince1970: 0),
                minimumHostVersion: "0.1.0",
                plugins: entries
            ),
            sourceURL: URL(string: "https://example.com/catalog.json")!,
            sourceKind: .production,
            loadedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@MainActor
private struct StubPluginCatalogProvider: PluginCatalogProviding {
    let snapshot: PluginCatalogSnapshot

    func loadCatalog() async throws -> PluginCatalogSnapshot {
        snapshot
    }
}

@MainActor
private struct StubPluginPackageResolver: PluginPackageResolving {
    let packagesByID: [String: URL]

    func resolvePackage(for entry: PluginCatalogEntry) async throws -> URL {
        guard let url = packagesByID[entry.id] else {
            throw PluginCatalogManagerError.catalogEntryNotFound(entry.id)
        }

        return url
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
}
