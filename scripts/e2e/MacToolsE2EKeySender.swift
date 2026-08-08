import ApplicationServices
import CoreGraphics
import Foundation

private struct WindowBounds {
    let origin: CGPoint
    let size: CGSize
}

private func attribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func point(from value: CFTypeRef?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
}

private func size(from value: CFTypeRef?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
}

private func focusedWindowBounds(processIdentifier: pid_t) -> WindowBounds? {
    let application = AXUIElementCreateApplication(processIdentifier)
    guard let window = attribute(kAXFocusedWindowAttribute, from: application),
          CFGetTypeID(window) == AXUIElementGetTypeID() else {
        return nil
    }
    let element = unsafeBitCast(window, to: AXUIElement.self)
    guard let origin = point(from: attribute(kAXPositionAttribute, from: element)),
          let size = size(from: attribute(kAXSizeAttribute, from: element)),
          size.width >= 1,
          size.height >= 1 else {
        return nil
    }
    return WindowBounds(origin: origin, size: size)
}

private func postLeftClick(at target: CGPoint) throws {
    guard let move = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: target,
        mouseButton: .left
    ), let down = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseDown,
        mouseCursorPosition: target,
        mouseButton: .left
    ), let up = CGEvent(
        mouseEventSource: nil,
        mouseType: .leftMouseUp,
        mouseCursorPosition: target,
        mouseButton: .left
    ) else {
        throw NSError(
            domain: "MacToolsE2EKeySender",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Could not create pointer events."]
        )
    }

    move.flags = []
    down.flags = []
    up.flags = []
    move.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.12)
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.08)
    up.post(tap: .cghidEventTap)
}

private enum ShortcutName: String {
    case openSettings = "open-settings"
    case actionGrid = "action-grid"
    case dashboard = "dashboard"
    case safeWorkflow = "safe-workflow"

    var keyCode: CGKeyCode {
        switch self {
        case .openSettings: 20
        case .actionGrid: 21
        case .dashboard: 23
        case .safeWorkflow: 22
        }
    }
}

private enum InputKey: String {
    case commandK = "command-k"
    case returnKey = "return"
    case escape

    var keyCode: CGKeyCode {
        switch self {
        case .commandK: 40
        case .returnKey: 36
        case .escape: 53
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .commandK: .maskCommand
        case .returnKey, .escape: []
        }
    }
}

private func writeJSON(_ payload: [String: Any]) throws {
    let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
    )
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func shortcut(named value: String?) -> ShortcutName? {
    value.flatMap(ShortcutName.init(rawValue:))
}

private func describe(_ shortcut: ShortcutName) throws {
    try writeJSON([
        "keyCode": Int(shortcut.keyCode),
        "modifiers": ["control", "command"],
        "name": shortcut.rawValue,
    ])
}

private func send(_ shortcut: ShortcutName) throws {
    guard CGPreflightPostEventAccess() else {
        FileHandle.standardError.write(Data(
            "Synthetic event posting is not authorized. Grant Accessibility to the process hosting this test, then retry.\n".utf8
        ))
        Foundation.exit(2)
    }
    guard let keyDown = CGEvent(
        keyboardEventSource: nil,
        virtualKey: shortcut.keyCode,
        keyDown: true
    ), let keyUp = CGEvent(
        keyboardEventSource: nil,
        virtualKey: shortcut.keyCode,
        keyDown: false
    ) else {
        throw NSError(
            domain: "MacToolsE2EKeySender",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not create keyboard events."]
        )
    }

    let flags: CGEventFlags = [.maskControl, .maskCommand]
    keyDown.flags = flags
    keyUp.flags = flags
    keyDown.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
    keyUp.post(tap: .cghidEventTap)
    try writeJSON([
        "keyCode": Int(shortcut.keyCode),
        "modifiers": ["control", "command"],
        "name": shortcut.rawValue,
        "sent": true,
    ])
}

private func requireEventPostingAccess() {
    guard CGPreflightPostEventAccess() else {
        FileHandle.standardError.write(Data(
            "Synthetic event posting is not authorized. Grant Accessibility to the process hosting this test, then retry.\n".utf8
        ))
        Foundation.exit(2)
    }
}

private func pressInputKey(_ inputKey: InputKey) throws {
    requireEventPostingAccess()
    guard let keyDown = CGEvent(
        keyboardEventSource: nil,
        virtualKey: inputKey.keyCode,
        keyDown: true
    ), let keyUp = CGEvent(
        keyboardEventSource: nil,
        virtualKey: inputKey.keyCode,
        keyDown: false
    ) else {
        throw NSError(
            domain: "MacToolsE2EKeySender",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "Could not create input key events."]
        )
    }
    keyDown.flags = inputKey.flags
    keyUp.flags = inputKey.flags
    keyDown.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.04)
    keyUp.post(tap: .cghidEventTap)
    try writeJSON(["key": inputKey.rawValue, "pressed": true])
}

