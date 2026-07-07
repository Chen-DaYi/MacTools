import Foundation

struct PluginCatalogStatus: Equatable {
    enum Source: Equatable {
        case production(URL)
        case localDevelopment(URL)
        case unavailable
    }

    var source: Source
    var lastUpdatedAt: Date?
    var errorMessage: String?
    var isRefreshing: Bool

    static let unavailable = PluginCatalogStatus(
        source: .unavailable,
        lastUpdatedAt: nil,
        errorMessage: nil,
        isRefreshing: false
    )

    var title: String {
        switch source {
        case .production:
            return AppL10n.plugins("plugin.catalog.title.production", defaultValue: "插件列表")
        case .localDevelopment:
            return AppL10n.plugins("plugin.catalog.title.localDevelopment", defaultValue: "本地开发列表")
        case .unavailable:
            return AppL10n.plugins("plugin.catalog.title.unavailable", defaultValue: "插件列表未配置")
        }
    }

    var detailText: String {
        if let errorMessage {
            return errorMessage
        }

        if isRefreshing {
            return AppL10n.plugins("plugin.catalog.detail.refreshing", defaultValue: "正在刷新插件列表...")
        }

        switch source {
        case let .production(url), let .localDevelopment(url):
            return url.absoluteString
        case .unavailable:
            return AppL10n.plugins("plugin.catalog.detail.unavailable", defaultValue: "已安装插件仍可继续管理。")
        }
    }
}

struct PluginCatalogBulkUpdateError: LocalizedError {
    let failures: [PluginPackageUpdateFailure]

    var errorDescription: String? {
        let ids = failures.map(\.pluginID).joined(separator: "、")
        return AppL10n.pluginsFormat("plugin.error.catalog.bulkUpdateFailedFormat", defaultValue: "部分插件更新失败：%@", ids)
    }
}

struct PluginCatalogUpdatePlan: Equatable {
    let updateableInstalledPluginIDs: [String]

    var isEmpty: Bool {
        updateableInstalledPluginIDs.isEmpty
    }
}

struct PluginCatalogUpdateProgress: Equatable {
    let completedCount: Int
    let totalCount: Int

    init(completedCount: Int, totalCount: Int) {
        self.totalCount = max(0, totalCount)
        self.completedCount = min(max(0, completedCount), self.totalCount)
    }
}

@MainActor
final class PluginCatalogManager {
    private let catalogProvider: (any PluginCatalogProviding)?
    private let packageResolver: any PluginPackageResolving
    private let dynamicPluginManager: DynamicPluginManager
    private let source: PluginCatalogSource?

    private var snapshot: PluginCatalogSnapshot?
    private(set) var status: PluginCatalogStatus

    init(
        catalogProvider: (any PluginCatalogProviding)?,
        packageResolver: any PluginPackageResolving,
        dynamicPluginManager: DynamicPluginManager,
        source: PluginCatalogSource?
    ) {
        self.catalogProvider = catalogProvider
        self.packageResolver = packageResolver
        self.dynamicPluginManager = dynamicPluginManager
        self.source = source

        if let source {
            switch source {
            case let .production(url):
                self.status = PluginCatalogStatus(
                    source: .production(url),
                    lastUpdatedAt: nil,
                    errorMessage: nil,
                    isRefreshing: false
                )
            case let .localDevelopment(url):
                self.status = PluginCatalogStatus(
                    source: .localDevelopment(url),
                    lastUpdatedAt: nil,
                    errorMessage: nil,
                    isRefreshing: false
                )
            }
        } else {
            self.status = .unavailable
        }
    }

    static func live(dynamicPluginManager: DynamicPluginManager) -> PluginCatalogManager {
        let source = PluginCatalogProviderConfiguration.defaultSource()
        let provider = PluginCatalogProviderFactory.makeProvider(source: source)
        let resolver = PluginPackageResolver(
            temporaryDirectory: dynamicPluginManager.temporaryDirectory
        )

        return PluginCatalogManager(
            catalogProvider: provider,
            packageResolver: resolver,
            dynamicPluginManager: dynamicPluginManager,
            source: source
        )
    }

    func refreshCatalog() async {
        guard let catalogProvider else {
            status = .unavailable
            return
        }

        status.isRefreshing = true
        status.errorMessage = nil

        do {
            let snapshot = try await catalogProvider.loadCatalog()
            self.snapshot = snapshot
            status = PluginCatalogStatus(
                source: statusSource(for: snapshot),
                lastUpdatedAt: snapshot.loadedAt,
                errorMessage: nil,
                isRefreshing: false
            )
        } catch {
            status.isRefreshing = false
            status.errorMessage = error.localizedDescription
        }

        dynamicPluginManager.rebuildManagementItems(catalogSnapshot: snapshot)
    }

    func installPlugin(id: String) async throws {
        let entry = try catalogEntry(id: id)
        let packageURL = try await packageResolver.resolvePackage(for: entry)
        try dynamicPluginManager.installPluginPackage(from: packageURL, catalogEntry: entry)
    }

