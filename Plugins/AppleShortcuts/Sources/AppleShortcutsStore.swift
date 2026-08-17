import Combine
import Foundation
import MacToolsPluginKit

struct AppleShortcutsSettingsState: Codable, Equatable, Sendable {
    var explicitlyEnabledIDs: Set<UUID> = []
    var syncedFolders: [UUID: AppleShortcutSyncedFolder] = [:]
    var excludedIDs: Set<UUID> = []
    var policies: [UUID: AppleShortcutPolicy] = [:]
    var trackedRecords: [UUID: AppleShortcutTrackedRecord] = [:]

    var effectiveEnabledIDs: Set<UUID> {
        let folderMembers = syncedFolders.values.reduce(into: Set<UUID>()) {
            $0.formUnion($1.memberIDs)
        }
        return explicitlyEnabledIDs.union(folderMembers.subtracting(excludedIDs))
    }
}

@MainActor
final class AppleShortcutsStore: ObservableObject {
    private struct Envelope: Codable {
        let formatVersion: Int
        let state: AppleShortcutsSettingsState
    }

    private struct PortableEnvelope: Codable {
        struct Folder: Codable {
            let id: UUID
            let memberIDs: Set<UUID>
        }

        let formatVersion: Int
        let explicitlyEnabledIDs: Set<UUID>
        let syncedFolders: [Folder]
        let excludedIDs: Set<UUID>
        let policies: [UUID: AppleShortcutPolicy]
        let trackedActionIDs: Set<String>
    }

    static let currentFormatVersion = 1
    static let maximumTrackedShortcutCount = AppleShortcutsLimits.maximumTrackedShortcutCount
    static let maximumPayloadByteCount = 1 * 1_024 * 1_024
    static let storageKey = "settings.v1"

    @Published private(set) var state = AppleShortcutsSettingsState()
    @Published private(set) var loadError: String?

    var onMutation: (() -> Void)?
    var onSafetyPolicyMutation: (() -> Void)?

