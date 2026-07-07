import CoreGraphics
import Foundation
import AppKit

@_silgen_name("MTConfigureDisplayEnabled")
private func MTConfigureDisplayEnabled(
    _ config: CGDisplayConfigRef,
    _ display: CGDirectDisplayID,
    _ enabled: Bool
) -> CGError

@_silgen_name("MTDisplayEnableSPIAvailable")
private func MTDisplayEnableSPIAvailable() -> Bool

@MainActor
protocol DisplayDisableServicing: AnyObject {
    var isSupported: Bool { get }

    func listDisplays() -> [DisplayDisableDisplay]
    func setDisplay(_ displayID: CGDirectDisplayID, enabled: Bool) throws
}

@MainActor
protocol DisplayDisableStateStoring: AnyObject {
    var snapshot: DisplayDisableRecoverySnapshot? { get set }
}

enum DisplayDisableServiceError: Error, LocalizedError {
    case privateSPIUnavailable
    case beginConfigurationFailed(CGError)
    case configureDisplayFailed(CGError)
    case completeConfigurationFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .privateSPIUnavailable:
            return DisplayBrightnessLocalization.string(
                "displayDisable.unsupported",
                defaultValue: "当前系统不支持关闭内建显示屏"
            )
        case .beginConfigurationFailed:
            return DisplayBrightnessLocalization.string(
                "displayDisable.error.beginConfiguration",
                defaultValue: "无法开始显示器配置"
            )
        case .configureDisplayFailed:
            return DisplayBrightnessLocalization.string(
                "displayDisable.error.configureDisplay",
                defaultValue: "无法切换显示器状态"
            )
        case .completeConfigurationFailed:
            return DisplayBrightnessLocalization.string(
                "displayDisable.error.completeConfiguration",
                defaultValue: "无法提交显示器配置"
            )
        }
    }
}

@MainActor
final class SystemDisplayDisableService: DisplayDisableServicing {
    var isSupported: Bool {
        MTDisplayEnableSPIAvailable()
    }

    func listDisplays() -> [DisplayDisableDisplay] {
        let activeDisplayIDs = Set(Self.activeDisplayIDs())
        let visibleDisplayIDs = Set(Self.visibleAppKitDisplayIDs())

        return Self.onlineDisplayIDs().enumerated().map { index, displayID in
            let screen = NSScreen.screens.first(where: { screen in
                Self.displayID(for: screen) == displayID
            })
            let vendorNumber = CGDisplayVendorNumber(displayID)
            let modelNumber = CGDisplayModelNumber(displayID)
            let serialNumber = CGDisplaySerialNumber(displayID)

            return DisplayDisableDisplay(
                id: displayID,
                name: screen?.localizedName ?? "Display \(index + 1)",
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                isActive: activeDisplayIDs.contains(displayID),
                isInMirrorSet: CGDisplayIsInMirrorSet(displayID) != 0,
                isVisibleToAppKit: visibleDisplayIDs.contains(displayID),
                vendorNumber: vendorNumber == 0 ? nil : vendorNumber,
                modelNumber: modelNumber == 0 ? nil : modelNumber,
                serialNumber: serialNumber == 0 ? nil : serialNumber
            )
        }
    }

    func setDisplay(_ displayID: CGDirectDisplayID, enabled: Bool) throws {
        guard isSupported else {
            throw DisplayDisableServiceError.privateSPIUnavailable
        }

        var config: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&config)
        guard beginError == .success, let config else {
            throw DisplayDisableServiceError.beginConfigurationFailed(beginError)
        }

        var committed = false
        defer {
            if !committed {
                CGCancelDisplayConfiguration(config)
            }
        }

        let configureError = MTConfigureDisplayEnabled(config, displayID, enabled)
        guard configureError == .success else {
            throw DisplayDisableServiceError.configureDisplayFailed(configureError)
        }

        let completeError = CGCompleteDisplayConfiguration(config, .forSession)
        committed = completeError == .success
        guard completeError == .success else {
            throw DisplayDisableServiceError.completeConfigurationFailed(completeError)
        }
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)

        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(count))
        CGGetOnlineDisplayList(count, &displayIDs, &count)
        return Array(displayIDs.prefix(Int(count)))
    }

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)

        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(count))
        CGGetActiveDisplayList(count, &displayIDs, &count)
        return Array(displayIDs.prefix(Int(count)))
    }

    private static func visibleAppKitDisplayIDs() -> [CGDirectDisplayID] {
        NSScreen.screens.compactMap(displayID(for:))
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        )?.uint32Value
    }
}
