import Foundation
import MacToolsPluginKit

struct PluginManagementItem: Identifiable, Equatable {
    enum State: Equatable {
        case available
        case localDevelopment
        case enabled
        case disabled
        case updateAvailable(installedVersion: String, catalogVersion: String)
        case restartRequired
        case failed(String)
        case incompatible(String)
        case revoked(String?)
    }

    let id: String
    let title: String
    let summary: String?
    let version: String
    let state: State
    let packageURL: URL?
    let requiresRestartToFullyUnload: Bool
    let releaseNotesURL: URL?
    let category: String?
    let releaseChannel: String?

    init(
        id: String,
        title: String,
        summary: String?,
        version: String,
        state: State,
        packageURL: URL?,
        requiresRestartToFullyUnload: Bool,
        releaseNotesURL: URL?,
        category: String? = nil,
        releaseChannel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.version = version
        self.state = state
        self.packageURL = packageURL
        self.requiresRestartToFullyUnload = requiresRestartToFullyUnload
        self.releaseNotesURL = releaseNotesURL
        self.category = category
        self.releaseChannel = releaseChannel
    }

    var statusText: String {
        switch state {
        case .available:
            return AppL10n.plugins("plugin.status.available", defaultValue: "可安装")
        case .localDevelopment:
            return AppL10n.plugins("plugin.status.localDevelopment", defaultValue: "本地开发")
        case .enabled, .disabled:
            return AppL10n.plugins("plugin.status.installed", defaultValue: "已安装")
        case .updateAvailable:
            return AppL10n.plugins("plugin.status.updateAvailable", defaultValue: "可更新")
        case .restartRequired:
            return AppL10n.plugins("plugin.status.restartRequired", defaultValue: "需重启")
        case .failed:
            return AppL10n.plugins("plugin.status.failed", defaultValue: "加载失败")
        case .incompatible:
            return AppL10n.plugins("plugin.status.incompatible", defaultValue: "不兼容")
        case .revoked:
            return AppL10n.plugins("plugin.status.revoked", defaultValue: "已撤回")
        }
    }

    var detailText: String {
        switch state {
        case .available:
            return summary ?? AppL10n.plugins("plugin.detail.available", defaultValue: "可以安装此插件。")
        case .localDevelopment:
            return summary ?? AppL10n.plugins("plugin.detail.localDevelopment", defaultValue: "来自本地开发插件列表。")
        case .enabled:
            if requiresRestartToFullyUnload {
                return AppL10n.plugins("plugin.detail.restartRequiredAfterUpdate", defaultValue: "新版本将在重启后启用，旧代码将在重启后彻底释放。")
            }

            return summary ?? ""
        case .disabled:
            if requiresRestartToFullyUnload {
                return AppL10n.plugins("plugin.detail.restartRequiredAfterRemoval", defaultValue: "已移出界面，重启后彻底释放已加载代码。")
            }

            return summary ?? ""
        case let .updateAvailable(installedVersion, catalogVersion):
            return AppL10n.pluginsFormat(
                "plugin.detail.updateAvailableFormat",
                defaultValue: "已安装 %@，可更新到 %@。",
                installedVersion,
                catalogVersion
            )
        case .restartRequired:
            return AppL10n.plugins("plugin.detail.restartRequiredAfterUpdate", defaultValue: "新版本将在重启后启用，旧代码将在重启后彻底释放。")
        case let .failed(reason), let .incompatible(reason):
            return reason
        case let .revoked(reason):
            return reason ?? AppL10n.plugins("plugin.detail.revoked", defaultValue: "此版本已被撤回。")
        }
    }

    var canInstall: Bool {
        switch state {
        case .available, .localDevelopment:
            return true
        default:
            return false
        }
    }

    var canUpdate: Bool {
        if case .updateAvailable = state {
            return true
        }

        return false
    }

    var canUninstall: Bool {
        switch state {
        case .enabled, .disabled, .updateAvailable, .restartRequired, .failed, .incompatible, .revoked:
            return packageURL != nil
        case .available, .localDevelopment:
            return false
        }
    }
}

