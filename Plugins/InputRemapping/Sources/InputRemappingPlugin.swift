import AppKit
import ApplicationServices
import CoreGraphics
@preconcurrency import IOKit.hid
import MacToolsPluginKit
import SwiftUI

public final class InputRemappingPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        InputRemappingProvider(context: context)
    }
}

@MainActor
private struct InputRemappingProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            InputRemappingPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            )
        ]
    }
}

enum InputRemappingInputMonitoringStatus: Equatable {
    case granted
    case denied
    case unknown
}

@MainActor
final class InputRemappingPlugin: MacToolsPlugin, PluginPrimaryPanel,
    AccessibilityPermissionRefreshing, PluginSettingsPresenting {
    private enum PermissionID {
        static let accessibility = "accessibility"
        static let inputMonitoring = "input-monitoring"
    }

    private enum SettingsID {
        static let rules = "rules"
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    let store: InputRemappingStore

    private let localization: PluginLocalization
    private let tap: any InputRemappingEventTapping
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool
    private let inputMonitoringStatus: @MainActor () -> InputRemappingInputMonitoringStatus
    private let openURL: (URL) -> Void
    private let notificationCenter: NotificationCenter

    private var isAccessibilityGranted: Bool
    private var isInputMonitoringGranted: Bool
    private var errorMessage: String?
    private var applicationActivationObserver: NSObjectProtocol?

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization? = nil,
        tap: (any InputRemappingEventTapping)? = nil,
        accessibilityTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = { prompt in
            let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        },
        inputMonitoringStatus: @escaping @MainActor () -> InputRemappingInputMonitoringStatus = {
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted:
                .granted
            case kIOHIDAccessTypeDenied:
                .denied
            default:
                .unknown
            }
        },
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        notificationCenter: NotificationCenter = .default
    ) {
        let resolvedLocalization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = resolvedLocalization
        self.store = InputRemappingStore(storage: context.storage)
        self.tap = tap ?? InputRemappingEventTap()
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.inputMonitoringStatus = inputMonitoringStatus
        self.openURL = openURL
        self.notificationCenter = notificationCenter
        self.isAccessibilityGranted = accessibilityTrusted()
        self.isInputMonitoringGranted = inputMonitoringStatus() == .granted
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .keepPresented,
            buttonTitleProvider: {
                resolvedLocalization.string("panel.button.settings", defaultValue: "设置")
            }
        )
        self.metadata = PluginMetadata(
            id: "input-remapping",
            title: resolvedLocalization.string("metadata.title", defaultValue: "输入重映射"),
            iconName: "computermouse",
            iconTint: .purple,
            order: 57,
            defaultDescription: resolvedLocalization.string(
                "metadata.description",
                defaultValue: "使用额外鼠标按键触发快捷操作"
            )
        )

        self.tap.update(rules: store.rules)
        store.onRulesChange = { [weak self] in
            self?.applyConfiguration()
        }
    }

    func activate(context: PluginRuntimeContext) {
        observeApplicationActivation()
        refreshPermissionState()
        applyConfiguration()
    }

    func deactivate(reason: PluginDeactivationReason) {
        removeApplicationActivationObserver()
        tap.stop()
        onStateChange?()
    }

    func refresh() {
        refreshPermissionState()
        applyConfiguration()
        onStateChange?()
    }

    func refreshAccessibilityPermission() {
        refreshPermissionState()
        applyConfiguration()
    }

    var primaryPanelState: PluginPanelState {
        let enabledRuleCount = store.rules.filter(\.isEnabled).count
        let subtitle = enabledRuleCount == 0
            ? localization.string("panel.subtitle.noRules", defaultValue: "无规则")
            : localization.format(
                "panel.subtitle.activeRulesFormat",
                defaultValue: "%d 条活跃规则",
                enabledRuleCount
            )

        return PluginPanelState(
            subtitle: subtitle,
            isOn: enabledRuleCount > 0 && errorMessage == nil,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string(
                    "permission.accessibility.title",
                    defaultValue: "辅助功能"
                ),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于发送重映射后的鼠标点击和快捷键。"
                )
            ),
            PluginPermissionRequirement(
                id: PermissionID.inputMonitoring,
                kind: .inputMonitoring,
                title: localization.string(
                    "permission.inputMonitoring.title",
                    defaultValue: "输入监控"
                ),
                description: localization.string(
                    "permission.inputMonitoring.description",
                    defaultValue: "用于在系统范围内监听额外鼠标按键。所有处理均在本机完成。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: SettingsID.rules,
                title: localization.string("settings.rules.title", defaultValue: "按键映射"),
                systemImage: "computermouse",
                presentation: .edgeToEdge
            ) { [weak self] _ in
                if let self {
                    InputRemappingSettingsView(
                        store: self.store,
                        localization: self.localization
                    )
                }
            }
            .headerAccessory { [store, localization] _ in
                Button {
                    store.addRule()
                } label: {
                    Label(
                        localization.string("settings.addRule", defaultValue: "添加规则"),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        ])
    }

    func handleAction(_ action: PluginPanelAction) {
        if case .invokeAction = action {
            requestSettingsPresentation?()
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        switch permissionID {
        case PermissionID.accessibility:
            PluginPermissionState(
                isGranted: isAccessibilityGranted,
                footnote: isAccessibilityGranted ? nil : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 辅助功能，允许 MacTools。"
                )
            )

        case PermissionID.inputMonitoring:
            PluginPermissionState(
                isGranted: isInputMonitoringGranted,
                footnote: isInputMonitoringGranted ? nil : localization.string(
                    "permission.inputMonitoring.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 输入监控，允许 MacTools。"
                )
            )

        default:
            PluginPermissionState(isGranted: false, footnote: nil)
        }
    }

    func handlePermissionAction(id: String) {
        switch id {
        case PermissionID.accessibility:
            isAccessibilityGranted = requestAccessibilityTrust(true)
            refreshPermissionState()
            applyConfiguration()

        case PermissionID.inputMonitoring:
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            ) {
                openURL(url)
            }
            refreshPermissionState()
            applyConfiguration()

        default:
            return
        }
        onStateChange?()
    }

    private func refreshPermissionState() {
        isAccessibilityGranted = accessibilityTrusted()
        isInputMonitoringGranted = inputMonitoringStatus() == .granted
    }

    private func applyConfiguration() {
        tap.update(rules: store.rules)

        guard store.rules.contains(where: \.isEnabled) else {
            tap.stop()
            errorMessage = nil
            onStateChange?()
            return
        }

        guard isAccessibilityGranted else {
            tap.stop()
            errorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "请先授予辅助功能权限以启用规则。"
            )
            onStateChange?()
            return
        }

        guard isInputMonitoringGranted else {
            tap.stop()
            errorMessage = localization.string(
                "error.inputMonitoringRequired",
                defaultValue: "请先授予输入监控权限以启用规则。"
            )
            onStateChange?()
            return
        }

        if tap.start() {
            errorMessage = nil
        } else {
            errorMessage = localization.string(
                "error.tapUnavailable",
                defaultValue: "无法启动输入监听，请检查权限后重试。"
            )
        }
        onStateChange?()
    }

    private func observeApplicationActivation() {
        guard applicationActivationObserver == nil else { return }
        applicationActivationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshPermissionState()
                self.applyConfiguration()
            }
        }
    }

    private func removeApplicationActivationObserver() {
        guard let applicationActivationObserver else { return }
        notificationCenter.removeObserver(applicationActivationObserver)
        self.applicationActivationObserver = nil
    }
}