private func selectAll() throws {
    requireEventPostingAccess()
    guard let keyDown = CGEvent(
        keyboardEventSource: nil,
        virtualKey: 0,
        keyDown: true
    ), let keyUp = CGEvent(
        keyboardEventSource: nil,
        virtualKey: 0,
        keyDown: false
    ) else {
        throw NSError(
            domain: "MacToolsE2EKeySender",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Could not create Select All events."]
        )
    }
    keyDown.flags = .maskCommand
    keyUp.flags = []
    keyDown.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.04)
    keyUp.post(tap: .cghidEventTap)
    try writeJSON(["selectedAll": true])
}

private func typeText(_ text: String) throws {
    requireEventPostingAccess()
    let codeUnits = Array(text.utf16)
    for offset in stride(from: 0, to: codeUnits.count, by: 20) {
        let end = min(offset + 20, codeUnits.count)
        let chunk = Array(codeUnits[offset..<end])
        guard let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: false
        ) else {
            throw NSError(
                domain: "MacToolsE2EKeySender",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Could not create text input events."]
            )
        }
        keyDown.flags = []
        keyUp.flags = []
        chunk.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
            keyUp.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: baseAddress
            )
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.01)
    }
    try writeJSON(["characters": codeUnits.count, "typed": true])
}

private func clickRelative(arguments: ArraySlice<String>) throws {
    guard arguments.count == 5,
          let processIdentifier = pid_t(arguments[arguments.startIndex]),
          let referenceWidth = Double(arguments[arguments.index(arguments.startIndex, offsetBy: 1)]),
          let referenceHeight = Double(arguments[arguments.index(arguments.startIndex, offsetBy: 2)]),
          let localX = Double(arguments[arguments.index(arguments.startIndex, offsetBy: 3)]),
          let localY = Double(arguments[arguments.index(arguments.startIndex, offsetBy: 4)]),
          referenceWidth > 0,
          referenceHeight > 0,
          localX >= 0,
          localY >= 0,
          localX <= referenceWidth,
          localY <= referenceHeight else {
        throw NSError(
            domain: "MacToolsE2EKeySender",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Expected process ID, reference width/height, and an in-bounds x/y point."]
        )
    }
    guard CGPreflightPostEventAccess() else {
        FileHandle.standardError.write(Data(
            "Synthetic event posting is not authorized. Grant Accessibility to the process hosting this test, then retry.\n".utf8
        ))
        Foundation.exit(2)
    }
    guard let bounds = focusedWindowBounds(processIdentifier: processIdentifier) else {
        throw NSError(
            domain: "MacToolsE2EKeySender",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Could not resolve the focused MacTools window."]
        )
    }

    let target = CGPoint(
        x: bounds.origin.x + CGFloat(localX / referenceWidth) * bounds.size.width,
        y: bounds.origin.y + CGFloat(localY / referenceHeight) * bounds.size.height
    )
    try postLeftClick(at: target)
    try writeJSON([
        "clicked": true,
        "screenX": target.x,
        "screenY": target.y,
    ])
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "check":
        let granted = CGPreflightPostEventAccess()
        try writeJSON(["eventPostingAccess": granted])
        Foundation.exit(granted ? 0 : 2)
    case "describe":
        guard let shortcut = shortcut(named: arguments.dropFirst().first) else {
            throw NSError(
                domain: "MacToolsE2EKeySender",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Expected open-settings, action-grid, dashboard, or safe-workflow."]
            )
        }
        try describe(shortcut)
    case "send":
        guard let shortcut = shortcut(named: arguments.dropFirst().first) else {
            throw NSError(
                domain: "MacToolsE2EKeySender",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Expected open-settings, action-grid, dashboard, or safe-workflow."]
            )
        }
        try send(shortcut)
    case "click-relative":
        try clickRelative(arguments: arguments.dropFirst())
    case "select-all":
        try selectAll()
    case "type-text":
        guard arguments.count == 2 else {
            throw NSError(
                domain: "MacToolsE2EKeySender",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Expected one text argument."]
            )
        }
        try typeText(arguments[1])
    case "press-key":
        guard arguments.count == 2,
              let inputKey = InputKey(rawValue: arguments[1]) else {
            throw NSError(
                domain: "MacToolsE2EKeySender",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Expected command-k, return, or escape."]
            )
        }
        try pressInputKey(inputKey)
    default:
        throw NSError(
            domain: "MacToolsE2EKeySender",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Usage: MacToolsE2EKeySender.swift <check|describe|send|click-relative|select-all|type-text|press-key> [...]"]
        )
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    Foundation.exit(1)
}
