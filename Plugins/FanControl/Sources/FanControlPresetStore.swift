import Foundation
import MacToolsPluginKit

// MARK: - FanControlPresetStore

/// Manages fan presets (built-in + user-created) with persistence via PluginStorage.
@MainActor
final class FanControlPresetStore: ObservableObject {
    private struct PortablePreferences: Codable {
        let version: Int
        let customPresets: [FanPreset]
        let activePresetID: String
    }

    private struct PortableRestoreTransaction: Codable {
        let customPresets: Data?
        let activePresetID: String?
    }

    private static let portablePreferencesVersion = 1
    private static let maximumPortablePreferencesSize = 256 * 1_024
    private static let maximumCustomPresetCount = 100
    private static let maximumPresetNameLength = 100

    // MARK: - Storage Keys

    private enum Key {
        static let customPresets = "custom-presets"
        static let activePresetID = "active-preset-id"
        static let portableRestoreTransaction = "portable-restore-transaction.v1"
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
    var onCatalogChange: (() -> Void)?

    var allPresets: [FanPreset] {
        Self.builtInPresets + customPresets
    }

    var activePreset: FanPreset {
        allPresets.first(where: { $0.id == activePresetID })
            ?? Self.builtInPresets[0]
    }

    var canAddPreset: Bool {
        customPresets.count < Self.maximumCustomPresetCount
    }

    // MARK: - Init

    init(
        storage: PluginStorage,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.storage = storage
        self.localization = localization
        _ = recoverInterruptedPortableRestore()
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

    func makePortablePreferencesBackup() -> Data? {
        let payload = PortablePreferences(
            version: Self.portablePreferencesVersion,
            customPresets: customPresets,
            activePresetID: activePresetID
        )
        guard Self.isValidPortablePayload(payload),
              let data = try? JSONEncoder().encode(payload),
              data.count <= Self.maximumPortablePreferencesSize else {
            return nil
        }
        return data
    }

    @discardableResult
    func restorePortablePreferences(from data: Data) -> Bool {
        guard data.count <= Self.maximumPortablePreferencesSize,
              let payload = try? JSONDecoder().decode(PortablePreferences.self, from: data),
              payload.version == Self.portablePreferencesVersion,
              Self.isValidPortablePayload(payload)
        else {
            return false
        }

        guard let presetData = try? JSONEncoder().encode(payload.customPresets) else {
            return false
        }
        guard recoverInterruptedPortableRestore(),
              beginPortableRestoreTransaction(),
              writePortableValues(
                  customPresets: presetData,
                  activePresetID: payload.activePresetID
              ),
              finishPortableRestoreTransaction() else {
            rollbackPortableRestoreTransaction()
            return false
        }
        customPresets = payload.customPresets
        activePresetID = payload.activePresetID
        onCatalogChange?()
        return true
    }

    func customPresetIDs(inPortablePreferences data: Data) -> [String]? {
        guard data.count <= Self.maximumPortablePreferencesSize,
              let payload = try? JSONDecoder().decode(PortablePreferences.self, from: data),
              payload.version == Self.portablePreferencesVersion,
              Self.isValidPortablePayload(payload) else {
            return nil
        }
        return payload.customPresets.map(\.id)
    }

    private func beginPortableRestoreTransaction() -> Bool {
        let transaction = PortableRestoreTransaction(
            customPresets: storage.data(forKey: Key.customPresets),
            activePresetID: storage.string(forKey: Key.activePresetID)
        )
        guard let data = try? JSONEncoder().encode(transaction) else { return false }
        storage.set(data, forKey: Key.portableRestoreTransaction)
        return storage.data(forKey: Key.portableRestoreTransaction) == data
    }

    private func recoverInterruptedPortableRestore() -> Bool {
        guard let transactionData = storage.data(forKey: Key.portableRestoreTransaction) else {
            return true
        }
        guard let transaction = try? JSONDecoder().decode(
            PortableRestoreTransaction.self,
            from: transactionData
        ) else {
            return false
        }
        guard writePortableValues(
            customPresets: transaction.customPresets,
            activePresetID: transaction.activePresetID
        ) else {
            return false
        }
        storage.removeObject(forKey: Key.portableRestoreTransaction)
        return storage.data(forKey: Key.portableRestoreTransaction) == nil
    }

    @discardableResult
    private func rollbackPortableRestoreTransaction() -> Bool {
        recoverInterruptedPortableRestore()
    }

    private func finishPortableRestoreTransaction() -> Bool {
        storage.removeObject(forKey: Key.portableRestoreTransaction)
        return storage.data(forKey: Key.portableRestoreTransaction) == nil
    }

    private func writePortableValues(customPresets: Data?, activePresetID: String?) -> Bool {
        setOptional(customPresets, forKey: Key.customPresets)
        setOptional(activePresetID, forKey: Key.activePresetID)
        return storage.data(forKey: Key.customPresets) == customPresets
            && storage.string(forKey: Key.activePresetID) == activePresetID
    }

    private func setOptional(_ value: Any?, forKey key: String) {
        if let value {
            storage.set(value, forKey: key)
        } else {
            storage.removeObject(forKey: key)
        }
    }

    private static func isValidPortablePayload(_ payload: PortablePreferences) -> Bool {
        guard payload.customPresets.count <= maximumCustomPresetCount else { return false }
        let identifiers = Set(payload.customPresets.map(\.id))
        guard identifiers.count == payload.customPresets.count else { return false }
        guard payload.customPresets.allSatisfy({ preset in
            guard UUID(uuidString: preset.id) != nil,
                  !preset.isBuiltIn,
                  !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  preset.name.count <= maximumPresetNameLength,
                  case let .fixed(rpm) = preset.strategy
            else {
                return false
            }
            return (FanRPMLimits.absoluteMin...FanRPMLimits.absoluteMax).contains(rpm)
        }) else {
            return false
        }

        return payload.activePresetID == FanPresetBuiltInID.auto
            || payload.activePresetID == FanPresetBuiltInID.fullSpeed
            || identifiers.contains(payload.activePresetID)
    }

    // MARK: - CRUD

    func setActivePreset(id: String) {
        guard allPresets.contains(where: { $0.id == id }) else { return }
        activePresetID = id
        saveActivePresetID()
    }

    func addCustomPreset() -> FanPreset? {
        guard customPresets.count < Self.maximumCustomPresetCount else { return nil }
        let index = customPresets.count + 1
        let preset = FanPreset(
            id: UUID().uuidString,
            name: localization.format("preset.custom.defaultName", defaultValue: "自定义预设 %d", index),
            strategy: .fixed(rpm: FanRPMLimits.absoluteMin),
            isBuiltIn: false
        )
        customPresets.append(preset)
        saveCustomPresets()
        onCatalogChange?()
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
        customPresets[idx].name = String(trimmed.prefix(Self.maximumPresetNameLength))
        saveCustomPresets()
        onCatalogChange?()
    }

    func deleteCustomPreset(id: String) {
        customPresets.removeAll(where: { $0.id == id })
        if activePresetID == id {
            activePresetID = FanPresetBuiltInID.auto
            saveActivePresetID()
        }
        saveCustomPresets()
        onCatalogChange?()
    }
}
