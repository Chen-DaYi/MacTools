import Foundation

enum PluginDisplaySurface: CaseIterable, Hashable, Sendable {
    case dashboard
    case featurePanel
}

@MainActor
final class PluginDisplayPreferencesStore {
    private enum DefaultsKey {
        static let storage = "plugin.display.preferences"
    }

    private struct LegacyStoredPreferences: Codable, Equatable {
        var orderedPluginIDs: [String] = []
        var hiddenPluginIDs: Set<String> = []
    }

    private struct StoredPreferences: Codable, Equatable {
        static let currentVersion = 2

        var version = currentVersion
        var generalPluginOrder: [String] = []
        var globallyHiddenPluginIDs: Set<String> = []
        var dashboardOrderedPluginIDs: [String] = []
        var featurePanelOrderedPluginIDs: [String] = []
        var isDashboardOrderInitialized = false
        var isFeaturePanelOrderInitialized = false
    }

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedPreferences: StoredPreferences?
    // True when a fallback read came from data this version cannot safely
    // decode. Read-time lazy migrations should update only the cache so
    // downgrades do not erase newer schemas.
    private var shouldPreserveStoredPayload = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - General/global preferences

    func orderedPluginIDs(defaultPluginIDs: [String]) -> [String] {
        normalizedVisibleOrder(
            loadPreferences().generalPluginOrder,
            defaultPluginIDs: defaultPluginIDs
        )
    }

    func setOrderedPluginIDs(
        _ orderedPluginIDs: [String],
        defaultPluginIDs: [String]
    ) {
        var preferences = loadPreferences()
        preferences.generalPluginOrder = mergedStoredOrder(
            requestedOrder: orderedPluginIDs,
            storedOrder: preferences.generalPluginOrder,
            defaultPluginIDs: defaultPluginIDs
        )
        persist(preferences)
    }

    func isPluginGloballyEnabled(_ pluginID: String) -> Bool {
        !loadPreferences().globallyHiddenPluginIDs.contains(pluginID)
    }

    func setPluginGloballyEnabled(_ isEnabled: Bool, pluginID: String) {
        var preferences = loadPreferences()

        if isEnabled {
            preferences.globallyHiddenPluginIDs.remove(pluginID)
        } else {
            preferences.globallyHiddenPluginIDs.insert(pluginID)
        }

        persist(preferences)
    }

    // Compatibility entry points for callers that still use the original
    // general visibility terminology.
    func isVisible(_ pluginID: String, defaultPluginIDs: [String]) -> Bool {
        guard defaultPluginIDs.contains(pluginID) else {
            return true
        }

        return isPluginGloballyEnabled(pluginID)
    }

    func setVisibility(
        _ isVisible: Bool,
        for pluginID: String,
        defaultPluginIDs: [String]
    ) {
        guard defaultPluginIDs.contains(pluginID) else {
            return
        }

        setPluginGloballyEnabled(isVisible, pluginID: pluginID)
    }

    // MARK: - Surface preferences

    /// Returns the saved order for a surface. The first non-empty read lazily
    /// seeds the surface order from the legacy/global order so upgrades
    /// preserve the user's existing layout intent without doing launch-time
    /// migration work before plugin capabilities are available.
    func orderedPluginIDs(
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) -> [String] {
        var preferences = loadPreferences()
        initializeSurfaceOrderIfNeeded(
            surface,
            defaultPluginIDs: defaultPluginIDs,
            preferences: &preferences
        )

        return normalizedVisibleOrder(
            storedOrder(for: surface, preferences: preferences),
            defaultPluginIDs: defaultPluginIDs
        )
    }