struct PluginPackageUpdateFailure {
    let pluginID: String
    let error: Error
}

@MainActor
final class DynamicPluginManager: ObservableObject {
    private let packageStore: PluginPackageStore
    private let pluginLoader: any DynamicPluginLoading
    private var loadedPluginsByID: [String: [any MacToolsPlugin]] = [:]
    private var loadedPluginIDs: Set<String> = []
    private var deferredPluginIDs: Set<String> = []
    private var catalogSnapshot: PluginCatalogSnapshot?
    private var latestLoadErrorsByID: [String: String] = [:]

    @Published private(set) var pluginManagementItems: [PluginManagementItem] = []
    var onPluginsChanged: (([any MacToolsPlugin]) -> Void)?

    var temporaryDirectory: URL {
        packageStore.temporaryDirectory
    }

    init(
        packageStore: PluginPackageStore = PluginPackageStore(),
        pluginLoader: (any DynamicPluginLoading)? = nil
    ) {
        self.packageStore = packageStore
        self.pluginLoader = pluginLoader ?? DynamicPluginLoader(packageStore: packageStore)
    }

    func loadInstalledPlugins() -> [any MacToolsPlugin] {
        let records = packageStore.installedRecords()
        deactivateMissingOrDisabledPlugins(records: records)

        let recordsToLoad = records.filter { record in
            guard case .enabled = record.state else {
                return false
            }

            return loadedPluginsByID[record.id] == nil && !deferredPluginIDs.contains(record.id)
        }
        let loadedResults = recordsToLoad.isEmpty
            ? []
            : pluginLoader.loadInstalledPlugins(from: recordsToLoad)
        let loadedResultsByID = Dictionary(
            uniqueKeysWithValues: loadedResults.map { ($0.record.id, $0) }
        )

        for result in loadedResults where result.errorMessage == nil && !result.plugins.isEmpty {
            loadedPluginsByID[result.record.id] = result.plugins
            loadedPluginIDs.insert(result.record.id)
        }

        let results = records.map { record in
            if let activePlugins = loadedPluginsByID[record.id] {
                return DynamicPluginLoadResult(record: record, plugins: activePlugins, errorMessage: nil)
            }

            if let loadedResult = loadedResultsByID[record.id] {
                return loadedResult
            }

            if deferredPluginIDs.contains(record.id) {
                return DynamicPluginLoadResult(
                    record: record.markingRestartRequired(),
                    plugins: [],
                    errorMessage: nil
                )
            }

            return DynamicPluginLoadResult(record: record, plugins: [], errorMessage: nil)
        }

        latestLoadErrorsByID = Dictionary(
            uniqueKeysWithValues: results.compactMap { result in
                result.errorMessage.map { (result.record.id, $0) }
            }
        )
        rebuildManagementItems(results: results, catalogSnapshot: catalogSnapshot)
        return activePlugins(from: records)
    }

    func prepareInstalledPluginsWithoutLoading() {
        let records = packageStore.installedRecords()
        deactivateMissingOrDisabledPlugins(records: records)
        latestLoadErrorsByID = [:]
        let results = records.map { record in
            DynamicPluginLoadResult(
                record: deferredPluginIDs.contains(record.id) ? record.markingRestartRequired() : record,
                plugins: [],
                errorMessage: nil
            )
        }
        rebuildManagementItems(results: results, catalogSnapshot: catalogSnapshot)
    }

    func reloadInstalledPlugins() {
        onPluginsChanged?(loadInstalledPlugins())
    }

    func installPluginPackage(from sourceURL: URL, catalogEntry: PluginCatalogEntry? = nil) throws {
        try validatePackage(sourceURL, matches: catalogEntry)
        let record = try packageStore.installPackage(from: sourceURL)

        if loadedPluginIDs.contains(record.id) {
            deferredPluginIDs.insert(record.id)
            packageStore.markRequiresRestartToFullyUnload(pluginID: record.id)
        } else {
            deferredPluginIDs.remove(record.id)
        }

        reloadInstalledPlugins()
    }

