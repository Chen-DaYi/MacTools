import Foundation
import MacToolsPluginKit

struct ActionShortcutAssignmentRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    let reference: ActionReference
    let binding: ShortcutBinding

    init(
        id: UUID = UUID(),
        reference: ActionReference,
        binding: ShortcutBinding
    ) {
        self.id = id
        self.reference = reference
        self.binding = binding
    }
}

@MainActor
final class ActionShortcutAssignmentStore {
    private struct Payload: Codable {
        let version: Int
        let assignments: [ActionShortcutAssignmentRecord]
    }

    private enum DefaultsKey {
        static let payload = "action-shortcuts.assignments"
        static let legacyAppMigration = "action-shortcuts.migrated-app-shortcuts"
        static let legacyPluginMigrationPrefix = "action-shortcuts.migrated-plugin."
    }

    static let maximumAssignmentCount = 512
    private static let currentVersion = 1

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var loadError: String?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func assignments() -> [ActionShortcutAssignmentRecord] {
        guard let data = userDefaults.data(forKey: DefaultsKey.payload) else {
            loadError = nil
            return []
        }
        do {
            let payload = try decoder.decode(Payload.self, from: data)
            guard payload.version == Self.currentVersion,
                  payload.assignments.count <= Self.maximumAssignmentCount,
                  Set(payload.assignments.map(\.id)).count == payload.assignments.count,
                  Set(payload.assignments.map(\.reference)).count == payload.assignments.count else {
                loadError = "快捷键数据格式无效。"
                return []
            }
            loadError = nil
            return payload.assignments
        } catch {
            loadError = "快捷键数据无法读取。"
            return []
        }
    }

    @discardableResult
    func replaceAll(_ assignments: [ActionShortcutAssignmentRecord]) -> Bool {
        guard assignments.count <= Self.maximumAssignmentCount,
              Set(assignments.map(\.id)).count == assignments.count,
              Set(assignments.map(\.reference)).count == assignments.count,
              let data = try? encoder.encode(
                  Payload(version: Self.currentVersion, assignments: assignments)
              ) else {
            return false
        }
        userDefaults.set(data, forKey: DefaultsKey.payload)
        loadError = nil
        return true
    }

    func assignment(for reference: ActionReference) -> ActionShortcutAssignmentRecord? {
        assignments().first { $0.reference == reference }
    }

    @discardableResult
    func migrateLegacyAppAssignments(
        _ candidates: [(reference: ActionReference, binding: ShortcutBinding)],
        didPersist: () -> Void
    ) -> Bool {
        guard !userDefaults.bool(forKey: DefaultsKey.legacyAppMigration) else {
            return false
        }

        var records = assignments()
        for candidate in candidates where !records.contains(where: {
            $0.reference == candidate.reference
        }) {
            records.append(
                ActionShortcutAssignmentRecord(
                    reference: candidate.reference,
                    binding: candidate.binding
                )
            )
        }
        guard replaceAll(records) else {
            return false
        }
        didPersist()
        userDefaults.set(true, forKey: DefaultsKey.legacyAppMigration)
        return true
    }

    @discardableResult
    func migrateLegacyPluginAssignments(
        pluginID: String,
        assignments: [LegacyActionShortcutAssignment],
        didPersist: () -> Void
    ) -> Bool {
        let migrationKey = DefaultsKey.legacyPluginMigrationPrefix + pluginID
        guard !userDefaults.bool(forKey: migrationKey) else {
            return false
        }

        var records = self.assignments()
        for assignment in assignments where !records.contains(where: {
            $0.reference == assignment.reference
        }) {
            records.append(
                ActionShortcutAssignmentRecord(
                    reference: assignment.reference,
                    binding: assignment.binding
                )
            )
        }
        guard replaceAll(records) else {
            return false
        }
        didPersist()
        userDefaults.set(true, forKey: migrationKey)
        return true
    }
}
