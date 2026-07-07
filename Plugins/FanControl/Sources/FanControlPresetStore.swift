import Foundation
import MacToolsPluginKit

// MARK: - FanControlPresetStore

/// Manages fan presets (built-in + user-created) with persistence via PluginStorage.
@MainActor
final class FanControlPresetStore: ObservableObject {
    // MARK: - Storage Keys

    private enum Key {
        static let customPresets = "custom-presets"
        static let activePresetID = "active-preset-id"
    }

    // MARK: - Built-in Presets

    static let builtInPresets: [FanPreset] = [
        FanPreset(
            id: FanPresetBuiltInID.auto,
            name: "",
            strategy: .auto,
            isBuiltIn: true
        ),
        FanPreset(
            id: FanPresetBuiltInID.fullSpeed,
            name: "",
            strategy: .fullSpeed,
            isBuiltIn: true
        ),
    ]

    // MARK: - State

    private let storage: PluginStorage
    private let localization: PluginLocalization
    @Published private(set) var customPresets: [FanPreset] = []
    @Published private(set) var activePresetID: String = FanPresetBuiltInID.auto

    var allPresets: [FanPreset] {
        Self.builtInPresets + customPresets
    }

    var activePreset: FanPreset {
        allPresets.first(where: { $0.id == activePresetID })
            ?? Self.builtInPresets[0]
    }

    // MARK: - Init

    init(
        storage: PluginStorage,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.storage = storage
        self.localization = localization
        load()
    }

    // MARK: - Persistence

    private func load() {
        if let data = storage.data(forKey: Key.customPresets),
           let decoded = try? JSONDecoder().decode([FanPreset].self, from: data) {
            customPresets = decoded
        }
        if let saved = storage.string(forKey: Key.activePresetID) {
            activePresetID = saved
        }
        // Validate active ID still exists
        if !allPresets.contains(where: { $0.id == activePresetID }) {
            activePresetID = FanPresetBuiltInID.auto
        }
    }

    private func saveCustomPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            storage.set(data, forKey: Key.customPresets)
        }
    }

    private func saveActivePresetID() {
        storage.set(activePresetID, forKey: Key.activePresetID)
    }

    // MARK: - CRUD

    func setActivePreset(id: String) {
        guard allPresets.contains(where: { $0.id == id }) else { return }
        activePresetID = id
        saveActivePresetID()
    }

    func addCustomPreset() -> FanPreset {
        let index = customPresets.count + 1
        let preset = FanPreset(
            id: UUID().uuidString,
            name: localization.format("preset.custom.defaultName", defaultValue: "自定义预设 %d", index),
            strategy: .fixed(rpm: FanRPMLimits.absoluteMin),
            isBuiltIn: false
        )
        customPresets.append(preset)
        saveCustomPresets()
        return preset
    }

    func updateCustomPresetRPM(id: String, rpm: Int) {
        guard let idx = customPresets.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(FanRPMLimits.absoluteMin, min(FanRPMLimits.absoluteMax, rpm))
        customPresets[idx].strategy = .fixed(rpm: clamped)
        saveCustomPresets()
    }

    func renameCustomPreset(id: String, newName: String) {
        guard let idx = customPresets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        customPresets[idx].name = trimmed
        saveCustomPresets()
    }

    func deleteCustomPreset(id: String) {
        customPresets.removeAll(where: { $0.id == id })
        if activePresetID == id {
            activePresetID = FanPresetBuiltInID.auto
            saveActivePresetID()
        }
        saveCustomPresets()
    }
}
