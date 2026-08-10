import Foundation
import MacToolsPluginKit

enum AutoInputStoreMutationResult: Equatable {
    case committed
    case rejected(rollbackSucceeded: Bool)
}

@MainActor
final class AutoInputStore: ObservableObject {
    private enum Keys {
        static let isEnabled = "isEnabled"
        static let remembersLastInputSource = "remembersLastInputSource"
        static let rules = "rules"
        static let memories = "memories"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var remembersLastInputSource: Bool
    @Published private(set) var rules: [AutoInputRule]
    @Published private(set) var persistenceFailure: AutoInputStoreMutationResult?

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
        let decodedRules = Self.decode([AutoInputRule].self, from: storage.data(forKey: Keys.rules)) ?? []
        self.rules = Self.normalizedRules(decodedRules)
        let decodedMemories = Self.decode([String: String].self, from: storage.data(forKey: Keys.memories)) ?? [:]
        self.memories = decodedMemories.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    @discardableResult
    func setEnabled(_ value: Bool) -> AutoInputStoreMutationResult {
        guard isEnabled != value else { return record(.committed) }
        let result = persist(value, forKey: Keys.isEnabled)
        if result == .committed { isEnabled = value }
        return record(result)
    }

    @discardableResult
    func setRemembersLastInputSource(_ value: Bool) -> AutoInputStoreMutationResult {
        guard remembersLastInputSource != value else { return record(.committed) }
        let result = persist(value, forKey: Keys.remembersLastInputSource)
        if result == .committed { remembersLastInputSource = value }
        return record(result)
    }

    @discardableResult
    func upsertRule(_ rule: AutoInputRule) -> AutoInputStoreMutationResult {
        var candidate = rules
        if let index = candidate.firstIndex(where: { $0.bundleIdentifier == rule.bundleIdentifier }) {
            candidate[index] = rule
        } else {
            candidate.append(rule)
        }
        candidate.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let result = persist(candidate, forKey: Keys.rules)
        if result == .committed { rules = candidate }
        return record(result)
    }

    @discardableResult
    func updateRule(bundleIdentifier: String, inputSourceID: String) -> AutoInputStoreMutationResult {
        guard let index = rules.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return record(.committed)
        }
        var candidate = rules
        candidate[index].inputSourceID = inputSourceID
        let result = persist(candidate, forKey: Keys.rules)
        if result == .committed { rules = candidate }
        return record(result)
    }

    @discardableResult
    func removeRule(bundleIdentifier: String) -> AutoInputStoreMutationResult {
        let candidate = rules.filter { $0.bundleIdentifier != bundleIdentifier }
        guard candidate != rules else { return record(.committed) }
        let result = persist(candidate, forKey: Keys.rules)
        if result == .committed { rules = candidate }
        return record(result)
    }

    func rule(for bundleIdentifier: String) -> AutoInputRule? {
        rules.first { $0.bundleIdentifier == bundleIdentifier }
    }

    @discardableResult
    func remember(inputSourceID: String, for bundleIdentifier: String) -> AutoInputStoreMutationResult {
        guard memories[bundleIdentifier] != inputSourceID else { return record(.committed) }
        var candidate = memories
        candidate[bundleIdentifier] = inputSourceID
        let result = persist(candidate, forKey: Keys.memories)
        if result == .committed { memories = candidate }
        return record(result)
    }

    func rememberedInputSourceID(for bundleIdentifier: String) -> String? {
        memories[bundleIdentifier]
    }

    private func persist(_ value: Bool, forKey key: String) -> AutoInputStoreMutationResult {
        let previous = storage.object(forKey: key)
        storage.set(value, forKey: key)
        guard let persisted = storage.object(forKey: key) as? Bool, persisted == value else {
            restore(previous, forKey: key)
            return .rejected(rollbackSucceeded: rawValue(storage.object(forKey: key), equals: previous))
        }
        return .committed
    }

    private func persist<Value: Encodable>(
        _ value: Value,
        forKey key: String
    ) -> AutoInputStoreMutationResult {
        guard let data = try? encoder.encode(value) else {
            return .rejected(rollbackSucceeded: true)
        }
        let previous = storage.object(forKey: key)
        storage.set(data, forKey: key)
        guard storage.data(forKey: key) == data else {
            restore(previous, forKey: key)
            return .rejected(
                rollbackSucceeded: rawValue(storage.object(forKey: key), equals: previous)
            )
        }
        return .committed
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            storage.set(value, forKey: key)
        } else {
            storage.removeObject(forKey: key)
        }
    }

    private func rawValue(_ lhs: Any?, equals rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs as NSObject, rhs as NSObject): lhs.isEqual(rhs)
        default: false
        }
    }

    private func record(_ result: AutoInputStoreMutationResult) -> AutoInputStoreMutationResult {
        persistenceFailure = result == .committed ? nil : result
        return result
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
