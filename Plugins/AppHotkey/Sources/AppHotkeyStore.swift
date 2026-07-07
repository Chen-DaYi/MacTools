import Foundation
import MacToolsPluginKit

@MainActor
final class AppHotkeyStore: ObservableObject {
    private enum Keys {
        static let entries = "entries"
    }

    @Published private(set) var entries: [AppShortcutEntry]

    private let storage: PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: PluginStorage) {
        self.storage = storage
        if let data = storage.data(forKey: Keys.entries),
           let loaded = try? JSONDecoder().decode([AppShortcutEntry].self, from: data) {
            self.entries = loaded
        } else {
            self.entries = []
        }
    }

    func addEntry(_ entry: AppShortcutEntry) {
        entries.append(entry)
        persist()
    }

    func updateShortcut(id: UUID, shortcut: ShortcutBinding?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].shortcut = shortcut
        persist()
    }

    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    /// Returns the existing entry that conflicts with the shortcut, excluding the current entry.
    func conflictEntry(for shortcut: ShortcutBinding, excludingID: UUID? = nil) -> AppShortcutEntry? {
        entries.first { $0.id != excludingID && $0.shortcut == shortcut }
    }

    private func persist() {
        guard let data = try? encoder.encode(entries) else { return }
        storage.set(data, forKey: Keys.entries)
    }
}
