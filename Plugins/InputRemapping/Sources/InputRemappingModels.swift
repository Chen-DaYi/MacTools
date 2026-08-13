import Combine
import CoreGraphics
import Foundation
import MacToolsPluginKit
import OSLog

enum InputRemappingRulePolicy {
    static let minimumButtonNumber: Int64 = 0
    static let maximumButtonNumber: Int64 = 32
    static let eligibleButtonNumbers = minimumButtonNumber...maximumButtonNumber
    static let longPressDuration: TimeInterval = 0.45
    static let doubleClickInterval: TimeInterval = 0.35

    static func isEligible(buttonNumber: Int64) -> Bool { eligibleButtonNumbers.contains(buttonNumber) }
    static func normalized(buttonNumber: Int64) -> Int64 {
        min(maximumButtonNumber, max(minimumButtonNumber, buttonNumber))
    }
}

enum InputRemappingMouseInteraction: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case click
    case doubleClick
    case longPress
}

enum InputRemappingScrollDirection: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case up
    case down
    case left
    case right
}

enum InputRemappingTrigger: Codable, Equatable, Hashable, Sendable {
    case keyboard(keyCode: UInt16, modifiers: ShortcutModifiers)
    case mouseButton(number: Int64, modifiers: ShortcutModifiers, interaction: InputRemappingMouseInteraction)
    case scroll(direction: InputRemappingScrollDirection, modifiers: ShortcutModifiers)
    case trackpadGesture(TrackpadGesture)

    private enum CodingKeys: String, CodingKey { case kind, keyCode, number, modifiers, interaction, direction, gesture }
    private enum Kind: String, Codable { case keyboard, mouseButton, scroll, trackpadGesture }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .keyboard:
            self = .keyboard(keyCode: try c.decode(UInt16.self, forKey: .keyCode), modifiers: try c.decode(ShortcutModifiers.self, forKey: .modifiers))
        case .mouseButton:
            self = .mouseButton(number: InputRemappingRulePolicy.normalized(buttonNumber: try c.decode(Int64.self, forKey: .number)), modifiers: try c.decode(ShortcutModifiers.self, forKey: .modifiers), interaction: try c.decode(InputRemappingMouseInteraction.self, forKey: .interaction))
        case .scroll:
            self = .scroll(direction: try c.decode(InputRemappingScrollDirection.self, forKey: .direction), modifiers: try c.decode(ShortcutModifiers.self, forKey: .modifiers))
        case .trackpadGesture:
            self = .trackpadGesture(try c.decode(TrackpadGesture.self, forKey: .gesture))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .keyboard(keyCode, modifiers):
            try c.encode(Kind.keyboard, forKey: .kind); try c.encode(keyCode, forKey: .keyCode); try c.encode(modifiers, forKey: .modifiers)
        case let .mouseButton(number, modifiers, interaction):
            try c.encode(Kind.mouseButton, forKey: .kind); try c.encode(number, forKey: .number); try c.encode(modifiers, forKey: .modifiers); try c.encode(interaction, forKey: .interaction)
        case let .scroll(direction, modifiers):
            try c.encode(Kind.scroll, forKey: .kind); try c.encode(direction, forKey: .direction); try c.encode(modifiers, forKey: .modifiers)
        case let .trackpadGesture(gesture):
            try c.encode(Kind.trackpadGesture, forKey: .kind); try c.encode(gesture, forKey: .gesture)
        }
    }

    var modifiers: ShortcutModifiers {
        switch self { case let .keyboard(_, modifiers), let .mouseButton(_, modifiers, _), let .scroll(_, modifiers): modifiers; case .trackpadGesture: [] }
    }

    func normalized() -> Self {
        guard case let .mouseButton(number, modifiers, interaction) = self else { return self }
        return .mouseButton(number: InputRemappingRulePolicy.normalized(buttonNumber: number), modifiers: modifiers, interaction: interaction)
    }
}

