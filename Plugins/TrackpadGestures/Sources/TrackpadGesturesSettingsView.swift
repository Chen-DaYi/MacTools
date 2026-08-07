import AppKit
import SwiftUI
import MacToolsPluginKit

struct TrackpadGesturesSettingsView: View {
    @ObservedObject var store: TrackpadGestureStore
    let localization: PluginLocalization
    let actionHostContext: TrackpadActionHostContext?
    let onChange: () -> Void
    let onSetTesting: (Bool) -> Void

    @State private var editingDraft: TrackpadGestureMappingDraft?
    @State private var isShowingTipTapGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            mappingsSection
            typingProtectionSection
            testingSection
        }
        .sheet(item: $editingDraft) { draft in
            TrackpadGestureEditor(
                draft: draft,
                store: store,
                localization: localization,
                actionHostContext: actionHostContext,
                onCancel: { editingDraft = nil },
                onDelete: store.mappings.contains(where: { $0.id == draft.id }) ? {
                    store.delete(id: draft.id)
                    editingDraft = nil
                    onChange()
                } : nil,
                onSave: { mapping in
                    guard store.save(mapping) else { return }
                    editingDraft = nil
                    onChange()
                }
            )
        }
        .onDisappear {
            guard store.isTesting else { return }
            onSetTesting(false)
        }
        .onChange(of: store.lastTestGesture) { _, gesture in
            guard let gesture else { return }
            announceRecognizedTestGesture(gesture)
        }
    }

    private var typingProtectionSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(
                localization.string("settings.typing.title", defaultValue: "输入保护"),
                systemImage: "keyboard"
            )
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(
                        alignment: .leading,
                        spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                    ) {
                        Text(localization.string(
                            "settings.typing.ignore.title",
                            defaultValue: "输入时忽略手势"
                        ))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        Text(localization.string(
                            "settings.typing.ignore.description",
                            defaultValue: "按下普通按键时暂停识别，避免手掌误触触控板。"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                    Toggle("", isOn: Binding(
                        get: { store.ignoresGesturesWhileTyping },
                        set: { isEnabled in
                            store.setIgnoresGesturesWhileTyping(isEnabled)
                            onChange()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text(localization.string(
                        "settings.typing.ignore.title",
                        defaultValue: "输入时忽略手势"
                    )))
                    .accessibilityHint(Text(localization.string(
                        "settings.typing.ignore.description",
                        defaultValue: "按下普通按键时暂停识别，避免手掌误触触控板。"
                    )))
                }
                .pluginSettingsListRowPadding(interactive: true)

                PluginSettingsListDivider()

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(
                        alignment: .leading,
                        spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                    ) {
                        Text(localization.string(
                            "settings.typing.grace.title",
                            defaultValue: "停止输入后的延迟"
                        ))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        Text(localization.string(
                            "settings.typing.grace.description",
                            defaultValue: "最后一次按键后继续暂停识别；较短更灵敏，较长可减少更多误触；默认 0.4 秒。"
                        ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                    Slider(
                        value: Binding(
                            get: { store.typingGracePeriod },
                            set: { gracePeriod in
                                store.setTypingGracePeriod(gracePeriod)
                                onChange()
                            }
                        ),
                        in: TrackpadTypingSuppressionGate.minimumGracePeriod
                            ... TrackpadTypingSuppressionGate.maximumGracePeriod,
                        step: 0.1
                    )
                    .frame(minWidth: 120, idealWidth: 150, maxWidth: 180)
                    .disabled(!store.ignoresGesturesWhileTyping)
                    .accessibilityLabel(Text(localization.string(
                        "settings.typing.grace.title",
                        defaultValue: "停止输入后的延迟"
                    )))
                    .accessibilityValue(Text(typingGracePeriodText))
                    .accessibilityHint(Text(localization.string(
                        "settings.typing.grace.description",
                        defaultValue: "最后一次按键后继续暂停识别；较短更灵敏，较长可减少更多误触；默认 0.4 秒。"
                    )))
                    Text(localization.format(
                        "settings.typing.grace.valueFormat",
                        defaultValue: "%.1f 秒",
                        store.typingGracePeriod
                    ))
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .frame(width: 52, alignment: .trailing)
                }
                .pluginSettingsListRowPadding(interactive: true)
            }
            .pluginSettingsCardBackground(.host)
        }
    }

    private var mappingsSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label(
                    localization.string("settings.mappings.title", defaultValue: "手势映射"),
                    systemImage: "hand.tap"
                )
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

                Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        tipTapGuideButton(compact: false)
                        addMappingButton(compact: false)
                    }
                    .fixedSize()
                    HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                        tipTapGuideButton(compact: true)
                        addMappingButton(compact: true)
                    }
                    .fixedSize()
                }
                .popover(isPresented: $isShowingTipTapGuide, arrowEdge: .top) {
                    tipTapGuide
                }
            }

            if store.mappings.isEmpty {
                emptyState
            } else {
                mappingList
            }
        }
    }

    @ViewBuilder
    private func tipTapGuideButton(compact: Bool) -> some View {
        let title = localization.string(
            "settings.mappings.tipTapGuide",
            defaultValue: "了解 TipTap"
        )
        Button {
            isShowingTipTapGuide.toggle()
        } label: {
            if compact {
                Image(systemName: "questionmark.circle")
                    .frame(
                        width: PluginSettingsTheme.Size.controlHeight,
                        height: PluginSettingsTheme.Size.controlHeight
                    )
            } else {
                Label(title, systemImage: "questionmark.circle")
                    .font(PluginSettingsTheme.Typography.controlLabel)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(Text(title))
    }

    @ViewBuilder
    private func addMappingButton(compact: Bool) -> some View {
        let title = localization.string("settings.mappings.add", defaultValue: "添加手势")
        Button(action: addMapping) {
            if compact {
                Image(systemName: "plus")
                    .frame(
                        width: PluginSettingsTheme.Size.controlHeight,
                        height: PluginSettingsTheme.Size.controlHeight
                    )
            } else {
                Label(title, systemImage: "plus")
                    .font(PluginSettingsTheme.Typography.controlLabel)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(Text(title))
        .disabled(store.mappings.count == TrackpadGesture.configurableCases.count)
    }

    private var tipTapGuide: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(
                localization.string(
                    "settings.mappings.tipTapGuide",
                    defaultValue: "了解 TipTap"
                ),
                systemImage: "hand.tap"
            )
            .font(PluginSettingsTheme.Typography.sectionTitle)

            Label(
                localization.string(
                    "settings.mappings.tipTapGuide.hold",
                    defaultValue: "先放下 1 或 2 指并保持不动。"
                ),
                systemImage: "1.circle"
            )
            Label(
                localization.string(
                    "settings.mappings.tipTapGuide.tap",
                    defaultValue: "用另一指在固定手指组的左侧或右侧轻点。"
                ),
                systemImage: "2.circle"
            )
            Label(
                localization.string(
                    "settings.mappings.tipTapGuide.repeat",
                    defaultValue: "只抬起轻点手指；固定手指保持接触即可继续轻点。"
                ),
                systemImage: "3.circle"
            )

            Label(
                localization.string(
                    "settings.mappings.tipTapGuide.middle",
                    defaultValue: "固定两指时，“中间”表示在两指之间轻点。"
                ),
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)

            Divider()

            Label(
                localization.string(
                    "settings.mappings.tipTapGuide.test",
                    defaultValue: "可使用下方的“测试”练习，不会执行已配置的操作。"
                ),
                systemImage: "waveform.path"
            )
            .foregroundStyle(.secondary)
        }
        .font(PluginSettingsTheme.Typography.rowDescription)
        .fixedSize(horizontal: false, vertical: true)
        .padding(PluginSettingsTheme.Spacing.rowHorizontal)
        .frame(width: 360, alignment: .leading)
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: "hand.tap")
                    .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                    .foregroundStyle(.secondary)
                Text(localization.string("settings.empty.title", defaultValue: "尚未配置手势"))
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(localization.string(
                    "settings.empty.description",
                    defaultValue: "仅添加你需要使用的触控板手势。"
                ))
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
                Button(action: addMapping) {
                    Text(localization.string("settings.mappings.add", defaultValue: "添加手势"))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
            Spacer()
        }
        .pluginSettingsCardBackground(.host)
    }

    private var mappingList: some View {
        VStack(spacing: 0) {
            ForEach(store.mappings) { mapping in
                mappingRow(mapping)
                if mapping.id != store.mappings.last?.id {
                    PluginSettingsListDivider()
                }
            }
        }
        .pluginSettingsCardBackground(.host)
    }

    private func mappingRow(_ mapping: TrackpadGestureMapping) -> some View {
        let gestureTitle = mapping.gesture.title(localization: localization)
        let editTitle = localization.string("settings.mapping.edit", defaultValue: "编辑映射")

        return HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Button {
                editingDraft = TrackpadGestureMappingDraft(mapping: mapping)
            } label: {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(
                        alignment: .leading,
                        spacing: PluginSettingsTheme.Spacing.rowTitleDescription
                    ) {
                        Text(mapping.gesture.title(localization: localization))
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                            .lineLimit(1)
                        Text(mappingActionTitle(mapping.action))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .pluginSettingsRowIconStyle(.secondary)
                        .frame(
                            width: PluginSettingsTheme.Size.rowIcon,
                            height: PluginSettingsTheme.Size.controlHeight
                        )
                }
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, minHeight: PluginSettingsTheme.Size.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(gestureTitle)
            .accessibilityValue(mappingActionTitle(mapping.action))
            .accessibilityHint(editTitle)
            .onHover { hovering in
                TrackpadSettingsCursor.update(isHovering: hovering)
            }
            .onDisappear {
                TrackpadSettingsCursor.reset()
            }

            Toggle(gestureTitle, isOn: Binding(
                get: { mapping.isEnabled },
                set: { enabled in
                    store.setEnabled(enabled, id: mapping.id)
                    onChange()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(gestureTitle)
        }
        .pluginSettingsListRowPadding(interactive: true)
        .contextMenu {
            Button(role: .destructive) {
                store.delete(id: mapping.id)
                onChange()
            } label: {
                Label(
                    localization.string("settings.mapping.delete", defaultValue: "删除"),
                    systemImage: "trash"
                )
            }
        }
    }

    private var testingSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(
                localization.string("settings.testing.title", defaultValue: "测试"),
                systemImage: "waveform.path"
            )
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)

            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Text(store.isTesting
                        ? localization.string("settings.testing.active", defaultValue: "正在识别手势")
                        : localization.string("settings.testing.inactive", defaultValue: "测试手势"))
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(testingDescription)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                Button {
                    onSetTesting(!store.isTesting)
                } label: {
                    Text(store.isTesting
                        ? localization.string("settings.testing.stop", defaultValue: "停止测试")
                        : localization.string("settings.testing.start", defaultValue: "开始测试"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .pluginSettingsListRowPadding(interactive: true)
            .pluginSettingsCardBackground(.host)
        }
    }

    private var testingDescription: String {
        if let gesture = store.lastTestGesture {
            return localization.format(
                "settings.testing.recognizedFormat",
                defaultValue: "已识别：%@。测试期间不会执行操作。",
                gesture.title(localization: localization)
            )
        }
        return localization.string(
            "settings.testing.description",
            defaultValue: "识别手势但不执行操作。"
        )
    }

    private var typingGracePeriodText: String {
        localization.format(
            "settings.typing.grace.valueFormat",
            defaultValue: "%.1f 秒",
            store.typingGracePeriod
        )
    }

    private func announceRecognizedTestGesture(_ gesture: TrackpadGesture) {
        let announcement = localization.format(
            "settings.testing.recognizedFormat",
            defaultValue: "已识别：%@。测试期间不会执行操作。",
            gesture.title(localization: localization)
        )
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func addMapping() {
        guard let gesture = store.availableGestures().first else {
            return
        }
        editingDraft = TrackpadGestureMappingDraft(gesture: gesture)
    }

    private func mappingActionTitle(_ action: TrackpadGestureAction) -> String {
        if case let .action(reference) = action {
            return actionHostContext?.item(for: reference)?.title
                ?? localization.string(
                    "editor.action.unavailable",
                    defaultValue: "不可用的 MacTools 操作"
                )
        }
        return action.title(localization: localization)
    }
}

private enum TrackpadGestureEditorActionKind: String, Identifiable {
    case none
    case action
    case keyboardShortcut
    case middleClick

    var id: String { rawValue }
}

private struct TrackpadGestureMappingDraft: Identifiable {
    let id: UUID
    var gesture: TrackpadGesture
    var actionKind: TrackpadGestureEditorActionKind
    var actionReference: ActionReference?
    var shortcut: ShortcutBinding?
    var isEnabled: Bool

    init(gesture: TrackpadGesture) {
        self.id = UUID()
        self.gesture = gesture
        self.actionKind = .none
        self.actionReference = nil
        self.shortcut = nil
        self.isEnabled = true
    }

    init(mapping: TrackpadGestureMapping) {
        self.id = mapping.id
        self.gesture = mapping.gesture
        self.isEnabled = mapping.isEnabled
        switch mapping.action {
        case let .action(reference):
            self.actionKind = .action
            self.actionReference = reference
            self.shortcut = nil
        case let .keyboardShortcut(shortcut):
            self.actionKind = .keyboardShortcut
            self.actionReference = nil
            self.shortcut = shortcut
        case .middleClick:
            self.actionKind = .middleClick
            self.actionReference = nil
            self.shortcut = nil
        }
    }

    var mapping: TrackpadGestureMapping? {
        let action: TrackpadGestureAction
        switch actionKind {
        case .none:
            return nil
        case .action:
            guard let actionReference else { return nil }
            action = .action(actionReference)
        case .keyboardShortcut:
            guard let shortcut, shortcut.isValid else { return nil }
            action = .keyboardShortcut(shortcut)
        case .middleClick:
            action = .middleClick
        }
        return TrackpadGestureMapping(
            id: id,
            gesture: gesture,
            action: action,
            isEnabled: isEnabled
        )
    }
}

private struct TrackpadGestureEditor: View {
    @ObservedObject var store: TrackpadGestureStore
    let localization: PluginLocalization
    let actionHostContext: TrackpadActionHostContext?
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let onSave: (TrackpadGestureMapping) -> Void

    @State private var draft: TrackpadGestureMappingDraft

    init(
        draft: TrackpadGestureMappingDraft,
        store: TrackpadGestureStore,
        localization: PluginLocalization,
        actionHostContext: TrackpadActionHostContext?,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)?,
        onSave: @escaping (TrackpadGestureMapping) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.store = store
        self.localization = localization
        self.actionHostContext = actionHostContext
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    Text(localization.string("editor.title", defaultValue: "手势映射"))
                        .font(PluginSettingsTheme.Typography.pageTitle)

                    editorSection(
                        title: localization.string("editor.gesture.title", defaultValue: "手势"),
                        icon: "hand.tap"
                    ) {
                        Picker(
                            localization.string("editor.gesture.title", defaultValue: "手势"),
                            selection: $draft.gesture
                        ) {
                            ForEach(store.availableGestures(excludingID: draft.id)) { gesture in
                                Text(gesture.title(localization: localization)).tag(gesture)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)

                        Label(
                            draft.gesture.demonstration(localization: localization),
                            systemImage: draft.gesture.systemImage
                        )
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)

                        ForEach(
                            draft.gesture.conflictGuidance(
                                localization: localization,
                                actionKind: draft.actionKind
                            ),
                            id: \.self
                        ) { guidance in
                            Label(guidance, systemImage: "exclamationmark.triangle")
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    editorSection(
                        title: localization.string("editor.action.title", defaultValue: "操作"),
                        icon: "arrow.right.circle"
                    ) {
                        TrackpadUnifiedActionPickerControl(
                            localization: localization,
                            context: actionHostContext,
                            actionKind: $draft.actionKind,
                            actionReference: $draft.actionReference,
                            shortcut: $draft.shortcut
                        )

                        if draft.actionKind == .keyboardShortcut {
                            PluginShortcutRecorder(
                                title: localization.string(
                                    "editor.shortcut.record",
                                    defaultValue: "录制快捷键"
                                ),
                                displayText: shortcutDisplayText,
                                onRecord: { binding in
                                    draft.shortcut = binding
                                    return .accepted
                                }
                            )

                            if let shortcutReuseGuidance {
                                Label(shortcutReuseGuidance, systemImage: "info.circle")
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.red)
                    }
                }
                .padding(PluginSettingsTheme.Spacing.pagePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                if let onDelete {
                    Button(
                        localization.string(
                            "settings.mapping.deleteMapping",
                            defaultValue: "删除映射"
                        ),
                        role: .destructive,
                        action: onDelete
                    )
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button(
                    localization.string("editor.cancel", defaultValue: "取消"),
                    action: onCancel
                )
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                Button(localization.string("editor.save", defaultValue: "保存")) {
                    if let mapping = draft.mapping {
                        onSave(mapping)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(validationMessage != nil || draft.mapping == nil)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.pagePadding)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 430, idealHeight: 520)
    }

    @ViewBuilder
    private func editorSection<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(title, systemImage: icon)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pluginSettingsListRowPadding(interactive: true)
            .pluginSettingsCardBackground(.plugin)
        }
    }

    private var validationMessage: String? {
        if store.conflictingMapping(for: draft.gesture, excludingID: draft.id) != nil {
            return localization.string(
                "editor.error.duplicateGesture",
                defaultValue: "该手势已配置，请选择其他手势。"
            )
        }
        if draft.actionKind == .none {
            return localization.string(
                "editor.error.actionRequired",
                defaultValue: "请选择一个操作。"
            )
        }
        if draft.actionKind == .keyboardShortcut, draft.shortcut == nil {
            return localization.string(
                "editor.error.shortcutRequired",
                defaultValue: "请录制一个键盘快捷键。"
            )
        }
        if draft.actionKind == .action, draft.actionReference == nil {
            return localization.string(
                "editor.error.actionRequired",
                defaultValue: "请选择一个操作。"
            )
        }
        return nil
    }

    private var shortcutDisplayText: String {
        guard let shortcut = draft.shortcut else {
            return localization.string("editor.shortcut.unset", defaultValue: "未设置")
        }
        return ShortcutFormatter.displayString(for: shortcut)
    }

    private var shortcutReuseGuidance: String? {
        guard draft.actionKind == .keyboardShortcut,
              let shortcut = draft.shortcut
        else {
            return nil
        }
        let gestureTitles = store.mappings(
            using: shortcut,
            excludingID: draft.id
        ).map { $0.gesture.title(localization: localization) }
        guard !gestureTitles.isEmpty else {
            return nil
        }
        return localization.format(
            "editor.shortcut.reusedFormat",
            defaultValue: "此快捷键也用于：%@。允许重复使用。",
            gestureTitles.joined(separator: ", ")
        )
    }
}

private struct TrackpadActionPickerGroup: Identifiable {
    let title: String
    let items: [ActionSurfaceCatalogItem]

    var id: String { title }
}

private enum TrackpadInputActionChoice: String, CaseIterable, Identifiable {
    case keyboardShortcut
    case middleClick

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .keyboardShortcut: "keyboard"
        case .middleClick: "computermouse"
        }
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .keyboardShortcut:
            localization.string("action.shortcut", defaultValue: "键盘快捷键")
        case .middleClick:
            localization.string("action.middleClick", defaultValue: "鼠标中键")
        }
    }
}

private struct TrackpadUnifiedActionPickerControl: View {
    let localization: PluginLocalization
    let context: TrackpadActionHostContext?
    @Binding var actionKind: TrackpadGestureEditorActionKind
    @Binding var actionReference: ActionReference?
    @Binding var shortcut: ShortcutBinding?

    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: selectedSystemImage)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(actionKind == .none ? Color.secondary : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(actionKind == .none ? 0.06 : 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTitle)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let selectedSubtitle {
                        Text(selectedSubtitle)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minWidth: 340, idealWidth: 390, maxWidth: 440, minHeight: 52)
            .contentShape(Rectangle())
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.control)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            pickerContent
        }
        .accessibilityIdentifier("mactools.trackpad.action-picker")
        .accessibilityLabel(localization.string("editor.action.title", defaultValue: "操作"))
        .accessibilityValue(selectedTitle)
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                localization.string("editor.action.search", defaultValue: "搜索操作"),
                text: $query
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("mactools.trackpad.action-picker.search")

            Divider()

            if !hasResults {
                ContentUnavailableView(
                    localization.string("editor.action.empty", defaultValue: "没有匹配的操作"),
                    systemImage: "magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !filteredInputActions.isEmpty {
                            pickerGroup(
                                title: localization.string(
                                    "editor.action.inputGroup",
                                    defaultValue: "输入"
                                )
                            ) {
                                ForEach(filteredInputActions) { choice in
                                    inputActionRow(choice)
                                }
                            }
                        }

                        ForEach(groups) { group in
                            pickerGroup(title: group.title) {
                                ForEach(group.items) { item in
                                    macToolsActionRow(item)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .frame(width: 460, height: 500)
    }

    private var selectedItem: ActionSurfaceCatalogItem? {
        guard actionKind == .action, let actionReference else { return nil }
        return context?.item(for: actionReference)
    }

    private var selectedTitle: String {
        switch actionKind {
        case .none:
            localization.string("editor.action.choose", defaultValue: "选择操作…")
        case .action:
            selectedItem?.title ?? localization.string(
                "editor.action.unavailable",
                defaultValue: "不可用的 MacTools 操作"
            )
        case .keyboardShortcut:
            localization.string("action.shortcut", defaultValue: "键盘快捷键")
        case .middleClick:
            localization.string("action.middleClick", defaultValue: "鼠标中键")
        }
    }

    private var selectedSubtitle: String? {
        switch actionKind {
        case .none, .middleClick:
            nil
        case .action:
            selectedItem?.ownerTitle
        case .keyboardShortcut:
            shortcut.map(ShortcutFormatter.displayString(for:))
                ?? localization.string("editor.shortcut.unset", defaultValue: "未设置")
        }
    }

    private var selectedSystemImage: String {
        switch actionKind {
        case .none: "bolt.circle"
        case .action: selectedItem?.systemImage ?? "questionmark.square.dashed"
        case .keyboardShortcut: TrackpadInputActionChoice.keyboardShortcut.systemImage
        case .middleClick: TrackpadInputActionChoice.middleClick.systemImage
        }
    }

    private var hasResults: Bool {
        !filteredInputActions.isEmpty || !groups.isEmpty
    }

    private var filteredInputActions: [TrackpadInputActionChoice] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return TrackpadInputActionChoice.allCases.filter { choice in
            normalizedQuery.isEmpty
                || choice.title(localization: localization)
                    .localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var groups: [TrackpadActionPickerGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = (context?.catalog ?? []).filter { item in
            guard item.availability.isAvailable else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return [item.title, item.subtitle, item.ownerTitle]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
        let grouped = Dictionary(grouping: items, by: \.ownerTitle)
        return grouped.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { owner in
            TrackpadActionPickerGroup(title: owner, items: grouped[owner] ?? [])
        }
    }

    @ViewBuilder
    private func pickerGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func inputActionRow(_ choice: TrackpadInputActionChoice) -> some View {
        Button {
            actionReference = nil
            switch choice {
            case .keyboardShortcut:
                actionKind = .keyboardShortcut
            case .middleClick:
                actionKind = .middleClick
                shortcut = nil
            }
            isPresented = false
        } label: {
            pickerRow(
                title: choice.title(localization: localization),
                subtitle: choice == .keyboardShortcut
                    ? shortcut.map(ShortcutFormatter.displayString(for:))
                    : nil,
                systemImage: choice.systemImage,
                isSafe: true,
                isSelected: isSelected(choice)
            )
        }
        .buttonStyle(.plain)
    }

    private func macToolsActionRow(_ item: ActionSurfaceCatalogItem) -> some View {
        Button {
            actionKind = .action
            actionReference = item.reference
            shortcut = nil
            isPresented = false
        } label: {
            pickerRow(
                title: item.title,
                subtitle: item.subtitle,
                systemImage: item.systemImage,
                isSafe: item.isSafe,
                isSelected: actionKind == .action && actionReference == item.reference
            )
        }
        .buttonStyle(.plain)
        .disabled(!item.availability.isAvailable)
    }

    private func pickerRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        isSafe: Bool,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .frame(width: 20)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isSafe {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func isSelected(_ choice: TrackpadInputActionChoice) -> Bool {
        switch choice {
        case .keyboardShortcut: actionKind == .keyboardShortcut
        case .middleClick: actionKind == .middleClick
        }
    }
}

@MainActor
private enum TrackpadSettingsCursor {
    static func update(isHovering: Bool) {
        (isHovering ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    static func reset() {
        NSCursor.arrow.set()
    }
}

extension TrackpadGesture {
    var systemImage: String {
        longTouchFingerCount == nil ? "hand.tap" : "hand.raised"
    }

    func title(localization: PluginLocalization) -> String {
        switch self {
        case .tipTapLeftOneFixed:
            localization.string("gesture.tipTapLeftOneFixed", defaultValue: "TipTap 左侧（1 指固定）")
        case .tipTapRightOneFixed:
            localization.string("gesture.tipTapRightOneFixed", defaultValue: "TipTap 右侧（1 指固定）")
        case .tipTapLeftTwoFixed:
            localization.string("gesture.tipTapLeftTwoFixed", defaultValue: "TipTap 左侧（2 指固定）")
        case .tipTapMiddleTwoFixed:
            localization.string("gesture.tipTapMiddleTwoFixed", defaultValue: "TipTap 中间（2 指固定）")
        case .tipTapRightTwoFixed:
            localization.string("gesture.tipTapRightTwoFixed", defaultValue: "TipTap 右侧（2 指固定）")
        case .threeFingerTap:
            localization.string("gesture.threeFingerTap", defaultValue: "三指轻点")
        case .fourFingerTap:
            localization.string("gesture.fourFingerTap", defaultValue: "四指轻点")
        case .fiveFingerTap:
            localization.string("gesture.fiveFingerTap", defaultValue: "五指轻点")
        case .threeFingerLongTouch:
            localization.string("gesture.threeFingerLongTouch", defaultValue: "三指长触")
        case .fourFingerLongTouch:
            localization.string("gesture.fourFingerLongTouch", defaultValue: "四指长触")
        case .fiveFingerLongTouch:
            localization.string("gesture.fiveFingerLongTouch", defaultValue: "五指长触")
        case .threeFingerDoubleTap, .fourFingerDoubleTap, .fiveFingerDoubleTap:
            localization.format(
                "gesture.doubleTapFormat",
                defaultValue: "%d 指双击",
                doubleFingerTapCount ?? 3
            )
        }
    }

    func demonstration(localization: PluginLocalization) -> String {
        if let configuration = tipTapConfiguration {
            return localization.format(
                "gesture.demo.tipTapFormat",
                defaultValue: "保持 %d 指不动，再用一指反复轻点指定区域。",
                configuration.fixedFingerCount
            )
        }
        if let count = fingerTapCount {
            return localization.format(
                "gesture.demo.tapFormat",
                defaultValue: "%d 指同时轻触并抬起。",
                count
            )
        }
        if let count = doubleFingerTapCount {
            return localization.format(
                "gesture.demo.doubleTapFormat",
                defaultValue: "%d 指连续轻触并抬起两次。",
                count
            )
        }
        return localization.format(
            "gesture.demo.longTouchFormat",
            defaultValue: "%d 指保持接触约半秒。",
            longTouchFingerCount ?? 3
        )
    }

    fileprivate func conflictGuidance(
        localization: PluginLocalization,
        actionKind: TrackpadGestureEditorActionKind
    ) -> [String] {
        var guidance: [String] = []
        if tipTapConfiguration != nil || actionKind == .middleClick {
            guidance.append(localization.string(
                "gesture.conflict.secondaryClick",
                defaultValue: "macOS 不提供原生点击来源。MacTools 仅在一个手势候选活动时关联点击；同时点击外接鼠标时可能发生冲突。"
            ))
        }

        switch self {
        case .threeFingerTap, .threeFingerLongTouch, .threeFingerDoubleTap:
            guidance.append(localization.string(
                "gesture.conflict.threeFinger",
                defaultValue: "可能与“查询与数据检测器”或三指拖移冲突。"
            ))
        case .fourFingerTap, .fourFingerLongTouch, .fourFingerDoubleTap:
            guidance.append(localization.string(
                "gesture.conflict.fourFinger",
                defaultValue: "可能与调度中心、App Exposé 或全屏切换手势冲突。"
            ))
        case .tipTapLeftOneFixed, .tipTapRightOneFixed,
             .tipTapLeftTwoFixed, .tipTapMiddleTwoFixed, .tipTapRightTwoFixed,
             .fiveFingerTap, .fiveFingerLongTouch, .fiveFingerDoubleTap:
            break
        }
        return guidance
    }
}

extension TrackpadGestureAction {
    func title(localization: PluginLocalization) -> String {
        switch self {
        case .action:
            localization.string("action.macToolsAction", defaultValue: "MacTools 操作")
        case let .keyboardShortcut(binding):
            localization.format(
                "action.shortcutFormat",
                defaultValue: "快捷键 %@",
                ShortcutFormatter.displayString(for: binding)
            )
        case .middleClick:
            localization.string("action.middleClick", defaultValue: "鼠标中键")
        }
    }
}