    func setOrderedPluginIDs(
        _ orderedPluginIDs: [String],
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) {
        var preferences = loadPreferences()
        initializeSurfaceOrderIfNeeded(
            surface,
            defaultPluginIDs: defaultPluginIDs,
            preferences: &preferences,
            persistChanges: false
        )
        let mergedOrder = mergedStoredOrder(
            requestedOrder: orderedPluginIDs,
            storedOrder: storedOrder(for: surface, preferences: preferences),
            defaultPluginIDs: defaultPluginIDs
        )
        setStoredOrder(mergedOrder, for: surface, preferences: &preferences)
        persist(preferences)
    }

    func resetOrder(
        for surface: PluginDisplaySurface,
        defaultPluginIDs: [String]
    ) {
        setOrderedPluginIDs(
            defaultPluginIDs,
            for: surface,
            defaultPluginIDs: defaultPluginIDs
        )
    }

    func backupSnapshot(
        defaultPluginIDs: [String],
        dashboardDefaultPluginIDs: [String] = [],
        featurePanelDefaultPluginIDs: [String] = []
    ) -> PluginDisplayPreferencesBackup {
        var preferences = loadPreferences()
        initializeSurfaceOrderIfNeeded(
            .dashboard,
            defaultPluginIDs: dashboardDefaultPluginIDs,
            preferences: &preferences,
            persistChanges: false
        )
        initializeSurfaceOrderIfNeeded(
            .featurePanel,
            defaultPluginIDs: featurePanelDefaultPluginIDs,
            preferences: &preferences,
            persistChanges: false
        )

        return PluginDisplayPreferencesBackup(
            orderedPluginIDs: normalizedVisibleOrder(
                preferences.generalPluginOrder,
                defaultPluginIDs: defaultPluginIDs
            ),
            hiddenPluginIDs: preferences.globallyHiddenPluginIDs
                .filter { defaultPluginIDs.contains($0) }
                .sorted(),
            dashboardOrderedPluginIDs: normalizedVisibleOrder(
                storedOrder(for: .dashboard, preferences: preferences),
                defaultPluginIDs: dashboardDefaultPluginIDs
            ),
            featurePanelOrderedPluginIDs: normalizedVisibleOrder(
                storedOrder(for: .featurePanel, preferences: preferences),
                defaultPluginIDs: featurePanelDefaultPluginIDs
            )
        )
    }

    // MARK: - Persistence and migration

    private func loadPreferences() -> StoredPreferences {
        if let cachedPreferences {
            return cachedPreferences
        }

        guard let data = userDefaults.data(forKey: DefaultsKey.storage) else {
            let preferences = StoredPreferences()
            cachedPreferences = preferences
            shouldPreserveStoredPayload = false
            return preferences
        }

        if let preferences = try? decoder.decode(StoredPreferences.self, from: data),
           preferences.version == StoredPreferences.currentVersion {
            cachedPreferences = preferences
            shouldPreserveStoredPayload = false
            return preferences
        }

        if let legacyPreferences = try? decoder.decode(LegacyStoredPreferences.self, from: data) {
            let migratedPreferences = StoredPreferences(
                generalPluginOrder: deduplicated(legacyPreferences.orderedPluginIDs),
                globallyHiddenPluginIDs: legacyPreferences.hiddenPluginIDs
            )
            persist(migratedPreferences)
            return migratedPreferences
        }

        // Preserve unknown or unreadable payloads instead of deleting them.
        // This keeps downgrade paths non-destructive: an older app version can
        // fall back to defaults without erasing preferences written by a newer
        // schema.
        let preferences = StoredPreferences()
        cachedPreferences = preferences
        shouldPreserveStoredPayload = true
        return preferences
    }

    private func persist(_ preferences: StoredPreferences) {
        guard let data = try? encoder.encode(preferences) else {
            return
        }

        userDefaults.set(data, forKey: DefaultsKey.storage)
        cachedPreferences = preferences
        shouldPreserveStoredPayload = false
    }

