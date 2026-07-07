import AppKit
import Foundation
@preconcurrency import IOKit.hid
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class MouseEnhancerPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        MouseEnhancerPluginProvider(context: context)
    }
}

@MainActor
private struct MouseEnhancerPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            MouseEnhancerPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

enum MouseEnhancerInputMonitoringAuthorizationStatus {
    case granted
    case denied
    case unknown
}

@MainActor
final class MouseEnhancerPlugin: MacToolsPlugin, PluginPrimaryPanel, AccessibilityPermissionRefreshing, PluginConfigurationPresenting {
    private enum PermissionID {
        static let accessibility = "accessibility"
        static let inputMonitoring = "input-monitoring"
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestConfigurationPresentation: (() -> Void)?

    let store: MouseEnhancerStore

    private let localization: PluginLocalization
    private let session: any MouseEnhancerSessionManaging
    private let makeMiddleClickSession: @MainActor () -> any MouseEnhancerMiddleClickSessionManaging
    private var middleClickSession: (any MouseEnhancerMiddleClickSessionManaging)?
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool
    private let inputMonitoringAuthorizationStatus: @MainActor () -> MouseEnhancerInputMonitoringAuthorizationStatus
    private let openURL: (URL) -> Void
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MouseEnhancerPlugin"
    )

