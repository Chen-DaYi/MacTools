import Combine
import Foundation
import MacToolsPluginKit

@MainActor
final class SavedScriptsStore: ObservableObject {
    private struct Envelope: Codable {
        let formatVersion: Int
        let scripts: [SavedScript]
    }

    static let currentFormatVersion = 1
    static let maximumScriptCount = 32
    static let maximumPayloadByteCount = 1 * 1_024 * 1_024
    private static let storageKey = "library.v1"

    @Published private(set) var scripts: [SavedScript] = []
    @Published private(set) var loadError: String?

    var onMutation: (() -> Void)?

    private let storage: any PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: any PluginStorage) {
        self.storage = storage
        reload()
    }

    func script(id: UUID) -> SavedScript? {
        scripts.first { $0.id == id }
    }

    @discardableResult
    func save(_ candidate: SavedScript) -> Result<SavedScript, Error> {
        do {
            let normalized = try candidate.normalized()
            var updated = scripts
            if let index = updated.firstIndex(where: { $0.id == normalized.id }) {
                updated[index] = normalized
            } else {
                guard updated.count < Self.maximumScriptCount else {
                    throw SavedScriptValidationError.tooManyScripts
                }
                updated.append(normalized)
            }
            updated.sort(by: Self.scriptOrder)
            try persist(updated)
            scripts = updated
            loadError = nil
            onMutation?()
            return .success(normalized)
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        var updated = scripts
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return false }
        updated.remove(at: index)
        do {
            try persist(updated)
            scripts = updated
            loadError = nil
            onMutation?()
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    func duplicate(id: UUID, copySuffix: String) -> Result<SavedScript, Error> {
        guard var copy = script(id: id) else {
            return .failure(SavedScriptValidationError.emptySource)
        }
        copy = SavedScript(
            name: "\(copy.name) \(copySuffix)",
            kind: copy.kind,
            source: copy.source,
            workingDirectory: copy.workingDirectory,
            timeoutSeconds: copy.timeoutSeconds,
            confirmOutsideManager: copy.confirmOutsideManager,
            allowExternalInvocation: copy.allowExternalInvocation,
            includeSourceInBackup: copy.includeSourceInBackup
        )
        return save(copy)
    }

    func portableBackup() -> Data? {
        let portableScripts = scripts
            .filter(\.includeSourceInBackup)
            .map { $0.portableCopy() }
        return try? encode(portableScripts)
    }

    func actionIDs(inPortableBackup data: Data) -> [String]? {
        guard data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.formatVersion == Self.currentFormatVersion,
              let decoded = try? validated(envelope.scripts) else {
            return nil
        }
        return decoded.map(\.actionID)
    }

    @discardableResult
    func restorePortableBackup(_ data: Data) -> Bool {
        guard data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.formatVersion == Self.currentFormatVersion,
              let restored = try? validated(envelope.scripts) else {
            return false
        }

        let updated = restored.sorted(by: Self.scriptOrder)
        guard updated.count <= Self.maximumScriptCount else { return false }
        do {
            try persist(updated)
            scripts = updated
            loadError = nil
            onMutation?()
            return true
        } catch {
            return false
        }
    }

    private func reload() {
        guard let data = storage.data(forKey: Self.storageKey) else {
            scripts = []
            loadError = nil
            return
        }
        guard data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.formatVersion == Self.currentFormatVersion,
              let loaded = try? validated(envelope.scripts) else {
            scripts = []
            loadError = "invalid-saved-scripts-library"
            return
        }
        scripts = loaded.sorted(by: Self.scriptOrder)
        loadError = nil
    }

    private func persist(_ scripts: [SavedScript]) throws {
        storage.set(try encode(try validated(scripts)), forKey: Self.storageKey)
    }

    private func encode(_ scripts: [SavedScript]) throws -> Data {
        let data = try encoder.encode(
            Envelope(formatVersion: Self.currentFormatVersion, scripts: scripts)
        )
        guard data.count <= Self.maximumPayloadByteCount else {
            throw SavedScriptValidationError.payloadTooLarge
        }
        return data
    }

    private func validated(_ scripts: [SavedScript]) throws -> [SavedScript] {
        guard scripts.count <= Self.maximumScriptCount else {
            throw SavedScriptValidationError.tooManyScripts
        }
        var ids = Set<UUID>()
        return try scripts.map { script in
            guard ids.insert(script.id).inserted else {
                throw SavedScriptValidationError.duplicateID
            }
            return try script.normalized(now: script.updatedAt)
        }
    }

    private static func scriptOrder(_ lhs: SavedScript, _ rhs: SavedScript) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : comparison == .orderedAscending
    }
}
