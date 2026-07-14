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
        [SidecarPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

private enum ControlID {
    static let deviceNavigationPrefix = "sidecar-device-navigation."
    static let connectPrefix = "sidecar-connect."
    static let disconnectPrefix = "sidecar-disconnect."
    static let wiredConnectPrefix = "sidecar-wired-connect."

    static func deviceNavigation(for deviceID: String) -> String {
        deviceNavigationPrefix + deviceID
    }
}

@MainActor
final class SidecarPlugin: MacToolsPlugin, PluginPrimaryPanel {
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
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SidecarPlugin"
    )
    private var devices: [SidecarDevice] = []
    private var isExpanded = false
    private var selectedDeviceID: String?
    private var operation: SidecarOperationState?
    private var operationToken: UUID?
    private var timeoutTask: Task<Void, Never>?
    private let operationTimeoutNanoseconds: UInt64

    init(
        service: any SidecarServicing = SidecarCoreService(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        operationTimeoutNanoseconds: UInt64 = 15_000_000_000
    ) {
        self.service = service
        self.localization = localization
        self.operationTimeoutNanoseconds = operationTimeoutNanoseconds
        metadata = PluginMetadata(
            id: "sidecar",
            title: localization.string("metadata.title", defaultValue: "Sidecar"),
            iconName: "ipad.landscape",
            iconTint: Color(nsColor: .systemIndigo),
            order: 31,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "连接附近可用的 iPad 作为扩展显示器"
            )
        )
        service.onDevicesChanged = { [weak self] in
            self?.refreshDevices(notify: true)
        }
        refreshDevices(notify: false)
    }

    deinit {
        timeoutTask?.cancel()
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
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        refreshDevices(notify: true)
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            if !expanded {
                selectedDeviceID = nil
            }
            onStateChange?()
        case let .setNavigationSelection(controlID, optionID):
            guard controlID.hasPrefix(ControlID.deviceNavigationPrefix) else { return }
            if selectedDeviceID == optionID {
                selectedDeviceID = nil
                operation = nil
                onStateChange?()
                return
            }
            selectedDeviceID = optionID
            operation = nil
            onStateChange?()
        case let .clearNavigationSelection(controlID):
            guard controlID.hasPrefix(ControlID.deviceNavigationPrefix) else { return }
            selectedDeviceID = nil
            operation = nil
            onStateChange?()
        case let .invokeAction(controlID):
            handleOperationAction(controlID)
        case .setSwitch, .setSelection, .setDate, .setSlider:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    private var subtitle: String {
        if let operation {
            return operationSubtitle(operation)
        }
        if devices.isEmpty {
            return localization.string("panel.subtitle.noDevices", defaultValue: "未发现可连接的 iPad")
        }
        let connectedCount = devices.filter { $0.connectionState == .connected }.count
        if connectedCount > 0 {
            return localization.format(
                "panel.subtitle.connectedCount",
                defaultValue: "%d 台 iPad 已通过 Sidecar 连接",
                connectedCount
            )
        }
        return localization.format("panel.subtitle.deviceCount", defaultValue: "%d 台可连接的 iPad", devices.count)
    }

    private var operationErrorMessage: String? {
        guard let operation else { return nil }
        switch operation {
        case let .failed(_, _, message):
            return message
        case .timedOut:
            return localization.string("panel.error.timeout", defaultValue: "操作超时，请检查 iPad、线缆和网络后重试")
        case .pending, .succeeded:
            return nil
        }
    }

    private var isOperationPending: Bool {
        if case .pending = operation { return true }
        return false
    }

    private func refreshDevices(notify: Bool) {
        let updatedDevices = service.reachableDevices()
        let changed = updatedDevices != devices
        devices = updatedDevices
        if let selectedDeviceID, !devices.contains(where: { $0.id == selectedDeviceID }) {
            self.selectedDeviceID = nil
        }
        if notify && changed {
            onStateChange?()
        }
    }

    private func buildDetail() -> PluginPanelDetail {
        guard !devices.isEmpty else {
            return PluginPanelDetail(controls: [])
        }

        var controls: [PluginPanelControl] = []
        for device in devices {
            controls.append(deviceNavigationControl(for: device))
            if selectedDeviceID == device.id {
                controls.append(contentsOf: actionControls(for: device))
            }
        }

        return PluginPanelDetail(
            primaryControls: controls,
            secondaryPanel: nil
        )
    }

    private func deviceNavigationControl(for device: SidecarDevice) -> PluginPanelControl {
        PluginPanelControl(
            id: ControlID.deviceNavigation(for: device.id),
            kind: .navigationList,
            options: [
                PluginPanelControlOption(
                    id: device.id,
                    title: device.name,
                    subtitle: deviceSubtitle(for: device)
                )
            ],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            isEnabled: !isOperationPending
        )
    }

    private func actionControls(for device: SidecarDevice) -> [PluginPanelControl] {
        let isEnabled = !isOperationPending
        switch device.connectionState {
        case .connected:
            return [
                actionControl(
                    id: ControlID.disconnectPrefix + device.id,
                    title: localization.string("panel.action.disconnect", defaultValue: "断开连接"),
                    icon: "rectangle.portrait.and.arrow.right",
                    sectionTitle: nil,
                    showsLeadingDivider: true,
                    isEnabled: isEnabled
                )
            ]
        case .disconnected:
            return connectControls(for: device, isEnabled: isEnabled)
        case .unknown:
            return [
                actionControl(
                    id: ControlID.connectPrefix + device.id,
                    title: localization.string("panel.action.connect", defaultValue: "连接"),
                    icon: "rectangle.on.rectangle",
                    sectionTitle: nil,
                    showsLeadingDivider: true,
                    isEnabled: isEnabled
                ),
                actionControl(
                    id: ControlID.disconnectPrefix + device.id,
                    title: localization.string("panel.action.disconnect", defaultValue: "断开连接"),
                    icon: "rectangle.portrait.and.arrow.right",
                    sectionTitle: nil,
                    showsLeadingDivider: false,
                    isEnabled: isEnabled
                ),
                actionControl(
                    id: ControlID.wiredConnectPrefix + device.id,
                    title: localization.string("panel.action.wiredConnect", defaultValue: "仅通过有线连接"),
                    icon: "cable.connector",
                    sectionTitle: localization.string(
                        "panel.wired.warning",
                        defaultValue: "仅有线：不会回退到 Wi-Fi"
                    ),
                    showsLeadingDivider: false,
                    isEnabled: isEnabled
                )
            ]
        }
    }

    private func connectControls(for device: SidecarDevice, isEnabled: Bool) -> [PluginPanelControl] {
        [
            actionControl(
                id: ControlID.connectPrefix + device.id,
                title: localization.string("panel.action.connect", defaultValue: "连接"),
                icon: "rectangle.on.rectangle",
                sectionTitle: nil,
                showsLeadingDivider: true,
                isEnabled: isEnabled
            ),
            actionControl(
                id: ControlID.wiredConnectPrefix + device.id,
                title: localization.string("panel.action.wiredConnect", defaultValue: "仅通过有线连接"),
                icon: "cable.connector",
                sectionTitle: localization.string(
                    "panel.wired.warning",
                    defaultValue: "仅有线：不会回退到 Wi-Fi"
                ),
                showsLeadingDivider: false,
                isEnabled: isEnabled
            )
        ]
    }

    private func deviceSubtitle(for device: SidecarDevice) -> String {
        switch device.connectionState {
        case .connected:
            localization.string("panel.device.subtitle.connected", defaultValue: "已通过 Sidecar 连接")
        case .disconnected, .unknown:
            localization.string("panel.device.subtitle", defaultValue: "可请求 Sidecar 连接")
        }
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
            action = .connect
            deviceID = String(controlID.dropFirst(ControlID.connectPrefix.count))
        } else if controlID.hasPrefix(ControlID.disconnectPrefix) {
            action = .disconnect
            deviceID = String(controlID.dropFirst(ControlID.disconnectPrefix.count))
        } else if controlID.hasPrefix(ControlID.wiredConnectPrefix) {
            action = .wiredConnect
            deviceID = String(controlID.dropFirst(ControlID.wiredConnectPrefix.count))
        } else {
            return
        }

        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        start(action: action, for: device)
    }

    private func start(action: SidecarOperationKind, for device: SidecarDevice) {
        let token = UUID()
        operationToken = token
        operation = .pending(action, deviceName: device.name)
        timeoutTask?.cancel()
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
            let message = localizedErrorMessage(for: error)
            operation = .failed(action, deviceName: device.name, message: message)
            logger.error("Sidecar operation failed action=\(String(describing: action), privacy: .public) reason=\(message, privacy: .public)")
        }
        refreshDevices(notify: false)
        scheduleFollowUpRefresh()
        onStateChange?()
    }

    private func finishTimeout(for token: UUID, action: SidecarOperationKind, device: SidecarDevice) {
        guard operationToken == token else { return }
        operationToken = nil
        timeoutTask = nil
        operation = .timedOut(action, deviceName: device.name)
        logger.error("Sidecar operation timed out action=\(String(describing: action), privacy: .public) device=\(device.name, privacy: .public)")
        onStateChange?()
    }

    private func operationSubtitle(_ operation: SidecarOperationState) -> String {
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
                defaultValue: "iPad 已不在可用设备列表中"
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
        case .minimumTestedVersion:
            "service.unsupported.minimumTestedVersion"
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
        case .minimumTestedVersion:
            "Sidecar 已在 macOS 14.2 及更高版本测试"
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            self?.refreshDevices(notify: true)
        }
    }
}
