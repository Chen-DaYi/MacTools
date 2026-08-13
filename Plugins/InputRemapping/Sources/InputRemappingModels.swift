import Combine
import CoreGraphics
import Foundation
import MacToolsPluginKit
import OSLog

enum InputRemappingRulePolicy {
    static let minimumButtonNumber: Int64 = 3
    static let maximumButtonNumber: Int64 = 32
    static let eligibleButtonNumbers = minimumButtonNumber...maximumButtonNumber

    static func isEligible(buttonNumber: Int64) -> Bool {
        eligibleButtonNumbers.contains(buttonNumber)
    }

    static func normalized(buttonNumber: Int64) -> Int64 {
        min(maximumButtonNumber, max(minimumButtonNumber, buttonNumber))
    }
}

struct InputRemappingRule: Identifiable, Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case buttonNumber
        case modifiers
        case action
    }

    enum Action: Codable, Equatable, Hashable, Sendable, CaseIterable {
        case shortcut(ShortcutBinding)
        case mouseBack
        case mouseForward
        case mouseMiddle
        case missionControl
        case spaceLeft
        case spaceRight
        case mediaPlayPause
        case volumeDown
        case volumeUp

        static var allCases: [Action] {
            [
                .shortcut(ShortcutBinding(keyCode: 0, modifiers: [.command])),
                .mouseBack,
                .mouseForward,
                .mouseMiddle,
                .missionControl,
                .spaceLeft,
                .spaceRight,
                .mediaPlayPause,
                .volumeDown,
                .volumeUp,
            ]
        }

        func title(localization: PluginLocalization) -> String {
            switch self {
            case let .shortcut(binding):
                localization.format(
                    "action.shortcut.format",
                    defaultValue: "快捷键 %@%d",
                    binding.modifiers.symbolString,
                    binding.keyCode
                )
            case .mouseBack:
                localization.string("action.mouseBack", defaultValue: "鼠标后退")
            case .mouseForward:
                localization.string("action.mouseForward", defaultValue: "鼠标前进")
            case .mouseMiddle:
                localization.string("action.mouseMiddle", defaultValue: "中键点击")
            case .missionControl:
                localization.string("action.missionControl", defaultValue: "调度中心")
            case .spaceLeft:
                localization.string("action.spaceLeft", defaultValue: "左侧空间")
            case .spaceRight:
                localization.string("action.spaceRight", defaultValue: "右侧空间")
            case .mediaPlayPause:
                localization.string("action.mediaPlayPause", defaultValue: "播放/暂停")
            case .volumeDown:
                localization.string("action.volumeDown", defaultValue: "降低音量")
            case .volumeUp:
                localization.string("action.volumeUp", defaultValue: "提高音量")
            }
        }
    }

    let id: UUID
    var isEnabled: Bool
    var buttonNumber: Int64
    var modifiers: ShortcutModifiers
    var action: Action

    init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        buttonNumber: Int64 = InputRemappingRulePolicy.minimumButtonNumber,
        modifiers: ShortcutModifiers = [],
        action: Action = .mouseBack
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.buttonNumber = InputRemappingRulePolicy.normalized(buttonNumber: buttonNumber)
        self.modifiers = modifiers
        self.action = action
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled),
            buttonNumber: try container.decode(Int64.self, forKey: .buttonNumber),
            modifiers: try container.decode(ShortcutModifiers.self, forKey: .modifiers),
            action: try container.decode(Action.self, forKey: .action)
        )
    }

    func normalized() -> InputRemappingRule {
        var copy = self
        copy.buttonNumber = InputRemappingRulePolicy.normalized(buttonNumber: buttonNumber)
        return copy
    }

    func matches(buttonNumber: Int64, flags: CGEventFlags) -> Bool {
        isEnabled
            && InputRemappingRulePolicy.isEligible(buttonNumber: self.buttonNumber)
            && InputRemappingRulePolicy.isEligible(buttonNumber: buttonNumber)
            && self.buttonNumber == buttonNumber
            && modifiers == InputRemappingRule.modifiers(from: flags)
    }

    static func modifiers(from flags: CGEventFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }
}

enum InputRemappingRuleMatcher {
    static func rule(
        for buttonNumber: Int64,
        flags: CGEventFlags,
        in rules: [InputRemappingRule]
    ) -> InputRemappingRule? {
        guard InputRemappingRulePolicy.isEligible(buttonNumber: buttonNumber) else {
            return nil
        }
        return rules.first { $0.matches(buttonNumber: buttonNumber, flags: flags) }
    }
}

enum InputRemappingMouseEventPhase {
    case down
    case up
}

struct InputRemappingEventProcessor {
    private var buttonsAwaitingConsumedUp: Set<Int64> = []

    mutating func shouldConsume(
        phase: InputRemappingMouseEventPhase,
        buttonNumber: Int64,
        flags: CGEventFlags,
        isMarkedSynthetic: Bool,
        rules: [InputRemappingRule],
        execute: (InputRemappingRule.Action) -> Bool
    ) -> Bool {
        guard !isMarkedSynthetic else { return false }

        switch phase {
        case .down:
            guard let rule = InputRemappingRuleMatcher.rule(
                for: buttonNumber,
                flags: flags,
                in: rules
            ), execute(rule.action) else {
                return false
            }
            buttonsAwaitingConsumedUp.insert(buttonNumber)
            return true

        case .up:
            return buttonsAwaitingConsumedUp.remove(buttonNumber) != nil
        }
    }

    mutating func reset() {
        buttonsAwaitingConsumedUp.removeAll()
    }
}

@MainActor
final class InputRemappingStore: ObservableObject {
    @Published private(set) var rules: [InputRemappingRule]

    private static let storageKey = "input-remapping.rules.v1"

    private let storage: any PluginStorage
    private let logger: Logger

    var onRulesChange: (() -> Void)?

    init(
        storage: any PluginStorage,
        logger: Logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
            category: "InputRemappingStore"
        )
    ) {
        self.storage = storage
        self.logger = logger

        guard let data = storage.data(forKey: Self.storageKey) else {
            rules = []
            return
        }

        do {
            rules = try JSONDecoder().decode([InputRemappingRule].self, from: data)
        } catch {
            logger.error(
                "Failed to decode input remapping rules: \(String(describing: error), privacy: .public)"
            )
            rules = []
        }
    }

    func addRule() {
        update(rules + [InputRemappingRule()])
    }

    func delete(_ rule: InputRemappingRule) {
        update(rules.filter { $0.id != rule.id })
    }

    func replace(_ rule: InputRemappingRule) {
        update(rules.map { $0.id == rule.id ? rule : $0 })
    }

    private func update(_ rules: [InputRemappingRule]) {
        let normalizedRules = rules.map { $0.normalized() }
        do {
            let data = try JSONEncoder().encode(normalizedRules)
            storage.set(data, forKey: Self.storageKey)
            self.rules = normalizedRules
            onRulesChange?()
        } catch {
            logger.error(
                "Failed to encode input remapping rules: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
