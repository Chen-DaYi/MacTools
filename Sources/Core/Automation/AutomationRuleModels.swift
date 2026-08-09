import Foundation

enum AutomationTriggerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case schedule
    case calendar
    case application
    case power
    case display
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .schedule: FeatureL10n.string("时间与日程")
        case .calendar: FeatureL10n.string("日历事件")
        case .application: FeatureL10n.string("应用")
        case .power: FeatureL10n.string("电池与电源")
        case .display: FeatureL10n.string("显示器")
        case .network: FeatureL10n.string("网络")
        }
    }
}

struct ScheduleAutomationTrigger: Codable, Equatable, Hashable, Sendable {
    var hour: Int = 9
    var minute: Int = 0
    var weekdays: [Int] = Array(1 ... 7)
}

enum CalendarAutomationPhase: String, Codable, CaseIterable, Sendable {
    case starts
    case ends
}

struct CalendarAutomationTrigger: Codable, Equatable, Hashable, Sendable {
    var phase: CalendarAutomationPhase = .starts
    var calendarIdentifier: String?
    var titleContains: String?
    var offsetMinutes: Int = 0
}

enum ApplicationAutomationEvent: String, Codable, CaseIterable, Sendable {
    case launches
    case activates
}

struct ApplicationAutomationTrigger: Codable, Equatable, Hashable, Sendable {
    var event: ApplicationAutomationEvent = .activates
    var bundleIdentifier: String = "com.apple.finder"
}

enum PowerAutomationEvent: String, Codable, CaseIterable, Sendable {
    case adapterConnected
    case adapterDisconnected
    case batteryAtOrBelow
}

struct PowerAutomationTrigger: Codable, Equatable, Hashable, Sendable {
    var event: PowerAutomationEvent = .adapterConnected
    var batteryLevel: Int = 20
}

enum DisplayAutomationEvent: String, Codable, CaseIterable, Sendable {
    case connected
    case disconnected
}

struct DisplayAutomationTrigger: Codable, Equatable, Hashable, Sendable {
    var event: DisplayAutomationEvent = .connected
    var displayIdentifier: String?
    var displayNameContains: String?
}

enum AutomationNetworkStatus: String, Codable, CaseIterable, Sendable {
    case available
    case unavailable
}

enum AutomationNetworkInterface: String, Codable, CaseIterable, Sendable {
    case any
    case wifi
    case wiredEthernet
    case cellular
    case other
}

struct NetworkAutomationTrigger: Codable, Equatable, Hashable, Sendable {
    var status: AutomationNetworkStatus = .available
    var interface: AutomationNetworkInterface = .any
}

enum AutomationTrigger: Codable, Equatable, Hashable, Sendable {
    case schedule(ScheduleAutomationTrigger)
    case calendar(CalendarAutomationTrigger)
    case application(ApplicationAutomationTrigger)
    case power(PowerAutomationTrigger)
    case display(DisplayAutomationTrigger)
    case network(NetworkAutomationTrigger)

    var kind: AutomationTriggerKind {
        switch self {
        case .schedule: .schedule
        case .calendar: .calendar
        case .application: .application
        case .power: .power
        case .display: .display
        case .network: .network
        }
    }

    static func defaultValue(for kind: AutomationTriggerKind) -> Self {
        switch kind {
        case .schedule: .schedule(ScheduleAutomationTrigger())
        case .calendar: .calendar(CalendarAutomationTrigger())
        case .application: .application(ApplicationAutomationTrigger())
        case .power: .power(PowerAutomationTrigger())
        case .display: .display(DisplayAutomationTrigger())
        case .network: .network(NetworkAutomationTrigger())
        }
    }
}

enum AutomationPowerSource: String, Codable, CaseIterable, Sendable {
    case adapter
    case battery
    case unknown
}

struct FrontmostApplicationCondition: Codable, Equatable, Hashable, Sendable {
    var bundleIdentifier: String
    var isExcluded: Bool = false
}

struct PowerAutomationCondition: Codable, Equatable, Hashable, Sendable {
    var source: AutomationPowerSource? = nil
    var minimumBatteryLevel: Int? = nil
    var maximumBatteryLevel: Int? = nil
}

struct ConnectedDisplayCondition: Codable, Equatable, Hashable, Sendable {
    var displayIdentifier: String? = nil
    var displayNameContains: String? = nil
}

struct TimeRangeAutomationCondition: Codable, Equatable, Hashable, Sendable {
    var startMinute: Int = 9 * 60
    var endMinute: Int = 17 * 60
    var weekdays: [Int] = Array(1 ... 7)
}

struct NetworkAutomationCondition: Codable, Equatable, Hashable, Sendable {
    var status: AutomationNetworkStatus = .available
    var interface: AutomationNetworkInterface = .any
}

