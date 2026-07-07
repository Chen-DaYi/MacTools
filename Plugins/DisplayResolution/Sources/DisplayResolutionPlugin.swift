import AppKit
import CoreGraphics
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class DisplayResolutionPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DisplayResolutionPluginProvider(context: context)
    }
}

@MainActor
private struct DisplayResolutionPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DisplayResolutionPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

private enum ControlID {
    static let displayNavigation = "display-navigation"
    static let openSystemSettings = "display-open-system-settings"
}

@MainActor
protocol DisplaySystemSettingsLauncher {
    @discardableResult
    func openDisplaySettings() -> Bool
}

@MainActor
struct WorkspaceDisplaySystemSettingsLauncher: DisplaySystemSettingsLauncher {
    // Opens System Settings > Displays. The URL works for Ventura+ System Settings and the
    // legacy System Preferences app.
    private static let systemDisplaySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.displays")!

    @discardableResult
    func openDisplaySettings() -> Bool {
        NSWorkspace.shared.open(Self.systemDisplaySettingsURL)
    }
}

@MainActor
final class DisplayResolutionPlugin: MacToolsPlugin, PluginPrimaryPanel, DisplayTopologyRefreshing {
    private static let openSystemSettingsIcon = "gearshape"

    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private var isExpanded = false
    private var selectedDisplayID: CGDirectDisplayID?
    private var lastErrorMessage: String?
    private let controller: DisplayResolutionControlling
    private let systemSettingsLauncher: DisplaySystemSettingsLauncher
    private let localization: PluginLocalization
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "DisplayResolutionPlugin")
    private var snapshot = DisplayResolutionSnapshot(displays: [])

    init(
        controller: DisplayResolutionControlling = DisplayResolutionController(),
        systemSettingsLauncher: DisplaySystemSettingsLauncher = WorkspaceDisplaySystemSettingsLauncher(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.controller = controller
        self.systemSettingsLauncher = systemSettingsLauncher
        self.metadata = PluginMetadata(
            id: "display-resolution",
            title: localization.string("metadata.title", defaultValue: "显示器分辨率"),
            iconName: "display",
            iconTint: Color(nsColor: .systemBlue),
            order: 30,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "查看并切换每个显示器的分辨率"
            )
        )
        refreshSnapshot()
    }

    var primaryPanelState: PluginPanelState {
        let displays = snapshot.displays
        let panelDisplays = displays.filter { !$0.modes.isEmpty }

        if !panelDisplays.contains(where: { $0.display.id == selectedDisplayID }) {
            selectedDisplayID = nil
        }

        guard !displays.isEmpty else {
            selectedDisplayID = nil
            return PluginPanelState(
                subtitle: localization.string("panel.subtitle.noDisplays", defaultValue: "未检测到可用显示器"),
                isOn: false,
                isExpanded: false,
                isEnabled: false,
                isVisible: true,
                detail: nil,
                errorMessage: nil
            )
        }

        guard !panelDisplays.isEmpty else {
            selectedDisplayID = nil
            return PluginPanelState(
                subtitle: localization.string("panel.subtitle.noModes", defaultValue: "未检测到可用分辨率"),
                isOn: false,
                isExpanded: false,
                isEnabled: false,
                isVisible: true,
                detail: nil,
                errorMessage: nil
            )
        }

        return PluginPanelState(
            subtitle: subtitleForRowState(panelDisplays),
            isOn: false,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? buildDetail(for: panelDisplays) : nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        refreshSnapshot()
    }

    func refreshDisplayTopology() {
        refreshSnapshot()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(value):
            isExpanded = value
            if !value {
                selectedDisplayID = nil
            }
            lastErrorMessage = nil
            onStateChange?()
        case let .setNavigationSelection(controlID, optionID):
            guard
                controlID == ControlID.displayNavigation,
                let rawDisplayID = UInt32(optionID)
            else {
                return
            }

            let displayID = CGDirectDisplayID(rawDisplayID)
            selectedDisplayID = displayID
            lastErrorMessage = nil
            onStateChange?()
        case let .clearNavigationSelection(controlID):
            guard controlID == ControlID.displayNavigation else {
                return
            }

            selectedDisplayID = nil
            lastErrorMessage = nil
            onStateChange?()
        case let .setSelection(controlID, optionID):
            guard let displayID = Self.parseDisplayID(from: controlID), let modeId = Int32(optionID) else {
                logger.error("invalid selection payload controlID=\(controlID, privacy: .public) optionID=\(optionID, privacy: .public)")
                return
            }

            refreshSnapshot()

            guard snapshot.displays.contains(where: { $0.display.id == displayID }) else {
                handleApplyFailure(.displayUnavailable(displayID: displayID), displayID: displayID, modeId: modeId)
                return
            }

            guard let target = snapshot.displays.first(where: { $0.display.id == displayID })?
                .allModes
                .first(where: { $0.modeId == modeId }) else {
                handleApplyFailure(.modeNotFound(modeId: modeId), displayID: displayID, modeId: modeId)
                return
            }

            logger.info("applying \(target.width)×\(target.height) on display \(displayID)")

            switch controller.applyResolution(target, for: displayID) {
            case .success:
                refreshSnapshot()
                lastErrorMessage = nil
                logger.info("applied \(target.width)×\(target.height) on display \(displayID)")
                onStateChange?()
            case .failure(let error):
                handleApplyFailure(error, displayID: displayID, modeId: modeId)
            }
        case let .invokeAction(controlID):
            guard controlID == ControlID.openSystemSettings else {
                return
            }

            let opened = systemSettingsLauncher.openDisplaySettings()
            if !opened {
                logger.error("failed to open system display settings via NSWorkspace")
            }
        case .setSwitch, .setDate, .setSlider:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    nonisolated static func visibleModes(_ modes: [DisplayResolutionInfo]) -> [DisplayResolutionInfo] {
        guard let first = modes.first else { return [] }
        let nativeAspect = modes.first(where: { $0.isNative })?.aspectRatio ?? first.aspectRatio
        return modes.filter { mode in
            abs(mode.aspectRatio - nativeAspect) < 0.005 || mode.isCurrent
        }
    }

    nonisolated static func optionTitle(
        for mode: DisplayResolutionInfo,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) -> String {
        var title = "\(mode.width)×\(mode.height)"
        if mode.isNative {
            title += localization.string("resolution.badge.native", defaultValue: " (原生)")
        } else if mode.isDefault {
            title += localization.string("resolution.badge.default", defaultValue: " (默认)")
        } else if mode.isHiDPI {
            title += " (HiDPI)"
        } else {
            title += " (LoDPI)"
        }
        return title
    }

    nonisolated static func parseDisplayID(from controlID: String) -> CGDirectDisplayID? {
        let prefix = "display."
        guard controlID.hasPrefix(prefix) else { return nil }
        return CGDirectDisplayID(controlID.dropFirst(prefix.count))
    }

    private func refreshSnapshot() {
        let displays = controller.listConnectedDisplays()
        let panelDisplays = displays.map { display in
            let modes = controller.listAvailableResolutions(for: display.id)
            return PanelDisplay(
                display: display,
                modes: Self.visibleModes(modes),
                allModes: modes
            )
        }

        snapshot = DisplayResolutionSnapshot(displays: panelDisplays)
    }

    private func subtitleForRowState(_ displays: [PanelDisplay]) -> String {
        if displays.count == 1, let display = displays.first {
            let current = display.modes.first(where: { $0.isCurrent })
            return current.map {
                let displayName = display.display.isMain
                    ? localization.string("display.main", defaultValue: "主屏")
                    : display.display.name
                return "\(displayName) \($0.displayTitle)"
            } ?? metadata.defaultDescription
        }
        return localization.format("panel.subtitle.displayCountFormat", defaultValue: "%d 个显示器", displays.count)
    }

    private func buildDetail(for displays: [PanelDisplay]) -> PluginPanelDetail {
        let displayNavigation = PluginPanelControl(
            id: ControlID.displayNavigation,
            kind: .navigationList,
            options: displays.map { display in
                let currentSummary = display.modes.first(where: { $0.isCurrent })?.displayTitle
                    ?? localization.string("display.currentResolution.unknown", defaultValue: "未知")

                return PluginPanelControlOption(
                    id: String(display.display.id),
                    title: display.display.name,
                    subtitle: currentSummary
                )
            },
            selectedOptionID: selectedDisplayID.map(String.init),
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            isEnabled: true
        )

        let openSystemSettings = PluginPanelControl(
            id: ControlID.openSystemSettings,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.openSystemSettings", defaultValue: "打开系统显示器设置"),
            actionIconSystemName: Self.openSystemSettingsIcon,
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: true,
            isEnabled: true
        )

        let navigationSecondaryPanels = displays.map { display in
            PluginPanelNavigationSecondaryPanel(
                controlID: ControlID.displayNavigation,
                optionID: String(display.display.id),
                panel: secondaryPanel(for: display)
            )
        }
        let selectedSecondaryPanel = selectedDisplayID.flatMap { selectedID in
            displays.first(where: { $0.display.id == selectedID }).map(secondaryPanel(for:))
        }

        return PluginPanelDetail(
            primaryControls: [displayNavigation, openSystemSettings],
            secondaryPanel: selectedSecondaryPanel,
            navigationSecondaryPanels: navigationSecondaryPanels
        )
    }

    private func secondaryPanel(for display: PanelDisplay) -> PluginPanelSecondaryPanel {
        let resolutionControl = PluginPanelControl(
            id: "display.\(display.display.id)",
            kind: .selectList,
            options: display.modes.map {
                PluginPanelControlOption(
                    id: String($0.modeId),
                    title: Self.optionTitle(for: $0, localization: localization),
                    subtitle: nil
                )
            },
            selectedOptionID: display.modes.first(where: { $0.isCurrent }).map { String($0.modeId) },
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            isEnabled: true
        )

        return PluginPanelSecondaryPanel(title: display.display.name, controls: [resolutionControl])
    }

    private func handleApplyFailure(
        _ error: DisplayResolutionError,
        displayID: CGDirectDisplayID,
        modeId: Int32
    ) {
        logger.error(
            "apply failed display=\(displayID) modeId=\(modeId) reason=\(error.localizedDescription, privacy: .public)"
        )
        lastErrorMessage = localization.format(
            "error.applyFailedFormat",
            defaultValue: "切换失败：%@",
            error.localizedDescription(localization: localization)
        )
        onStateChange?()
    }
}

private struct PanelDisplay {
    let display: DisplayInfo
    let modes: [DisplayResolutionInfo]
    let allModes: [DisplayResolutionInfo]
}

private struct DisplayResolutionSnapshot {
    let displays: [PanelDisplay]
}
