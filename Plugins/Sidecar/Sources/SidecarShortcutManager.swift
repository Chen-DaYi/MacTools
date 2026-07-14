import Carbon
import Foundation
import MacToolsPluginKit
import OSLog

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
    private final class RegisteredHotKey {
        let binding: ShortcutBinding
        let reference: EventHotKeyRef
        let carbonID: UInt32

        init(binding: ShortcutBinding, reference: EventHotKeyRef, carbonID: UInt32) {
            self.binding = binding
            self.reference = reference
            self.carbonID = carbonID
        }

        deinit {
            UnregisterEventHotKey(reference)
        }
    }

    private final class HandlerContext {
        weak var manager: SidecarShortcutManager?

        init(manager: SidecarShortcutManager) {
            self.manager = manager
        }
    }

    private final class HandlerRegistration {
        private let context: HandlerContext
        private let handlerRef: EventHandlerRef?

        init(manager: SidecarShortcutManager) {
            context = HandlerContext(manager: manager)

            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            var installedHandler: EventHandlerRef?
            let status = InstallEventHandler(
                GetEventDispatcherTarget(),
                Self.managerHandler,
                1,
                &eventType,
                UnsafeMutableRawPointer(Unmanaged.passUnretained(context).toOpaque()),
                &installedHandler
            )
            handlerRef = status == noErr ? installedHandler : nil
        }

        deinit {
            if let handlerRef {
                RemoveEventHandler(handlerRef)
            }
        }

        var isInstalled: Bool {
            handlerRef != nil
        }

        private nonisolated static let managerHandler: EventHandlerUPP = SidecarShortcutManager.hotKeyHandler
    }

    // "SCKR" keeps this plugin's Carbon IDs distinct from the host and other plugins.
    private static let signature: OSType = 0x5343_4B52

    var onTrigger: ((String) -> Void)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SidecarShortcutManager"
    )
    private lazy var handlerRegistration = HandlerRegistration(manager: self)
    private var registeredHotKeys: [String: RegisteredHotKey] = [:]
    private var idsByCarbon: [UInt32: String] = [:]
    private var nextCarbonID: UInt32 = 1

    init() {
        _ = handlerRegistration
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

    private func register(id: String, binding: ShortcutBinding) {
        guard binding.isValid, handlerRegistration.isInstalled else { return }
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
        guard status == noErr, let reference else {
            logger.warning("Could not register Sidecar shortcut id=\(id, privacy: .public) status=\(status, privacy: .public)")
            return
        }

        registeredHotKeys[id] = RegisteredHotKey(
            binding: binding,
            reference: reference,
            carbonID: carbonID
        )
        idsByCarbon[carbonID] = id
    }

    private func unregister(id: String) {
        guard let registered = registeredHotKeys.removeValue(forKey: id) else { return }
        idsByCarbon.removeValue(forKey: registered.carbonID)
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

        let context = Unmanaged<HandlerContext>.fromOpaque(userData).takeUnretainedValue()
        guard let manager = context.manager else { return OSStatus(eventNotHandledErr) }
        Task { @MainActor in
            manager.dispatch(carbonID: hotKeyID.id)
        }
        return noErr
    }
}
