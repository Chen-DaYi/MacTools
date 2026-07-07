import Foundation
import MacToolsPluginKit

enum DeviceBatteryLayoutMode: String, CaseIterable, Equatable {
    case grid
    case list

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .grid:
            return localization.string("layout.grid.title", defaultValue: "列表")
        case .list:
            return localization.string("layout.list.title", defaultValue: "圆环")
        }
    }

    func subtitle(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .grid:
            return localization.string("layout.grid.subtitle", defaultValue: "按设备逐行显示")
        case .list:
            return localization.string("layout.list.subtitle", defaultValue: "多设备圆环")
        }
    }

}

enum DeviceBatteryChargeState: Equatable, Sendable {
    case unknown
    case normal
    case charging
    case charged
    case plugged
    case invalid

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .unknown:
            return localization.string("chargeState.unknown", defaultValue: "未知")
        case .normal:
            return localization.string("chargeState.normal", defaultValue: "正常")
        case .charging:
            return localization.string("chargeState.charging", defaultValue: "充电中")
        case .charged:
            return localization.string("chargeState.charged", defaultValue: "已充满")
        case .plugged:
            return localization.string("chargeState.plugged", defaultValue: "外接电源")
        case .invalid:
            return localization.string("chargeState.invalid", defaultValue: "电量无效")
        }
    }

    var isActiveChargingState: Bool {
        switch self {
        case .charging, .charged, .plugged:
            return true
        case .unknown, .normal, .invalid:
            return false
        }
    }
}

enum DeviceBatteryKind: Equatable, Sendable {
    case internalBattery
    case bluetooth
    case magicAccessory
    case rapooMouse
    case airPodsPart
    case other

    var iconName: String {
        switch self {
        case .internalBattery:
            return "laptopcomputer"
        case .bluetooth:
            return "dot.radiowaves.left.and.right"
        case .magicAccessory:
            return "keyboard"
        case .rapooMouse:
            return "computermouse.fill"
        case .airPodsPart:
            return "airpodspro"
        case .other:
            return "battery.75percent"
        }
    }

    func title(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .internalBattery:
            return "Mac"
        case .bluetooth:
            return localization.string("deviceKind.bluetooth", defaultValue: "蓝牙")
        case .magicAccessory:
            return localization.string("deviceKind.magicAccessory", defaultValue: "Apple 外设")
        case .rapooMouse:
            return localization.string("deviceKind.rapooMouse", defaultValue: "雷柏鼠标")
        case .airPodsPart:
            return localization.string("deviceKind.airPodsPart", defaultValue: "耳机")
        case .other:
            return localization.string("deviceKind.other", defaultValue: "设备")
        }
    }
}

enum DeviceBatteryComponentRole: String, Equatable, Sendable {
    case aggregate
    case left
    case right
    case chargingCase

    var isPart: Bool {
        self != .aggregate
    }
}

enum DeviceBatteryLowBatteryThresholds {
    static let defaultValue = 20
    static let minimum = 1
    static let maximum = 99

    static func normalized(_ threshold: Int) -> Int {
        min(max(threshold, minimum), maximum)
    }
}

struct DeviceBatteryComponentIdentity: Equatable, Sendable {
    let groupID: String
    let role: DeviceBatteryComponentRole
}

struct DeviceBatteryItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let model: String?
    let kind: DeviceBatteryKind
    let level: Int?
    let chargeState: DeviceBatteryChargeState
    let parentName: String?
    let source: String
    let lastUpdated: Date?
    let isConnected: Bool
    let detail: String?
    let componentIdentity: DeviceBatteryComponentIdentity?

    init(
        id: String,
        name: String,
        model: String?,
        kind: DeviceBatteryKind,
        level: Int?,
        chargeState: DeviceBatteryChargeState,
        parentName: String?,
        source: String,
        lastUpdated: Date?,
        isConnected: Bool,
        detail: String?,
        componentIdentity: DeviceBatteryComponentIdentity? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.kind = kind
        self.level = level
        self.chargeState = chargeState
        self.parentName = parentName
        self.source = source
        self.lastUpdated = lastUpdated
        self.isConnected = isConnected
        self.detail = detail
        self.componentIdentity = componentIdentity
    }

    var clampedLevel: Int? {
        guard let level else {
            return nil
        }

        return min(max(level, 0), 100)
    }

    func isLowBattery(threshold: Int) -> Bool {
        guard let level = clampedLevel else {
            return false
        }

        return isConnected
            && level < threshold
            && chargeState != .charging
            && chargeState != .charged
            && chargeState != .plugged
    }

    var isDisplayLowBattery: Bool {
        guard let level = clampedLevel else {
            return false
        }

        return level <= DeviceBatteryLowBatteryThresholds.defaultValue
            && chargeState != .charging
            && chargeState != .charged
    }
}

