import CoreGraphics
import Foundation

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
    default:
        throw NSError(
            domain: "MacToolsE2EKeySender",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Usage: MacToolsE2EKeySender.swift <check|describe|send> [open-settings|action-grid|dashboard|safe-workflow]"]
        )
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    Foundation.exit(1)
}