    func updatePluginPackage(from sourceURL: URL, catalogEntry: PluginCatalogEntry? = nil) throws {
        try updatePluginPackageWithoutReload(from: sourceURL, catalogEntry: catalogEntry)
        reloadInstalledPlugins()
    }

    func updatePluginPackages(
        _ updates: [(sourceURL: URL, catalogEntry: PluginCatalogEntry)],
        reloadAfterUpdate: Bool = true,
        onPackageProcessed: (() -> Void)? = nil
    ) -> [PluginPackageUpdateFailure] {
        guard !updates.isEmpty else {
            return []
        }

        var failures: [PluginPackageUpdateFailure] = []
        var didUpdatePackage = false

        defer {
            if reloadAfterUpdate && didUpdatePackage {
                reloadInstalledPlugins()
            }
        }

        for update in updates {
            do {
                try updatePluginPackageWithoutReload(
                    from: update.sourceURL,
                    catalogEntry: update.catalogEntry
                )
                didUpdatePackage = true
            } catch {
                failures.append(
                    PluginPackageUpdateFailure(
                        pluginID: update.catalogEntry.id,
                        error: error
                    )
                )
            }

            onPackageProcessed?()
        }

        return failures
    }

    private func updatePluginPackageWithoutReload(
        from sourceURL: URL,
        catalogEntry: PluginCatalogEntry? = nil
    ) throws {
        try validatePackage(sourceURL, matches: catalogEntry)
        let manifest = try PluginPackageManifestLoader.load(
            from: sourceURL,
            hostVersion: packageStore.hostVersion
        )
        let wasLoaded = loadedPluginIDs.contains(manifest.id)

        _ = try packageStore.updatePackage(from: sourceURL)

        if wasLoaded {
            deactivateLoadedPlugins(pluginID: manifest.id, reason: .updating)
            deferredPluginIDs.insert(manifest.id)
            packageStore.markRequiresRestartToFullyUnload(pluginID: manifest.id)
        } else {
            deferredPluginIDs.remove(manifest.id)
        }
    }

    func isInstalledPlugin(_ pluginID: String) -> Bool {
        packageStore.installedRecords().contains { $0.id == pluginID }
    }

    func installedCapabilitiesByID() -> [String: PluginPackageManifest.Capabilities] {
        Dictionary(
            uniqueKeysWithValues: packageStore.installedRecords().compactMap { record in
                guard record.state.isLoadable else {
                    return nil
                }

                return (record.id, record.manifest.capabilities)
            }
        )
    }

