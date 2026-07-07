import Carbon
import Foundation
import MacToolsPluginKit

/// Manages Carbon Event hotkey registration alongside `GlobalShortcutManager`.
/// Uses a dedicated OSType signature ("AHKY") to avoid Carbon ID collisions.
@MainActor
final class AppHotkeyManager {
    private struct RegisteredHotKey {
        let entryID: UUID
        let binding: ShortcutBinding
        let reference: EventHotKeyRef
        let carbonID: UInt32
    }

    // "AHKY" = 0x4148_4B59
    private static let signature: OSType = 0x4148_4B59

    var onTrigger: ((UUID) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var registeredHotKeys: [UUID: RegisteredHotKey] = [:]
    private var idsByCarbon: [UInt32: UUID] = [:]
    private var nextCarbonID: UInt32 = 1

    init() {
        installHandler()
    }

    /// Resynchronizes registered hotkeys from the current entries using an incremental diff.
    func sync(entries: [AppShortcutEntry]) {
        let desired = Dictionary(
            uniqueKeysWithValues: entries.compactMap { e -> (UUID, ShortcutBinding)? in
                guard let s = e.shortcut else { return nil }
                return (e.id, s)
            }
        )

        for id in registeredHotKeys.keys where desired[id] == nil {
            unregister(id: id)
        }

        for (id, binding) in desired {
            if let existing = registeredHotKeys[id], existing.binding == binding { continue }
            unregister(id: id)
            register(id: id, binding: binding)
        }
    }

    func unregisterAll() {
        for id in Array(registeredHotKeys.keys) { unregister(id: id) }
    }

    /// Temporarily unregisters an entry while recording; callers restore it by invoking `sync`.
    func temporarilyDisable(id: UUID) {
        unregister(id: id)
    }

    // MARK: Private

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Match the host global-shortcut path by using the event dispatcher target, avoiding
        // routing differences between Carbon targets. The handler still filters AppHotkey events
        // through the dedicated signature.
        InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.hotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &handlerRef
        )
    }

    private func register(id: UUID, binding: ShortcutBinding) {
        var ref: EventHotKeyRef?
        let cid = nextCarbonID
        nextCarbonID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: cid)
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.modifiers.carbonFlags,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return }

        registeredHotKeys[id] = RegisteredHotKey(
            entryID: id, binding: binding, reference: ref, carbonID: cid
        )
        idsByCarbon[cid] = id
    }

    private func unregister(id: UUID) {
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
        guard status == noErr else { return status }

        guard hotKeyID.signature == 0x4148_4B59 else {
            return OSStatus(eventNotHandledErr)
        }

        let manager = Unmanaged<AppHotkeyManager>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in
            manager.dispatch(carbonID: hotKeyID.id)
        }
        return noErr
    }
}
