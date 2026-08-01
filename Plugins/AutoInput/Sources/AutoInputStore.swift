import Foundation
import MacToolsPluginKit

@MainActor
final class AutoInputStore: ObservableObject {
    private enum Keys {
        static let isEnabled = "isEnabled"
        static let remembersLastInputSource = "remembersLastInputSource"
        static let showsSwitchHUD = "showsSwitchHUD"
        static let rules = "rules"
        static let memories = "memories"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var remembersLastInputSource: Bool
    @Published private(set) var showsSwitchHUD: Bool
    @Published private(set) var rules: [AutoInputRule]

    private(set) var memories: [String: String]

    private let storage: PluginStorage
    private let encoder = JSONEncoder()

    init(storage: PluginStorage) {
        self.storage = storage
        self.isEnabled = storage.object(forKey: Keys.isEnabled) == nil
            ? true
            : storage.bool(forKey: Keys.isEnabled)
        self.remembersLastInputSource = storage.object(forKey: Keys.remembersLastInputSource) == nil
            ? true
            : storage.bool(forKey: Keys.remembersLastInputSource)
        self.showsSwitchHUD = storage.object(forKey: Keys.showsSwitchHUD) == nil
            ? false
            : storage.bool(forKey: Keys.showsSwitchHUD)
        let decodedRules = Self.decode([AutoInputRule].self, from: storage.data(forKey: Keys.rules)) ?? []
        self.rules = Self.normalizedRules(decodedRules)
        let decodedMemories = Self.decode([String: String].self, from: storage.data(forKey: Keys.memories)) ?? [:]
        self.memories = decodedMemories.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    func setEnabled(_ value: Bool) {
        guard isEnabled != value else { return }
        isEnabled = value
        storage.set(value, forKey: Keys.isEnabled)
    }

    func setRemembersLastInputSource(_ value: Bool) {
        guard remembersLastInputSource != value else { return }
        remembersLastInputSource = value
        storage.set(value, forKey: Keys.remembersLastInputSource)
    }

    func setShowsSwitchHUD(_ value: Bool) {
        guard showsSwitchHUD != value else { return }
        showsSwitchHUD = value
        storage.set(value, forKey: Keys.showsSwitchHUD)
    }

    func upsertRule(_ rule: AutoInputRule) {
        if let index = rules.firstIndex(where: { $0.bundleIdentifier == rule.bundleIdentifier }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        rules.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        persistRules()
    }

    func updateRule(bundleIdentifier: String, inputSourceID: String) {
        guard let index = rules.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        rules[index].inputSourceID = inputSourceID
        persistRules()
    }

    func removeRule(bundleIdentifier: String) {
        rules.removeAll { $0.bundleIdentifier == bundleIdentifier }
        persistRules()
    }

    func rule(for bundleIdentifier: String) -> AutoInputRule? {
        rules.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func remember(inputSourceID: String, for bundleIdentifier: String) {
        guard memories[bundleIdentifier] != inputSourceID else { return }
        memories[bundleIdentifier] = inputSourceID
        persistMemories()
    }

    func rememberedInputSourceID(for bundleIdentifier: String) -> String? {
        memories[bundleIdentifier]
    }

    private func persistRules() {
        guard let data = try? encoder.encode(rules) else { return }
        storage.set(data, forKey: Keys.rules)
    }

    private func persistMemories() {
        guard let data = try? encoder.encode(memories) else { return }
        storage.set(data, forKey: Keys.memories)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data?) -> Value? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func normalizedRules(_ rules: [AutoInputRule]) -> [AutoInputRule] {
        var rulesByBundleID: [String: AutoInputRule] = [:]
        for rule in rules where !rule.bundleIdentifier.isEmpty && !rule.inputSourceID.isEmpty {
            rulesByBundleID[rule.bundleIdentifier] = rule
        }
        return rulesByBundleID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}
