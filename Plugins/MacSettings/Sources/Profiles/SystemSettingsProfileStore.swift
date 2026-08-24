import Foundation
import MacToolsPluginKit

@MainActor
protocol SystemSettingsProfileStoring: AnyObject {
    func load() -> [SystemSettingsProfile]
    @discardableResult
    func save(_ profile: SystemSettingsProfile) -> Bool
    @discardableResult
    func remove(id: UUID) -> Bool
}

@MainActor
final class SystemSettingsProfileStore: SystemSettingsProfileStoring {
    private enum Key {
        static let profiles = "settings-profiles-v1"
    }

    private let storage: any PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: any PluginStorage) {
        self.storage = storage
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [SystemSettingsProfile] {
        guard let data = storage.data(forKey: Key.profiles),
              data.count <= SystemSettingsProfileCodec.maximumFileSize,
              let profiles = try? decoder.decode([SystemSettingsProfile].self, from: data) else {
            return []
        }
        return profiles
            .filter { $0.formatVersion == SystemSettingsProfile.currentFormatVersion }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    @discardableResult
    func save(_ profile: SystemSettingsProfile) -> Bool {
        var profiles = load()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.modifiedAt > $1.modifiedAt }
        guard profiles.count <= 100,
              let data = try? encoder.encode(profiles),
              data.count <= SystemSettingsProfileCodec.maximumFileSize else {
            return false
        }
        storage.set(data, forKey: Key.profiles)
        return storage.data(forKey: Key.profiles) == data
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        let updated = load().filter { $0.id != id }
        guard let data = try? encoder.encode(updated) else { return false }
        storage.set(data, forKey: Key.profiles)
        return storage.data(forKey: Key.profiles) == data
    }
}

@MainActor
final class InMemorySystemSettingsProfileStore: SystemSettingsProfileStoring {
    private(set) var profiles: [SystemSettingsProfile]

    init(profiles: [SystemSettingsProfile] = []) {
        self.profiles = profiles
    }

    func load() -> [SystemSettingsProfile] {
        profiles.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func save(_ profile: SystemSettingsProfile) -> Bool {
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        return true
    }

    func remove(id: UUID) -> Bool {
        profiles.removeAll { $0.id == id }
        return true
    }
}