enum InputRemappingCapturedInput: Equatable, Sendable {
    case keyboard(keyCode: UInt16, modifiers: ShortcutModifiers)
    case mouseButton(number: Int64, modifiers: ShortcutModifiers)
    case scroll(direction: InputRemappingScrollDirection, modifiers: ShortcutModifiers)

    func trigger(interaction: InputRemappingMouseInteraction = .click) -> InputRemappingTrigger {
        switch self {
        case let .keyboard(keyCode, modifiers): .keyboard(keyCode: keyCode, modifiers: modifiers)
        case let .mouseButton(number, modifiers): .mouseButton(number: number, modifiers: modifiers, interaction: interaction)
        case let .scroll(direction, modifiers): .scroll(direction: direction, modifiers: modifiers)
        }
    }
}

struct InputRemappingRule: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey { case id, isEnabled, trigger, buttonNumber, modifiers, action }

    enum Action: Codable, Equatable, Hashable, Sendable, CaseIterable {
        case shortcut(ShortcutBinding), mouseBack, mouseForward, mouseMiddle, missionControl, spaceLeft, spaceRight, mediaPlayPause, volumeDown, volumeUp
        static var allCases: [Action] { [.shortcut(ShortcutBinding(keyCode: 0, modifiers: [.command])), .mouseBack, .mouseForward, .mouseMiddle, .missionControl, .spaceLeft, .spaceRight, .mediaPlayPause, .volumeDown, .volumeUp] }
        func title(localization: PluginLocalization) -> String {
            switch self {
            case let .shortcut(binding): localization.format("action.shortcut.format", defaultValue: "快捷键 %@%d", binding.modifiers.symbolString, binding.keyCode)
            case .mouseBack: localization.string("action.mouseBack", defaultValue: "鼠标后退")
            case .mouseForward: localization.string("action.mouseForward", defaultValue: "鼠标前进")
            case .mouseMiddle: localization.string("action.mouseMiddle", defaultValue: "中键点击")
            case .missionControl: localization.string("action.missionControl", defaultValue: "调度中心")
            case .spaceLeft: localization.string("action.spaceLeft", defaultValue: "左侧空间")
            case .spaceRight: localization.string("action.spaceRight", defaultValue: "右侧空间")
            case .mediaPlayPause: localization.string("action.mediaPlayPause", defaultValue: "播放/暂停")
            case .volumeDown: localization.string("action.volumeDown", defaultValue: "降低音量")
            case .volumeUp: localization.string("action.volumeUp", defaultValue: "提高音量")
            }
        }
    }

    let id: UUID
    var isEnabled: Bool
    var trigger: InputRemappingTrigger
    var action: Action

    // Compatibility conveniences for rules saved before universal input support.
    var buttonNumber: Int64 {
        get { if case let .mouseButton(number, _, _) = trigger { number } else { InputRemappingRulePolicy.minimumButtonNumber } }
        set { replaceTrigger(.mouseButton(number: newValue, modifiers: modifiers, interaction: mouseInteraction)) }
    }
    var modifiers: ShortcutModifiers {
        get { trigger.modifiers }
        set {
            switch trigger {
            case let .keyboard(keyCode, _): replaceTrigger(.keyboard(keyCode: keyCode, modifiers: newValue))
            case let .mouseButton(number, _, interaction): replaceTrigger(.mouseButton(number: number, modifiers: newValue, interaction: interaction))
            case let .scroll(direction, _): replaceTrigger(.scroll(direction: direction, modifiers: newValue))
            case .trackpadGesture: break
            }
        }
    }
    var mouseInteraction: InputRemappingMouseInteraction {
        get { if case let .mouseButton(_, _, interaction) = trigger { interaction } else { .click } }
        set { if case let .mouseButton(number, modifiers, _) = trigger { replaceTrigger(.mouseButton(number: number, modifiers: modifiers, interaction: newValue)) } }
    }

    init(id: UUID = UUID(), isEnabled: Bool = true, trigger: InputRemappingTrigger = .mouseButton(number: 3, modifiers: [], interaction: .click), action: Action = .mouseBack) {
        self.id = id
        self.trigger = trigger.normalized()
        self.isEnabled = isEnabled && !Self.requiresExplicitConfirmation(for: self.trigger)
        self.action = action
    }

    init(id: UUID = UUID(), isEnabled: Bool = true, buttonNumber: Int64 = 3, modifiers: ShortcutModifiers = [], action: Action = .mouseBack) {
        self.init(id: id, isEnabled: isEnabled, trigger: .mouseButton(number: buttonNumber, modifiers: modifiers, interaction: .click), action: action)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let enabled = try c.decode(Bool.self, forKey: .isEnabled)
        let action = try c.decode(Action.self, forKey: .action)
        if let trigger = try c.decodeIfPresent(InputRemappingTrigger.self, forKey: .trigger) {
            self.init(id: id, isEnabled: enabled, trigger: trigger, action: action)
        } else {
            self.init(id: id, isEnabled: enabled, buttonNumber: try c.decode(Int64.self, forKey: .buttonNumber), modifiers: try c.decode(ShortcutModifiers.self, forKey: .modifiers), action: action)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(isEnabled, forKey: .isEnabled); try c.encode(trigger.normalized(), forKey: .trigger); try c.encode(action, forKey: .action)
    }
    func normalized() -> InputRemappingRule {
        InputRemappingRule(id: id, isEnabled: isEnabled, trigger: trigger, action: action)
    }

    mutating func replaceTrigger(_ newTrigger: InputRemappingTrigger) {
        trigger = newTrigger.normalized()
        if Self.requiresExplicitConfirmation(for: trigger) {
            isEnabled = false
        }
    }

    static func requiresExplicitConfirmation(for trigger: InputRemappingTrigger) -> Bool {
        guard case let .keyboard(_, modifiers) = trigger else { return false }
        return modifiers.isEmpty
    }
    static func modifiers(from flags: CGEventFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if flags.contains(.maskShift) { result.insert(.shift) }; if flags.contains(.maskControl) { result.insert(.control) }; if flags.contains(.maskAlternate) { result.insert(.option) }; if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }
}

