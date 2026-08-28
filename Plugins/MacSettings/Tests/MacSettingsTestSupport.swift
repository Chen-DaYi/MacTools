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
final class FirstReadSuspendingSystemSettingAdapter: SystemSettingAdapter {
    var value: SystemSettingValue
    private(set) var firstReadStarted = false
    private var readCount = 0
    private var firstReadContinuation: CheckedContinuation<SystemSettingValue, Error>?

    init(value: SystemSettingValue) {
        self.value = value
    }

    func read() async throws -> SystemSettingValue {
        readCount += 1
        guard readCount == 1 else { return value }
        firstReadStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            firstReadContinuation = continuation
        }
    }

    func resumeFirstRead(with value: SystemSettingValue) {
        firstReadContinuation?.resume(returning: value)
        firstReadContinuation = nil
    }

    func apply(_ value: SystemSettingValue) async throws {
        self.value = value
    }

    func verify(_ expectedValue: SystemSettingValue) async throws -> SystemSettingVerification {
        value == expectedValue ? .verified(value) : .mismatch(actual: value)
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
