import AppKit
import SwiftUI
import MacToolsPluginKit

struct TrackpadGesturesSettingsView: View {
    enum SectionKind {
        case mappings
        case typingProtection
        case testing
    }

    @ObservedObject var store: TrackpadGestureStore
    let localization: PluginLocalization
    let onChange: () -> Void
    let onSetTesting: (Bool) -> Void
    let section: SectionKind

    @State private var editingDraft: TrackpadGestureMappingDraft?
    @State private var isShowingTipTapGuide = false

    @ViewBuilder
    var body: some View {
        switch section {
        case .mappings:
            mappingsContent
        case .typingProtection:
            typingProtectionSection
        case .testing:
            testingContent
        }
    }

    private var mappingsContent: some View {
        mappingsSection
        .sheet(item: $editingDraft) { draft in
            TrackpadGestureEditor(
                draft: draft,
                store: store,
                localization: localization,
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
    }

    private var testingContent: some View {
        testingSection
        .onChange(of: store.lastTestGesture) { _, gesture in
            guard let gesture else { return }
            announceRecognizedTestGesture(gesture)
        }
    }

    private var typingProtectionSection: some View {
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
                    PluginSettingsSlider(
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
    }

    private var mappingsSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
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
            .pluginSettingsListRowPadding()

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
                        Text(mapping.action.title(localization: localization))
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
            .accessibilityValue(mapping.action.title(localization: localization))
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
}

private enum TrackpadGestureEditorActionKind: String, CaseIterable, Identifiable {
    case keyboardShortcut
    case middleClick

    var id: String { rawValue }
}

private struct TrackpadGestureMappingDraft: Identifiable {
    let id: UUID
    var gesture: TrackpadGesture
    var actionKind: TrackpadGestureEditorActionKind
    var shortcut: ShortcutBinding?
    var isEnabled: Bool

    init(gesture: TrackpadGesture) {
        self.id = UUID()
        self.gesture = gesture
        self.actionKind = .keyboardShortcut
        self.shortcut = nil
        self.isEnabled = true
    }

    init(mapping: TrackpadGestureMapping) {
        self.id = mapping.id
        self.gesture = mapping.gesture
        self.isEnabled = mapping.isEnabled
        switch mapping.action {
        case let .keyboardShortcut(shortcut):
            self.actionKind = .keyboardShortcut
            self.shortcut = shortcut
        case .middleClick:
            self.actionKind = .middleClick
            self.shortcut = nil
        }
    }

    var mapping: TrackpadGestureMapping? {
        let action: TrackpadGestureAction
        switch actionKind {
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
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    let onSave: (TrackpadGestureMapping) -> Void

    @State private var draft: TrackpadGestureMappingDraft

    init(
        draft: TrackpadGestureMappingDraft,
        store: TrackpadGestureStore,
        localization: PluginLocalization,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)?,
        onSave: @escaping (TrackpadGestureMapping) -> Void
    ) {
        _draft = State(initialValue: draft)
        self.store = store
        self.localization = localization
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
                        Picker(
                            localization.string("editor.action.title", defaultValue: "操作"),
                            selection: $draft.actionKind
                        ) {
                            Text(localization.string("action.shortcut", defaultValue: "键盘快捷键"))
                                .tag(TrackpadGestureEditorActionKind.keyboardShortcut)
                            Text(localization.string("action.middleClick", defaultValue: "鼠标中键"))
                                .tag(TrackpadGestureEditorActionKind.middleClick)
                        }
                        .pickerStyle(.segmented)
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)

                        if draft.actionKind == .keyboardShortcut {
                            PluginSettingsShortcutControlLayout {
                                Label(
                                    localization.string(
                                        "editor.shortcut.record",
                                        defaultValue: "录制快捷键"
                                    ),
                                    systemImage: "keyboard"
                                )
                                .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                                .lineLimit(1)

                                PluginShortcutRecorder(
                                    title: localization.string(
                                        "editor.shortcut.record",
                                        defaultValue: "录制快捷键"
                                    ),
                                    displayText: shortcutDisplayText,
                                    minWidth: PluginSettingsTheme.Size.shortcutRecorderWidth,
                                    onRecord: { binding in
                                        draft.shortcut = binding
                                        return .accepted
                                    }
                                )
                                .frame(width: PluginSettingsTheme.Size.shortcutRecorderWidth)
                            }

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
            .pluginSettingsCardBackground(.standard)
        }
    }

    private var validationMessage: String? {
        if store.conflictingMapping(for: draft.gesture, excludingID: draft.id) != nil {
            return localization.string(
                "editor.error.duplicateGesture",
                defaultValue: "该手势已配置，请选择其他手势。"
            )
        }
        if draft.actionKind == .keyboardShortcut, draft.shortcut == nil {
            return localization.string(
                "editor.error.shortcutRequired",
                defaultValue: "请录制一个键盘快捷键。"
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
