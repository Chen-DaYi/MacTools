import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

struct MacSettingsWorkspaceView: View {
    @ObservedObject var controller: MacSettingsController
    @FocusState private var searchFocused: Bool

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 270)

            content
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: controller.searchFocusRequest) {
            searchFocused = true
        }
        .task {
            if controller.rowStates.values.contains(where: \.isLoading) {
                controller.refresh()
            }
        }
    }

    private var sidebar: some View {
        List(selection: $controller.destination) {
            Section("当前 Mac") {
                sidebarRow("所有设置", image: "slider.horizontal.3", destination: .all)
                sidebarRow("个人收藏", image: "star", destination: .favorites)
                sidebarRow("最近更改", image: "clock.arrow.circlepath", destination: .recent)
                sidebarRow(
                    "需要关注",
                    image: "exclamationmark.triangle",
                    destination: .attention,
                    count: controller.attentionCount
                )
            }

            Section("类别") {
                ForEach(controller.availableCategories) { category in
                    sidebarRow(
                        category.title,
                        image: category.systemImage,
                        destination: .category(category)
                    )
                }
            }

            Section("高级") {
                sidebarRow("配置", image: "square.stack.3d.up", destination: .profiles)
                sidebarRow("导入与导出", image: "arrow.up.arrow.down.square", destination: .importExport)
                sidebarRow("更改历史", image: "list.bullet.rectangle", destination: .history)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Mac 设置导航")
    }

    private func sidebarRow(
        _ title: String,
        image: String,
        destination: MacSettingsDestination,
        count: Int = 0
    ) -> some View {
        HStack {
            Label(title, systemImage: image)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(destination)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.destination {
        case .profiles:
            MacSettingsProfilesView(controller: controller)
        case .importExport:
            MacSettingsImportExportView(controller: controller)
        case .history:
            MacSettingsHistoryView(controller: controller)
        case .all, .favorites, .recent, .attention, .category:
            liveSettings
        }
    }

    private var liveSettings: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("搜索设置", text: $controller.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .accessibilityLabel("搜索 Mac 设置")

                Picker("密度", selection: Binding(
                    get: { controller.density },
                    set: { newDensity in controller.setDensity(newDensity) }
                )) {
                    Text("舒适").tag(MacSettingsWorkspaceDensity.comfortable)
                    Text("紧凑").tag(MacSettingsWorkspaceDensity.compact)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 120)

                Button {
                    controller.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
                .frame(width: 28, height: 28)
                .help("刷新当前值")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            if controller.visibleRecords.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyImage,
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                        ForEach(groupedRecords, id: \.0) { category, records in
                            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                                Label(category.title, systemImage: category.systemImage)
                                    .font(PluginSettingsTheme.Typography.sectionTitle)
                                    .foregroundStyle(.secondary)

                                VStack(spacing: 0) {
                                    ForEach(records, id: \.id) { record in
                                        MacSettingRow(
                                            record: record,
                                            state: controller.rowStates[record.id],
                                            isFavorite: controller.favoriteIDs.contains(record.id),
                                            density: controller.density,
                                            onApply: { controller.apply($0, to: record.id) },
                                            onFavorite: { controller.toggleFavorite(record.id) },
                                            favoriteIndex: controller.destination == .favorites
                                                ? controller.favoriteIDs.firstIndex(of: record.id)
                                                : nil,
                                            favoriteCount: controller.favoriteIDs.count,
                                            onMoveFavorite: { controller.moveFavorite(record.id, by: $0) },
                                            onOpenSystemSettings: { controller.openSystemSettings(for: record.id) }
                                        )
                                        if record.id != records.last?.id {
                                            Divider().padding(.leading, 42)
                                        }
                                    }
                                }
                                .pluginSettingsCardBackground(.standard)
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private var groupedRecords: [(SystemSettingCategory, [SystemSettingRecord])] {
        controller.availableCategories.compactMap { category in
            let records = controller.visibleRecords.filter { $0.definition.category == category }
            return records.isEmpty ? nil : (category, records)
        }
    }

    private var emptyTitle: String {
        switch controller.destination {
        case .favorites: "暂无收藏"
        case .attention: "无需关注"
        case .recent: "暂无最近更改"
        default: "未找到设置"
        }
    }

    private var emptyImage: String {
        controller.destination == .attention ? "checkmark.circle" : "magnifyingglass"
    }

    private var emptyDescription: String {
        switch controller.destination {
        case .favorites: "点按设置旁的星标，即可在这里快速访问。"
        case .attention: "当前没有失败、缺少条件或待完成的设置。"
        case .recent: "通过 MacTools 更改设置后会显示在这里。"
        default: "尝试其他关键词或类别。"
        }
    }
}

private struct MacSettingRow: View {
    let record: SystemSettingRecord
    let state: SystemSettingRowState?
    let isFavorite: Bool
    let density: MacSettingsWorkspaceDensity
    let onApply: (SystemSettingValue) -> Void
    let onFavorite: () -> Void
    let favoriteIndex: Int?
    let favoriteCount: Int
    let onMoveFavorite: (Int) -> Void
    let onOpenSystemSettings: () -> Void

    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: detailsExpanded ? 10 : 0) {
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: record.definition.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    HStack(spacing: 6) {
                        Text(record.definition.title)
                            .font(PluginSettingsTheme.Typography.rowTitle)
                            .lineLimit(1)
                        availabilityBadge
                    }
                    if density == .comfortable {
                        Text(record.definition.description)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let error = state?.errorMessage {
                        Text(error)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 12)

                if state?.isLoading == true || state?.isApplying == true {
                    ProgressView().controlSize(.small)
                } else {
                    settingControl
                }

                Button(action: onFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundStyle(isFavorite ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "取消收藏" : "添加到收藏")
                .accessibilityLabel(isFavorite ? "取消收藏 \(record.definition.title)" : "收藏 \(record.definition.title)")

                if let favoriteIndex {
                    Button { onMoveFavorite(-1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .disabled(favoriteIndex == 0)
                    .help("在功能面板中前移")
                    .accessibilityLabel("前移收藏 \(record.definition.title)")

                    Button { onMoveFavorite(1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(favoriteIndex == favoriteCount - 1)
                    .help("在功能面板中后移")
                    .accessibilityLabel("后移收藏 \(record.definition.title)")
                }

                Button {
                    detailsExpanded.toggle()
                } label: {
                    Image(systemName: detailsExpanded ? "chevron.up" : "info.circle")
                }
                .buttonStyle(.plain)
                .help("设置详情")
                .accessibilityLabel("显示 \(record.definition.title) 的详情")
            }

            if detailsExpanded {
                HStack(alignment: .top, spacing: 12) {
                    Color.clear.frame(width: 22, height: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(detailText)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if record.definition.destination != nil {
                            Button("在系统设置中打开", action: onOpenSystemSettings)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
        .padding(.vertical, density == .compact ? 7 : PluginSettingsTheme.Spacing.rowVertical)
        .contentShape(Rectangle())
        .focusable()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var settingControl: some View {
        let availability = state?.availability ?? .unsupported("无法读取状态。")
        if isDirectlyControllable(availability), let value = state?.value {
            SystemSettingValueControl(
                schema: record.definition.schema,
                value: value,
                enabled: state?.isApplying != true,
                compact: true,
                sliderPresentation: record.id == "accessibility.pointer-size"
                    ? .pointerSize
                    : .standard,
                onChange: onApply
            )
        } else {
            switch availability {
            case .guidedManual:
                Button("打开系统设置", action: onOpenSystemSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .permissionMissing:
                Button("前往授权", action: onOpenSystemSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .providerUnavailable:
                Button("查看插件", action: onOpenSystemSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            default:
                Text(statusText(for: availability))
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var availabilityBadge: some View {
        if let state {
            switch state.availability {
            case .requiresLogout:
                badge("需重新登录", color: .orange)
            case .requiresRestart:
                badge("需重新打开应用", color: .orange)
            case .guidedManual:
                badge("手动", color: .blue)
            case .hardwareUnavailable, .providerUnavailable, .permissionMissing:
                badge("不可用", color: .orange)
            case .managedOnly:
                badge("受管理", color: .purple)
            case .unsupported, .systemVersionUnsupported:
                badge("不支持", color: .secondary)
            case .available:
                if state.verification == .verified {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help("已验证")
                } else if state.verification == .unverified {
                    badge("未验证", color: .orange)
                }
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(PluginSettingsTheme.Typography.statusBadge)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }

    private var detailText: String {
        let execution = switch record.definition.executionClass {
        case .directVerified: "可直接更改并验证"
        case .directAppliesNextUse: "已保存并验证；下次使用时生效"
        case .directRequiresLogout: "可直接更改；重新登录后完全生效"
        case .directRequiresRestart: "可直接更改；重新打开相关应用后完全生效"
        case .existingPluginProvider: "由现有 MacTools 插件执行并验证"
        case .guidedManual: "需要在系统设置中手动完成"
        case .hardwareDependent: "需要受支持的硬件"
        case .managedOnly: "只能由组织管理"
        case .unsupported: "当前不支持直接更改"
        }
        return "\(execution)。\n\(record.definition.implementationNote)"
    }

    private var accessibilityDescription: String {
        let value = state?.value?.conciseDescription ?? "未知"
        let favorite = isFavorite ? "，已收藏" : ""
        return "\(record.definition.title)，当前值 \(value)\(favorite)。\(record.definition.description)"
    }

    private func isDirectlyControllable(_ availability: SystemSettingAvailability) -> Bool {
        switch availability {
        case .available, .requiresLogout, .requiresRestart: true
        default: false
        }
    }

    private func statusText(for availability: SystemSettingAvailability) -> String {
        switch availability {
        case .available: "可用"
        case .requiresLogout: "需重新登录"
        case .requiresRestart: "需重新打开应用"
        case .providerUnavailable: "插件不可用"
        case .hardwareUnavailable: "硬件不可用"
        case .permissionMissing: "缺少权限"
        case .guidedManual: "手动设置"
        case .managedOnly: "由组织管理"
        case .unsupported: "不支持"
        case .systemVersionUnsupported: "系统版本不支持"
        }
    }
}

struct SystemSettingValueControl: View {
    let schema: SystemSettingValueSchema
    let value: SystemSettingValue
    let enabled: Bool
    let compact: Bool
    var sliderPresentation: SystemSettingSliderPresentation = .standard
    let onChange: (SystemSettingValue) -> Void

    var body: some View {
        switch (schema, value) {
        case let (.boolean, .boolean(isOn)):
            Toggle("", isOn: Binding(get: { isOn }, set: { onChange(.boolean($0)) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!enabled)
        case let (.choice(options), .choice(selectionID)):
            Picker("", selection: Binding(
                get: { selectionID },
                set: { onChange(.choice(id: $0)) }
            )) {
                ForEach(options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 110, idealWidth: 140, maxWidth: 180)
            .disabled(!enabled)
        case let (.integer(range, step), .integer(integer)):
            SystemSettingSliderControl(
                value: Double(integer),
                range: Double(range.lowerBound) ... Double(range.upperBound),
                step: Double(step),
                fractionDigits: 0,
                enabled: enabled,
                presentation: sliderPresentation,
                onCommit: { onChange(.integer(Int($0.rounded()))) }
            )
        case let (.decimal(range, step), .decimal(decimal)):
            SystemSettingSliderControl(
                value: decimal,
                range: range,
                step: step ?? 0.01,
                fractionDigits: step.map { $0 < 1 ? 1 : 0 } ?? 2,
                enabled: enabled,
                presentation: sliderPresentation,
                onCommit: { onChange(.decimal($0)) }
            )
        case (.url, .url(let url)):
            Button(url.lastPathComponent.isEmpty ? "选择…" : url.lastPathComponent) {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.directoryURL = url
                PluginPresentationSafety.prepareForWindowOrdering()
                guard panel.runModal() == .OK, let selected = panel.url else { return }
                onChange(.url(selected))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: 180)
            .lineLimit(1)
            .disabled(!enabled)
        default:
            Text(value.conciseDescription)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .foregroundStyle(.secondary)
        }
    }
}

enum SystemSettingSliderPresentation {
    case standard
    case pointerSize
}

private struct SystemSettingSliderControl: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let fractionDigits: Int
    let enabled: Bool
    let presentation: SystemSettingSliderPresentation
    let onCommit: (Double) -> Void

    @State private var draft: Double

    init(
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        fractionDigits: Int,
        enabled: Bool,
        presentation: SystemSettingSliderPresentation,
        onCommit: @escaping (Double) -> Void
    ) {
        self.value = value
        self.range = range
        self.step = step
        self.fractionDigits = fractionDigits
        self.enabled = enabled
        self.presentation = presentation
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        Group {
            switch presentation {
            case .standard:
                standardSlider
            case .pointerSize:
                pointerSizeSlider
            }
        }
        .disabled(!enabled)
        .onChange(of: value) { draft = value }
    }

    private var standardSlider: some View {
        HStack(spacing: 8) {
            slider
                .frame(minWidth: 90, idealWidth: 120, maxWidth: 150)
            Text(formattedDraft)
                .font(PluginSettingsTheme.Typography.monospacedValue)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var pointerSizeSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            slider
                .frame(minWidth: 130, idealWidth: 170, maxWidth: 210)
                .accessibilityLabel("指针大小")
                .accessibilityValue(formattedDraft)

            Image(systemName: "cursorarrow")
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var slider: some View {
            Slider(value: $draft, in: range, step: step) { editing in
                if !editing { onCommit(draft) }
            }
    }

    private var formattedDraft: String {
        draft.formatted(.number.precision(.fractionLength(fractionDigits)))
    }
}

private struct MacSettingsHistoryView: View {
    @ObservedObject var controller: MacSettingsController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader("更改历史", description: "仅记录通过 MacTools 完成的本地更改。") {
                Button("清除历史", action: controller.clearHistory)
                    .disabled(controller.history.isEmpty)
            }
            Divider()
            if controller.history.isEmpty {
                ContentUnavailableView("暂无更改", systemImage: "clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(controller.history) { change in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.settingTitle)
                                .font(PluginSettingsTheme.Typography.rowTitle)
                            Text("\(change.previousValue.conciseDescription) → \(change.newValue.conciseDescription)")
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                            Text(change.date, format: .dateTime.year().month().day().hour().minute())
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(change.verification == .verified ? "已验证" : "未验证")
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(change.verification == .verified ? .green : .orange)
                        if change.canRollback {
                            Button("恢复") { controller.rollback(change) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct MacSettingsProfilesView: View {
    @ObservedObject var controller: MacSettingsController
    @State private var editorDraft: SystemSettingsProfileDraft?
    @State private var editingProfile: SystemSettingsProfile?
    @State private var showsEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader("配置", description: "保存并选择性应用一组期望设置。") {
                Button("新建配置") {
                    editingProfile = nil
                    editorDraft = controller.makeDraft()
                    showsEditor = true
                }
                .buttonStyle(.borderedProminent)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    if !controller.builtInTemplates.isEmpty {
                        profileSection("内置模板", image: "sparkles", profiles: controller.builtInTemplates, isTemplate: true)
                    }
                    profileSection("我的配置", image: "square.stack.3d.up", profiles: controller.profiles, isTemplate: false)
                    if let plan = controller.activePlan {
                        MacSettingsProfilePlanView(controller: controller, plan: plan)
                    }
                }
                .padding(18)
            }
        }
        .sheet(isPresented: $showsEditor) {
            if let editorDraft {
                MacSettingsProfileEditorView(
                    controller: controller,
                    initialDraft: editorDraft,
                    profile: editingProfile,
                    onCancel: { showsEditor = false },
                    onSave: { draft in
                        if controller.saveDraft(draft, replacing: editingProfile) {
                            showsEditor = false
                        }
                    }
                )
                .frame(minWidth: 720, minHeight: 600)
            }
        }
    }

    private func profileSection(
        _ title: String,
        image: String,
        profiles: [SystemSettingsProfile],
        isTemplate: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(title, systemImage: image)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
            if profiles.isEmpty {
                Text("暂无配置")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsCardBackground(.standard)
            } else {
                VStack(spacing: 0) {
                    ForEach(profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).font(PluginSettingsTheme.Typography.rowTitle)
                                Text(profile.profileDescription.isEmpty ? "\(profile.entries.count) 项设置" : profile.profileDescription)
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text("\(profile.entries.count) 项")
                                .font(PluginSettingsTheme.Typography.statusBadge)
                                .foregroundStyle(.secondary)
                            Button("预览并应用") { controller.preparePlan(for: profile) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            if isTemplate {
                                Button("保存副本") { controller.saveTemplate(profile) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            } else {
                                Menu {
                                    Button("编辑") {
                                        editingProfile = profile
                                        editorDraft = controller.makeDraft(from: profile)
                                        showsEditor = true
                                    }
                                    Button("删除", role: .destructive) { controller.removeProfile(profile) }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 28)
                            }
                        }
                        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
                        if profile.id != profiles.last?.id { Divider() }
                    }
                }
                .pluginSettingsCardBackground(.standard)
            }
        }
    }
}

private struct MacSettingsProfileEditorView: View {
    @ObservedObject var controller: MacSettingsController
    @State private var draft: SystemSettingsProfileDraft
    let profile: SystemSettingsProfile?
    let onCancel: () -> Void
    let onSave: (SystemSettingsProfileDraft) -> Void

    init(
        controller: MacSettingsController,
        initialDraft: SystemSettingsProfileDraft,
        profile: SystemSettingsProfile?,
        onCancel: @escaping () -> Void,
        onSave: @escaping (SystemSettingsProfileDraft) -> Void
    ) {
        self.controller = controller
        _draft = State(initialValue: initialDraft)
        self.profile = profile
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile == nil ? "新建配置" : "编辑配置")
                        .font(PluginSettingsTheme.Typography.pageTitle)
                    Text("勾选表示配置会管理该设置；关闭仍是一个明确的期望值。")
                        .font(PluginSettingsTheme.Typography.pageDescription)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", action: onCancel)
                Button("保存") { onSave(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !draft.items.contains(where: \.isIncluded))
            }
            .padding(18)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("配置名称", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                    TextField("说明（可选）", text: $draft.profileDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2 ... 4)

                    ForEach(controller.availableCategories) { category in
                        let categoryRecords = controller.catalog.records.filter {
                            $0.definition.category == category && $0.definition.isProfileEligible
                        }
                        if !categoryRecords.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(category.title, systemImage: category.systemImage)
                                        .font(PluginSettingsTheme.Typography.sectionTitle)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("全选") { draft.setIncluded(true, in: category, catalog: controller.catalog) }
                                        .buttonStyle(.link)
                                    Button("取消全选") { draft.setIncluded(false, in: category, catalog: controller.catalog) }
                                        .buttonStyle(.link)
                                }

                                VStack(spacing: 0) {
                                    ForEach(categoryRecords, id: \.id) { record in
                                        if let index = draft.items.firstIndex(where: { $0.settingID == record.id }) {
                                            HStack(spacing: 12) {
                                                Toggle("", isOn: $draft.items[index].isIncluded)
                                                    .labelsHidden()
                                                    .accessibilityLabel("在配置中包含 \(record.definition.title)")
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(record.definition.title)
                                                        .font(PluginSettingsTheme.Typography.rowTitle)
                                                    Text("当前：\(controller.rowStates[record.id]?.value?.conciseDescription ?? "未知")")
                                                        .font(PluginSettingsTheme.Typography.rowDescription)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                SystemSettingValueControl(
                                                    schema: record.definition.schema,
                                                    value: draft.items[index].desiredValue,
                                                    enabled: true,
                                                    compact: true,
                                                    onChange: { draft.setDesiredValue($0, for: record.id) }
                                                )
                                            }
                                            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                                            .padding(.vertical, PluginSettingsTheme.Spacing.interactiveRowVertical)
                                            if record.id != categoryRecords.last?.id { Divider() }
                                        }
                                    }
                                }
                                .pluginSettingsCardBackground(.standard)
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }
}

private struct MacSettingsProfilePlanView: View {
    @ObservedObject var controller: MacSettingsController
    let plan: SystemSettingsProfileApplyPlan

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label("比较与应用 · \(plan.profileName)", systemImage: "arrow.triangle.2.circlepath")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("应用所选更改") { controller.applyActivePlan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!plan.items.contains(where: { $0.isSelected }))
            }

            VStack(spacing: 0) {
                ForEach(plan.items) { item in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { item.isSelected },
                            set: { selected in
                                var ids = Set(plan.items.filter(\.isSelected).map(\.settingID))
                                if selected { ids.insert(item.settingID) } else { ids.remove(item.settingID) }
                                controller.updatePlanSelection(ids)
                            }
                        ))
                        .labelsHidden()
                        .disabled(!item.status.canSelect)
                        Text(item.title).frame(maxWidth: .infinity, alignment: .leading)
                        Text(item.currentValue?.conciseDescription ?? "未知")
                            .frame(width: 90, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(item.desiredValue.conciseDescription)
                            .frame(width: 90, alignment: .leading)
                        Text(planStatusText(item.status))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                            .foregroundStyle(item.status.canSelect ? .primary : .secondary)
                            .frame(width: 115, alignment: .leading)
                    }
                    .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                    .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
                    if item.id != plan.items.last?.id { Divider() }
                }
            }
            .pluginSettingsCardBackground(.standard)

            if let report = controller.lastApplyReport {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(report.hasPartialSuccess ? "部分完成" : "已完成")
                            .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                        Spacer()
                        if !report.rollbackPoint.entries.isEmpty {
                            Button("回滚此次应用") { controller.rollbackLastApply() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    ForEach(report.results) { result in
                        HStack {
                            Text(result.title)
                            Spacer()
                            Text(applyResultText(result.kind))
                                .foregroundStyle(result.kind == .appliedAndVerified ? .green : .secondary)
                            if let message = result.message {
                                Text(message).foregroundStyle(.red).lineLimit(1)
                            }
                        }
                        .font(PluginSettingsTheme.Typography.rowDescription)
                    }
                }
                .padding()
                .pluginSettingsCardBackground(.recessed)
            }
        }
    }

    private func planStatusText(_ status: SystemSettingsProfilePlanStatus) -> String {
        switch status {
        case .ready: "可应用"
        case .alreadyMatches: "已经匹配"
        case .requiresLogout: "需要重新登录"
        case .requiresRestart: "需重新打开应用"
        case .guidedManual: "手动步骤"
        case .unsupported: "不支持"
        case .unavailable: "不可用"
        case .verificationUnavailable: "无法验证"
        case .invalidValue: "值无效"
        case .unknownSetting: "未知设置"
        }
    }

    private func applyResultText(_ result: SystemSettingsProfileApplyResultKind) -> String {
        switch result {
        case .appliedAndVerified: "已应用并验证"
        case .alreadyMatched: "已经匹配"
        case .pendingLogout: "已应用，待重新登录"
        case .pendingRestart: "已应用，待重新打开应用"
        case .skippedByUser: "已跳过"
        case .guidedManual: "手动步骤"
        case .unsupported: "不支持"
        case .providerUnavailable: "提供方不可用"
        case .failedAndRolledBack: "失败并已回滚"
        case .failedWithoutRollback: "失败，未能回滚"
        case .verificationUnavailable: "已应用但无法验证"
        }
    }
}

private struct MacSettingsImportExportView: View {
    @ObservedObject var controller: MacSettingsController
    @State private var importsFile = false
    @State private var exportsFile = false
    @State private var exportDocument = MacSettingsProfileDocument(data: Data())
    @State private var exportFilename = "Mac Settings.mactoolsprofile"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader("导入与导出", description: "导入文件始终先预览；不会自动更改任何设置。") {
                Button("导入配置…") { importsFile = true }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                    if let preview = controller.importedPreview {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("导入预览", systemImage: "doc.text.magnifyingglass")
                                .font(PluginSettingsTheme.Typography.sectionTitle)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(preview.profile.name).font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                                Text(preview.profile.profileDescription).foregroundStyle(.secondary)
                                Text("\(preview.profile.entries.count) 项设置 · 来源 \(preview.profile.sourceSystemVersion)")
                                    .font(PluginSettingsTheme.Typography.rowDescription)
                                if !preview.validation.warnings.isEmpty {
                                    Text("包含 \(preview.validation.warnings.count) 个未知设置；它们会保留，但不会执行。")
                                        .foregroundStyle(.orange)
                                }
                                HStack {
                                    Button("保存到我的配置") { controller.acceptImportedProfile() }
                                    Button("比较与应用") {
                                        controller.preparePlan(for: preview.profile)
                                        controller.destination = .profiles
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .padding()
                            .pluginSettingsCardBackground(.standard)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("导出我的配置", systemImage: "square.and.arrow.up")
                            .font(PluginSettingsTheme.Typography.sectionTitle)
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(controller.profiles) { profile in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name)
                                        Text("\(profile.entries.count) 项设置")
                                            .font(PluginSettingsTheme.Typography.rowDescription)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("导出…") {
                                        guard let data = try? controller.exportData(for: profile) else { return }
                                        exportDocument = MacSettingsProfileDocument(data: data)
                                        exportFilename = "\(profile.name).mactoolsprofile"
                                        exportsFile = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                                .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
                                if profile.id != controller.profiles.last?.id { Divider() }
                            }
                        }
                        .pluginSettingsCardBackground(.standard)
                    }

                    if let error = controller.profileErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                .padding(18)
            }
        }
        .fileImporter(
            isPresented: $importsFile,
            allowedContentTypes: [.macToolsSettingsProfile, .json],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            controller.importProfile(data: data)
        }
        .fileExporter(
            isPresented: $exportsFile,
            document: exportDocument,
            contentType: .macToolsSettingsProfile,
            defaultFilename: exportFilename
        ) { _ in }
    }
}

private struct MacSettingsProfileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.macToolsSettingsProfile, .json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private func pageHeader<Trailing: View>(
    _ title: String,
    description: String,
    @ViewBuilder trailing: () -> Trailing
) -> some View {
    HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(PluginSettingsTheme.Typography.pageTitle)
            Text(description)
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
        }
        Spacer()
        trailing()
    }
    .padding(18)
}