    func installedPackageVersionsByID() -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: packageStore.installedRecords().map {
                ($0.id, $0.manifest.version)
            }
        )
    }

    func installedCategoriesByID() -> [String: String?] {
        Dictionary(
            uniqueKeysWithValues: packageStore.installedRecords().map {
                ($0.id, $0.manifest.category)
            }
        )
    }

    func installedReleaseChannelsByID() -> [String: String?] {
        Dictionary(
            uniqueKeysWithValues: packageStore.installedRecords().map {
                ($0.id, $0.manifest.releaseChannel)
            }
        )
    }

    /// Deactivate a loaded plugin without unloading it.
    /// Used when the user hides the plugin — it stays in the list but its side effects stop.
    func pausePlugin(_ pluginID: String) {
        guard let plugins = loadedPluginsByID[pluginID] else { return }
        for plugin in plugins {
            plugin.deactivate(reason: .disabled)
        }
    }

    /// Re-activate a previously paused plugin without reloading it.
    func resumePlugin(_ pluginID: String) {
        guard let plugins = loadedPluginsByID[pluginID] else { return }
        // Re-activate with the SAME context the plugin was first loaded with
        // (support/cache/temp directories, resource bundle, scoped storage). A bare
        // `PluginRuntimeContext(pluginID:)` has nil directories and the .main bundle,
        // so plugins that recompute paths in activate() — e.g. ActivityBar's hook
        // script location — would silently switch on-disk locations after hide/show.
        let context = packageStore.installedRecords().first { $0.id == pluginID }
            .map { packageStore.runtimeContext(for: $0) }
            ?? PluginRuntimeContext(pluginID: pluginID)
        for plugin in plugins {
            plugin.activate(context: context)
        }
    }

    func setPluginEnabled(_ isEnabled: Bool, pluginID: String) {
        if !isEnabled {
            deactivateLoadedPlugins(pluginID: pluginID, reason: .disabled)
        }

        packageStore.setEnabled(isEnabled, for: pluginID)
        reloadInstalledPlugins()
    }

    func uninstallPlugin(pluginID: String, removeData: Bool = false) throws {
        let wasLoaded = loadedPluginIDs.contains(pluginID)

        deactivateLoadedPlugins(pluginID: pluginID, reason: .uninstalling)
        try packageStore.uninstall(pluginID: pluginID, removeData: removeData)
        loadedPluginsByID.removeValue(forKey: pluginID)

        if wasLoaded {
            deferredPluginIDs.insert(pluginID)
        }

        reloadInstalledPlugins()
    }

    func deactivateAll(reason: PluginDeactivationReason = .hostShutdown) {
        for pluginID in Array(loadedPluginsByID.keys) {
            deactivateLoadedPlugins(pluginID: pluginID, reason: reason)
        }
    }

    func rebuildManagementItems(catalogSnapshot: PluginCatalogSnapshot?) {
        self.catalogSnapshot = catalogSnapshot
        let records = packageStore.installedRecords()
        let results = records.map { record in
            DynamicPluginLoadResult(
                record: deferredPluginIDs.contains(record.id) ? record.markingRestartRequired() : record,
                plugins: loadedPluginsByID[record.id] ?? [],
                errorMessage: latestLoadErrorsByID[record.id]
            )
        }
        rebuildManagementItems(results: results, catalogSnapshot: catalogSnapshot)
    }

    private func deactivateMissingOrDisabledPlugins(records: [PluginPackageRecord]) {
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })

        for pluginID in Array(loadedPluginsByID.keys) {
            guard let record = recordsByID[pluginID] else {
                deactivateLoadedPlugins(pluginID: pluginID, reason: .uninstalling)
                continue
            }

            if record.state != .enabled {
                deactivateLoadedPlugins(pluginID: pluginID, reason: .disabled)
            }
        }
    }

    private func activePlugins(from records: [PluginPackageRecord]) -> [any MacToolsPlugin] {
        records.flatMap { record in
            loadedPluginsByID[record.id] ?? []
        }
    }

    private func deactivateLoadedPlugins(pluginID: String, reason: PluginDeactivationReason) {
        guard let plugins = loadedPluginsByID.removeValue(forKey: pluginID) else {
            return
        }

        for plugin in plugins {
            plugin.deactivate(reason: reason)
            plugin.onStateChange = nil
            plugin.requestPermissionGuidance = nil
            plugin.shortcutBindingResolver = nil
        }
    }

    private func validatePackage(_ sourceURL: URL, matches entry: PluginCatalogEntry?) throws {
        guard let entry else {
            return
        }

        let manifest = try PluginPackageManifestLoader.load(
            from: sourceURL,
            hostVersion: packageStore.hostVersion
        )

        guard manifest.id == entry.id else {
            throw PluginPackageResolverError.manifestMismatch(field: "id")
        }

        guard manifest.version == entry.version else {
            throw PluginPackageResolverError.manifestMismatch(field: "version")
        }

        guard manifest.minHostVersion == entry.minimumHostVersion else {
            throw PluginPackageResolverError.manifestMismatch(field: "minimumHostVersion")
        }

        guard manifest.pluginKitVersion == entry.pluginKitVersion else {
            throw PluginPackageResolverError.manifestMismatch(field: "pluginKitVersion")
        }

        guard manifest.releaseChannel == entry.releaseChannel else {
            throw PluginPackageResolverError.manifestMismatch(field: "releaseChannel")
        }
    }

    private func rebuildManagementItems(
        results: [DynamicPluginLoadResult],
        catalogSnapshot: PluginCatalogSnapshot?
    ) {
        let installedItems = Dictionary(uniqueKeysWithValues: results.map { ($0.record.id, $0) })
        let catalogEntries = catalogSnapshot?.catalog.plugins ?? []
        var itemIDs = Set<String>()
        var items: [PluginManagementItem] = []

        for entry in catalogEntries.sorted(by: catalogEntrySort) {
            itemIDs.insert(entry.id)
            let revocation = catalogSnapshot?.catalog.revoked.first {
                $0.matches(pluginID: entry.id, version: entry.version)
            }

            if let result = installedItems[entry.id] {
                items.append(
                    managementItem(
                        for: result,
                        catalogEntry: entry,
                        revocation: revocation
                    )
                )
            } else {
                items.append(
                    PluginManagementItem(
                        id: entry.id,
                        title: entry.localizedDisplayName,
                        summary: entry.localizedSummary,
                        version: entry.version,
                        state: catalogSnapshot?.isLocalDevelopment == true ? .localDevelopment : .available,
                        packageURL: nil,
                        requiresRestartToFullyUnload: false,
                        releaseNotesURL: entry.releaseNotesURL,
                        category: entry.category,
                        releaseChannel: entry.releaseChannel
                    )
                )
            }
        }

        for result in results where !itemIDs.contains(result.record.id) {
            let revocation = catalogSnapshot?.catalog.revoked.first {
                $0.matches(pluginID: result.record.id, version: result.record.manifest.version)
            }
            items.append(
                managementItem(
                    for: result,
                    catalogEntry: nil,
                    revocation: revocation
                )
            )
        }

        pluginManagementItems = items.sorted(by: managementItemSort)
    }

    private func managementItem(
        for result: DynamicPluginLoadResult,
        catalogEntry: PluginCatalogEntry?,
        revocation: PluginCatalogRevocation?
    ) -> PluginManagementItem {
        let record = result.record
        let state: PluginManagementItem.State

        if let revocation {
            state = .revoked(revocation.reason)
        } else if record.requiresRestartToFullyUnload && record.state == .enabled {
            state = .restartRequired
        } else if let errorMessage = result.errorMessage {
            state = .failed(errorMessage)
        } else if let catalogEntry,
                  PluginVersionComparator.isVersion(catalogEntry.version, newerThan: record.manifest.version) {
            state = .updateAvailable(
                installedVersion: record.manifest.version,
                catalogVersion: catalogEntry.version
            )
        } else {
            switch record.state {
            case .enabled:
                state = .enabled
            case .disabled:
                state = .disabled
            case let .incompatible(reason):
                state = .incompatible(reason)
            case let .failed(reason):
                state = .failed(reason)
            }
        }

        return PluginManagementItem(
            id: record.id,
            title: catalogEntry?.localizedDisplayName ?? record.manifest.localizedDisplayName,
            summary: catalogEntry?.localizedSummary ?? record.manifest.localizedSummary,
            version: catalogEntry?.version ?? record.manifest.version,
            state: state,
            packageURL: record.packageURL,
            requiresRestartToFullyUnload: record.requiresRestartToFullyUnload,
            releaseNotesURL: catalogEntry?.releaseNotesURL,
            category: catalogEntry?.category ?? record.manifest.category,
            releaseChannel: catalogEntry?.releaseChannel ?? record.manifest.releaseChannel
        )
    }

    private func catalogEntrySort(_ lhs: PluginCatalogEntry, _ rhs: PluginCatalogEntry) -> Bool {
        lhs.localizedDisplayName.localizedCompare(rhs.localizedDisplayName) == .orderedAscending
    }

    private func managementItemSort(_ lhs: PluginManagementItem, _ rhs: PluginManagementItem) -> Bool {
        lhs.title.localizedCompare(rhs.title) == .orderedAscending
    }
}

private extension PluginPackageRecord.State {
    var isLoadable: Bool {
        switch self {
        case .enabled, .disabled:
            return true
        case .incompatible, .failed:
            return false
        }
    }
}

private extension PluginPackageRecord {
    func markingRestartRequired() -> PluginPackageRecord {
        PluginPackageRecord(
            id: id,
            manifest: manifest,
            packageURL: packageURL,
            bundleURL: bundleURL,
            state: state,
            requiresRestartToFullyUnload: true
        )
    }
}
