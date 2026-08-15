import Foundation
import MacToolsPluginKit

@MainActor
final class SavedScriptsTestStorage: PluginStorage {
    enum WriteBehavior {
        case accept
        case ignore
        case corrupt
    }

    var values: [String: Any] = [:]
    var blocksWrites = false
    private var writeBehaviors: [String: [WriteBehavior]] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) {
        guard !blocksWrites else { return }
        let behavior = writeBehaviors[key]?.isEmpty == false
            ? writeBehaviors[key]!.removeFirst()
            : .accept
        switch behavior {
        case .accept:
            values[key] = value
        case .ignore:
            break
        case .corrupt:
            values[key] = "corrupt"
        }
    }
    func removeObject(forKey key: String) { values[key] = nil }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values[legacyKey] = nil
    }

    func enqueueWriteBehaviors(_ behaviors: [WriteBehavior], forKey key: String) {
        writeBehaviors[key, default: []].append(contentsOf: behaviors)
    }
}
