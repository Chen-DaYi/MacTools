import CoreGraphics
import Foundation
import MacToolsPluginKit

struct DisplayResolutionInfo: Equatable {
    let modeId: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
    let isNative: Bool
    let isDefault: Bool
    let isCurrent: Bool

    var displayTitle: String { "\(width)×\(height)" }
    var aspectRatio: Double { Double(width) / Double(height) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modeId == rhs.modeId
    }
}

enum DisplayResolutionError: Error, LocalizedError {
    case displayUnavailable(displayID: CGDirectDisplayID)
    case modeNotFound(modeId: Int32)
    case beginConfigFailed(CGError)
    case configureFailed(CGError)
    case completeFailed(CGError)

    var errorDescription: String? {
        localizedDescription(localization: PluginLocalization(bundle: .main))
    }

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case .displayUnavailable:
            return localization.string("error.displayUnavailable", defaultValue: "显示器已断开连接")
        case .modeNotFound:
            return localization.string("error.modeNotFound", defaultValue: "分辨率模式已失效")
        case .beginConfigFailed:
            return localization.string("error.beginConfigFailed", defaultValue: "无法开始显示配置")
        case .configureFailed:
            return localization.string("error.configureFailed", defaultValue: "配置显示模式失败")
        case .completeFailed:
            return localization.string("error.completeFailed", defaultValue: "提交显示配置失败")
        }
    }
}
