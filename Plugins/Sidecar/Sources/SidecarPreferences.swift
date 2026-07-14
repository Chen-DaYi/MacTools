import Foundation
import MacToolsPluginKit

enum SidecarConnectionTransport: String, Codable, CaseIterable {
    case automatic
    case wiredOnly
}

enum SidecarShortcutAction: String, Codable, CaseIterable {
    case toggle
    case connect
    case disconnect
}

struct SidecarDevicePreference: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var transport: SidecarConnectionTransport
    var shortcutAction: SidecarShortcutAction
    var shortcut: ShortcutBinding?

    init(
        id: String,
        name: String,
        transport: SidecarConnectionTransport = .automatic,
        shortcutAction: SidecarShortcutAction = .toggle,
        shortcut: ShortcutBinding? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.shortcutAction = shortcutAction
        self.shortcut = shortcut
    }

    var hasCustomConfiguration: Bool {
        transport != .automatic || shortcutAction != .toggle || shortcut != nil
    }
}

@MainActor
final class SidecarPreferencesStore: ObservableObject {
    private enum StorageKey {
        static let devices = "savedDevices"
        static let disconnectAllShortcut = "disconnectAllShortcut"
        static let connectFirstAvailableShortcut = "connectFirstAvailableShortcut"
    }

    private struct PortablePreferences: Codable {
        let devices: [SidecarDevicePreference]
        let disconnectAllShortcut: ShortcutBinding?
        let connectFirstAvailableShortcut: ShortcutBinding?
    }

    @Published private(set) var devices: [SidecarDevicePreference]
    @Published private(set) var disconnectAllShortcut: ShortcutBinding?
    @Published private(set) var connectFirstAvailableShortcut: ShortcutBinding?

    private let storage: PluginStorage
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storage: PluginStorage) {
        self.storage = storage
        if let data = storage.data(forKey: StorageKey.devices),
           let savedDevices = try? decoder.decode([SidecarDevicePreference].self, from: data) {
            devices = savedDevices
        } else {
            devices = []
        }

        if let data = storage.data(forKey: StorageKey.disconnectAllShortcut),
           let binding = try? decoder.decode(ShortcutBinding.self, from: data) {
            disconnectAllShortcut = binding
        } else {
            disconnectAllShortcut = nil
        }

        if let data = storage.data(forKey: StorageKey.connectFirstAvailableShortcut),
           let binding = try? decoder.decode(ShortcutBinding.self, from: data) {
            connectFirstAvailableShortcut = binding
        } else {
            connectFirstAvailableShortcut = nil
        }
    }

    func reconcile(with reachableDevices: [SidecarDevice]) {
        var updated = devices
        var didChange = false

        for device in reachableDevices {
            if let index = updated.firstIndex(where: { $0.id == device.id }) {
                guard updated[index].name != device.name else { continue }
                updated[index].name = device.name
                didChange = true
            } else {
                updated.append(SidecarDevicePreference(id: device.id, name: device.name))
                didChange = true
            }
        }

        guard didChange else { return }
        devices = updated
        persistDevices()
    }

    func preference(for deviceID: String) -> SidecarDevicePreference? {
        devices.first(where: { $0.id == deviceID })
    }

    func updateTransport(_ transport: SidecarConnectionTransport, for deviceID: String) {
        update(deviceID: deviceID) { $0.transport = transport }
    }

    func updateShortcutAction(_ action: SidecarShortcutAction, for deviceID: String) {
        update(deviceID: deviceID) { $0.shortcutAction = action }
    }

    func updateShortcut(_ shortcut: ShortcutBinding?, for deviceID: String) {
        update(deviceID: deviceID) { $0.shortcut = shortcut }
    }

    func updateDisconnectAllShortcut(_ shortcut: ShortcutBinding?) {
        guard disconnectAllShortcut != shortcut else { return }
        disconnectAllShortcut = shortcut
        if let shortcut, let data = try? encoder.encode(shortcut) {
            storage.set(data, forKey: StorageKey.disconnectAllShortcut)
        } else {
            storage.removeObject(forKey: StorageKey.disconnectAllShortcut)
        }
    }

    func updateConnectFirstAvailableShortcut(_ shortcut: ShortcutBinding?) {
        guard connectFirstAvailableShortcut != shortcut else { return }
        connectFirstAvailableShortcut = shortcut
        persistShortcut(shortcut, forKey: StorageKey.connectFirstAvailableShortcut)
    }

    func move(deviceID: String, before beforeDeviceID: String?) {
        guard let sourceIndex = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        var updated = devices
        let device = updated.remove(at: sourceIndex)
        let destinationIndex = beforeDeviceID.flatMap { targetID in
            updated.firstIndex(where: { $0.id == targetID })
        } ?? updated.endIndex
        updated.insert(device, at: destinationIndex)
        guard updated != devices else { return }
        devices = updated
        persistDevices()
    }

    func priorityIndex(for deviceID: String) -> Int {
        devices.firstIndex(where: { $0.id == deviceID }) ?? .max
    }

    func portablePreferencesData() -> Data? {
        try? encoder.encode(PortablePreferences(
            devices: devices,
            disconnectAllShortcut: disconnectAllShortcut,
            connectFirstAvailableShortcut: connectFirstAvailableShortcut
        ))
    }

    func restorePortablePreferences(from data: Data) {
        guard let portablePreferences = try? decoder.decode(PortablePreferences.self, from: data) else {
            return
        }
        devices = uniqueDevices(portablePreferences.devices)
        disconnectAllShortcut = portablePreferences.disconnectAllShortcut
        connectFirstAvailableShortcut = portablePreferences.connectFirstAvailableShortcut
        persistDevices()
        persistShortcut(disconnectAllShortcut, forKey: StorageKey.disconnectAllShortcut)
        persistShortcut(connectFirstAvailableShortcut, forKey: StorageKey.connectFirstAvailableShortcut)
    }

    private func update(deviceID: String, _ change: (inout SidecarDevicePreference) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        var updated = devices[index]
        change(&updated)
        guard updated != devices[index] else { return }
        devices[index] = updated
        persistDevices()
    }

    private func persistDevices() {
        guard let data = try? encoder.encode(devices) else { return }
        storage.set(data, forKey: StorageKey.devices)
    }

    private func persistShortcut(_ shortcut: ShortcutBinding?, forKey key: String) {
        if let shortcut, let data = try? encoder.encode(shortcut) {
            storage.set(data, forKey: key)
        } else {
            storage.removeObject(forKey: key)
        }
    }

    private func uniqueDevices(_ candidates: [SidecarDevicePreference]) -> [SidecarDevicePreference] {
        var seenIDs = Set<String>()
        return candidates.filter { seenIDs.insert($0.id).inserted }
    }
}
