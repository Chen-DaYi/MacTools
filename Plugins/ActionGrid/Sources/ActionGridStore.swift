import Combine
import Foundation
import MacToolsPluginKit

struct ActionGridEntry: Codable, Equatable, Identifiable, Sendable {
    static let maximumCustomTitleByteCount = 80

    let id: UUID
    var reference: ActionReference
    var customTitle: String?

    init(id: UUID = UUID(), reference: ActionReference, customTitle: String? = nil) {
        self.id = id
        self.reference = reference
        self.customTitle = customTitle
    }

    var presentationEntry: ActionGridPresentationEntry {
        ActionGridPresentationEntry(
            id: id.uuidString.lowercased(),
            reference: reference,
            customTitle: customTitle
        )
    }
}

@MainActor
final class ActionGridStore: ObservableObject {
    private struct Envelope: Codable {
        let formatVersion: Int
        let entries: [ActionGridEntry]
    }

    static let currentFormatVersion = 1
    static let maximumEntryCount = 9
    static let maximumPayloadByteCount = 64 * 1_024
    private static let storageKey = "layout.v1"

    @Published private(set) var entries: [ActionGridEntry] = []
    @Published private(set) var loadError: String?

    private let storage: any PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: any PluginStorage) {
        self.storage = storage
        reload()
    }

    @discardableResult
    func add(reference: ActionReference) -> Bool {
        guard entries.count < Self.maximumEntryCount,
              !entries.contains(where: { $0.reference == reference }) else {
            return false
        }
        var updated = entries
        updated.append(ActionGridEntry(reference: reference))
        return replace(updated)
    }

    @discardableResult
    func replace(id: UUID, reference: ActionReference) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              !entries.enumerated().contains(where: { $0.offset != index && $0.element.reference == reference }) else {
            return false
        }
        var updated = entries
        updated[index].reference = reference
        return replace(updated)
    }

    @discardableResult
    func setCustomTitle(id: UUID, title: String?) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = entries
        updated[index].customTitle = trimmed?.isEmpty == false ? trimmed : nil
        return replace(updated)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        var updated = entries
        let oldCount = updated.count
        updated.removeAll { $0.id == id }
        return oldCount != updated.count && replace(updated)
    }

    @discardableResult
    func move(fromOffsets: IndexSet, toOffset: Int) -> Bool {
        guard fromOffsets.allSatisfy(entries.indices.contains),
              (0 ... entries.count).contains(toOffset) else {
            return false
        }
        var updated = entries
        updated.move(fromOffsets: fromOffsets, toOffset: toOffset)
        return replace(updated)
    }

    @discardableResult
    func reset(to references: [ActionReference]) -> Bool {
        var seen = Set<ActionReference>()
        let entries = references.prefix(Self.maximumEntryCount).compactMap { reference -> ActionGridEntry? in
            guard seen.insert(reference).inserted else { return nil }
            return ActionGridEntry(reference: reference)
        }
        return replace(entries)
    }

    @discardableResult
    func migrate(using context: ActionGridHostContext) -> Bool {
        var updated = entries
        var changed = false
        for index in updated.indices {
            guard let migrated = context.migrate(updated[index].reference),
                  migrated != updated[index].reference else {
                continue
            }
            updated[index].reference = migrated
            changed = true
        }
        return changed && replace(updated)
    }

    func portableBackup() -> Data? {
        guard validate(entries) else { return nil }
        return try? encoder.encode(
            Envelope(formatVersion: Self.currentFormatVersion, entries: entries)
        )
    }

    @discardableResult
    func restorePortableBackup(_ data: Data) -> Bool {
        guard data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.formatVersion == Self.currentFormatVersion,
              validate(envelope.entries) else {
            return false
        }
        return replace(envelope.entries)
    }

    @discardableResult
    private func replace(_ entries: [ActionGridEntry]) -> Bool {
        guard validate(entries),
              let data = try? encoder.encode(
                Envelope(formatVersion: Self.currentFormatVersion, entries: entries)
              ),
              data.count <= Self.maximumPayloadByteCount else {
            return false
        }
        storage.set(data, forKey: Self.storageKey)
        guard storage.data(forKey: Self.storageKey) == data else { return false }
        self.entries = entries
        loadError = nil
        return true
    }

    private func reload() {
        guard let data = storage.data(forKey: Self.storageKey) else {
            entries = []
            loadError = nil
            return
        }
        guard data.count <= Self.maximumPayloadByteCount,
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.formatVersion == Self.currentFormatVersion,
              validate(envelope.entries) else {
            entries = []
            loadError = "invalid-grid-layout"
            return
        }
        entries = envelope.entries
        loadError = nil
    }

    private func validate(_ entries: [ActionGridEntry]) -> Bool {
        entries.count <= Self.maximumEntryCount
            && Set(entries.map(\.id)).count == entries.count
            && Set(entries.map(\.reference)).count == entries.count
            && entries.allSatisfy {
                ($0.customTitle?.utf8.count ?? 0) <= ActionGridEntry.maximumCustomTitleByteCount
            }
    }
}

private extension Array {
    mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.sorted().map { self[$0] }
        for index in offsets.sorted(by: >) {
            remove(at: index)
        }
        let removedBeforeDestination = offsets.filter { $0 < destination }.count
        insert(contentsOf: moving, at: destination - removedBeforeDestination)
    }
}
