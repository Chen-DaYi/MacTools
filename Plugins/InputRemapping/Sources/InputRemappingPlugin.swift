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
final class InputRemappingButtonCaptureCoordinator: ObservableObject {
    @Published private(set) var recordingRuleID: UUID?
    @Published private(set) var recordingShortcutRuleID: UUID?
    @Published private(set) var preparingRuleID: UUID?
    @Published private(set) var preparingShortcutRuleID: UUID?

    private let tap: any InputRemappingEventTapping
    private let scheduleArming: (@escaping @MainActor () -> Void) -> Void

    init(
        tap: any InputRemappingEventTapping,
        scheduleArming: @escaping (@escaping @MainActor () -> Void) -> Void = { operation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Task { @MainActor in operation() }
            }
        }
    ) {
        self.tap = tap
        self.scheduleArming = scheduleArming
    }

    func start(
        ruleID: UUID,
        onCapture: @escaping @MainActor (InputRemappingCapturedInput) -> Void
    ) -> Bool {
        cancel()
        preparingRuleID = ruleID
        scheduleArming { [weak self] in
            guard let self, self.preparingRuleID == ruleID else { return }
            self.preparingRuleID = nil
            self.recordingRuleID = ruleID
            guard self.tap.beginInputCapture({ [weak self] input in
                Task { @MainActor [weak self] in
                    guard let self, self.recordingRuleID == ruleID else { return }
                    self.recordingRuleID = nil
                    onCapture(input)
                }
            }) else {
                self.recordingRuleID = nil
                return
            }
        }
        return true
    }

    func cancel() {
        guard recordingRuleID != nil || recordingShortcutRuleID != nil
            || preparingRuleID != nil || preparingShortcutRuleID != nil
        else { return }
        recordingRuleID = nil
        recordingShortcutRuleID = nil
        preparingRuleID = nil
        preparingShortcutRuleID = nil
        tap.cancelButtonCapture()
    }

    func startShortcut(
        ruleID: UUID,
        onCapture: @escaping @MainActor (ShortcutBinding) -> Void
    ) -> Bool {
        cancel()
        preparingShortcutRuleID = ruleID
        scheduleArming { [weak self] in
            guard let self, self.preparingShortcutRuleID == ruleID else { return }
            self.preparingShortcutRuleID = nil
            self.recordingShortcutRuleID = ruleID
            guard self.tap.beginShortcutCapture({ [weak self] shortcut in
                Task { @MainActor [weak self] in
                    guard let self, self.recordingShortcutRuleID == ruleID else { return }
                    self.recordingShortcutRuleID = nil
                    onCapture(shortcut)
                }
            }) else {
                self.recordingShortcutRuleID = nil
                return
            }
        }
        return true
    }
}

