import Foundation
import MacToolsPluginKit

@MainActor
final class PluginDisplayPreferencesStore {
    private enum DefaultsKey {
        static let storage = "plugin.display.preferences"
    }

    private struct StoredPreferences: Codable, Equatable {
        var orderedPluginIDs: [String] = []
        var hiddenPluginIDs: Set<String> = []
    }

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func orderedPluginIDs(defaultPluginIDs: [String]) -> [String] {
        normalizeOrder(
            loadPreferences().orderedPluginIDs,
            defaultPluginIDs: defaultPluginIDs
        )
    }

    func isVisible(_ pluginID: String, defaultPluginIDs: [String]) -> Bool {
        guard defaultPluginIDs.contains(pluginID) else {
            return true
        }

        return !loadPreferences().hiddenPluginIDs.contains(pluginID)
    }

    func setVisibility(
        _ isVisible: Bool,
        for pluginID: String,
        defaultPluginIDs: [String]
    ) {
        guard defaultPluginIDs.contains(pluginID) else {
            return
        }

        var preferences = loadPreferences()

        if isVisible {
            preferences.hiddenPluginIDs.remove(pluginID)
        } else {
            preferences.hiddenPluginIDs.insert(pluginID)
        }

        persist(preferences)
    }

    func setOrderedPluginIDs(
        _ orderedPluginIDs: [String],
        defaultPluginIDs: [String]
    ) {
        var preferences = loadPreferences()
        preferences.orderedPluginIDs = normalizeOrder(
            orderedPluginIDs,
            defaultPluginIDs: defaultPluginIDs
        )
        persist(preferences)
    }

    private func loadPreferences() -> StoredPreferences {
        guard let data = userDefaults.data(forKey: DefaultsKey.storage) else {
            return StoredPreferences()
        }

        do {
            return try decoder.decode(StoredPreferences.self, from: data)
        } catch {
            userDefaults.removeObject(forKey: DefaultsKey.storage)
            return StoredPreferences()
        }
    }

    private func persist(_ preferences: StoredPreferences) {
        guard let data = try? encoder.encode(preferences) else {
            return
        }

        userDefaults.set(data, forKey: DefaultsKey.storage)
    }

    private func normalizeOrder(
        _ orderedPluginIDs: [String],
        defaultPluginIDs: [String]
    ) -> [String] {
        let validPluginIDs = Set(defaultPluginIDs)
        var seenPluginIDs: Set<String> = []
        var result: [String] = []

        for pluginID in orderedPluginIDs where validPluginIDs.contains(pluginID) {
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
}