    private var isAccessibilityGranted: Bool
    private var lastErrorMessage: String?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "mouse-enhancer"),
        session: (any MouseEnhancerSessionManaging)? = nil,
        makeMiddleClickSession: @escaping @MainActor () -> any MouseEnhancerMiddleClickSessionManaging = {
            MouseEnhancerMiddleClickSession()
        },
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        accessibilityTrusted: @escaping @MainActor () -> Bool = MouseEnhancerAccessibilityCheck.isTrusted,
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = MouseEnhancerAccessibilityCheck.requestTrust(prompt:),
        inputMonitoringAuthorizationStatus: @escaping @MainActor () -> MouseEnhancerInputMonitoringAuthorizationStatus = MouseEnhancerPlugin.currentInputMonitoringAuthorizationStatus,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.localization = localization
        self.store = MouseEnhancerStore(storage: context.storage)
        self.session = session ?? MouseEnhancerSession()
        self.makeMiddleClickSession = makeMiddleClickSession
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.inputMonitoringAuthorizationStatus = inputMonitoringAuthorizationStatus
        self.openURL = openURL
        self.isAccessibilityGranted = accessibilityTrusted()
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .keepPresented,
            buttonTitle: localization.string("panel.button.settings", defaultValue: "设置")
        )
        self.metadata = PluginMetadata(
            id: "mouse-enhancer",
            title: localization.string("metadata.title", defaultValue: "鼠标增强"),
            iconName: "computermouse",
            iconTint: Color(nsColor: .systemTeal),
            order: 56,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "增强鼠标与触控板滚动控制"
            )
        )
    }

    func activate(context: PluginRuntimeContext) {
        refreshAccessibilityPermission()
        applyCurrentConfiguration()
        applyMiddleClickConfiguration()
    }

    func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup else {
            return
        }

        session.deactivate()
        stopMiddleClickSession()
        onStateChange?()
    }

    func refresh() {
        refreshAccessibilityPermission()
        applyCurrentConfiguration()
        applyMiddleClickConfiguration()
        onStateChange?()
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于监听滚动事件和发送中键点击。"
                )
            ),
            PluginPermissionRequirement(
                id: PermissionID.inputMonitoring,
                kind: .inputMonitoring,
                title: localization.string("permission.inputMonitoring.title", defaultValue: "输入监控"),
                description: localization.string(
                    "permission.inputMonitoring.description",
                    defaultValue: "用于区分鼠标滚轮和触控板手势。"
                )
            ),
        ]
    }

    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [weak self] _ in
            guard let self else {
                return AnyView(EmptyView())
            }

            return AnyView(
                MouseEnhancerSettingsView(
                    store: self.store,
                    localization: self.localization,
                    onChange: { [weak self] in
                        self?.configurationDidChange()
                    }
                )
            )
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case .invokeAction(controlID: _):
            requestConfigurationPresentation?()
        default:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case PermissionID.accessibility:
            return PluginPermissionState(
                isGranted: isAccessibilityGranted,
                footnote: isAccessibilityGranted
                    ? nil
                    : localization.string(
                        "permission.accessibility.footnote",
                        defaultValue: "系统设置 → 隐私与安全性 → 辅助功能，允许 MacTools。"
                    )
            )
        case PermissionID.inputMonitoring:
            return inputMonitoringPermissionState
        default:
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case PermissionID.accessibility:
            handleAccessibilityPermissionAction()
        case PermissionID.inputMonitoring:
            openInputMonitoringSettings()
        default:
            return
        }
    }

    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    func refreshAccessibilityPermission() {
        let previous = isAccessibilityGranted
        isAccessibilityGranted = accessibilityTrusted()

        if previous && !isAccessibilityGranted {
            session.deactivate()
            stopMiddleClickSession()
            lastErrorMessage = localization.string(
                "error.accessibilityRevoked",
                defaultValue: "辅助功能权限已关闭，鼠标增强已暂停。"
            )
        } else if !previous && isAccessibilityGranted {
            lastErrorMessage = nil
            applyCurrentConfiguration()
            applyMiddleClickConfiguration()
        }

        if previous != isAccessibilityGranted {
            onStateChange?()
        }
    }

    private func ensureAccessibilityPermissionForActiveConfiguration() -> Bool {
        lastErrorMessage = nil

        let configuration = store.configuration
        guard configuration.shouldInstallEventTap || configuration.middleClickEnabled else {
            return true
        }

        isAccessibilityGranted = accessibilityTrusted()
        if !isAccessibilityGranted {
            isAccessibilityGranted = requestAccessibilityTrust(true)
        }

        guard isAccessibilityGranted else {
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "鼠标增强需要辅助功能权限，请先前往设置完成授权。"
            )
            requestPermissionGuidance?(PermissionID.accessibility)
            return false
        }

        return true
    }

    func configurationDidChange() {
        lastErrorMessage = nil
        guard ensureAccessibilityPermissionForActiveConfiguration() else {
            session.deactivate()
            stopMiddleClickSession()
            onStateChange?()
            return
        }

        applyCurrentConfiguration()
        applyMiddleClickConfiguration()
        onStateChange?()
    }

    private func applyCurrentConfiguration() {
        let configuration = store.configuration

        guard configuration.shouldInstallEventTap else {
            session.deactivate()
            return
        }

        guard isAccessibilityGranted else {
            session.deactivate()
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "鼠标增强需要辅助功能权限，请先前往设置完成授权。"
            )
            return
        }

        if session.state.scrollTapInstalled {
            session.update(configuration: configuration)
            return
        }

        guard session.activate(configuration: configuration) else {
            lastErrorMessage = localization.string(
                "error.tapUnavailable",
                defaultValue: "无法启动滚动事件监听，请确认辅助功能授权后重试。"
            )
            logger.error("failed to install scroll event tap")
            return
        }
    }

    private func applyMiddleClickConfiguration() {
        let configuration = store.configuration

        guard configuration.middleClickEnabled else {
            stopMiddleClickSession()
            return
        }

        guard isAccessibilityGranted else {
            stopMiddleClickSession()
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "鼠标增强需要辅助功能权限，请先前往设置完成授权。"
            )
            return
        }

        if let middleClickSession {
            middleClickSession.requiredFingerCount = configuration.middleClickFingerCount
            return
        }

        let newSession = makeMiddleClickSession()
        newSession.requiredFingerCount = configuration.middleClickFingerCount
        newSession.activate()
        middleClickSession = newSession
        logger.info("middle click enabled requiredFingerCount=\(configuration.middleClickFingerCount, privacy: .public)")
    }

    private func stopMiddleClickSession() {
        middleClickSession?.deactivate()
        middleClickSession = nil
    }

    private func handleAccessibilityPermissionAction() {
        if isAccessibilityGranted {
            refreshAccessibilityPermission()
            return
        }

        isAccessibilityGranted = requestAccessibilityTrust(true)
        if isAccessibilityGranted {
            lastErrorMessage = nil
            applyCurrentConfiguration()
            applyMiddleClickConfiguration()
        } else {
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "鼠标增强需要辅助功能权限，请先前往设置完成授权。"
            )
        }
        onStateChange?()
    }

    private var panelSubtitle: String {
        let configuration = store.configuration

        if session.state.scrollTapInstalled {
            return localization.format(
                "panel.subtitle.enabledFormat",
                defaultValue: "已开启 · %@ · %@",
                deviceSummary(configuration),
                axisSummary(configuration)
            )
        }

        if activeConfigurationNeedsAccessibility(configuration), !isAccessibilityGranted {
            return localization.string("panel.subtitle.needsAccessibility", defaultValue: "启用前需要辅助功能授权")
        }

        if !configuration.shouldInstallEventTap, !configuration.middleClickEnabled {
            return localization.string("panel.subtitle.off", defaultValue: "未启用增强功能")
        }

        if configuration.middleClickEnabled, !configuration.shouldInstallEventTap {
            return localization.format(
                "panel.subtitle.middleClickEnabledFormat",
                defaultValue: "模拟中键 · %d指",
                configuration.middleClickFingerCount
            )
        }

        return metadata.defaultDescription
    }

    private func deviceSummary(_ configuration: MouseEnhancerConfiguration) -> String {
        switch (configuration.hasMouseReversing, configuration.hasTrackpadReversing) {
        case (true, true):
            return localization.string("summary.device.all", defaultValue: "鼠标和触控板")
        case (true, false):
            return localization.string("summary.device.mouse", defaultValue: "鼠标")
        case (false, true):
            return localization.string("summary.device.trackpad", defaultValue: "触控板")
        case (false, false):
            return localization.string("summary.device.none", defaultValue: "未选设备")
        }
    }

    private func axisSummary(_ configuration: MouseEnhancerConfiguration) -> String {
        let hasVertical = configuration.reverseMouseVertical || configuration.reverseTrackpadVertical
        let hasHorizontal = configuration.reverseMouseHorizontal || configuration.reverseTrackpadHorizontal

        switch (hasVertical, hasHorizontal) {
        case (true, true):
            return localization.string("summary.axis.all", defaultValue: "水平和垂直")
        case (true, false):
            return localization.string("summary.axis.vertical", defaultValue: "垂直")
        case (false, true):
            return localization.string("summary.axis.horizontal", defaultValue: "水平")
        case (false, false):
            return localization.string("summary.axis.none", defaultValue: "未选方向")
        }
    }

    private func activeConfigurationNeedsAccessibility(_ configuration: MouseEnhancerConfiguration) -> Bool {
        configuration.shouldInstallEventTap || configuration.middleClickEnabled
    }

    private var inputMonitoringPermissionState: PluginPermissionState {
        switch inputMonitoringAuthorizationStatus() {
        case .granted:
            return PluginPermissionState(
                isGranted: true,
                footnote: localization.string(
                    "permission.inputMonitoring.granted",
                    defaultValue: "已允许，可提升设备识别准确性。"
                )
            )
        case .denied, .unknown:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.inputMonitoring.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 输入监控，允许 MacTools。"
                )
            )
        }
    }

    private static func currentInputMonitoringAuthorizationStatus() -> MouseEnhancerInputMonitoringAuthorizationStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        case kIOHIDAccessTypeUnknown:
            return .unknown
        default:
            return .unknown
        }
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }

        openURL(url)
    }
}
