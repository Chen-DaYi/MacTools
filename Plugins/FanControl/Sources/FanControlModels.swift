import Foundation
import MacToolsPluginKit

// MARK: - Fan Preset

struct FanPreset: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var strategy: FanControlStrategy
    /// Built-in presets (auto / full-speed) cannot be deleted or renamed.
    let isBuiltIn: Bool

    init(id: String, name: String, strategy: FanControlStrategy, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.strategy = strategy
        self.isBuiltIn = isBuiltIn
    }

    func displayName(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch id {
        case FanPresetBuiltInID.auto:
            return localization.string("preset.auto.name", defaultValue: "自动")
        case FanPresetBuiltInID.fullSpeed:
            return localization.string("preset.fullSpeed.name", defaultValue: "全速")
        default:
            return name
        }
    }
}

enum FanControlStrategy: Codable, Equatable {
    /// Restore macOS automatic fan management.
    case auto
    /// Set all fans to their hardware-reported maximum speed.
    case fullSpeed
    /// Set all fans to a fixed RPM (clamped to hardware limits at write time).
    case fixed(rpm: Int)
}

// MARK: - Built-in Preset IDs

enum FanPresetBuiltInID {
    static let auto = "builtin-auto"
    static let fullSpeed = "builtin-full-speed"
}

// MARK: - Fan Snapshot

struct FanSnapshot: Equatable {
    var fanCount: Int
    var fanSpeeds: [Int]
    var fanMinSpeeds: [Int]
    var fanMaxSpeeds: [Int]
    var cpuTemperature: Double?

    var averageSpeed: Int? {
        guard !fanSpeeds.isEmpty else { return nil }
        return fanSpeeds.reduce(0, +) / fanSpeeds.count
    }

    var globalMaxSpeed: Int {
        fanMaxSpeeds.max() ?? FanRPMLimits.fallbackMax
    }

    static let empty = FanSnapshot(
        fanCount: 0,
        fanSpeeds: [],
        fanMinSpeeds: [],
        fanMaxSpeeds: [],
        cpuTemperature: nil
    )
}

// MARK: - RPM Limits

enum FanRPMLimits {
    static let absoluteMin = 500
    static let absoluteMax = 8000
    static let fallbackMin = 1000
    static let fallbackMax = 5200
    static let defaultCustomRPM = 3000
}

// MARK: - Write Error

enum FanWriteError: Error, LocalizedError {
    case helperNotFound
    case helperInstallFailed(String)
    case helperVerificationFailed
    case writeFailed(String)

    var errorDescription: String? {
        localizedDescription()
    }

    func localizedDescription(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .helperNotFound:
            return localization.string(
                "writeError.helperNotFound",
                defaultValue: "未找到内置风扇控制组件。请重新安装风扇控制插件。"
            )
        case .helperInstallFailed(let msg):
            return localization.format(
                "writeError.helperInstallFailed",
                defaultValue: "安装风扇控制组件失败：%@",
                msg
            )
        case .helperVerificationFailed:
            return localization.string(
                "writeError.helperVerificationFailed",
                defaultValue: "风扇控制组件校验失败。请重新安装风扇控制插件。"
            )
        case .writeFailed(let msg):
            return localization.format("writeError.writeFailed", defaultValue: "写入风扇速度失败：%@", msg)
        }
    }
}

// MARK: - SMC Protocols

protocol FanControlSMCReading: AnyObject {
    @MainActor func readSnapshot() -> FanSnapshot
}

protocol FanControlSMCWriting: AnyObject {
    @MainActor var isHelperAvailable: Bool { get }
    @MainActor var isInstalledHelperAvailable: Bool { get }
    @MainActor @discardableResult
    func apply(strategy: FanControlStrategy, snapshot: FanSnapshot) -> FanWriteError?
}