enum InputRemappingRuleMatcher {
    static func rule(for buttonNumber: Int64, flags: CGEventFlags, in rules: [InputRemappingRule], interaction: InputRemappingMouseInteraction = .click) -> InputRemappingRule? {
        rules.first { rule in
            guard rule.isEnabled, case let .mouseButton(number, modifiers, expectedInteraction) = rule.trigger else { return false }
            return number == buttonNumber && modifiers == InputRemappingRule.modifiers(from: flags) && expectedInteraction == interaction
        }
    }
    static func keyboardRule(for keyCode: UInt16, flags: CGEventFlags, in rules: [InputRemappingRule]) -> InputRemappingRule? {
        rules.first { rule in if case let .keyboard(expected, modifiers) = rule.trigger { return rule.isEnabled && expected == keyCode && modifiers == InputRemappingRule.modifiers(from: flags) }; return false }
    }
    static func scrollRule(for direction: InputRemappingScrollDirection, flags: CGEventFlags, in rules: [InputRemappingRule]) -> InputRemappingRule? {
        rules.first { rule in if case let .scroll(expected, modifiers) = rule.trigger { return rule.isEnabled && expected == direction && modifiers == InputRemappingRule.modifiers(from: flags) }; return false }
    }
}

enum InputRemappingMouseEventPhase { case down, up }

struct InputRemappingEventProcessor {
    private var buttonsAwaitingConsumedUp: Set<Int64> = []
    private var keysAwaitingConsumedUp: Set<UInt16> = []
    private var lastClickTime: [Int64: TimeInterval] = [:]
    private var mouseDownTime: [Int64: TimeInterval] = [:]