private struct InputRemappingSettingsView: View {
    @ObservedObject var store: InputRemappingStore
    let localization: PluginLocalization

    var body: some View {
        VStack(spacing: 0) {
            if store.rules.isEmpty {
                HStack {
                    Spacer()
                    Text(
                        localization.format(
                            "settings.empty",
                            defaultValue: "为额外鼠标按键（按键 %d 至 %d）添加规则。",
                            InputRemappingRulePolicy.minimumButtonNumber,
                            InputRemappingRulePolicy.maximumButtonNumber
                        )
                    )
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
                    Spacer()
                }
            } else {
                ForEach(Array(store.rules.enumerated()), id: \.element.id) { index, rule in
                    InputRemappingRuleEditor(
                        rule: rule,
                        store: store,
                        localization: localization
                    )
                    if index < store.rules.count - 1 {
                        PluginSettingsListDivider()
                    }
                }
            }
        }
    }
}

private struct InputRemappingRuleEditor: View {
    let rule: InputRemappingRule
    @ObservedObject var store: InputRemappingStore
    let localization: PluginLocalization

    @State private var draft: InputRemappingRule

    init(
        rule: InputRemappingRule,
        store: InputRemappingStore,
        localization: PluginLocalization
    ) {
        self.rule = rule
        self.store = store
        self.localization = localization
        _draft = State(initialValue: rule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Toggle(
                    localization.string("settings.enabled", defaultValue: "启用"),
                    isOn: binding(\.isEnabled)
                )
                .toggleStyle(.switch)
                .font(PluginSettingsTheme.Typography.rowTitle)

                Spacer()

                Button(role: .destructive) {
                    store.delete(rule)
                } label: {
                    Label(
                        localization.string("settings.delete", defaultValue: "删除"),
                        systemImage: "trash"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Stepper(
                    value: binding(\.buttonNumber),
                    in: InputRemappingRulePolicy.eligibleButtonNumbers
                ) {
                    Label(
                        localization.format(
                            "settings.button.format",
                            defaultValue: "按键 %d",
                            draft.buttonNumber
                        ),
                        systemImage: "computermouse"
                    )
                    .font(PluginSettingsTheme.Typography.rowTitle)
                }
                .frame(minWidth: 130, idealWidth: 150, maxWidth: 180)

                Picker(
                    localization.string("settings.action", defaultValue: "操作"),
                    selection: actionBinding
                ) {
                    ForEach(InputRemappingRule.Action.allCases, id: \.self) { action in
                        Text(action.title(localization: localization)).tag(action)
                    }
                }
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
            }

            HStack(spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                modifierToggle("⇧", .shift)
                modifierToggle("⌥", .option)
                modifierToggle("⌃", .control)
                modifierToggle("⌘", .command)
            }

            if case let .shortcut(shortcut) = draft.action {
                HStack(spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Stepper(
                        localization.format(
                            "settings.shortcutKeyCode.format",
                            defaultValue: "快捷键代码 %d",
                            shortcut.keyCode
                        ),
                        value: shortcutKeyCodeBinding,
                        in: 0...127
                    )
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)

                    shortcutModifierToggle("⇧", .shift)
                    shortcutModifierToggle("⌥", .option)
                    shortcutModifierToggle("⌃", .control)
                    shortcutModifierToggle("⌘", .command)
                }
            }
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var actionBinding: Binding<InputRemappingRule.Action> {
        Binding(
            get: { draft.action },
            set: {
                draft.action = $0
                save()
            }
        )
    }

    private var shortcutKeyCodeBinding: Binding<UInt16> {
        Binding(
            get: {
                if case let .shortcut(binding) = draft.action {
                    return binding.keyCode
                }
                return 0
            },
            set: { setShortcut(keyCode: $0, modifiers: shortcutModifiers) }
        )
    }

    private var shortcutModifiers: ShortcutModifiers {
        if case let .shortcut(binding) = draft.action {
            return binding.modifiers
        }
        return []
    }

    private func binding<T>(_ keyPath: WritableKeyPath<InputRemappingRule, T>) -> Binding<T> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: {
                draft[keyPath: keyPath] = $0
                save()
            }
        )
    }

    private func modifierToggle(
        _ title: String,
        _ modifier: ShortcutModifiers
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { draft.modifiers.contains(modifier) },
                set: { enabled in
                    if enabled {
                        draft.modifiers.insert(modifier)
                    } else {
                        draft.modifiers.remove(modifier)
                    }
                    save()
                }
            )
        )
        .toggleStyle(.button)
        .controlSize(.small)
    }

    private func shortcutModifierToggle(
        _ title: String,
        _ modifier: ShortcutModifiers
    ) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { shortcutModifiers.contains(modifier) },
                set: { enabled in
                    var modifiers = shortcutModifiers
                    if enabled {
                        modifiers.insert(modifier)
                    } else {
                        modifiers.remove(modifier)
                    }
                    setShortcut(
                        keyCode: shortcutKeyCodeBinding.wrappedValue,
                        modifiers: modifiers
                    )
                }
            )
        )
        .toggleStyle(.button)
        .controlSize(.small)
    }

    private func setShortcut(keyCode: UInt16, modifiers: ShortcutModifiers) {
        draft.action = .shortcut(
            ShortcutBinding(keyCode: keyCode, modifiers: modifiers)
        )
        save()
    }

    private func save() {
        store.replace(draft)
    }
}
