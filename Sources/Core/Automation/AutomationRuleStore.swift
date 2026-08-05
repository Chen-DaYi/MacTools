import Foundation

@MainActor
final class AutomationRuleStore {
    private struct Envelope: Codable {
        let formatVersion: Int
        let rules: [AutomationRule]
    }

    private enum DefaultsKey {
        static let rules = "automation.rules.v1"
    }

    static let maximumRuleCount = 256
    static let maximumPayloadByteCount = 1_024 * 1_024

    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private(set) var loadError: String?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func rules(workflowID: UUID? = nil) -> [AutomationRule] {
        guard let data = userDefaults.data(forKey: DefaultsKey.rules) else {
            loadError = nil
            return []
        }
        guard data.count <= Self.maximumPayloadByteCount else {
            loadError = "rule-payload-too-large"
            return []
        }
        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.formatVersion == AutomationRule.currentFormatVersion,
                  validate(envelope.rules) == nil else {
                loadError = "invalid-rule-format"
                return []
            }
            loadError = nil
            if let workflowID {
                return envelope.rules.filter { $0.workflowID == workflowID }
            }
            return envelope.rules
        } catch {
            loadError = "invalid-rule-payload"
            return []
        }
    }

    func rule(id: UUID) -> AutomationRule? {
        rules().first { $0.id == id }
    }

    func create(workflowID: UUID) -> Result<AutomationRule, AutomationRuleStoreError> {
        var stored = rules()
        guard stored.count < Self.maximumRuleCount else {
            return .failure(.maximumRuleCountReached)
        }
        let rule = AutomationRule(workflowID: workflowID)
        stored.append(rule)
        guard replace(stored) else {
            return .failure(.persistenceFailed)
        }
        return .success(rule)
    }

    func upsert(_ rule: AutomationRule) -> Result<AutomationRule, AutomationRuleStoreError> {
        if let failure = validate(rule) {
            return .failure(.invalidRule(failure))
        }
        var stored = rules()
        var updated = rule
        updated.updatedAt = .now
        if let index = stored.firstIndex(where: { $0.id == rule.id }) {
            stored[index] = updated
        } else {
            guard stored.count < Self.maximumRuleCount else {
                return .failure(.maximumRuleCountReached)
            }
            stored.append(updated)
        }
        guard replace(stored) else {
            return .failure(.persistenceFailed)
        }
        return .success(updated)
    }

    func duplicate(id: UUID) -> Result<AutomationRule, AutomationRuleStoreError> {
        guard let source = rule(id: id) else {
            return .failure(.ruleNotFound)
        }
        let copy = AutomationRule(
            name: byteLimited(source.name + " 副本"),
            workflowID: source.workflowID,
            isEnabled: source.isEnabled,
            trigger: source.trigger,
            conditions: source.conditions
        )
        return upsert(copy)
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        var stored = rules()
        let oldCount = stored.count
        stored.removeAll { $0.id == id }
        return stored.count != oldCount && replace(stored)
    }

    @discardableResult
    func replace(_ rules: [AutomationRule]) -> Bool {
        guard validate(rules) == nil else {
            return false
        }
        do {
            let data = try encoder.encode(
                Envelope(formatVersion: AutomationRule.currentFormatVersion, rules: rules)
            )
            guard data.count <= Self.maximumPayloadByteCount else {
                return false
            }
            userDefaults.set(data, forKey: DefaultsKey.rules)
            return userDefaults.data(forKey: DefaultsKey.rules) == data
        } catch {
            return false
        }
    }

    private func validate(_ rules: [AutomationRule]) -> String? {
        guard rules.count <= Self.maximumRuleCount,
              Set(rules.map(\.id)).count == rules.count else {
            return "rule-count-or-id"
        }
        return rules.lazy.compactMap(validate).first
    }

    private func validate(_ rule: AutomationRule) -> String? {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rule.formatVersion == AutomationRule.currentFormatVersion,
              !name.isEmpty,
              rule.name.utf8.count <= AutomationRule.maximumNameByteCount,
              rule.conditions.count <= AutomationRule.maximumConditionCount,
              Set(rule.conditions.map(\.id)).count == rule.conditions.count,
              validate(rule.trigger),
              rule.conditions.allSatisfy(validate) else {
            return "rule-fields"
        }
        return nil
    }

    private func validate(_ trigger: AutomationTrigger) -> Bool {
        switch trigger {
        case let .schedule(value):
            validTime(hour: value.hour, minute: value.minute)
                && validWeekdays(value.weekdays)
        case let .calendar(value):
            (-1_440 ... 1_440).contains(value.offsetMinutes)
                && (value.titleContains?.utf8.count ?? 0) <= 256
                && (value.calendarIdentifier?.utf8.count ?? 0) <= 512
        case let .application(value):
            !value.bundleIdentifier.isEmpty && value.bundleIdentifier.utf8.count <= 512
        case let .power(value):
            (0 ... 100).contains(value.batteryLevel)
        case let .display(value):
            (value.displayIdentifier?.utf8.count ?? 0) <= 512
                && (value.displayNameContains?.utf8.count ?? 0) <= 256
        case .network:
            true
        }
    }

    private func validate(_ condition: AutomationCondition) -> Bool {
        switch condition {
        case let .frontmostApplication(value):
            !value.bundleIdentifier.isEmpty && value.bundleIdentifier.utf8.count <= 512
        case let .power(value):
            validBatteryLevel(value.minimumBatteryLevel)
                && validBatteryLevel(value.maximumBatteryLevel)
                && (value.minimumBatteryLevel ?? 0) <= (value.maximumBatteryLevel ?? 100)
        case let .connectedDisplay(value):
            (value.displayIdentifier?.utf8.count ?? 0) <= 512
                && (value.displayNameContains?.utf8.count ?? 0) <= 256
        case let .timeRange(value):
            (0 ... 1_439).contains(value.startMinute)
                && (0 ... 1_439).contains(value.endMinute)
                && validWeekdays(value.weekdays)
        case .network:
            true
        }
    }

    private func validTime(hour: Int, minute: Int) -> Bool {
        (0 ... 23).contains(hour) && (0 ... 59).contains(minute)
    }

    private func validWeekdays(_ weekdays: [Int]) -> Bool {
        !weekdays.isEmpty
            && weekdays.count == Set(weekdays).count
            && weekdays.allSatisfy { (1 ... 7).contains($0) }
    }

    private func validBatteryLevel(_ level: Int?) -> Bool {
        level.map { (0 ... 100).contains($0) } ?? true
    }

    private func byteLimited(_ value: String) -> String {
        var result = ""
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= AutomationRule.maximumNameByteCount else {
                break
            }
            result = candidate
        }
        return result
    }
}
