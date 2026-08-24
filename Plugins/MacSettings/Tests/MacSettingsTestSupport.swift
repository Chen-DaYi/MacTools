import Foundation
@testable import MacSettingsPlugin
import MacToolsPluginKit

@MainActor
final class MacSettingsTestStorage: PluginStorage {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values[legacyKey] = nil
    }
}

@MainActor
func makeTestRecord(
    id: SystemSettingID,
    title: String,
    category: SystemSettingCategory = .finder,
    schema: SystemSettingValueSchema = .boolean,
    defaultValue: SystemSettingValue = .boolean(false),
    executionClass: SystemSettingExecutionClass = .directVerified,
    requirements: SystemSettingRequirements = .init(),
    portability: SystemSettingPortability = .portable,
    isSensitive: Bool = false,
    canRollback: Bool = true,
    verificationAvailable: Bool = true,
    adapter: any SystemSettingAdapter
) -> SystemSettingRecord {
    SystemSettingRecord(
        definition: SystemSettingDefinition(
            id: id,
            title: title,
            description: "Test description for \(title)",
            category: category,
            systemImage: "gearshape",
            schema: schema,
            defaultValue: defaultValue,
            executionClass: executionClass,
            requirements: requirements,
            portability: portability,
            isSensitive: isSensitive,
            canReset: true,
            canRollback: canRollback,
            verificationAvailable: verificationAvailable,
            searchTerms: [title, "test alias"],
            destination: .init(pane: "com.apple.Settings", anchor: nil),
            implementationNote: "Deterministic test adapter."
        ),
        adapter: adapter
    )
}

@MainActor
func makeTestCatalog(_ records: [SystemSettingRecord]) -> SystemSettingCatalog {
    try! SystemSettingCatalog(records: records)
}
