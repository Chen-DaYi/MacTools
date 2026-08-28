import Foundation

enum SystemSettingsOperationState: Equatable {
    case idle
    case preparing
    case applying
    case restoring
}

enum SystemSettingOperationPhase: String, Equatable {
    case reading
    case applying
    case verifying
    case restoring

    var title: String {
        switch self {
        case .reading: "读取中"
        case .applying: "应用中"
        case .verifying: "验证中"
        case .restoring: "恢复中"
        }
    }
}

enum SystemSettingsProgressEvent {
    case phase(SystemSettingID, SystemSettingOperationPhase)
    case finished(SystemSettingsProfileApplyResult)
}

struct SystemSettingsOperationProgress {
    let total: Int
    var results: [SystemSettingsProfileApplyResult] = []
    var activeSettingID: SystemSettingID?
    var phase: SystemSettingOperationPhase?
    var completed: Int { results.count }
}

struct SystemSettingRecovery: Codable, Equatable, Identifiable {
    let settingID: SystemSettingID
    let original: SystemSettingSnapshot
    var current: SystemSettingSnapshot?
    var message: String

    var id: SystemSettingID { settingID }

    /// Local-only details: custom paths and raw device preferences never enter portable backups.
    var differences: [String] {
        guard let current else { return ["当前状态无法读取；原始快照已保留。"] }
        let before = original.recoveryFields
        let after = current.recoveryFields
        return Set(before.keys).union(after.keys).sorted().compactMap { key in
            guard before[key] != after[key] else { return nil }
            return "\(key)：\(after[key] ?? "未知")（原值：\(before[key] ?? "未知")）"
        }
    }
}

private extension SystemSettingSnapshot {
    var recoveryFields: [String: String] {
        if let components {
            return components.reduce(into: [:]) { result, component in
                let name: String = switch component.key {
                case "persisted": "设备偏好"
                case "live": "实时状态"
                case "0": "内置触控板"
                case "1": "蓝牙触控板"
                default: component.key
                }
                for (key, value) in component.value.recoveryFields {
                    result[key == "值" ? name : "\(name) · \(key)"] = value
                }
            }
        }
        if let restoration {
            return restoration.mapValues {
                switch $0 {
                case .missing: "未设置"
                case let .boolean(value): value ? "开" : "关"
                case let .integer(value): String(value)
                case let .string(value): value
                }
            }
        }
        return ["值": value.conciseDescription]
    }
}
