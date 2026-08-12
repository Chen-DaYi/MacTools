import Foundation

enum AutomationRunSkipReason: String, Codable, Equatable, Sendable {
    case frontmostApplicationExcluded = "当前应用不符合排除条件。"
    case frontmostApplicationMismatch = "当前应用不匹配。"
    case powerSourceMismatch = "当前电源来源不匹配。"
    case batteryLevelUnavailable = "无法读取电池电量。"
    case batteryLevelBelowRange = "电池电量低于规则范围。"
    case batteryLevelAboveRange = "电池电量高于规则范围。"
    case displayNotConnected = "指定显示器未连接。"
    case dateOutsideRange = "当前日期不在规则范围内。"
    case timeOutsideRange = "当前时间不在规则范围内。"
    case networkMismatch = "当前网络状态不匹配。"
    case conditionsNotMet = "规则条件不满足。"
    case workflowDoesNotExist = "工作流不存在。"
    case workflowDisabled = "工作流已停用。"
    case previousRunActive = "该规则的上一次运行尚未结束。"
    case workflowNotFound = "找不到工作流。"
    case emptyWorkflow = "工作流尚未添加步骤。"
    case recursiveInvocation = "检测到递归工作流调用。"
    case maximumDepthExceeded = "工作流嵌套层级已达上限。"
    case backgroundExecutionUnsupported = "工作流包含只能交互运行的操作。"
    case confirmationRequiredForAutomaticExecution = "工作流包含需要确认的操作，无法自动运行。"

    var localizedText: String {
        switch self {
        case .frontmostApplicationExcluded:
            FeatureL10n.string("当前应用不符合排除条件。")
        case .frontmostApplicationMismatch:
            FeatureL10n.string("当前应用不匹配。")
        case .powerSourceMismatch:
            FeatureL10n.string("当前电源来源不匹配。")
        case .batteryLevelUnavailable:
            FeatureL10n.string("无法读取电池电量。")
        case .batteryLevelBelowRange:
            FeatureL10n.string("电池电量低于规则范围。")
        case .batteryLevelAboveRange:
            FeatureL10n.string("电池电量高于规则范围。")
        case .displayNotConnected:
            FeatureL10n.string("指定显示器未连接。")
        case .dateOutsideRange:
            FeatureL10n.string("当前日期不在规则范围内。")
        case .timeOutsideRange:
            FeatureL10n.string("当前时间不在规则范围内。")
        case .networkMismatch:
            FeatureL10n.string("当前网络状态不匹配。")
        case .conditionsNotMet:
            FeatureL10n.string("规则条件不满足。")
        case .workflowDoesNotExist:
            FeatureL10n.string("工作流不存在。")
        case .workflowDisabled:
            FeatureL10n.string("工作流已停用。")
        case .previousRunActive:
            FeatureL10n.string("该规则的上一次运行尚未结束。")
        case .workflowNotFound:
            FeatureL10n.string("找不到工作流。")
        case .emptyWorkflow:
            FeatureL10n.string("工作流尚未添加步骤。")
        case .recursiveInvocation:
            FeatureL10n.string("检测到递归工作流调用。")
        case .maximumDepthExceeded:
            FeatureL10n.string("工作流嵌套层级已达上限。")
        case .backgroundExecutionUnsupported:
            FeatureL10n.string("工作流包含只能交互运行的操作。")
        case .confirmationRequiredForAutomaticExecution:
            FeatureL10n.string("工作流包含需要确认的操作，无法自动运行。")
        }
    }
}

struct AutomationConditionEvaluation: Equatable, Sendable {
    let isSatisfied: Bool
    let failureReason: AutomationRunSkipReason?

    static let satisfied = Self(isSatisfied: true, failureReason: nil)

    static func failed(_ reason: AutomationRunSkipReason) -> Self {
        Self(isSatisfied: false, failureReason: reason)
    }

    var reason: String? {
        failureReason?.localizedText
    }
}

struct AutomationRuleEvaluator {
    var calendar: Calendar = .autoupdatingCurrent

    func triggerMatches(_ trigger: AutomationTrigger, event: AutomationTriggerEvent) -> Bool {
        switch (trigger, event) {
        case let (.schedule(configuration), .schedule(date)):
            let components = calendar.dateComponents([.hour, .minute, .weekday], from: date)
            return components.hour == configuration.hour
                && components.minute == configuration.minute
                && components.weekday.map(configuration.weekdays.contains) == true
        case let (
            .calendar(configuration),
            .calendar(_, title, calendarIdentifier, phase, offsetMinutes, _)
        ):
            guard phase == configuration.phase,
                  offsetMinutes == configuration.offsetMinutes,
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
                || batteryLevel == configuration.batteryLevel
        case let (.display(configuration), .display(display, event, _)):
            return configuration.event == event
                && (normalized(configuration.displayIdentifier).map({ $0 == display.identifier }) ?? true)
                && (normalized(configuration.displayNameContains).map({
                    display.name.localizedCaseInsensitiveContains($0)
                }) ?? true)
        case let (.network(configuration), .network(status, interface, _)):
            return configuration.status == status
                && configuration.interface == interface
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
                return .failed(
                    value.isExcluded
                        ? .frontmostApplicationExcluded
                        : .frontmostApplicationMismatch
                )
            }
        case let .power(value):
            if let source = value.source, snapshot.powerSource != source {
                return .failed(.powerSourceMismatch)
            }
            if value.minimumBatteryLevel != nil || value.maximumBatteryLevel != nil {
                guard let level = snapshot.batteryLevel else {
                    return .failed(.batteryLevelUnavailable)
                }
                if let minimum = value.minimumBatteryLevel, level < minimum {
                    return .failed(.batteryLevelBelowRange)
                }
                if let maximum = value.maximumBatteryLevel, level > maximum {
                    return .failed(.batteryLevelAboveRange)
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
                return .failed(.displayNotConnected)
            }
        case let .timeRange(value):
            let components = calendar.dateComponents([.hour, .minute, .weekday], from: snapshot.date)
            guard let hour = components.hour,
                  let minute = components.minute,
                  let weekday = components.weekday,
                  value.weekdays.contains(weekday) else {
                return .failed(.dateOutsideRange)
            }
            let currentMinute = hour * 60 + minute
            let inRange = value.startMinute <= value.endMinute
                ? (value.startMinute ... value.endMinute).contains(currentMinute)
                : currentMinute >= value.startMinute || currentMinute <= value.endMinute
            guard inRange else {
                return .failed(.timeOutsideRange)
            }
        case let .network(value):
            guard snapshot.networkStatus == value.status,
                  value.interface == .any || snapshot.networkInterface == value.interface else {
                return .failed(.networkMismatch)
            }
        }
        return .satisfied
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