    private func initializeSurfaceOrderIfNeeded(
        _ surface: PluginDisplaySurface,
        defaultPluginIDs: [String],
        preferences: inout StoredPreferences,
        persistChanges: Bool = true
    ) {
        let isInitialized: Bool
        switch surface {
        case .dashboard:
            isInitialized = preferences.isDashboardOrderInitialized
        case .featurePanel:
            isInitialized = preferences.isFeaturePanelOrderInitialized
        }

        // Dynamic plugins may intentionally load after the host's first
        // rebuild. An empty list does not contain enough capability data to
        // complete a legacy migration, so defer initialization until it does.
        guard !isInitialized, !defaultPluginIDs.isEmpty else {
            return
        }

        let seededOrder = normalizedVisibleOrder(
            preferences.generalPluginOrder,
            defaultPluginIDs: defaultPluginIDs
        )
        setStoredOrder(seededOrder, for: surface, preferences: &preferences)

        switch surface {
        case .dashboard:
            preferences.isDashboardOrderInitialized = true
        case .featurePanel:
            preferences.isFeaturePanelOrderInitialized = true
        }

        if persistChanges, shouldPreserveStoredPayload {
            cachedPreferences = preferences
        } else if persistChanges {
            persist(preferences)
        }
    }

    private func storedOrder(
        for surface: PluginDisplaySurface,
        preferences: StoredPreferences
    ) -> [String] {
        switch surface {
        case .dashboard:
            return preferences.dashboardOrderedPluginIDs
        case .featurePanel:
            return preferences.featurePanelOrderedPluginIDs
        }
    }

    private func setStoredOrder(
        _ orderedPluginIDs: [String],
        for surface: PluginDisplaySurface,
        preferences: inout StoredPreferences
    ) {
        switch surface {
        case .dashboard:
            preferences.dashboardOrderedPluginIDs = orderedPluginIDs
        case .featurePanel:
            preferences.featurePanelOrderedPluginIDs = orderedPluginIDs
        }
    }

    /// Produces the current view without rewriting storage, so IDs belonging
    /// to temporarily absent plugins remain available for later restoration.
    private func normalizedVisibleOrder(
        _ storedOrder: [String],
        defaultPluginIDs: [String]
    ) -> [String] {
        let validPluginIDs = Set(defaultPluginIDs)
        var seenPluginIDs: Set<String> = []
        var result: [String] = []

        for pluginID in storedOrder where validPluginIDs.contains(pluginID) {
            guard seenPluginIDs.insert(pluginID).inserted else {
                continue
            }

            result.append(pluginID)
        }

        for pluginID in defaultPluginIDs where seenPluginIDs.insert(pluginID).inserted {
            result.append(pluginID)
        }

        return result
    }

    /// Replaces the currently available IDs in their stored slots while
    /// retaining unavailable IDs and their relative positions.
    private func mergedStoredOrder(
        requestedOrder: [String],
        storedOrder: [String],
        defaultPluginIDs: [String]
    ) -> [String] {
        let availablePluginIDs = Set(defaultPluginIDs)
        let normalizedRequestedOrder = normalizedVisibleOrder(
            requestedOrder,
            defaultPluginIDs: defaultPluginIDs
        )
        var requestedIterator = normalizedRequestedOrder.makeIterator()
        var seenPluginIDs: Set<String> = []
        var result: [String] = []

        for storedPluginID in deduplicated(storedOrder) {
            let nextPluginID: String
            if availablePluginIDs.contains(storedPluginID) {
                guard let requestedPluginID = requestedIterator.next() else {
                    continue
                }
                nextPluginID = requestedPluginID
            } else {
                nextPluginID = storedPluginID
            }

            if seenPluginIDs.insert(nextPluginID).inserted {
                result.append(nextPluginID)
            }
        }

        while let requestedPluginID = requestedIterator.next() {
            if seenPluginIDs.insert(requestedPluginID).inserted {
                result.append(requestedPluginID)
            }
        }

        return result
    }

    private func deduplicated(_ pluginIDs: [String]) -> [String] {
        var seenPluginIDs: Set<String> = []
        return pluginIDs.filter { seenPluginIDs.insert($0).inserted }
    }
}
