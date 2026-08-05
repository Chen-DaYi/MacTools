import Foundation

struct KeepAwakeCapabilities: Equatable {
    var preventDisplaySleep: Bool
    var preventAutomaticScreenLock: Bool
    var continueWithLidClosed: Bool
    var keepScreenBasedToolsWorking: Bool
}

enum KeepAwakeBehavior: String, CaseIterable, Equatable {
    case allowDisplayToTurnOff = "allow-display-to-turn-off"
    case keepDisplayOn = "keep-display-on"
    case keepScreenBasedToolsWorking = "keep-screen-based-tools-working"
}

struct KeepAwakePreferences: Equatable {
    var behavior: KeepAwakeBehavior

    static let defaults = KeepAwakePreferences(
        behavior: .allowDisplayToTurnOff
    )

    var capabilities: KeepAwakeCapabilities {
        switch behavior {
        case .allowDisplayToTurnOff:
            KeepAwakeCapabilities(
                preventDisplaySleep: false,
                preventAutomaticScreenLock: false,
                continueWithLidClosed: false,
                keepScreenBasedToolsWorking: false
            )
        case .keepDisplayOn:
            KeepAwakeCapabilities(
                preventDisplaySleep: true,
                preventAutomaticScreenLock: false,
                continueWithLidClosed: false,
                keepScreenBasedToolsWorking: false
            )
        case .keepScreenBasedToolsWorking:
            KeepAwakeCapabilities(
                preventDisplaySleep: true,
                preventAutomaticScreenLock: true,
                continueWithLidClosed: true,
                keepScreenBasedToolsWorking: true
            )
        }
    }
}
