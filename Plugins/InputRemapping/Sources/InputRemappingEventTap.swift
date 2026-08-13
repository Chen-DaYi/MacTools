import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hidsystem
import MacToolsPluginKit
import OSLog

protocol InputRemappingEventTapping: AnyObject {
    func update(rules: [InputRemappingRule])
    func start() -> Bool
    func stop()
}

enum InputRemappingSystemDefinedEvent {
    static let auxiliaryControlButtonSubtype: Int16 = 8
    static let keyDownState: Int32 = 0xA00
    static let keyUpState: Int32 = 0xB00

    static func data1(keyType: Int32, state: Int32) -> Int {
        Int((keyType << 16) | state)
    }
}

final class InputRemappingEventTap: InputRemappingEventTapping {
    private static let syntheticMarker: Int64 = 0x4D_54_49_52

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "InputRemappingEventTap"
    )
    private let rulesLock = NSLock()

    private var currentRules: [InputRemappingRule] = []
    private var eventProcessor = InputRemappingEventProcessor()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func update(rules: [InputRemappingRule]) {
        rulesLock.lock()
        currentRules = rules
        rulesLock.unlock()
    }

    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            logger.error("Failed to create input remapping event tap")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        eventProcessor.reset()
        guard let tap else { return }

        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        return Unmanaged<InputRemappingEventTap>
            .fromOpaque(info)
            .takeUnretainedValue()
            .handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let phase: InputRemappingMouseEventPhase
        switch type {
        case .otherMouseDown:
            phase = .down
        case .otherMouseUp:
            phase = .up
        default:
            return Unmanaged.passUnretained(event)
        }

        rulesLock.lock()
        let rules = currentRules
        rulesLock.unlock()

        let shouldConsume = eventProcessor.shouldConsume(
            phase: phase,
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            flags: event.flags,
            isMarkedSynthetic:
                event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker,
            rules: rules,
            execute: execute
        )
        return shouldConsume ? nil : Unmanaged.passUnretained(event)
    }

    private func execute(_ action: InputRemappingRule.Action) -> Bool {
        switch action {
        case let .shortcut(binding):
            post(keyCode: binding.keyCode, modifiers: binding.modifiers)
        case .mouseBack:
            postMouse(button: 3)
        case .mouseForward:
            postMouse(button: 4)
        case .mouseMiddle:
            postMouse(button: 2)
        case .missionControl:
            post(keyCode: UInt16(kVK_UpArrow), modifiers: [.control])
        case .spaceLeft:
            post(keyCode: UInt16(kVK_LeftArrow), modifiers: [.control])
        case .spaceRight:
            post(keyCode: UInt16(kVK_RightArrow), modifiers: [.control])
        case .mediaPlayPause:
            postSystemKey(NX_KEYTYPE_PLAY)
        case .volumeDown:
            postSystemKey(NX_KEYTYPE_SOUND_DOWN)
        case .volumeUp:
            postSystemKey(NX_KEYTYPE_SOUND_UP)
        }
    }

    private func postMouse(button: Int64) -> Bool {
        guard let cursorEvent = CGEvent(source: nil),
              let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseDown,
                mouseCursorPosition: cursorEvent.location,
                mouseButton: .center
              ),
              let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseUp,
                mouseCursorPosition: cursorEvent.location,
                mouseButton: .center
              )
        else {
            logger.error("Failed to create remapped mouse events")
            return false
        }

        for event in [down, up] {
            event.setIntegerValueField(.mouseEventButtonNumber, value: button)
            postSynthetic(event)
        }
        return true
    }

    private func post(keyCode: UInt16, modifiers: ShortcutModifiers) -> Bool {
        guard let down = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: false
        ) else {
            logger.error("Failed to create remapped keyboard events")
            return false
        }

        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }

        for event in [down, up] {
            event.flags = flags
            postSynthetic(event)
        }
        return true
    }

    private func postSystemKey(_ keyType: Int32) -> Bool {
        guard let down = makeSystemKeyEvent(
            keyType: keyType,
            state: InputRemappingSystemDefinedEvent.keyDownState
        ), let up = makeSystemKeyEvent(
            keyType: keyType,
            state: InputRemappingSystemDefinedEvent.keyUpState
        )
        else {
            logger.error("Failed to create remapped system key events")
            return false
        }

        postSynthetic(down)
        postSynthetic(up)
        return true
    }

    private func makeSystemKeyEvent(keyType: Int32, state: Int32) -> CGEvent? {
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: InputRemappingSystemDefinedEvent.auxiliaryControlButtonSubtype,
            data1: InputRemappingSystemDefinedEvent.data1(keyType: keyType, state: state),
            data2: -1
        )?.cgEvent
    }

    private func postSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}
