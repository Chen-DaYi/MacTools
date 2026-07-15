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
    /// A legacy default binding. New bindings are stored and validated by the host shortcut store.
    var shortcut: ShortcutBinding?
    var hasShortcutConfiguration: Bool

    init(
        id: String,
        name: String,
        transport: SidecarConnectionTransport = .automatic,
        shortcutAction: SidecarShortcutAction = .toggle,
        shortcut: ShortcutBinding? = nil,
        hasShortcutConfiguration: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.shortcutAction = shortcutAction
        self.shortcut = shortcut
        self.hasShortcutConfiguration = hasShortcutConfiguration ?? (shortcut != nil)
    }

    var hasCustomConfiguration: Bool {
        transport != .automatic || shortcutAction != .toggle || shortcut != nil || hasShortcutConfiguration
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case transport
        case shortcutAction
        case shortcut
        case hasShortcutConfiguration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        transport = try container.decode(SidecarConnectionTransport.self, forKey: .transport)
        shortcutAction = try container.decode(SidecarShortcutAction.self, forKey: .shortcutAction)
        shortcut = try container.decodeIfPresent(ShortcutBinding.self, forKey: .shortcut)
        hasShortcutConfiguration = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasShortcutConfiguration
        ) ?? (shortcut != nil)
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
        let storedDevices: [SidecarDevicePreference]
        if let data = storage.data(forKey: StorageKey.devices),
           let savedDevices = try? decoder.decode([SidecarDevicePreference].self, from: data) {
            storedDevices = savedDevices
        } else {
            storedDevices = []
        }

        let storedDisconnectAllShortcut: ShortcutBinding?
        if let data = storage.data(forKey: StorageKey.disconnectAllShortcut),
           let binding = try? decoder.decode(ShortcutBinding.self, from: data) {
            storedDisconnectAllShortcut = binding
        } else {
            storedDisconnectAllShortcut = nil
        }

        let storedConnectFirstAvailableShortcut: ShortcutBinding?
        if let data = storage.data(forKey: StorageKey.connectFirstAvailableShortcut),
           let binding = try? decoder.decode(ShortcutBinding.self, from: data) {
            storedConnectFirstAvailableShortcut = binding
        } else {
            storedConnectFirstAvailableShortcut = nil
        }

        let normalized = Self.normalizedShortcuts(
            devices: storedDevices,
            disconnectAllShortcut: storedDisconnectAllShortcut,
            connectFirstAvailableShortcut: storedConnectFirstAvailableShortcut
        )
        devices = normalized.devices
        disconnectAllShortcut = normalized.disconnectAllShortcut
        connectFirstAvailableShortcut = normalized.connectFirstAvailableShortcut

        if normalized.devices != storedDevices
            || normalized.disconnectAllShortcut != storedDisconnectAllShortcut
            || normalized.connectFirstAvailableShortcut != storedConnectFirstAvailableShortcut {
            persistDevices()
            persistShortcut(disconnectAllShortcut, forKey: StorageKey.disconnectAllShortcut)
            persistShortcut(connectFirstAvailableShortcut, forKey: StorageKey.connectFirstAvailableShortcut)
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
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        guard devices[index].shortcut != shortcut
            || devices[index].hasShortcutConfiguration != (shortcut != nil)
        else {
            return
        }
        devices[index].shortcut = shortcut
        devices[index].hasShortcutConfiguration = shortcut != nil
        normalizeAndPersistShortcuts(persistWhenUnchanged: true)
    }

    func updateShortcutConfiguration(_ hasConfiguration: Bool, for deviceID: String) {
        update(deviceID: deviceID) { $0.hasShortcutConfiguration = hasConfiguration }
    }

    func updateDisconnectAllShortcut(_ shortcut: ShortcutBinding?) {
        guard disconnectAllShortcut != shortcut else { return }
        disconnectAllShortcut = shortcut
        normalizeAndPersistShortcuts(persistWhenUnchanged: true)
    }

    func updateConnectFirstAvailableShortcut(_ shortcut: ShortcutBinding?) {
        guard connectFirstAvailableShortcut != shortcut else { return }
        connectFirstAvailableShortcut = shortcut
        normalizeAndPersistShortcuts(persistWhenUnchanged: true)
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
        let normalized = Self.normalizedShortcuts(
            devices: portablePreferences.devices,
            disconnectAllShortcut: portablePreferences.disconnectAllShortcut,
            connectFirstAvailableShortcut: portablePreferences.connectFirstAvailableShortcut
        )
        devices = normalized.devices
        disconnectAllShortcut = normalized.disconnectAllShortcut
        connectFirstAvailableShortcut = normalized.connectFirstAvailableShortcut
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

    private func normalizeAndPersistShortcuts(persistWhenUnchanged: Bool = false) {
        let normalized = Self.normalizedShortcuts(
            devices: devices,
            disconnectAllShortcut: disconnectAllShortcut,
            connectFirstAvailableShortcut: connectFirstAvailableShortcut
        )
        let didChange = normalized.devices != devices
            || normalized.disconnectAllShortcut != disconnectAllShortcut
            || normalized.connectFirstAvailableShortcut != connectFirstAvailableShortcut
        guard didChange || persistWhenUnchanged else {
            return
        }
        devices = normalized.devices
        disconnectAllShortcut = normalized.disconnectAllShortcut
        connectFirstAvailableShortcut = normalized.connectFirstAvailableShortcut
        persistDevices()
        persistShortcut(disconnectAllShortcut, forKey: StorageKey.disconnectAllShortcut)
        persistShortcut(connectFirstAvailableShortcut, forKey: StorageKey.connectFirstAvailableShortcut)
    }

    private static func normalizedShortcuts(
        devices candidates: [SidecarDevicePreference],
        disconnectAllShortcut: ShortcutBinding?,
        connectFirstAvailableShortcut: ShortcutBinding?
    ) -> (
        devices: [SidecarDevicePreference],
        disconnectAllShortcut: ShortcutBinding?,
        connectFirstAvailableShortcut: ShortcutBinding?
    ) {
        var usedBindings = Set<ShortcutBinding>()
        func uniqueBinding(_ binding: ShortcutBinding?) -> ShortcutBinding? {
            guard let binding, binding.isValid, usedBindings.insert(binding).inserted else {
                return nil
            }
            return binding
        }

        let normalizedConnectFirstAvailableShortcut = uniqueBinding(connectFirstAvailableShortcut)
        let normalizedDisconnectAllShortcut = uniqueBinding(disconnectAllShortcut)
        var normalizedDevices = uniqueDevices(candidates)
        for index in normalizedDevices.indices {
            normalizedDevices[index].shortcut = uniqueBinding(normalizedDevices[index].shortcut)
        }
        return (
            normalizedDevices,
            normalizedDisconnectAllShortcut,
            normalizedConnectFirstAvailableShortcut
        )
    }

    private static func uniqueDevices(_ candidates: [SidecarDevicePreference]) -> [SidecarDevicePreference] {
        var seenIDs = Set<String>()
        return candidates.filter { seenIDs.insert($0.id).inserted }
    }
}
