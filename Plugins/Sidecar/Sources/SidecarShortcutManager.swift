import Carbon
import Foundation
import MacToolsPluginKit

@MainActor
protocol SidecarShortcutManaging: AnyObject {
    var onTrigger: ((String) -> Void)? { get set }

    func sync(bindings: [String: ShortcutBinding])
    func temporarilyDisable(id: String)
    func unregisterAll()
}

/// Registers the Sidecar settings shortcuts directly so each saved device can own one durable
/// binding, even while it is temporarily unavailable and absent from the host shortcut catalog.
@MainActor
final class SidecarShortcutManager: SidecarShortcutManaging {
    private struct RegisteredHotKey {
        let id: String
        let binding: ShortcutBinding
        let reference: EventHotKeyRef
        let carbonID: UInt32
    }

    // "SCKR" keeps this plugin's Carbon IDs distinct from the host and other plugins.
    private static let signature: OSType = 0x5343_4B52

    var onTrigger: ((String) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var registeredHotKeys: [String: RegisteredHotKey] = [:]
    private var idsByCarbon: [UInt32: String] = [:]
    private var nextCarbonID: UInt32 = 1

    init() {
        installHandler()
    }

    func sync(bindings: [String: ShortcutBinding]) {
        for id in registeredHotKeys.keys where bindings[id] == nil {
            unregister(id: id)
        }

        for (id, binding) in bindings {
            if let existing = registeredHotKeys[id], existing.binding == binding { continue }
            unregister(id: id)
            register(id: id, binding: binding)
        }
    }

    func temporarilyDisable(id: String) {
        unregister(id: id)
    }

    func unregisterAll() {
        for id in Array(registeredHotKeys.keys) {
            unregister(id: id)
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.hotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )
    }

    private func register(id: String, binding: ShortcutBinding) {
        var reference: EventHotKeyRef?
        let carbonID = nextCarbonID
        nextCarbonID += 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: carbonID)
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.modifiers.carbonFlags,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return }

        registeredHotKeys[id] = RegisteredHotKey(
            id: id,
            binding: binding,
            reference: reference,
            carbonID: carbonID
        )
        idsByCarbon[carbonID] = id
    }

    private func unregister(id: String) {
        guard let registered = registeredHotKeys.removeValue(forKey: id) else { return }
        idsByCarbon.removeValue(forKey: registered.carbonID)
        UnregisterEventHotKey(registered.reference)
    }

    private func dispatch(carbonID: UInt32) {
        guard let id = idsByCarbon[carbonID] else { return }
        onTrigger?(id)
    }

    private nonisolated static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID(signature: 0, id: 0)
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == 0x5343_4B52 else { return status }

        let manager = Unmanaged<SidecarShortcutManager>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in
            manager.dispatch(carbonID: hotKeyID.id)
        }
        return noErr
    }
}
