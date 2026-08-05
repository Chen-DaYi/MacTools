import Foundation

struct AutomationConditionEvaluation: Equatable, Sendable {
    let isSatisfied: Bool
    let reason: String?

    static let satisfied = Self(isSatisfied: true, reason: nil)

    static func failed(_ reason: String) -> Self {
        Self(isSatisfied: false, reason: reason)
    }
}

struct AutomationRuleEvaluator {
    var calendar: Calendar = .current

    func triggerMatches(_ trigger: AutomationTrigger, event: AutomationTriggerEvent) -> Bool {
        switch (trigger, event) {
        case let (.schedule(configuration), .schedule(date)):
            let components = calendar.dateComponents([.hour, .minute, .weekday], from: date)
            return components.hour == configuration.hour
                && components.minute == configuration.minute
                && components.weekday.map(configuration.weekdays.contains) == true
        case let (
            .calendar(configuration),
            .calendar(_, title, calendarIdentifier, phase, _)
        ):
            guard phase == configuration.phase,
                  normalized(configuration.calendarIdentifier).map({ $0 == calendarIdentifier }) ?? true,
                  normalized(configuration.titleContains).map({
                      title.localizedCaseInsensitiveContains($0)
                  }) ?? true else {
                return false
            }
            return true
        case let (.application(configuration), .application(bundleIdentifier, event, _)):
            return configuration.event == event
                && configuration.bundleIdentifier == bundleIdentifier
        case let (.power(configuration), .power(_, batteryLevel, event, _)):
            guard configuration.event == event else { return false }
            return event != .batteryAtOrBelow
                || batteryLevel.map { $0 <= configuration.batteryLevel } == true
        case let (.display(configuration), .display(display, event, _)):
            return configuration.event == event
                && (normalized(configuration.displayIdentifier).map({ $0 == display.identifier }) ?? true)
                && (normalized(configuration.displayNameContains).map({
                    display.name.localizedCaseInsensitiveContains($0)
                }) ?? true)
        case let (.network(configuration), .network(status, interface, _)):
            return configuration.status == status
                && (configuration.interface == .any || configuration.interface == interface)
        default:
            return false
        }
    }

    func evaluate(
        conditions: [AutomationCondition],
        snapshot: AutomationEnvironmentSnapshot
    ) -> AutomationConditionEvaluation {
        for condition in conditions {
            let evaluation = evaluate(condition, snapshot: snapshot)
            if !evaluation.isSatisfied {
                return evaluation
            }
        }
        return .satisfied
    }

    func evaluate(
        _ condition: AutomationCondition,
        snapshot: AutomationEnvironmentSnapshot
    ) -> AutomationConditionEvaluation {
        switch condition {
        case let .frontmostApplication(value):
            let matches = snapshot.frontmostApplicationBundleIdentifier == value.bundleIdentifier
            guard matches != value.isExcluded else {
                return .failed(value.isExcluded ? "当前应用不符合排除条件。" : "当前应用不匹配。")
            }
        case let .power(value):
            if let source = value.source, snapshot.powerSource != source {
                return .failed("当前电源来源不匹配。")
            }
            if value.minimumBatteryLevel != nil || value.maximumBatteryLevel != nil {
                guard let level = snapshot.batteryLevel else {
                    return .failed("无法读取电池电量。")
                }
                if let minimum = value.minimumBatteryLevel, level < minimum {
                    return .failed("电池电量低于规则范围。")
                }
                if let maximum = value.maximumBatteryLevel, level > maximum {
                    return .failed("电池电量高于规则范围。")
                }
            }
        case let .connectedDisplay(value):
            let match = snapshot.connectedDisplays.contains { display in
                (normalized(value.displayIdentifier).map({ $0 == display.identifier }) ?? true)
                    && (normalized(value.displayNameContains).map({
                        display.name.localizedCaseInsensitiveContains($0)
                    }) ?? true)
            }
            guard match else {
                return .failed("指定显示器未连接。")
            }
        case let .timeRange(value):
            let components = calendar.dateComponents([.hour, .minute, .weekday], from: snapshot.date)
            guard let hour = components.hour,
                  let minute = components.minute,
                  let weekday = components.weekday,
                  value.weekdays.contains(weekday) else {
                return .failed("当前日期不在规则范围内。")
            }
            let currentMinute = hour * 60 + minute
            let inRange = value.startMinute <= value.endMinute
                ? (value.startMinute ... value.endMinute).contains(currentMinute)
                : currentMinute >= value.startMinute || currentMinute <= value.endMinute
            guard inRange else {
                return .failed("当前时间不在规则范围内。")
            }
        case let .network(value):
            guard snapshot.networkStatus == value.status,
                  value.interface == .any || snapshot.networkInterface == value.interface else {
                return .failed("当前网络状态不匹配。")
            }
        }
        return .satisfied
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