    private let storage: any PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: any PluginStorage) {
        self.storage = storage
        reload()
    }

    var trackedRecords: [AppleShortcutTrackedRecord] {
        state.trackedRecords.values.sorted(by: Self.recordOrder)
    }

    func record(id: UUID) -> AppleShortcutTrackedRecord? { state.trackedRecords[id] }
    func policy(for id: UUID) -> AppleShortcutPolicy { state.policies[id] ?? .default }
    func isEnabled(_ id: UUID) -> Bool { state.effectiveEnabledIDs.contains(id) }
    func isExplicitlyEnabled(_ id: UUID) -> Bool { state.explicitlyEnabledIDs.contains(id) }
    func isFolderSynced(_ id: UUID) -> Bool { state.syncedFolders[id] != nil }

    func folderSourceIDs(for shortcutID: UUID) -> Set<UUID> {
        Set(state.syncedFolders.values.compactMap { folder in
            folder.memberIDs.contains(shortcutID) ? folder.id : nil
        })
    }

    func folderSyncPreview(members: [AppleShortcutItem]) -> AppleShortcutFolderSyncPreview {
        let memberIDs = Set(members.map(\.id))
        let enabledByFolder = memberIDs.subtracting(state.excludedIDs)
        let currentEnabled = state.effectiveEnabledIDs
        return AppleShortcutFolderSyncPreview(
            memberIDs: memberIDs,
            additionIDs: enabledByFolder.subtracting(currentEnabled),
            excludedIDs: memberIDs.intersection(state.excludedIDs),
            projectedTrackedCount: Self.retainedShortcutIDs(in: state).union(memberIDs).count
        )
    }

    func disappearingShortcutCount(whenStoppingSync folderID: UUID) -> Int {
        guard let folder = state.syncedFolders[folderID] else { return 0 }
        return folder.memberIDs.intersection(state.effectiveEnabledIDs).filter { shortcutID in
            !state.explicitlyEnabledIDs.contains(shortcutID)
                && folderSourceIDs(for: shortcutID).subtracting([folderID]).isEmpty
        }.count
    }

    func setShortcutEnabled(
        _ enabled: Bool,
        item: AppleShortcutItem?
    ) -> Result<Void, AppleShortcutsStoreError> {
        guard let item else { return .failure(.invalidData) }
        return setShortcutsEnabled(enabled, items: [item])
    }

    func setShortcutsEnabled(
        _ enabled: Bool,
        items: [AppleShortcutItem]
    ) -> Result<Void, AppleShortcutsStoreError> {
        let itemsByID = items.reduce(into: [UUID: AppleShortcutItem]()) { result, item in
            result[item.id] = item
        }
        guard !itemsByID.isEmpty else { return .success(()) }
        return mutate { updated in
            for item in itemsByID.values {
                if enabled {
                    updated.explicitlyEnabledIDs.insert(item.id)
                    updated.excludedIDs.remove(item.id)
                    updated.trackedRecords[item.id] = AppleShortcutTrackedRecord(
                        id: item.id,
                        lastKnownName: item.name,
                        lastKnownFolderIDs: item.folderIDs
                    )
                } else {
                    updated.explicitlyEnabledIDs.remove(item.id)
                    if updated.syncedFolders.values.contains(where: { $0.memberIDs.contains(item.id) }) {
                        updated.excludedIDs.insert(item.id)
                    } else {
                        updated.excludedIDs.remove(item.id)
                    }
                }
            }
            Self.prune(&updated)
        }
    }

    func setFolderSynced(
        _ enabled: Bool,
        folder: AppleShortcutFolder,
        members: [AppleShortcutItem]
    ) -> Result<Void, AppleShortcutsStoreError> {
        mutate { updated in
            if enabled {
                updated.syncedFolders[folder.id] = AppleShortcutSyncedFolder(
                    id: folder.id,
                    lastKnownName: folder.name,
                    memberIDs: Set(members.map(\.id))
                )
                for item in members where !updated.excludedIDs.contains(item.id) {
                    updated.trackedRecords[item.id] = AppleShortcutTrackedRecord(
                        id: item.id,
                        lastKnownName: item.name,
                        lastKnownFolderIDs: item.folderIDs
                    )
                }
            } else {
                updated.syncedFolders.removeValue(forKey: folder.id)
                if updated.syncedFolders.isEmpty {
                    updated.excludedIDs.removeAll()
                }
            }
            Self.prune(&updated)
        }
    }

    func setRequiresConfirmation(
        _ value: Bool,
        for id: UUID
    ) -> Result<Void, AppleShortcutsStoreError> {
        updatePolicy(id: id) { $0.requiresConfirmation = value }
    }

    func setAllowsRunLink(
        _ value: Bool,
        for id: UUID
    ) -> Result<Void, AppleShortcutsStoreError> {
        updatePolicy(id: id) { $0.allowsRunLink = value }
    }

    @discardableResult
    func reconcile(_ discovery: AppleShortcutsDiscovery) -> Result<Void, AppleShortcutsStoreError> {
        mutate { updated in
            let shortcutsByID = Dictionary(uniqueKeysWithValues: discovery.shortcuts.map { ($0.id, $0) })
            let foldersByID = Dictionary(uniqueKeysWithValues: discovery.folders.map { ($0.id, $0) })

            for (folderID, var syncedFolder) in updated.syncedFolders {
                if let folder = foldersByID[folderID] {
                    syncedFolder.lastKnownName = folder.name
                    if !discovery.failedFolderIDs.contains(folderID) {
                        let discoveredMembers = discovery.folderMemberships[folderID] ?? []
                        let globallyPresentIDs = Set(discovery.shortcuts.map(\.id))
                        let retainedMissingMembers = syncedFolder.memberIDs.subtracting(
                            globallyPresentIDs
                        )
                        syncedFolder.memberIDs = discoveredMembers.union(retainedMissingMembers)
                    }
                    updated.syncedFolders[folderID] = syncedFolder
                }
            }

            let enabledIDs = updated.effectiveEnabledIDs
            for id in enabledIDs {
                if let item = shortcutsByID[id] {
                    let retainedFailedFolderIDs = Set(updated.syncedFolders.values.compactMap { folder in
                        discovery.failedFolderIDs.contains(folder.id) && folder.memberIDs.contains(id)
                            ? folder.id : nil
                    })
                    let retainedMissingFolderIDs = Set(updated.syncedFolders.values.compactMap { folder in
                        foldersByID[folder.id] == nil && folder.memberIDs.contains(id)
                            ? folder.id : nil
                    })
                    updated.trackedRecords[id] = AppleShortcutTrackedRecord(
                        id: id,
                        lastKnownName: item.name,
                        lastKnownFolderIDs: item.folderIDs
                            .union(retainedFailedFolderIDs)
                            .union(retainedMissingFolderIDs)
                    )
                } else if updated.trackedRecords[id] == nil {
                    updated.trackedRecords[id] = AppleShortcutTrackedRecord(
                        id: id,
                        lastKnownName: "",
                        lastKnownFolderIDs: []
                    )
                }
            }
            Self.prune(&updated)
        }
    }

    func portableBackup() -> Data? {
        guard loadError == nil else { return nil }
        let payload = PortableEnvelope(
            formatVersion: Self.currentFormatVersion,
            explicitlyEnabledIDs: state.explicitlyEnabledIDs,
            syncedFolders: state.syncedFolders.values.map {
                PortableEnvelope.Folder(id: $0.id, memberIDs: $0.memberIDs)
            },
            excludedIDs: state.excludedIDs,
            policies: state.policies,
            trackedActionIDs: Set(state.effectiveEnabledIDs.map(Self.actionID(for:)))
        )
        guard let data = try? encoder.encode(payload),
              data.count <= Self.maximumPayloadByteCount else { return nil }
        return data
    }

    func actionIDs(inPortableBackup data: Data) -> [String]? {
        guard let portable = decodePortable(data),
              validatePortable(portable) != nil else { return nil }
        return portable.trackedActionIDs.sorted()
    }

    @discardableResult
    func restorePortableBackup(_ data: Data) -> Bool {
        guard let portable = decodePortable(data),
              let restored = validatePortable(portable) else { return false }
        do {
            try persist(restored)
            state = restored
            loadError = nil
            onMutation?()
            return true
        } catch {
            return false
        }
    }

    static func shortcutID(fromActionID actionID: String) -> UUID? {
        guard actionID.hasPrefix("run.") else { return nil }
        guard let id = UUID(uuidString: String(actionID.dropFirst(4))),
              actionID == Self.actionID(for: id) else { return nil }
        return id
    }

    static func actionID(for id: UUID) -> String {
        "run.\(id.uuidString.lowercased())"
    }

    private func updatePolicy(
        id: UUID,
        change: (inout AppleShortcutPolicy) -> Void
    ) -> Result<Void, AppleShortcutsStoreError> {
        guard state.effectiveEnabledIDs.contains(id) else { return .failure(.invalidData) }
        let previousPolicy = policy(for: id)
        let result = mutate { updated in
            var policy = updated.policies[id] ?? .default
            change(&policy)
            updated.policies[id] = policy == .default ? nil : policy
        }
        if case .success = result, policy(for: id) != previousPolicy {
            onSafetyPolicyMutation?()
        }
        return result
    }

    private func mutate(
        _ change: (inout AppleShortcutsSettingsState) -> Void
    ) -> Result<Void, AppleShortcutsStoreError> {
        guard loadError == nil else { return .failure(.recoveryRequired) }
        var updated = state
        change(&updated)
        guard updated != state else { return .success(()) }
        do {
            try validate(updated)
            try persist(updated)
            state = updated
            loadError = nil
            onMutation?()
            return .success(())
        } catch let error as AppleShortcutsStoreError {
            return .failure(error)
        } catch {
            return .failure(.invalidData)
        }
    }

    private static func prune(_ state: inout AppleShortcutsSettingsState) {
        let enabled = state.effectiveEnabledIDs
        state.trackedRecords = state.trackedRecords.filter { enabled.contains($0.key) }
        state.policies = state.policies.filter { enabled.contains($0.key) }
    }

    private static func retainedShortcutIDs(
        in state: AppleShortcutsSettingsState
    ) -> Set<UUID> {
        state.syncedFolders.values.reduce(into: state.explicitlyEnabledIDs) {
            $0.formUnion($1.memberIDs)
        }
        .union(state.excludedIDs)
        .union(state.policies.keys)
        .union(state.trackedRecords.keys)
    }

    private func reload() {
        guard let rawValue = storage.object(forKey: Self.storageKey) else {
            state = AppleShortcutsSettingsState()
            loadError = nil
            return
        }
        guard let data = rawValue as? Data,
              data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.formatVersion == Self.currentFormatVersion,
              (try? validate(envelope.state)) != nil else {
            state = AppleShortcutsSettingsState()
            loadError = "invalid-apple-shortcuts-settings"
            return
        }
        state = envelope.state
        loadError = nil
    }

    private func persist(_ state: AppleShortcutsSettingsState) throws {
        try validate(state)
        let data = try encoder.encode(Envelope(
            formatVersion: Self.currentFormatVersion,
            state: state
        ))
        guard data.count <= Self.maximumPayloadByteCount else {
            throw AppleShortcutsStoreError.payloadTooLarge
        }
        let previous = storage.object(forKey: Self.storageKey)
        storage.set(data, forKey: Self.storageKey)
        guard storage.data(forKey: Self.storageKey) == data else {
            if let previous {
                storage.set(previous, forKey: Self.storageKey)
            } else {
                storage.removeObject(forKey: Self.storageKey)
            }
            throw AppleShortcutsStoreError.persistenceFailed
        }
    }

    private func validate(_ state: AppleShortcutsSettingsState) throws {
        let enabled = state.effectiveEnabledIDs
        guard Self.retainedShortcutIDs(in: state).count <= Self.maximumTrackedShortcutCount,
              enabled.count <= Self.maximumTrackedShortcutCount,
              state.explicitlyEnabledIDs.count <= Self.maximumTrackedShortcutCount,
              state.syncedFolders.count <= Self.maximumTrackedShortcutCount,
              state.excludedIDs.count <= Self.maximumTrackedShortcutCount,
              state.trackedRecords.count <= Self.maximumTrackedShortcutCount,
              state.explicitlyEnabledIDs.isDisjoint(with: state.excludedIDs),
              !state.syncedFolders.isEmpty || state.excludedIDs.isEmpty,
              Set(state.trackedRecords.keys) == enabled,
              state.policies.keys.allSatisfy(enabled.contains),
              state.trackedRecords.allSatisfy({ $0.key == $0.value.id }),
              state.syncedFolders.allSatisfy({
                  $0.key == $0.value.id
                      && $0.value.memberIDs.count <= Self.maximumTrackedShortcutCount
              })
        else { throw AppleShortcutsStoreError.tooManyTrackedShortcuts }
        guard state.trackedRecords.values.allSatisfy({
            $0.lastKnownName.utf8.count <= AppleShortcutItem.maximumNameByteCount
        }), state.syncedFolders.values.allSatisfy({
            $0.lastKnownName.utf8.count <= AppleShortcutItem.maximumNameByteCount
        }) else { throw AppleShortcutsStoreError.invalidData }
    }

    private func decodePortable(_ data: Data) -> PortableEnvelope? {
        guard data.count <= Self.maximumPayloadByteCount,
              let portable = try? decoder.decode(PortableEnvelope.self, from: data),
              portable.formatVersion == Self.currentFormatVersion else { return nil }
        return portable
    }

    private func validatePortable(_ portable: PortableEnvelope) -> AppleShortcutsSettingsState? {
        var folders: [UUID: AppleShortcutSyncedFolder] = [:]
        for folder in portable.syncedFolders {
            guard folders[folder.id] == nil else { return nil }
            folders[folder.id] = AppleShortcutSyncedFolder(
                id: folder.id,
                lastKnownName: "",
                memberIDs: folder.memberIDs
            )
        }
        let enabled = portable.explicitlyEnabledIDs.union(
            folders.values.reduce(into: Set<UUID>()) { $0.formUnion($1.memberIDs) }
                .subtracting(portable.excludedIDs)
        )
        guard Set(enabled.map(Self.actionID(for:))) == portable.trackedActionIDs else { return nil }
        let records = Dictionary(uniqueKeysWithValues: enabled.map {
            ($0, AppleShortcutTrackedRecord(id: $0, lastKnownName: "", lastKnownFolderIDs: []))
        })
        let restored = AppleShortcutsSettingsState(
            explicitlyEnabledIDs: portable.explicitlyEnabledIDs,
            syncedFolders: folders,
            excludedIDs: portable.excludedIDs,
            policies: portable.policies,
            trackedRecords: records
        )
        guard (try? validate(restored)) != nil else { return nil }
        return restored
    }

    private static func recordOrder(
        _ lhs: AppleShortcutTrackedRecord,
        _ rhs: AppleShortcutTrackedRecord
    ) -> Bool {
        let comparison = lhs.lastKnownName.localizedStandardCompare(rhs.lastKnownName)
        return comparison == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : comparison == .orderedAscending
    }
}