    func updatePlugin(id: String) async throws {
        let entry = try catalogEntry(id: id)
        let packageURL = try await packageResolver.resolvePackage(for: entry)
        try dynamicPluginManager.updatePluginPackage(from: packageURL, catalogEntry: entry)
    }

    func updateAvailablePlugins(
        progress: ((PluginCatalogUpdateProgress) -> Void)? = nil
    ) async throws {
        let entries = try availableUpdateEntries()
        guard !entries.isEmpty else {
            return
        }

        try await updatePlugins(entries: entries, reloadAfterUpdate: true, progress: progress)
    }

    func automaticUpdatePlanForInstalledPlugins() -> PluginCatalogUpdatePlan {
        let entries = updateEntriesForInstalledPlugins()
        return PluginCatalogUpdatePlan(updateableInstalledPluginIDs: entries.map(\.id))
    }

    func updateInstalledPluginsToLatestBeforeLoading(
        progress: ((PluginCatalogUpdateProgress) -> Void)? = nil
    ) async throws {
        let entries = updateEntriesForInstalledPlugins()
        guard !entries.isEmpty else {
            return
        }

        try await updatePlugins(entries: entries, reloadAfterUpdate: false, progress: progress)
    }

    private func updatePlugins(
        entries: [PluginCatalogEntry],
        reloadAfterUpdate: Bool,
        progress: ((PluginCatalogUpdateProgress) -> Void)? = nil
    ) async throws {
        var resolvedUpdates: [(sourceURL: URL, catalogEntry: PluginCatalogEntry)] = []
        var failures: [PluginPackageUpdateFailure] = []
        let totalCount = entries.count
        var completedCount = 0

        func reportProgress() {
            progress?(
                PluginCatalogUpdateProgress(
                    completedCount: completedCount,
                    totalCount: totalCount
                )
            )
        }

        reportProgress()

        for entry in entries {
            do {
                let packageURL = try await packageResolver.resolvePackage(for: entry)
                resolvedUpdates.append((sourceURL: packageURL, catalogEntry: entry))
            } catch {
                failures.append(PluginPackageUpdateFailure(pluginID: entry.id, error: error))
                completedCount += 1
                reportProgress()
            }
        }

        failures.append(
            contentsOf: dynamicPluginManager.updatePluginPackages(
                resolvedUpdates,
                reloadAfterUpdate: reloadAfterUpdate,
                onPackageProcessed: {
                    completedCount += 1
                    reportProgress()
                }
            )
        )

        guard failures.isEmpty else {
            throw PluginCatalogBulkUpdateError(failures: failures)
        }
    }

    func rebuildManagementItems() {
        dynamicPluginManager.rebuildManagementItems(catalogSnapshot: snapshot)
    }

    private func catalogEntry(id: String) throws -> PluginCatalogEntry {
        guard let entry = snapshot?.catalog.plugins.first(where: { $0.id == id }) else {
            throw PluginCatalogManagerError.catalogEntryNotFound(id)
        }

        return entry
    }

    private func availableUpdateEntries() throws -> [PluginCatalogEntry] {
        let ids = dynamicPluginManager.pluginManagementItems
            .filter(\.canUpdate)
            .map(\.id)
        guard !ids.isEmpty else {
            return []
        }

        let entriesByID = Dictionary(
            uniqueKeysWithValues: (snapshot?.catalog.plugins ?? []).map { ($0.id, $0) }
        )

        return try ids.map { id in
            guard let entry = entriesByID[id] else {
                throw PluginCatalogManagerError.catalogEntryNotFound(id)
            }

            return entry
        }
    }

    private func updateEntriesForInstalledPlugins() -> [PluginCatalogEntry] {
        let installedVersionsByID = dynamicPluginManager.installedPackageVersionsByID()

        return (snapshot?.catalog.plugins ?? []).filter { entry in
            guard let installedVersion = installedVersionsByID[entry.id] else {
                return false
            }

            if snapshot?.catalog.revoked.contains(where: {
                $0.matches(pluginID: entry.id, version: entry.version)
            }) == true {
                return false
            }

            return PluginVersionComparator.isVersion(entry.version, newerThan: installedVersion)
        }
    }

    private func statusSource(for snapshot: PluginCatalogSnapshot) -> PluginCatalogStatus.Source {
        switch snapshot.sourceKind {
        case .production:
            return .production(snapshot.sourceURL)
        case .localDevelopment:
            return .localDevelopment(snapshot.sourceURL)
        }
    }
}

enum PluginCatalogManagerError: LocalizedError, Equatable {
    case catalogEntryNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .catalogEntryNotFound(id):
            return AppL10n.pluginsFormat("plugin.error.catalog.entryNotFoundFormat", defaultValue: "插件列表中未找到插件：%@", id)
        }
    }
}