enum DeviceBatteryItemNormalizer {
    static func removingRedundantComponentAggregates(
        _ items: [DeviceBatteryItem]
    ) -> [DeviceBatteryItem] {
        let componentGroups = Set(items.compactMap(componentGroupID))
        guard !componentGroups.isEmpty else {
            return items
        }

        return items.filter { item in
            guard let aggregateGroupID = aggregateGroupID(item) else {
                return true
            }

            return !componentGroups.contains(aggregateGroupID)
        }
    }

    private static func aggregateGroupID(_ item: DeviceBatteryItem) -> String? {
        guard let identity = item.componentIdentity,
              identity.role == .aggregate,
              item.clampedLevel != nil
        else {
            return nil
        }

        return identity.groupID
    }

    private static func componentGroupID(_ item: DeviceBatteryItem) -> String? {
        guard let identity = item.componentIdentity,
              identity.role.isPart,
              item.clampedLevel != nil
        else {
            return nil
        }

        return identity.groupID
    }
}

enum DeviceBatteryAccessState: Equatable, Sendable {
    case idle
    case scanning
    case ready
    case noDevices
    case permissionDenied
    case failed(String)

    var isError: Bool {
        switch self {
        case .permissionDenied, .failed:
            return true
        case .idle, .scanning, .ready, .noDevices:
            return false
        }
    }
}

struct DeviceBatterySnapshot: Equatable, Sendable {
    var accessState: DeviceBatteryAccessState
    var items: [DeviceBatteryItem]
    var lastUpdated: Date?
    var rapooState: RapooBatteryAccessState

    static let idle = DeviceBatterySnapshot(
        accessState: .idle,
        items: [],
        lastUpdated: nil,
        rapooState: .idle
    )

    var visibleItems: [DeviceBatteryItem] {
        items.sorted(by: Self.sortItems)
    }

    var primaryItem: DeviceBatteryItem? {
        visibleItems.first
    }

    var lowBatteryCount: Int {
        visibleItems.filter(\.isDisplayLowBattery).count
    }

    func lowBatteryItems(threshold: Int) -> [DeviceBatteryItem] {
        let normalizedThreshold = DeviceBatteryLowBatteryThresholds.normalized(threshold)
        return visibleItems.filter { $0.isLowBattery(threshold: normalizedThreshold) }
    }

    func subtitle(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch accessState {
        case .idle:
            return localization.string("snapshot.subtitle.idle", defaultValue: "等待检测")
        case .scanning:
            return localization.string("snapshot.subtitle.scanning", defaultValue: "正在读取设备电量")
        case .ready:
            if lowBatteryCount > 0 {
                return localization.format(
                    "snapshot.subtitle.readyWithLowBattery",
                    defaultValue: "%d 台设备，%d 台低电量",
                    visibleItems.count,
                    lowBatteryCount
                )
            }
            return localization.format(
                "snapshot.subtitle.ready",
                defaultValue: "%d 台设备",
                visibleItems.count
            )
        case .noDevices:
            return localization.string("snapshot.subtitle.noDevices", defaultValue: "未检测到可显示电量")
        case .permissionDenied:
            return localization.string("snapshot.subtitle.permissionDenied", defaultValue: "需要输入监控权限")
        case let .failed(message):
            return message
        }
    }

    func errorMessage(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String? {
        switch accessState {
        case .permissionDenied:
            return localization.string(
                "snapshot.error.permissionDenied",
                defaultValue: "无法访问雷柏 HID 接口，请在系统设置中允许 MacTools 使用输入监控。"
            )
        case let .failed(message):
            return message
        case .idle, .scanning, .ready, .noDevices:
            return nil
        }
    }

    private static func sortItems(_ left: DeviceBatteryItem, _ right: DeviceBatteryItem) -> Bool {
        let leftRank = itemRank(left)
        let rightRank = itemRank(right)
        if leftRank != rightRank {
            return leftRank < rightRank
        }

        return left.name.localizedCompare(right.name) == .orderedAscending
    }

    private static func itemRank(_ item: DeviceBatteryItem) -> Int {
        if item.isDisplayLowBattery {
            return 0
        }

        switch item.kind {
        case .internalBattery:
            return 1
        case .rapooMouse:
            return 2
        case .magicAccessory:
            return 3
        case .airPodsPart:
            return 4
        case .bluetooth:
            return 5
        case .other:
            return 6
        }
    }
}

enum DeviceBatteryFormatter {
    static func percent(_ level: Int?) -> String {
        guard let level else {
            return "--"
        }

        return "\(min(max(level, 0), 100))%"
    }

    static func time(
        _ date: Date?,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        guard let date else {
            return localization.string("time.notUpdated", defaultValue: "未更新")
        }

        return timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