    mutating func shouldConsume(phase: InputRemappingMouseEventPhase, buttonNumber: Int64, flags: CGEventFlags, isMarkedSynthetic: Bool, rules: [InputRemappingRule], timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime, execute: (InputRemappingRule.Action) -> Bool) -> Bool {
        guard !isMarkedSynthetic else { return false }
        switch phase {
        case .down:
            mouseDownTime[buttonNumber] = timestamp
            if let rule = InputRemappingRuleMatcher.rule(for: buttonNumber, flags: flags, in: rules), execute(rule.action) { buttonsAwaitingConsumedUp.insert(buttonNumber); return true }
            if let rule = InputRemappingRuleMatcher.rule(for: buttonNumber, flags: flags, in: rules, interaction: .doubleClick), let previous = lastClickTime[buttonNumber], timestamp - previous <= InputRemappingRulePolicy.doubleClickInterval {
                _ = execute(rule.action)
                lastClickTime[buttonNumber] = nil
                return false
            }
            lastClickTime[buttonNumber] = timestamp
            return false
        case .up:
            if buttonsAwaitingConsumedUp.remove(buttonNumber) != nil { return true }
            guard let started = mouseDownTime.removeValue(forKey: buttonNumber), timestamp - started >= InputRemappingRulePolicy.longPressDuration, let rule = InputRemappingRuleMatcher.rule(for: buttonNumber, flags: flags, in: rules, interaction: .longPress) else { return false }
            // Long presses intentionally pass through. Consuming them would require buffering/replaying the original click.
            _ = execute(rule.action)
            return false
        }
    }

    mutating func shouldConsumeKeyboard(
        isKeyDown: Bool,
        keyCode: UInt16,
        flags: CGEventFlags,
        isMarkedSynthetic: Bool,
        rules: [InputRemappingRule],
        execute: (InputRemappingRule.Action) -> Bool
    ) -> Bool {
        guard !isMarkedSynthetic else { return false }
        guard isKeyDown else { return keysAwaitingConsumedUp.remove(keyCode) != nil }
        guard let rule = InputRemappingRuleMatcher.keyboardRule(
            for: keyCode,
            flags: flags,
            in: rules
        ), execute(rule.action) else {
            return false
        }
        keysAwaitingConsumedUp.insert(keyCode)
        return true
    }

    mutating func reset() {
        buttonsAwaitingConsumedUp.removeAll()
        keysAwaitingConsumedUp.removeAll()
        lastClickTime.removeAll()
        mouseDownTime.removeAll()
    }
}

@MainActor
final class InputRemappingStore: ObservableObject {
    @Published private(set) var rules: [InputRemappingRule]
    private static let storageKey = "input-remapping.rules.v1"
    private let storage: any PluginStorage
    private let logger: Logger
    var onRulesChange: (() -> Void)?
    init(storage: any PluginStorage, logger: Logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "InputRemappingStore")) {
        self.storage = storage; self.logger = logger
        guard let data = storage.data(forKey: Self.storageKey) else { rules = []; return }
        do { rules = try JSONDecoder().decode([InputRemappingRule].self, from: data) } catch { logger.error("Failed to decode input remapping rules: \(String(describing: error), privacy: .public)"); rules = [] }
    }
    func addRule() { update(rules + [InputRemappingRule()]) }
    func delete(_ rule: InputRemappingRule) { update(rules.filter { $0.id != rule.id }) }
    func replace(_ rule: InputRemappingRule) { update(rules.map { $0.id == rule.id ? rule : $0 }) }
    private func update(_ rules: [InputRemappingRule]) { let normalizedRules = rules.map { $0.normalized() }; do { storage.set(try JSONEncoder().encode(normalizedRules), forKey: Self.storageKey); self.rules = normalizedRules; onRulesChange?() } catch { logger.error("Failed to encode input remapping rules: \(String(describing: error), privacy: .public)") } }
}