enum AutomationCondition: Codable, Equatable, Hashable, Sendable, Identifiable {
    case frontmostApplication(FrontmostApplicationCondition)
    case power(PowerAutomationCondition)
    case connectedDisplay(ConnectedDisplayCondition)
    case timeRange(TimeRangeAutomationCondition)
    case network(NetworkAutomationCondition)

    var id: String {
        switch self {
        case .frontmostApplication: "frontmost-application"
        case .power: "power"
        case .connectedDisplay: "connected-display"
        case .timeRange: "time-range"
        case .network: "network"
        }
    }
}

struct AutomationRule: Codable, Equatable, Sendable, Identifiable {
    static let currentFormatVersion = 1
    static let maximumNameByteCount = 80
    static let maximumConditionCount = 8

    let formatVersion: Int
    let id: UUID
    var name: String
    var workflowID: UUID
    var isEnabled: Bool
    var trigger: AutomationTrigger
    var conditions: [AutomationCondition]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String = FeatureL10n.string("新建规则"),
        workflowID: UUID,
        isEnabled: Bool = true,
        trigger: AutomationTrigger = .schedule(ScheduleAutomationTrigger()),
        conditions: [AutomationCondition] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        formatVersion: Int = currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.workflowID = workflowID
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.conditions = conditions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum AutomationRulePortabilityAnalysis {
    static func isPortable(_ rule: AutomationRule) -> Bool {
        !containsDeviceLocalDisplayReference(rule)
    }

    static func containsDeviceLocalDisplayReference(_ rule: AutomationRule) -> Bool {
        if case let .display(trigger) = rule.trigger,
           hasValue(trigger.displayIdentifier) {
            return true
        }
        return rule.conditions.contains { condition in
            guard case let .connectedDisplay(value) = condition else { return false }
            return hasValue(value.displayIdentifier)
        }
    }

    private static func hasValue(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

struct AutomationDisplaySnapshot: Codable, Equatable, Hashable, Sendable {
    let identifier: String
    let name: String
}

struct AutomationEnvironmentSnapshot: Equatable, Sendable {
    var date: Date
    var frontmostApplicationBundleIdentifier: String?
    var batteryLevel: Int?
    var powerSource: AutomationPowerSource
    var connectedDisplays: [AutomationDisplaySnapshot]
    var networkStatus: AutomationNetworkStatus
    var networkInterface: AutomationNetworkInterface
}

enum AutomationTriggerEvent: Equatable, Sendable {
    case schedule(Date)
    case calendar(
        identifier: String,
        title: String,
        calendarIdentifier: String?,
        phase: CalendarAutomationPhase,
        offsetMinutes: Int = 0,
        date: Date
    )
    case application(bundleIdentifier: String, event: ApplicationAutomationEvent, date: Date)
    case power(source: AutomationPowerSource, batteryLevel: Int?, event: PowerAutomationEvent, date: Date)
    case display(AutomationDisplaySnapshot, event: DisplayAutomationEvent, date: Date)
    case network(status: AutomationNetworkStatus, interface: AutomationNetworkInterface, date: Date)

    var kind: AutomationTriggerKind {
        switch self {
        case .schedule: .schedule
        case .calendar: .calendar
        case .application: .application
        case .power: .power
        case .display: .display
        case .network: .network
        }
    }

    var date: Date {
        switch self {
        case let .schedule(date), let .calendar(_, _, _, _, _, date), let .application(_, _, date),
             let .power(_, _, _, date), let .display(_, _, date), let .network(_, _, date):
            date
        }
    }

    var deduplicationKey: String {
        switch self {
        case .schedule:
            "schedule"
        case let .calendar(identifier, _, _, phase, offsetMinutes, _):
            "calendar:\(identifier):\(phase.rawValue):\(offsetMinutes)"
        case let .application(bundleIdentifier, event, _):
            "application:\(bundleIdentifier):\(event.rawValue)"
        case let .power(source, level, event, _):
            "power:\(source.rawValue):\(level ?? -1):\(event.rawValue)"
        case let .display(display, event, _):
            "display:\(display.identifier):\(event.rawValue)"
        case let .network(status, interface, _):
            "network:\(status.rawValue):\(interface.rawValue)"
        }
    }
}

struct AutomationTriggerAvailability: Equatable, Sendable {
    let isAvailable: Bool
    let reason: String?

    static let available = Self(isAvailable: true, reason: nil)

    static func unavailable(_ reason: String) -> Self {
        Self(isAvailable: false, reason: reason)
    }
}

enum AutomationRuleStoreError: Error, Equatable {
    case invalidRule(String)
    case ruleNotFound
    case maximumRuleCountReached
    case persistenceFailed
    case recoveryRequired
}
