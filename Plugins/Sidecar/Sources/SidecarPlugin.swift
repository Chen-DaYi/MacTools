import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class SidecarPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        SidecarPluginProvider(context: context)
    }
}

@MainActor
private struct SidecarPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [SidecarPlugin(
            localization: PluginLocalization(bundle: context.resourceBundle),
            preferences: SidecarPreferencesStore(storage: context.storage)
        )]
    }
}

private enum ControlID {
    static let connectPrefix = "sidecar-connect."
    static let disconnectPrefix = "sidecar-disconnect."
}

private enum SidecarShortcutID {
    static let devicePrefix = "device."
    static let connectFirstAvailable = "connect-first-available"
    static let disconnectAll = "disconnect-all"

    static func device(_ deviceID: String) -> String {
        devicePrefix + deviceID
    }

}

private struct SidecarSwitchRequest {
    let source: SidecarDevice
    let target: SidecarDevice
    let targetAction: SidecarOperationKind
}

@MainActor
final class SidecarPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginPanelSurfaceLifecycleHandling,
    PluginPortablePreferencesProviding, PluginShortcutBindingChangeHandling {
    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let service: any SidecarServicing
    private let localization: PluginLocalization
    private let preferences: SidecarPreferencesStore
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SidecarPlugin"
    )
    private var devices: [SidecarDevice] = []
    private var isExpanded = false
    private var operation: SidecarOperationState?
    private var operationDeviceID: String?
    private var operationToken: UUID?
    private var terminalFeedbackDate: Date?
    private var timeoutTask: Task<Void, Never>?
    private var operationFeedbackTask: Task<Void, Never>?
    private var deviceRefreshTask: Task<Void, Never>?
    private var followUpRefreshTask: Task<Void, Never>?
    private var switchRequest: SidecarSwitchRequest?
    private var disconnectAllRemainingCount = 0
    private var disconnectAllErrorMessage: String?
    private var isActive = false
    private var isPrimaryPanelVisible = false
    private let operationTimeoutNanoseconds: UInt64
    private let operationFeedbackNanoseconds: UInt64
    private let terminalFeedbackExpiration: TimeInterval
    private let initialDeviceRefreshDelayNanoseconds: UInt64
    private let deviceRefreshIntervalNanoseconds: UInt64

    init(
        service: any SidecarServicing = SidecarCoreService(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        preferences: SidecarPreferencesStore? = nil,
        operationTimeoutNanoseconds: UInt64 = 15_000_000_000,
        operationFeedbackNanoseconds: UInt64 = 4_000_000_000,
        terminalFeedbackExpiration: TimeInterval = 30,
        initialDeviceRefreshDelayNanoseconds: UInt64 = 750_000_000,
        deviceRefreshIntervalNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.service = service
        self.localization = localization
        self.preferences = preferences ?? SidecarPreferencesStore(
            storage: UserDefaultsPluginStorage(pluginID: "sidecar")
        )
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
        self.operationFeedbackNanoseconds = operationFeedbackNanoseconds
        self.terminalFeedbackExpiration = max(0, terminalFeedbackExpiration)
        self.initialDeviceRefreshDelayNanoseconds = initialDeviceRefreshDelayNanoseconds
        self.deviceRefreshIntervalNanoseconds = deviceRefreshIntervalNanoseconds
        metadata = PluginMetadata(
            id: "sidecar",
            title: localization.string("metadata.title", defaultValue: "Sidecar"),
            iconName: "display",
            iconTint: Color(nsColor: .systemIndigo),
            order: 31,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "连接附近可用的 Sidecar 显示器作为扩展显示器"
            )
        )
        service.onDevicesChanged = { [weak self] in
            guard self?.isActive == true else { return }
            self?.refreshDevices(notify: true)
        }
        refreshDevices(notify: false)
        isExpanded = !devices.isEmpty
    }

    deinit {
        timeoutTask?.cancel()
        operationFeedbackTask?.cancel()
        deviceRefreshTask?.cancel()
        followUpRefreshTask?.cancel()
    }

    var primaryPanelState: PluginPanelState {
        switch service.availability {
        case let .unsupported(reason):
            return PluginPanelState(
                subtitle: localization.string("panel.subtitle.unsupported", defaultValue: "此系统不支持 Sidecar 控制"),
                isOn: false,
                isExpanded: false,
                isEnabled: false,
                isVisible: true,
                detail: nil,
                errorMessage: unsupportedMessage(for: reason)
            )
        case .available:
            return PluginPanelState(
                subtitle: subtitle,
                isOn: false,
                isExpanded: isExpanded,
                isEnabled: true,
                isVisible: true,
                detail: isExpanded ? buildDetail() : nil,
                errorMessage: operationErrorMessage
            )
        }
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] {
        let connectFirstAvailableTitle = localization.string(
            "settings.connectFirstAvailable.title",
            defaultValue: "连接第一个可用显示器"
        )
        let disconnectAllTitle = localization.string(
            "settings.disconnectAll.title",
            defaultValue: "断开所有已连接设备"
        )
        let globalDefinitions = [
            shortcutDefinition(
                id: SidecarShortcutID.connectFirstAvailable,
                title: connectFirstAvailableTitle,
                description: localization.string(
                    "settings.connectFirstAvailable.description",
                    defaultValue: "按上方的可用显示器优先级连接第一个设备。"
                ),
                defaultBinding: preferences.connectFirstAvailableShortcut,
                groupID: "global",
                groupTitle: localization.string("settings.globalShortcuts.title", defaultValue: "Sidecar 快捷键"),
                settingsControlTitle: connectFirstAvailableTitle
            ),
            shortcutDefinition(
                id: SidecarShortcutID.disconnectAll,
                title: disconnectAllTitle,
                description: localization.string(
                    "settings.disconnectAll.description",
                    defaultValue: "只会断开 Sidecar 明确报告为已连接的显示器。"
                ),
                defaultBinding: preferences.disconnectAllShortcut,
                groupID: "global",
                groupTitle: localization.string("settings.globalShortcuts.title", defaultValue: "Sidecar 快捷键"),
                settingsControlTitle: disconnectAllTitle
            )
        ]

        let deviceDefinitions = preferences.devices
            .filter { preference in
                devices.contains(where: { $0.id == preference.id }) || preference.hasCustomConfiguration
            }
            .map { preference in
                shortcutDefinition(
                    id: SidecarShortcutID.device(preference.id),
                    title: preference.name,
                    description: localization.string(
                        "settings.shortcutAction.help",
                        defaultValue: "此设备快捷键执行的操作"
                    ),
                    defaultBinding: preference.shortcut,
                    groupID: "devices",
                    groupTitle: localization.string("settings.devices.title", defaultValue: "Sidecar 设备")
                )
            }

        return globalDefinitions + deviceDefinitions
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "device-settings",
                    title: localization.string("settings.devices.title", defaultValue: "Sidecar 设备"),
                    systemImage: "display.2",
                    presentation: .edgeToEdge,
                    embeddedShortcutGroupIDs: ["devices"]
                ) { [weak self] context in
                    if let self {
                        SidecarSettingsView(
                            store: self.preferences,
                            liveDevices: self.devices,
                            localization: self.localization,
                            settingsContext: context,
                            onRefresh: { [weak self] in self?.refresh() },
                            onUpdate: { [weak self] in
                                self?.onStateChange?()
                            }
                        )
                    } else {
                        EmptyView()
                    }
                }
                .headerAccessory { [weak self] _ in
                    Button {
                        self?.refresh()
                    } label: {
                        Label(
                            self?.localization.string("settings.refresh", defaultValue: "刷新") ?? "刷新",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            ]
        )
    }

    func activate(context: PluginRuntimeContext) {
        isActive = true
        refreshDevices(notify: false)
        scheduleDeviceRefreshIfNeeded()
    }

    func deactivate(reason _: PluginDeactivationReason) {
        isActive = false
        isPrimaryPanelVisible = false
        cancelDeviceRefresh()
        followUpRefreshTask?.cancel()
        followUpRefreshTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        operationFeedbackTask?.cancel()
        operationFeedbackTask = nil
        operation = nil
        operationDeviceID = nil
        operationToken = nil
        terminalFeedbackDate = nil
        switchRequest = nil
    }

    func refresh() {
        refreshDevices(notify: true)
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            if expanded {
                refreshDevices(notify: false)
            }
            onStateChange?()
        case .setNavigationSelection, .clearNavigationSelection:
            return
        case let .invokeAction(controlID):
            handleOperationAction(controlID)
        case .setSwitch, .setSelection, .setDate, .setSlider:
            return
        }
    }

    func panelSurfaceDidBecomeVisible(_ surface: PluginPanelSurface) {
        guard surface == .primary else { return }
        isPrimaryPanelVisible = true
        clearExpiredTerminalFeedbackIfNeeded()
        guard isActive else { return }
        refreshDevices(notify: true)
        scheduleDeviceRefreshIfNeeded()
    }

    func panelSurfaceDidBecomeHidden(_ surface: PluginPanelSurface) {
        guard surface == .primary else { return }
        isPrimaryPanelVisible = false
        cancelDeviceRefresh()
        clearTerminalFeedback()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {
        handleConfiguredShortcut(id: id)
    }

    func shortcutBindingDidChange(id: String, binding: ShortcutBinding?) {
        if id.hasPrefix(SidecarShortcutID.devicePrefix) {
            preferences.updateShortcutConfiguration(
                binding != nil,
                for: String(id.dropFirst(SidecarShortcutID.devicePrefix.count))
            )
        }
        onStateChange?()
    }

    func makePortablePreferencesBackup() -> Data? {
        preferences.portablePreferencesData()
    }

    func restorePortablePreferences(from data: Data) {
        preferences.restorePortablePreferences(from: data)
        refreshDevices(notify: false)
        onStateChange?()
    }

    private var subtitle: String {
        if let operation, operation.isPending {
            return operationSubtitle(operation)
        }
        let deviceSummary: String
        if devices.isEmpty {
            deviceSummary = localization.string("panel.subtitle.noDevices", defaultValue: "未发现可连接的 Sidecar 显示器")
        } else {
            let connectedCount = devices.filter { $0.connectionState == .connected }.count
            let availableCount = devices.filter { $0.connectionState == .disconnected }.count
            let unknownCount = devices.filter { $0.connectionState == .unknown }.count
            if unknownCount > 0 {
                deviceSummary = localization.format(
                    "panel.subtitle.unknownCount",
                    defaultValue: "%d 台 Sidecar 显示器的连接状态不可用",
                    unknownCount
                )
            } else if connectedCount > 0, availableCount > 0 {
                deviceSummary = localization.format(
                    "panel.subtitle.connectedAndAvailableCount",
                    defaultValue: "%d 台已连接 · %d 台可连接",
                    connectedCount,
                    availableCount
                )
            } else if connectedCount > 0 {
                deviceSummary = localization.format(
                    "panel.subtitle.connectedCount",
                    defaultValue: "%d 台显示器已通过 Sidecar 连接",
                    connectedCount
                )
            } else {
                deviceSummary = localization.format(
                    "panel.subtitle.deviceCount",
                    defaultValue: "%d 台可连接的 Sidecar 显示器",
                    availableCount
                )
            }
        }
        guard !service.isMinimumTestedSystem else { return deviceSummary }
        return localization.format(
            "panel.subtitle.untestedSystem",
            defaultValue: "%@ · 未在 macOS 14.2 之前测试",
            deviceSummary
        )
    }

    private var operationErrorMessage: String? {
        guard let operation else { return nil }
        switch operation {
        case let .failed(_, _, message):
            return message
        case .timedOut:
            return localization.string("panel.error.timeout", defaultValue: "操作超时，请检查目标设备、线缆和网络后重试")
        case .pending, .succeeded:
            return nil
        }
    }

    private var isOperationPending: Bool {
        if case .pending = operation { return true }
        return false
    }

    private func refreshDevices(notify: Bool) {
        let updatedDevices = service.reachableDevices().map(localizedDevice)
        let previousDevices = devices
        let previousPreferences = preferences.devices
        devices = updatedDevices
        preferences.reconcile(with: updatedDevices)
        let changed = updatedDevices != previousDevices || preferences.devices != previousPreferences
        if let operationDeviceID, !devices.contains(where: { $0.id == operationDeviceID }) {
            operation = nil
            self.operationDeviceID = nil
            operationToken = nil
            terminalFeedbackDate = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            operationFeedbackTask?.cancel()
            operationFeedbackTask = nil
            switchRequest = nil
        }
        clearCompletedOperationIfSnapshotConfirmsIt()
        if notify && changed {
            onStateChange?()
        }
    }

    private func scheduleDeviceRefreshIfNeeded() {
        guard isActive, isPrimaryPanelVisible, deviceRefreshTask == nil else { return }
        deviceRefreshTask = Task { @MainActor [weak self] in
            guard let initialRefreshDelayNanoseconds = self?.initialDeviceRefreshDelayNanoseconds else {
                return
            }
            var refreshDelayNanoseconds = initialRefreshDelayNanoseconds
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: refreshDelayNanoseconds)
                } catch {
                    return
                }
                guard let self else { return }
                guard self.isActive, self.isPrimaryPanelVisible else { return }
                self.refreshDevices(notify: true)
                refreshDelayNanoseconds = self.deviceRefreshIntervalNanoseconds
            }
        }
    }

    private func cancelDeviceRefresh() {
        deviceRefreshTask?.cancel()
        deviceRefreshTask = nil
    }

    private func clearCompletedOperationIfSnapshotConfirmsIt() {
        guard let operation, let operationDeviceID else { return }
        guard let device = devices.first(where: { $0.id == operationDeviceID }) else { return }

        let isConfirmed: Bool
        switch operation {
        case let .succeeded(action, _):
            switch action {
            case .connect, .wiredConnect:
                isConfirmed = device.connectionState == .connected
            case .disconnect:
                isConfirmed = device.connectionState == .disconnected
            }
        case .pending, .failed, .timedOut:
            isConfirmed = false
        }

        guard isConfirmed else { return }
        self.operation = nil
        self.operationDeviceID = nil
        terminalFeedbackDate = nil
        switchRequest = nil
        operationFeedbackTask?.cancel()
        operationFeedbackTask = nil
    }

    private func buildDetail() -> PluginPanelDetail {
        guard !devices.isEmpty else {
            return PluginPanelDetail(controls: [])
        }

        var controls: [PluginPanelControl] = []
        for (index, device) in orderedDevices.enumerated() {
            let previousDevice = index > 0 ? orderedDevices[index - 1] : nil
            let sectionTitle = sectionTitle(for: device, after: previousDevice)
            controls.append(contentsOf: actionControls(
                for: device,
                sectionTitle: sectionTitle,
                showsLeadingDivider: false
            ))
        }

        return PluginPanelDetail(
            primaryControls: controls,
            secondaryPanel: nil
        )
    }

    private var orderedDevices: [SidecarDevice] {
        devices.sorted { lhs, rhs in
            let lhsRank = deviceSortRank(lhs)
            let rhsRank = deviceSortRank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            let lhsPriority = preferences.priorityIndex(for: lhs.id)
            let rhsPriority = preferences.priorityIndex(for: rhs.id)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func deviceSortRank(_ device: SidecarDevice) -> Int {
        SidecarDeviceOrdering.rank(for: device.connectionState)
    }

    private func sectionTitle(for device: SidecarDevice, after previousDevice: SidecarDevice?) -> String? {
        let isConnected = device.connectionState == .connected
        let previousWasConnected = previousDevice?.connectionState == .connected
        guard previousDevice == nil || isConnected != previousWasConnected else { return nil }

        if isConnected {
            return localization.string("panel.section.connected", defaultValue: "已连接")
        }
        return localization.string("panel.section.available", defaultValue: "可用的 Sidecar 显示器")
    }

    private func actionControls(
        for device: SidecarDevice,
        sectionTitle: String?,
        showsLeadingDivider: Bool
    ) -> [PluginPanelControl] {
        let isEnabled = !isOperationPending
        switch device.connectionState {
        case .connected:
            return [
                actionControl(
                    id: ControlID.disconnectPrefix + device.id,
                    title: deviceActionTitle(for: device, action: .disconnect),
                    icon: actionIcon(for: device, defaultIcon: "checkmark.circle.fill"),
                    sectionTitle: sectionTitle,
                    showsLeadingDivider: showsLeadingDivider,
                    isEnabled: isEnabled
                )
            ]
        case .disconnected:
            return [
                actionControl(
                    id: ControlID.connectPrefix + device.id,
                    title: deviceActionTitle(for: device, action: connectAction(for: device)),
                    icon: actionIcon(for: device, defaultIcon: "circle"),
                    sectionTitle: sectionTitle,
                    showsLeadingDivider: showsLeadingDivider,
                    isEnabled: isEnabled
                )
            ]
        case .unknown:
            return [
                actionControl(
                    id: "sidecar-state-unknown." + device.id,
                    title: localization.format(
                        "panel.action.stateUnknown",
                        defaultValue: "%@ · Connection state unavailable",
                        device.name
                    ),
                    icon: "questionmark.circle",
                    sectionTitle: sectionTitle,
                    showsLeadingDivider: showsLeadingDivider,
                    isEnabled: false
                )
            ]
        }
    }

    private func deviceActionTitle(for device: SidecarDevice, action: SidecarOperationKind) -> String {
        if let operation = operation(for: device) {
            return operationSubtitle(operation)
        }

        let actionTitle: String
        switch action {
        case .connect:
            actionTitle = shouldSwitch(to: device)
                ? localization.string("panel.action.switch", defaultValue: "切换")
                : localization.string("panel.action.connect", defaultValue: "连接")
        case .disconnect:
            actionTitle = localization.string("panel.action.disconnect", defaultValue: "断开连接")
        case .wiredConnect:
            actionTitle = shouldSwitch(to: device)
                ? localization.string("panel.action.switch", defaultValue: "切换")
                : localization.string("panel.action.wiredConnect", defaultValue: "仅通过有线连接")
        }
        return "\(device.name) · \(actionTitle)"
    }

    private func shouldSwitch(to device: SidecarDevice) -> Bool {
        guard device.connectionState == .disconnected else { return false }
        return devices.filter { $0.connectionState == .connected }.count == 1
    }

    private func actionIcon(for device: SidecarDevice, defaultIcon: String) -> String {
        operation(for: device) == nil ? defaultIcon : deviceStatusIcon(for: device)
    }

    private func deviceSubtitle(for device: SidecarDevice) -> String {
        if let operation = operation(for: device) {
            return operationSubtitle(operation)
        }

        switch device.connectionState {
        case .connected:
            return localization.string("panel.device.subtitle.connected", defaultValue: "已通过 Sidecar 连接")
        case .disconnected, .unknown:
            return localization.string("panel.device.subtitle", defaultValue: "可请求 Sidecar 连接")
        }
    }

    private func deviceStatusIcon(for device: SidecarDevice) -> String {
        if let operation = operation(for: device) {
            switch operation {
            case .pending:
                return "arrow.triangle.2.circlepath.circle.fill"
            case .succeeded:
                return "checkmark.circle"
            case .failed, .timedOut:
                return "exclamationmark.circle.fill"
            }
        }

        return device.connectionState == .connected ? "checkmark.circle.fill" : "circle"
    }

    private func operation(for device: SidecarDevice) -> SidecarOperationState? {
        operationDeviceID == device.id ? operation : nil
    }

    private func actionControl(
        id: String,
        title: String,
        icon: String,
        sectionTitle: String?,
        showsLeadingDivider: Bool,
        isEnabled: Bool
    ) -> PluginPanelControl {
        PluginPanelControl(
            id: id,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: sectionTitle,
            actionTitle: title,
            actionIconSystemName: icon,
            actionBehavior: .keepPresented,
            showsLeadingDivider: showsLeadingDivider,
            isEnabled: isEnabled
        )
    }

    private func handleOperationAction(_ controlID: String) {
        guard !isOperationPending else { return }
        let action: SidecarOperationKind
        let deviceID: String
        if controlID.hasPrefix(ControlID.connectPrefix) {
            guard let device = devices.first(where: { $0.id == String(controlID.dropFirst(ControlID.connectPrefix.count)) }) else {
                return
            }
            connectOrSwitch(to: device)
            return
        } else if controlID.hasPrefix(ControlID.disconnectPrefix) {
            action = .disconnect
            deviceID = String(controlID.dropFirst(ControlID.disconnectPrefix.count))
        } else {
            return
        }

        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        start(action: action, for: device)
    }

    private func connectAction(for device: SidecarDevice) -> SidecarOperationKind {
        preferences.preference(for: device.id)?.transport == .wiredOnly ? .wiredConnect : .connect
    }

    private func supports(_ action: SidecarOperationKind) -> Bool {
        action != .wiredConnect || service.supportsWiredOnlyConnections
    }

    private func presentUnsupportedAction(_ action: SidecarOperationKind, for device: SidecarDevice) {
        presentShortcutFailure(
            action: action,
            deviceName: device.name,
            deviceID: device.id,
            message: localizedErrorMessage(for: .operationUnavailable)
        )
    }

    private func handleConfiguredShortcut(id: String) {
        guard isActive, !isOperationPending else { return }
        refreshDevices(notify: false)

        if id == SidecarShortcutID.connectFirstAvailable {
            connectFirstAvailableDevice()
            return
        }

        if id == SidecarShortcutID.disconnectAll {
            disconnectAllConnectedDevices()
            return
        }
        guard id.hasPrefix(SidecarShortcutID.devicePrefix) else { return }
        let deviceID = String(id.dropFirst(SidecarShortcutID.devicePrefix.count))
        guard let preference = preferences.preference(for: deviceID) else { return }
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            presentShortcutFailure(
                action: preference.shortcutAction == .disconnect ? .disconnect : .connect,
                deviceName: preference.name,
                deviceID: nil,
                message: localizedErrorMessage(for: .deviceUnavailable)
            )
            return
        }

        switch preference.shortcutAction {
        case .connect:
            connectOrSwitch(to: device)
        case .disconnect:
            guard device.connectionState == .connected else {
                presentShortcutFailure(
                    action: .disconnect,
                    deviceName: device.name,
                    deviceID: device.id,
                    message: localization.string(
                        "shortcut.error.notConnected",
                        defaultValue: "该 Sidecar 显示器当前未连接"
                    )
                )
                return
            }
            start(action: .disconnect, for: device)
        case .toggle:
            switch device.connectionState {
            case .connected:
                start(action: .disconnect, for: device)
            case .disconnected:
                start(action: connectAction(for: device), for: device)
            case .unknown:
                presentShortcutFailure(
                    action: .connect,
                    deviceName: device.name,
                    deviceID: device.id,
                    message: localization.string(
                        "shortcut.error.stateUnknown",
                        defaultValue: "无法确定此 Sidecar 显示器的连接状态"
                    )
                )
            }
        }
    }

    private func presentShortcutFailure(
        action: SidecarOperationKind,
        deviceName: String,
        deviceID: String?,
        message: String
    ) {
        operationFeedbackTask?.cancel()
        operationFeedbackTask = nil
        operation = .failed(action, deviceName: deviceName, message: message)
        operationDeviceID = deviceID
        markTerminalFeedback()
        scheduleOperationFeedbackDismissal()
        onStateChange?()
    }

    private func disconnectAllConnectedDevices() {
        let connectedDevices = devices.filter { $0.connectionState == .connected }
        guard !connectedDevices.isEmpty else {
            presentShortcutFailure(
                action: .disconnect,
                deviceName: localization.string("shortcut.disconnectAll.target", defaultValue: "所有已连接的 Sidecar 显示器"),
                deviceID: nil,
                message: localization.string("shortcut.error.noConnectedDevices", defaultValue: "没有已连接的 Sidecar 显示器可断开")
            )
            return
        }

        let token = UUID()
        operationToken = token
        operation = .pending(
            .disconnect,
            deviceName: localization.string("shortcut.disconnectAll.target", defaultValue: "所有已连接的 Sidecar 显示器")
        )
        operationDeviceID = nil
        disconnectAllRemainingCount = connectedDevices.count
        disconnectAllErrorMessage = nil
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.operationTimeoutNanoseconds ?? 0)
            } catch {
                return
            }
            guard self?.operationToken == token else { return }
            self?.operationToken = nil
            self?.timeoutTask = nil
            self?.operation = .timedOut(
                .disconnect,
                deviceName: self?.localization.string("shortcut.disconnectAll.target", defaultValue: "所有已连接的 Sidecar 显示器") ?? ""
            )
            self?.markTerminalFeedback()
            self?.scheduleOperationFeedbackDismissal()
            self?.onStateChange?()
        }
        onStateChange?()

        for device in connectedDevices {
            service.disconnect(from: device) { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.finishDisconnectAll(result: result, for: token)
                }
            }
        }
    }

    private func connectFirstAvailableDevice() {
        guard !devices.contains(where: { $0.connectionState == .connected }) else {
            presentShortcutFailure(
                action: .connect,
                deviceName: localization.string(
                    "shortcut.connectFirstAvailable.target",
                    defaultValue: "第一个可用的 Sidecar 显示器"
                ),
                deviceID: nil,
                message: localization.string(
                    "shortcut.error.displayAlreadyConnected",
                    defaultValue: "已有 Sidecar 显示器连接；请使用设备的“切换”操作"
                )
            )
            return
        }
        guard let device = orderedDevices.first(where: { $0.connectionState == .disconnected }) else {
            presentShortcutFailure(
                action: .connect,
                deviceName: localization.string(
                    "shortcut.connectFirstAvailable.target",
                    defaultValue: "第一个可连接的 Sidecar 显示器"
                ),
                deviceID: nil,
                message: localization.string(
                    "shortcut.error.noAvailableDevices",
                    defaultValue: "没有可连接的 Sidecar 显示器"
                )
            )
            return
        }
        let action = connectAction(for: device)
        guard supports(action) else {
            presentUnsupportedAction(action, for: device)
            return
        }
        start(action: action, for: device)
    }

    private func connectOrSwitch(to target: SidecarDevice) {
        let targetAction = connectAction(for: target)
        guard supports(targetAction) else {
            presentUnsupportedAction(targetAction, for: target)
            return
        }
        let connectedDevices = devices.filter { $0.connectionState == .connected }
        guard let source = connectedDevices.first else {
            start(action: targetAction, for: target)
            return
        }
        guard connectedDevices.count == 1, source.id != target.id else {
            return
        }
        switchRequest = SidecarSwitchRequest(
            source: source,
            target: target,
            targetAction: targetAction
        )
        startSwitchDisconnect(from: source)
    }

    private func startSwitchDisconnect(from source: SidecarDevice) {
        let token = beginOperation(action: .disconnect, for: source)
        service.disconnect(from: source) { [weak self] result in
            self?.finishSwitchDisconnect(result: result, for: token)
        }
    }

    private func finishSwitchDisconnect(
        result: Result<Void, SidecarServiceError>,
        for token: UUID
    ) {
        guard operationToken == token, let switchRequest else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        operationToken = nil

        switch result {
        case .success:
            logger.info("Sidecar switch disconnected source=\(switchRequest.source.name, privacy: .public)")
            startSwitchConnect(switchRequest)
        case .failure:
            operation = .failed(
                .connect,
                deviceName: switchRequest.target.name,
                message: localization.format(
                    "panel.error.switchDisconnectFailed",
                    defaultValue: "无法断开 %@，因此无法切换到 %@",
                    switchRequest.source.name,
                    switchRequest.target.name
                )
            )
            operationDeviceID = switchRequest.target.id
            markTerminalFeedback()
            scheduleOperationFeedbackDismissal()
            onStateChange?()
        }
    }

    private func startSwitchConnect(_ request: SidecarSwitchRequest) {
        let token = beginOperation(action: request.targetAction, for: request.target)
        let completion: (Result<Void, SidecarServiceError>) -> Void = { [weak self] result in
            self?.finish(result: result, for: token, action: request.targetAction, device: request.target)
        }
        switch request.targetAction {
        case .connect:
            service.connect(to: request.target, wiredOnly: false, completion: completion)
        case .wiredConnect:
            service.connect(to: request.target, wiredOnly: true, completion: completion)
        case .disconnect:
            return
        }
    }

    private func finishDisconnectAll(result: Result<Void, SidecarServiceError>, for token: UUID) {
        guard operationToken == token else { return }
        disconnectAllRemainingCount -= 1
        if case let .failure(error) = result, disconnectAllErrorMessage == nil {
            disconnectAllErrorMessage = localizedErrorMessage(for: error)
        }
        guard disconnectAllRemainingCount == 0 else { return }

        timeoutTask?.cancel()
        timeoutTask = nil
        operationToken = nil
        let target = localization.string("shortcut.disconnectAll.target", defaultValue: "所有已连接的 Sidecar 显示器")
        if let disconnectAllErrorMessage {
            operation = .failed(.disconnect, deviceName: target, message: disconnectAllErrorMessage)
            self.disconnectAllErrorMessage = nil
        } else {
            operation = .succeeded(.disconnect, deviceName: target)
        }
        markTerminalFeedback()
        refreshDevices(notify: false)
        scheduleFollowUpRefresh()
        scheduleOperationFeedbackDismissal()
        onStateChange?()
    }

    private func start(action: SidecarOperationKind, for device: SidecarDevice) {
        guard supports(action) else {
            presentUnsupportedAction(action, for: device)
            return
        }
        let token = beginOperation(action: action, for: device)
        let completion: (Result<Void, SidecarServiceError>) -> Void = { [weak self] result in
            self?.finish(result: result, for: token, action: action, device: device)
        }
        switch action {
        case .connect:
            service.connect(to: device, wiredOnly: false, completion: completion)
        case .wiredConnect:
            service.connect(to: device, wiredOnly: true, completion: completion)
        case .disconnect:
            service.disconnect(from: device, completion: completion)
        }
    }

    private func beginOperation(action: SidecarOperationKind, for device: SidecarDevice) -> UUID {
        let token = UUID()
        operationToken = token
        operation = .pending(action, deviceName: device.name)
        operationDeviceID = device.id
        terminalFeedbackDate = nil
        timeoutTask?.cancel()
        operationFeedbackTask?.cancel()
        operationFeedbackTask = nil
        let timeoutNanoseconds = operationTimeoutNanoseconds
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self?.finishTimeout(for: token, action: action, device: device)
        }
        onStateChange?()
        return token
    }

    private func finish(
        result: Result<Void, SidecarServiceError>,
        for token: UUID,
        action: SidecarOperationKind,
        device: SidecarDevice
    ) {
        guard operationToken == token else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        operationToken = nil
        switch result {
        case .success:
            operation = .succeeded(action, deviceName: device.name)
            logger.info("Sidecar operation completed action=\(String(describing: action), privacy: .public) device=\(device.name, privacy: .public)")
        case let .failure(error):
            let underlyingMessage = localizedErrorMessage(for: error)
            let message: String
            if let switchRequest {
                message = localization.format(
                    "panel.error.switchConnectFailed",
                    defaultValue: "已断开 %@，但无法连接 %@：%@",
                    switchRequest.source.name,
                    switchRequest.target.name,
                    underlyingMessage
                )
            } else {
                message = underlyingMessage
            }
            operation = .failed(action, deviceName: device.name, message: message)
            logger.error("Sidecar operation failed action=\(String(describing: action), privacy: .public) reason=\(message, privacy: .public)")
        }
        markTerminalFeedback()
        refreshDevices(notify: false)
        scheduleFollowUpRefresh()
        if operation != nil {
            scheduleOperationFeedbackDismissal()
        }
        onStateChange?()
    }

    private func finishTimeout(for token: UUID, action: SidecarOperationKind, device: SidecarDevice) {
        guard operationToken == token else { return }
        operationToken = nil
        timeoutTask = nil
        operation = .timedOut(action, deviceName: device.name)
        markTerminalFeedback()
        logger.error("Sidecar operation timed out action=\(String(describing: action), privacy: .public) device=\(device.name, privacy: .public)")
        scheduleOperationFeedbackDismissal()
        onStateChange?()
    }

    private func scheduleOperationFeedbackDismissal() {
        guard case .succeeded = operation else { return }
        operationFeedbackTask?.cancel()
        let feedbackNanoseconds = operationFeedbackNanoseconds
        operationFeedbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: feedbackNanoseconds)
            } catch {
                return
            }
            self?.operation = nil
            self?.operationDeviceID = nil
            self?.terminalFeedbackDate = nil
            self?.switchRequest = nil
            self?.operationFeedbackTask = nil
            self?.onStateChange?()
        }
    }

    private func markTerminalFeedback() {
        terminalFeedbackDate = Date()
    }

    private func clearExpiredTerminalFeedbackIfNeeded() {
        guard let terminalFeedbackDate,
              Date().timeIntervalSince(terminalFeedbackDate) >= terminalFeedbackExpiration
        else {
            return
        }
        clearTerminalFeedback()
    }

    private func clearTerminalFeedback() {
        guard let operation, !operation.isPending else { return }
        operationFeedbackTask?.cancel()
        operationFeedbackTask = nil
        self.operation = nil
        operationDeviceID = nil
        operationToken = nil
        terminalFeedbackDate = nil
        switchRequest = nil
        onStateChange?()
    }

    private func operationSubtitle(_ operation: SidecarOperationState) -> String {
        if let switchRequest {
            return switchOperationSubtitle(operation, request: switchRequest)
        }
        switch operation {
        case let .pending(action, deviceName):
            return localization.format(
                operationKey(prefix: "panel.operation.pending", action: action),
                defaultValue: operationDefaultValue(prefix: "pending", action: action),
                deviceName
            )
        case let .succeeded(action, deviceName):
            return localization.format(
                operationKey(prefix: "panel.operation.succeeded", action: action),
                defaultValue: operationDefaultValue(prefix: "succeeded", action: action),
                deviceName
            )
        case let .failed(action, deviceName, _):
            return localization.format(
                operationKey(prefix: "panel.operation.failed", action: action),
                defaultValue: operationDefaultValue(prefix: "failed", action: action),
                deviceName
            )
        case let .timedOut(action, deviceName):
            return localization.format(
                operationKey(prefix: "panel.operation.timedOut", action: action),
                defaultValue: operationDefaultValue(prefix: "timedOut", action: action),
                deviceName
            )
        }
    }

    private func switchOperationSubtitle(
        _ operation: SidecarOperationState,
        request: SidecarSwitchRequest
    ) -> String {
        let key: String
        let defaultValue: String
        switch operation {
        case .pending:
            key = "panel.operation.pending.switch"
            defaultValue = "正在断开 %@，然后连接 %@…"
        case .succeeded:
            key = "panel.operation.succeeded.switch"
            defaultValue = "已断开 %@，并已提交连接 %@ 的请求"
        case .failed:
            key = "panel.operation.failed.switch"
            defaultValue = "无法从 %@ 切换到 %@"
        case .timedOut:
            key = "panel.operation.timedOut.switch"
            defaultValue = "从 %@ 切换到 %@ 超时"
        }
        return localization.format(key, defaultValue: defaultValue, request.source.name, request.target.name)
    }

    private func operationKey(prefix: String, action: SidecarOperationKind) -> String {
        switch action {
        case .connect:
            "\(prefix).connect"
        case .disconnect:
            "\(prefix).disconnect"
        case .wiredConnect:
            "\(prefix).wiredConnect"
        }
    }

    private func operationDefaultValue(prefix: String, action: SidecarOperationKind) -> String {
        switch (prefix, action) {
        case ("pending", .connect):
            "正在连接 %@…"
        case ("pending", .disconnect):
            "正在断开 %@…"
        case ("pending", .wiredConnect):
            "正在通过有线连接 %@…"
        case ("succeeded", .connect):
            "已提交连接 %@ 的请求"
        case ("succeeded", .disconnect):
            "已提交断开 %@ 的请求"
        case ("succeeded", .wiredConnect):
            "已提交有线连接 %@ 的请求"
        case ("failed", .connect):
            "无法连接 %@"
        case ("failed", .disconnect):
            "无法断开 %@"
        case ("failed", .wiredConnect):
            "无法通过有线连接 %@"
        case ("timedOut", .connect):
            "连接 %@ 超时"
        case ("timedOut", .disconnect):
            "断开 %@ 超时"
        case ("timedOut", .wiredConnect):
            "有线连接 %@ 超时"
        default:
            "%@"
        }
    }

    private func localizedErrorMessage(for error: SidecarServiceError) -> String {
        switch error {
        case let .unsupported(reason):
            unsupportedMessage(for: reason)
        case .deviceUnavailable:
            localization.string(
                "service.error.deviceUnavailable",
                defaultValue: "Sidecar 显示器已不在可用设备列表中"
            )
        case .operationUnavailable:
            localization.string(
                "service.error.operationUnavailable",
                defaultValue: "当前系统不支持此 Sidecar 操作"
            )
        case let .system(message):
            message
        }
    }

    private func unsupportedMessage(for reason: SidecarUnavailableReason) -> String {
        localization.string(
            unsupportedKey(for: reason),
            defaultValue: unsupportedDefaultMessage(for: reason)
        )
    }

    private func unsupportedKey(for reason: SidecarUnavailableReason) -> String {
        switch reason {
        case .frameworkLoadFailed:
            "service.unsupported.frameworkLoadFailed"
        case .missingManager:
            "service.unsupported.missingManager"
        case .missingTypes:
            "service.unsupported.missingTypes"
        case .managerInitializationFailed:
            "service.unsupported.managerInitializationFailed"
        case .missingInterfaces:
            "service.unsupported.missingInterfaces"
        }
    }

    private func unsupportedDefaultMessage(for reason: SidecarUnavailableReason) -> String {
        switch reason {
        case .frameworkLoadFailed:
            "此系统无法加载 SidecarCore"
        case .missingManager:
            "此系统未提供 SidecarDisplayManager"
        case .missingTypes:
            "此系统的 SidecarCore 缺少所需类型"
        case .managerInitializationFailed:
            "此系统无法初始化 SidecarDisplayManager"
        case .missingInterfaces:
            "此系统的 SidecarCore 缺少所需接口"
        }
    }

    private func scheduleFollowUpRefresh() {
        guard isActive else { return }
        followUpRefreshTask?.cancel()
        followUpRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 750_000_000)
            } catch {
                return
            }
            guard let self, self.isActive else { return }
            self.refreshDevices(notify: true)
            self.followUpRefreshTask = nil
        }
    }

    private func localizedDevice(_ device: SidecarDevice) -> SidecarDevice {
        guard !device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SidecarDevice(
                id: device.id,
                name: localization.string("device.unnamed", defaultValue: "Sidecar 显示器"),
                connectionState: device.connectionState
            )
        }

        return device
    }

    private func shortcutDefinition(
        id: String,
        title: String,
        description: String,
        defaultBinding: ShortcutBinding?,
        groupID: String,
        groupTitle: String,
        settingsControlTitle: String? = nil
    ) -> PluginShortcutDefinition {
        PluginShortcutDefinition(
            id: id,
            title: title,
            description: description,
            actionID: id,
            scope: .global,
            defaultBinding: defaultBinding,
            isRequired: false,
            settingsGroupID: groupID,
            settingsGroupTitle: groupTitle,
            settingsGroupDescription: nil,
            settingsControlTitle: settingsControlTitle,
            settingsControlSystemImage: nil
        )
    }
}