@MainActor
final class InputRemappingPlugin: MacToolsPlugin, PluginPrimaryPanel,
    AccessibilityPermissionRefreshing, PluginSettingsPresenting, TrackpadGestureEventConsuming {
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
    var onTrackpadGestureClaimsChange: (() -> Void)?
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?

    let store: InputRemappingStore

    private let localization: PluginLocalization
    private let tap: any InputRemappingEventTapping
    private let buttonCapture: InputRemappingButtonCaptureCoordinator
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
        self.buttonCapture = InputRemappingButtonCaptureCoordinator(tap: self.tap)
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
            self?.onTrackpadGestureClaimsChange?()
        }
    }

    func activate(context: PluginRuntimeContext) {
        observeApplicationActivation()
        refreshPermissionState()
        applyConfiguration()
    }

    func deactivate(reason: PluginDeactivationReason) {
        buttonCapture.cancel()
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

    var claimedTrackpadGestures: Set<TrackpadGesture> {
        Set(store.rules.compactMap { rule in
            guard rule.isEnabled, case let .trackpadGesture(gesture) = rule.trigger else { return nil }
            return gesture
        })
    }

    func receiveTrackpadGesture(_ gesture: TrackpadGesture, deviceID: UInt64) {
        guard isAccessibilityGranted,
              let rule = store.rules.first(where: { $0.isEnabled && $0.trigger == .trackpadGesture(gesture) })
        else { return }
        _ = tap.execute(rule.action)
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
                title: localization.string("settings.rules.title", defaultValue: "Input Mappings"),
                systemImage: "computermouse",
                presentation: .edgeToEdge
            ) { [weak self] _ in
                if let self {
                    InputRemappingSettingsView(
                        store: self.store,
                        localization: self.localization,
                        buttonCapture: self.buttonCapture,
                        requestTrackpadGestureOwnership: self.requestTrackpadGestureOwnership
                    )
                }
            }
            .headerAccessory { [store, localization] _ in
                Button {
                    store.addRule()
                } label: {
                    Label(
                        localization.string("settings.addRule", defaultValue: "Add Mapping"),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.borderedProminent)
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
    @ObservedObject var buttonCapture: InputRemappingButtonCaptureCoordinator
    let requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Text(localization.string("settings.rules.subtitle", defaultValue: "Create shortcuts from keyboard/trackpad/mouse"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)

            if store.rules.isEmpty {
                HStack {
                    Spacer()
                    Text(
                        localization.string(
                            "settings.empty",
                            defaultValue: "Record a keyboard key, mouse button, or scroll direction to add a rule."
                        )
                    )
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
                    Spacer()
                }
            } else {
                ForEach(store.rules) { rule in
                    InputRemappingRuleEditor(
                        rule: rule,
                        store: store,
                        localization: localization,
                        buttonCapture: buttonCapture,
                        requestTrackpadGestureOwnership: requestTrackpadGestureOwnership
                    )
                }
            }
        }
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }
}

private enum InputRemappingInputKind: String, CaseIterable, Identifiable {
    case keyboard
    case mouse
    case trackpad
    case scroll

    var id: Self { self }
    var symbolName: String {
        switch self {
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .trackpad: "hand.tap"
        case .scroll: "scroll"
        }
    }
}

private struct InputRemappingRuleEditor: View {
    let rule: InputRemappingRule
    @ObservedObject var store: InputRemappingStore
    let localization: PluginLocalization
    @ObservedObject var buttonCapture: InputRemappingButtonCaptureCoordinator
    let requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?

    @State private var draft: InputRemappingRule
    @State private var requiresKeyboardConfirmation = false

    init(
        rule: InputRemappingRule,
        store: InputRemappingStore,
        localization: PluginLocalization,
        buttonCapture: InputRemappingButtonCaptureCoordinator,
        requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)? = nil
    ) {
        self.rule = rule
        self.store = store
        self.localization = localization
        self.buttonCapture = buttonCapture
        self.requestTrackpadGestureOwnership = requestTrackpadGestureOwnership
        _draft = State(initialValue: rule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            mappingHeader

            HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.section) {
                inputColumn
                flowArrow
                outputColumn
                flowArrow
                contextColumn
            }

            Divider()

            HStack {
                Spacer()
                Button(role: .destructive) { store.delete(rule) } label: {
                    Label(localization.string("settings.deleteMapping", defaultValue: "Delete mapping"), systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground(.standard)
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .alert(
            localization.string("settings.keyboard.confirmation.title", defaultValue: "Enable unmodified key?"),
            isPresented: $requiresKeyboardConfirmation
        ) {
            Button(localization.string("settings.keyboard.confirmation.enable", defaultValue: "Enable")) {
                draft.isEnabled = true
                save()
            }
            Button(localization.string("settings.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(localization.string("settings.keyboard.confirmation.message", defaultValue: "This rule captures normal typing system-wide. You can disable it at any time."))
        }
    }

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(localization.string("settings.mapping.when", defaultValue: "When I press"))
                .foregroundStyle(.secondary)

            inputKindMenu

            if inputKind != .trackpad {
                inputCaptureControl
            }

            if inputKind == .trackpad {
                Picker(localization.string("settings.trackpadGesture", defaultValue: "Trackpad gesture"), selection: trackpadGestureBinding) {
                    ForEach(TrackpadGesture.configurableCases) { gesture in
                        Text(trackpadGestureTitle(gesture)).tag(Optional(gesture))
                    }
                }
                .labelsHidden()
            }

            if inputKind != .trackpad {
                HStack(spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    modifierToggle("⇧", .shift)
                    modifierToggle("⌥", .option)
                    modifierToggle("⌃", .control)
                    modifierToggle("⌘", .command)
                }
            }

            if case .mouseButton = draft.trigger {
                Menu {
                    ForEach(InputRemappingMouseInteraction.allCases, id: \.self) { interaction in
                        Button(mouseInteractionTitle(interaction)) { mouseInteractionBinding.wrappedValue = interaction }
                    }
                } label: {
                    mappingField(mouseInteractionTitle(draft.mouseInteraction), systemImage: "cursorarrow")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
    }

    private var outputColumn: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(localization.string("settings.mapping.run", defaultValue: "Run"))
                .foregroundStyle(.secondary)
            actionMenu

            if case let .shortcut(shortcut) = draft.action {
                mappingField(shortcutTitle(shortcut), systemImage: "command")
                if buttonCapture.preparingShortcutRuleID == rule.id {
                    Label(localization.string("settings.shortcut.preparing", defaultValue: "Preparing shortcut recording…"), systemImage: "hourglass")
                        .foregroundStyle(.tint)
                    Text(localization.string("settings.shortcut.preparing.detail", defaultValue: "Release the Record Shortcut button; listening starts next."))
                        .foregroundStyle(.secondary)
                    Button(localization.string("settings.cancel", defaultValue: "Cancel")) { buttonCapture.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if buttonCapture.recordingShortcutRuleID == rule.id {
                    Label(localization.string("settings.shortcut.recording", defaultValue: "Press the shortcut"), systemImage: "record.circle")
                        .foregroundStyle(.tint)
                    Button(localization.string("settings.cancel", defaultValue: "Cancel")) { buttonCapture.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button(localization.string("settings.shortcut.record", defaultValue: "Record shortcut")) {
                        _ = buttonCapture.startShortcut(ruleID: rule.id) { binding in
                            draft.action = .shortcut(binding)
                            save()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
    }

    private var contextColumn: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(localization.string("settings.mapping.where", defaultValue: "Where"))
                .foregroundStyle(.secondary)
            mappingField(localization.string("settings.context.global", defaultValue: "Everywhere"), systemImage: "globe")

            if case let .keyboard(_, modifiers) = draft.trigger, modifiers.isEmpty {
                Text(localization.string("settings.keyboard.warning", defaultValue: "A key without modifiers overrides normal typing while the rule is enabled."))
                    .foregroundStyle(.orange)
            }
            if case .mouseButton = draft.trigger, draft.mouseInteraction != .click {
                Text(localization.string("settings.mouseInteraction.warning", defaultValue: "Double-click and long-press keep the original click available to avoid delaying or replaying input."))
                    .foregroundStyle(.secondary)
            }

        }
        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
    }

    private var mappingHeader: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(triggerTitle)
                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
            Spacer()
            Text(localization.string("settings.enabled", defaultValue: "Enabled"))
                .foregroundStyle(.secondary)
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
            Menu {
                Button(role: .destructive) { store.delete(rule) } label: {
                    Label(localization.string("settings.deleteMapping", defaultValue: "Delete mapping"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .help(localization.string("settings.mapping.more", defaultValue: "More options"))
        }
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.right")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(width: 24)
            .padding(.top, 31)
            .accessibilityHidden(true)
    }

    private var inputKindMenu: some View {
        Menu {
            ForEach(InputRemappingInputKind.allCases) { kind in
                Button(inputKindTitle(kind)) { inputKindBinding.wrappedValue = kind }
            }
        } label: {
            mappingField(triggerTitle, systemImage: inputKind.symbolName)
        }
        .menuStyle(.borderlessButton)
    }

    private var actionMenu: some View {
        Menu {
            ForEach(InputRemappingRule.Action.Kind.allCases, id: \.self) { kind in
                Button(InputRemappingRule.Action.action(for: kind).kindTitle(localization: localization)) {
                    actionBinding.wrappedValue = kind
                }
            }
        } label: {
            mappingField(actionTitle, systemImage: actionSymbolName)
        }
        .menuStyle(.borderlessButton)
    }

    private func mappingField(_ title: String, systemImage: String) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(title)
                .font(PluginSettingsTheme.Typography.rowTitle)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pluginSettingsCardBackground(.recessed)
    }

    private var actionTitle: String {
        switch draft.action {
        case let .shortcut(shortcut): shortcutTitle(shortcut)
        default: draft.action.title(localization: localization)
        }
    }

    private var actionSymbolName: String {
        switch draft.action {
        case .shortcut: "command"
        case .mouseBack: "arrow.left"
        case .mouseForward: "arrow.right"
        case .mouseMiddle: "computermouse"
        case .missionControl: "rectangle.3.group"
        case .spaceLeft: "arrow.left.to.line"
        case .spaceRight: "arrow.right.to.line"
        case .mediaPlayPause: "playpause"
        case .volumeDown: "speaker.wave.1"
        case .volumeUp: "speaker.wave.3"
        }
    }

    private func shortcutTitle(_ shortcut: ShortcutBinding) -> String {
        localization.format(
            "settings.shortcut.current",
            defaultValue: "%@%d",
            shortcut.modifiers.symbolString,
            shortcut.keyCode
        )
    }

    private var actionBinding: Binding<InputRemappingRule.Action.Kind> {
        Binding(
            get: { draft.action.kind },
            set: { kind in
                draft.action = draft.action.replacingKind(kind)
                save()
            }
        )
    }

    private var inputKind: InputRemappingInputKind {
        switch draft.trigger {
        case .keyboard: .keyboard
        case .mouseButton: .mouse
        case .trackpadGesture: .trackpad
        case .scroll: .scroll
        }
    }

    private var inputKindBinding: Binding<InputRemappingInputKind> {
        Binding(
            get: { inputKind },
            set: { kind in
                switch kind {
                case .keyboard:
                    draft.replaceTrigger(.keyboard(keyCode: 0, modifiers: []))
                case .mouse:
                    draft.replaceTrigger(.mouseButton(number: 0, modifiers: [], interaction: .click))
                case .trackpad:
                    let gesture = TrackpadGesture.threeFingerTap
                    requestTrackpadGestureOwnership?(gesture)
                    draft.replaceTrigger(.trackpadGesture(gesture))
                case .scroll:
                    draft.replaceTrigger(.scroll(direction: .up, modifiers: []))
                }
                save()
            }
        )
    }

    private func inputKindTitle(_ kind: InputRemappingInputKind) -> String {
        switch kind {
        case .keyboard: localization.string("settings.input.kind.keyboard", defaultValue: "Keyboard")
        case .mouse: localization.string("settings.input.kind.mouse", defaultValue: "Mouse")
        case .trackpad: localization.string("settings.input.kind.trackpad", defaultValue: "Trackpad")
        case .scroll: localization.string("settings.input.kind.scroll", defaultValue: "Scroll")
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { draft.isEnabled },
            set: { enabled in
                guard enabled, case let .keyboard(_, modifiers) = draft.trigger, modifiers.isEmpty else {
                    draft.isEnabled = enabled
                    save()
                    return
                }
                requiresKeyboardConfirmation = true
            }
        )
    }

    @ViewBuilder
    private var inputCaptureControl: some View {
        if buttonCapture.preparingRuleID == rule.id {
            captureStatus(
                title: localization.string("settings.input.preparing", defaultValue: "Preparing recording…"),
                detail: localization.string("settings.input.preparing.detail", defaultValue: "Release the Record Input button; listening starts next."),
                isPreparing: true
            )
        } else if buttonCapture.recordingRuleID == rule.id {
            captureStatus(
                title: localization.string("settings.input.recording", defaultValue: "Listening for an input"),
                detail: localization.string("settings.input.recording.detail", defaultValue: "Press a key, mouse button, or scroll once."),
                isPreparing: false
            )
        } else {
            Button(localization.string("settings.input.record", defaultValue: "Record input")) {
                _ = buttonCapture.start(ruleID: rule.id) { input in
                    draft.replaceTrigger(input.trigger(interaction: draft.mouseInteraction))
                    save()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(
                localization.string(
                    "settings.input.record.help",
                    defaultValue: "The next keyboard key, mouse button, or scroll direction becomes this trigger."
                )
            )
        }
    }

    private func captureStatus(title: String, detail: String, isPreparing: Bool) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Label(title, systemImage: isPreparing ? "hourglass" : "record.circle")
                .font(PluginSettingsTheme.Typography.rowTitle)
                .foregroundStyle(.tint)
            Text(detail).foregroundStyle(.secondary)
            Button(localization.string("settings.cancel", defaultValue: "Cancel")) { buttonCapture.cancel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var mouseInteractionBinding: Binding<InputRemappingMouseInteraction> {
        Binding(
            get: { draft.mouseInteraction },
            set: { interaction in
                draft.mouseInteraction = interaction
                save()
            }
        )
    }

    private var trackpadGestureBinding: Binding<TrackpadGesture?> {
        Binding(
            get: { if case let .trackpadGesture(gesture) = draft.trigger { gesture } else { nil } },
            set: { gesture in
                guard let gesture else { return }
                requestTrackpadGestureOwnership?(gesture)
                draft.replaceTrigger(.trackpadGesture(gesture))
                save()
            }
        )
    }

    private var triggerTitle: String {
        switch draft.trigger {
        case let .keyboard(keyCode, modifiers):
            return localization.format("settings.trigger.keyboard.format", defaultValue: "Key %@%d", modifiers.symbolString, keyCode)
        case let .mouseButton(number, modifiers, _):
            return localization.format("settings.trigger.mouse.format", defaultValue: "Mouse button %@%d", modifiers.symbolString, number)
        case let .scroll(direction, modifiers):
            return localization.format("settings.trigger.scroll.format", defaultValue: "Scroll %@%@", modifiers.symbolString, scrollTitle(direction))
        case let .trackpadGesture(gesture):
            return localization.format("settings.trigger.trackpad.format", defaultValue: "Trackpad %@", trackpadGestureTitle(gesture))
        }
    }

    private func trackpadGestureTitle(_ gesture: TrackpadGesture) -> String {
        localization.string(
            "settings.trackpadGesture.\(gesture.rawValue)",
            defaultValue: gesture.displayTitle
        )
    }

    private func mouseInteractionTitle(_ interaction: InputRemappingMouseInteraction) -> String {
        switch interaction {
        case .click: localization.string("settings.mouseInteraction.click", defaultValue: "Click")
        case .doubleClick: localization.string("settings.mouseInteraction.doubleClick", defaultValue: "Double-click")
        case .longPress: localization.string("settings.mouseInteraction.longPress", defaultValue: "Long press")
        }
    }

    private func scrollTitle(_ direction: InputRemappingScrollDirection) -> String {
        switch direction {
        case .up: localization.string("settings.scroll.up", defaultValue: "up")
        case .down: localization.string("settings.scroll.down", defaultValue: "down")
        case .left: localization.string("settings.scroll.left", defaultValue: "left")
        case .right: localization.string("settings.scroll.right", defaultValue: "right")
        }
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
