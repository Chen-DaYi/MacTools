import SwiftUI
import MacToolsPluginKit

struct AutomationSettingsView: View {
    @ObservedObject private var pluginHost: PluginHost
    @ObservedObject private var automation: AutomationController
    @State private var selectedWorkflowID: UUID?

    init(pluginHost: PluginHost) {
        self.pluginHost = pluginHost
        self.automation = pluginHost.automationController
    }

    var body: some View {
        HSplitView {
            workflowList
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)

            if let workflow = selectedWorkflow {
                WorkflowDetailView(
                    pluginHost: pluginHost,
                    automation: automation,
                    workflow: workflow,
                    onDeleted: { selectedWorkflowID = automation.workflows.first?.id }
                )
                .id(workflow.id)
            } else {
                ContentUnavailableView(
                    "尚无工作流",
                    systemImage: "bolt.horizontal.circle",
                    description: Text("创建工作流后，可组合多个 MacTools 操作。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(SettingsStyle.contentBackground)
        .onAppear(perform: selectInitialWorkflowIfNeeded)
        .onChange(of: automation.workflows.map(\.id)) { _, _ in
            selectInitialWorkflowIfNeeded()
        }
        .accessibilityIdentifier("mactools.automation")
    }

    private var workflowList: some View {
        VStack(spacing: 0) {
            HStack {
                Label("自动化", systemImage: "bolt.horizontal.circle")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                Spacer()
                Button {
                    if let workflow = automation.createWorkflow() {
                        selectedWorkflowID = workflow.id
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("新建工作流")
            }
            .padding(12)

            Divider()

            if automation.workflows.isEmpty {
                ContentUnavailableView("尚无工作流", systemImage: "bolt.slash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(automation.workflows, selection: $selectedWorkflowID) { workflow in
                    WorkflowCollectionRow(
                        automation: automation,
                        workflow: workflow,
                        ruleCount: automation.rules(workflowID: workflow.id).count,
                        lastRun: automation.recentRuns(workflowID: workflow.id, limit: 1).first
                    )
                    .tag(workflow.id)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var selectedWorkflow: WorkflowDefinition? {
        guard let selectedWorkflowID else {
            return nil
        }
        return automation.workflows.first { $0.id == selectedWorkflowID }
    }

    private func selectInitialWorkflowIfNeeded() {
        if let selectedWorkflowID,
           automation.workflows.contains(where: { $0.id == selectedWorkflowID }) {
            return
        }
        selectedWorkflowID = automation.workflows.first?.id
    }
}

private struct WorkflowCollectionRow: View {
    @ObservedObject var automation: AutomationController
    let workflow: WorkflowDefinition
    let ruleCount: Int
    let lastRun: WorkflowRun?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: workflow.systemImage)
                .foregroundStyle(workflow.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.name)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .lineLimit(1)
                Text(summary)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                _ = automation.startWorkflow(id: workflow.id)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.plain)
            .disabled(!workflow.isEnabled || workflow.steps.isEmpty)
            .help("运行工作流")
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workflow.name)，\(summary)")
    }

    private var summary: String {
        let state = workflow.isEnabled ? "已启用" : "已停用"
        let last = lastRun.map { " · 上次\(runStatusTitle($0.status))" } ?? ""
        return "\(workflow.steps.count) 个步骤 · \(ruleCount) 条规则 · \(state)\(last)"
    }
}

private struct WorkflowDetailView: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var automation: AutomationController
    let workflow: WorkflowDefinition
    let onDeleted: () -> Void

    @State private var pendingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
                header
                stepsSection
                runFromSection
                automaticRulesSection
                historySection

                if let error = automation.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                }
            }
            .padding(PluginSettingsTheme.Spacing.pagePadding)
        }
        .alert("删除工作流？", isPresented: $pendingDelete) {
            Button("删除", role: .destructive) {
                automation.deleteWorkflow(id: workflow.id)
                onDeleted()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存的快捷键、运行链接和网格条目会保留，并显示为不可用。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Image(systemName: workflow.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)

                TextField(
                    "工作流名称",
                    text: Binding(
                        get: { workflow.name },
                        set: { automation.renameWorkflow(id: workflow.id, name: $0) }
                    )
                )
                .font(PluginSettingsTheme.Typography.pageTitle)
                .textFieldStyle(.plain)

                Toggle(
                    "启用",
                    isOn: Binding(
                        get: { workflow.isEnabled },
                        set: { automation.setWorkflowEnabled($0, id: workflow.id) }
                    )
                )
                .toggleStyle(.switch)

                Button("测试") {
                    _ = automation.startWorkflow(id: workflow.id, test: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(workflow.steps.isEmpty)

                Button("运行") {
                    _ = automation.startWorkflow(id: workflow.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!workflow.isEnabled || workflow.steps.isEmpty)

                Menu {
                    Button("创建副本") { _ = automation.duplicateWorkflow(id: workflow.id) }
                    Divider()
                    Button("删除", role: .destructive) { pendingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text("按顺序运行多个操作；每个步骤都会重新检查可用性、权限和确认要求。")
                .font(PluginSettingsTheme.Typography.pageDescription)
                .foregroundStyle(.secondary)
        }
        .padding(PluginSettingsTheme.Spacing.cardContent)
        .pluginSettingsCardBackground(.host)
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label("步骤", systemImage: "list.number")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                actionPicker
            }

            if workflow.steps.isEmpty {
                ContentUnavailableView(
                    "尚未添加步骤",
                    systemImage: "plus.circle",
                    description: Text("从操作目录添加第一个步骤。")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
                .pluginSettingsCardBackground(.host)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(workflow.steps.enumerated()), id: \.element.id) { index, step in
                        WorkflowStepEditor(
                            automation: automation,
                            workflow: workflow,
                            step: step,
                            index: index,
                            canMoveUp: index > 0,
                            canMoveDown: index + 1 < workflow.steps.count
                        )
                        if index + 1 < workflow.steps.count {
                            PluginSettingsListDivider()
                        }
                    }
                }
                .pluginSettingsCardBackground(.host)
            }
        }
    }

    private var actionPicker: some View {
        Menu {
            ForEach(pluginHost.actionCatalogEntries.filter {
                $0.reference.key != workflow.actionKey
            }) { entry in
                Button {
                    automation.addStep(workflowID: workflow.id, reference: entry.reference)
                } label: {
                    Text(entry.subtitle.map { "\(entry.title) — \($0)" } ?? entry.title)
                }
            }
        } label: {
            Label("添加操作", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(workflow.steps.count >= WorkflowDefinition.maximumStepCount)
    }

    private var runFromSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label("运行方式", systemImage: "play.circle")
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Label("统一搜索中可用", systemImage: "magnifyingglass")
                if let item = pluginHost.actionShortcutSettingsItem(
                    for: workflow.actionReference
                ) {
                    Label("全局快捷键：\(item.bindingText)", systemImage: "command")
                } else {
                    Label("尚未分配全局快捷键", systemImage: "command")
                        .foregroundStyle(.secondary)
                }
                ActionRunLinkControl(
                    pluginHost: pluginHost,
                    reference: workflow.actionReference
                )
                Text("手势与操作网格由各自的功能页面管理。")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
            .padding(PluginSettingsTheme.Spacing.cardContent)
            .pluginSettingsCardBackground(.host)
        }
    }

    private var automaticRulesSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label("自动规则", systemImage: "clock.arrow.circlepath")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    _ = automation.createRule(workflowID: workflow.id)
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            let rules = automation.rules(workflowID: workflow.id)
            if rules.isEmpty {
                Text("当前没有自动规则。手动运行不受规则条件影响。")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .padding(PluginSettingsTheme.Spacing.cardContent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsCardBackground(.host)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        AutomationRuleEditor(
                            automation: automation,
                            rule: rule,
                            workflowName: workflow.name
                        )
                        if index + 1 < rules.count {
                            PluginSettingsListDivider()
                        }
                    }
                }
                .pluginSettingsCardBackground(.host)
            }
        }
    }

    private var historySection: some View {
        let runs = automation.recentRuns(workflowID: workflow.id)
        return VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label("最近运行", systemImage: "clock")
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)

            if runs.isEmpty {
                Text("尚无运行记录。")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .padding(PluginSettingsTheme.Spacing.cardContent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsCardBackground(.host)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        WorkflowRunRow(run: run)
                        if index + 1 < runs.count {
                            PluginSettingsListDivider()
                        }
                    }
                }
                .pluginSettingsCardBackground(.host)
            }
        }
    }
}

private struct AutomationRuleEditor: View {
    @ObservedObject var automation: AutomationController
    let rule: AutomationRule
    let workflowName: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                TextField("规则名称", text: binding(\.name))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 320)

                HStack {
                    Text("当")
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Picker("触发器", selection: triggerKindBinding) {
                        ForEach(AutomationTriggerKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 150, maxWidth: 220)
                    Spacer()
                    triggerAvailabilityView
                }

                triggerConfiguration

                HStack {
                    Text("如果")
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(rule.conditions.isEmpty ? "无附加条件" : "满足全部 \(rule.conditions.count) 个条件")
                        .foregroundStyle(.secondary)
                    Spacer()
                    conditionMenu
                }

                ForEach(rule.conditions) { condition in
                    AutomationConditionEditor(
                        condition: condition,
                        onChange: { replaceCondition($0) },
                        onDelete: { removeCondition(condition) }
                    )
                    .padding(.leading, 24)
                }

                HStack {
                    Text("运行")
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(workflowName)
                    Spacer()
                    Button("创建副本") { _ = automation.duplicateRule(id: rule.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("删除", role: .destructive) { automation.deleteRule(id: rule.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: triggerIcon)
                    .foregroundStyle(rule.isEnabled ? Color.accentColor : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.name)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text("当 \(triggerSummary)\(conditionSummary) · 运行 \(workflowName)")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("启用", isOn: binding(\.isEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .accessibilityIdentifier("mactools.automation.rule.\(rule.id.uuidString)")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AutomationRule, Value>) -> Binding<Value> {
        Binding(
            get: { rule[keyPath: keyPath] },
            set: { value in
                var updated = rule
                updated[keyPath: keyPath] = value
                automation.saveRule(updated)
            }
        )
    }

    private var triggerKindBinding: Binding<AutomationTriggerKind> {
        Binding(
            get: { rule.trigger.kind },
            set: { kind in
                var updated = rule
                updated.trigger = .defaultValue(for: kind)
                automation.saveRule(updated)
            }
        )
    }

    @ViewBuilder
    private var triggerConfiguration: some View {
        switch rule.trigger {
        case let .schedule(value):
            HStack {
                Stepper("\(twoDigits(value.hour)):\(twoDigits(value.minute))", value: triggerIntBinding(value.hour, range: 0 ... 23) { .schedule(replacing(value, hour: $0)) }, in: 0 ... 23)
                Stepper("分钟 \(value.minute)", value: triggerIntBinding(value.minute, range: 0 ... 59) { .schedule(replacing(value, minute: $0)) }, in: 0 ... 59)
            }
            weekdayEditor(value.weekdays) { .schedule(replacing(value, weekdays: $0)) }
        case let .calendar(value):
            HStack {
                Picker("时机", selection: triggerValueBinding(value.phase) { .calendar(replacing(value, phase: $0)) }) {
                    Text("开始").tag(CalendarAutomationPhase.starts)
                    Text("结束").tag(CalendarAutomationPhase.ends)
                }
                .frame(maxWidth: 150)
                Stepper("偏移 \(value.offsetMinutes) 分钟", value: triggerIntBinding(value.offsetMinutes, range: -1_440 ... 1_440) { .calendar(replacing(value, offsetMinutes: $0)) }, in: -1_440 ... 1_440)
            }
            TextField("标题包含（可选）", text: optionalTriggerStringBinding(value.titleContains) { .calendar(replacing(value, titleContains: $0)) })
                .textFieldStyle(.roundedBorder)
            if !automation.triggerAvailability(for: .calendar).isAvailable {
                Button("允许访问日历") {
                    Task { await automation.requestCalendarAccess() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case let .application(value):
            HStack {
                Picker("事件", selection: triggerValueBinding(value.event) { .application(replacing(value, event: $0)) }) {
                    Text("启动").tag(ApplicationAutomationEvent.launches)
                    Text("激活").tag(ApplicationAutomationEvent.activates)
                }
                .frame(maxWidth: 150)
                TextField("应用 Bundle ID", text: triggerStringBinding(value.bundleIdentifier) { .application(replacing(value, bundleIdentifier: $0)) })
                    .textFieldStyle(.roundedBorder)
            }
        case let .power(value):
            HStack {
                Picker("事件", selection: triggerValueBinding(value.event) { .power(replacing(value, event: $0)) }) {
                    Text("接入电源").tag(PowerAutomationEvent.adapterConnected)
                    Text("断开电源").tag(PowerAutomationEvent.adapterDisconnected)
                    Text("电量降至阈值").tag(PowerAutomationEvent.batteryAtOrBelow)
                }
                .frame(maxWidth: 180)
                if value.event == .batteryAtOrBelow {
                    Stepper("\(value.batteryLevel)%", value: triggerIntBinding(value.batteryLevel, range: 0 ... 100) { .power(replacing(value, batteryLevel: $0)) }, in: 0 ... 100)
                }
            }
        case let .display(value):
            HStack {
                Picker("事件", selection: triggerValueBinding(value.event) { .display(replacing(value, event: $0)) }) {
                    Text("连接").tag(DisplayAutomationEvent.connected)
                    Text("断开").tag(DisplayAutomationEvent.disconnected)
                }
                .frame(maxWidth: 150)
                TextField("显示器名称包含（可选）", text: optionalTriggerStringBinding(value.displayNameContains) { .display(replacing(value, displayNameContains: $0)) })
                    .textFieldStyle(.roundedBorder)
            }
        case let .network(value):
            HStack {
                Picker("状态", selection: triggerValueBinding(value.status) { .network(replacing(value, status: $0)) }) {
                    Text("可用").tag(AutomationNetworkStatus.available)
                    Text("不可用").tag(AutomationNetworkStatus.unavailable)
                }
                Picker("接口", selection: triggerValueBinding(value.interface) { .network(replacing(value, interface: $0)) }) {
                    ForEach(AutomationNetworkInterface.allCases, id: \.self) { interface in
                        Text(networkInterfaceTitle(interface)).tag(interface)
                    }
                }
            }
            .frame(maxWidth: 360)
        }
    }

    @ViewBuilder
    private var triggerAvailabilityView: some View {
        let availability = automation.triggerAvailability(for: rule.trigger.kind)
        if availability.isAvailable {
            Label("可用", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(PluginSettingsTheme.Typography.statusBadge)
        } else {
            Label(availability.reason ?? "不可用", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(PluginSettingsTheme.Typography.rowDescription)
        }
    }

    private var conditionMenu: some View {
        Menu {
            conditionButton("当前应用", condition: .frontmostApplication(FrontmostApplicationCondition(bundleIdentifier: "com.apple.finder")))
            conditionButton("电池与电源", condition: .power(PowerAutomationCondition()))
            conditionButton("已连接显示器", condition: .connectedDisplay(ConnectedDisplayCondition()))
            conditionButton("时间范围", condition: .timeRange(TimeRangeAutomationCondition()))
            conditionButton("网络状态", condition: .network(NetworkAutomationCondition()))
        } label: {
            Label("添加条件", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(rule.conditions.count >= AutomationRule.maximumConditionCount)
    }

    private func conditionButton(_ title: String, condition: AutomationCondition) -> some View {
        Button(title) {
            guard !rule.conditions.contains(where: { $0.id == condition.id }) else { return }
            var updated = rule
            updated.conditions.append(condition)
            automation.saveRule(updated)
        }
        .disabled(rule.conditions.contains(where: { $0.id == condition.id }))
    }

    private func replaceCondition(_ condition: AutomationCondition) {
        guard let index = rule.conditions.firstIndex(where: { $0.id == condition.id }) else { return }
        var updated = rule
        updated.conditions[index] = condition
        automation.saveRule(updated)
    }

    private func removeCondition(_ condition: AutomationCondition) {
        var updated = rule
        updated.conditions.removeAll { $0.id == condition.id }
        automation.saveRule(updated)
    }

    private func saveTrigger(_ trigger: AutomationTrigger) {
        var updated = rule
        updated.trigger = trigger
        automation.saveRule(updated)
    }

    private func triggerValueBinding<Value>(_ value: Value, make: @escaping (Value) -> AutomationTrigger) -> Binding<Value> {
        Binding(get: { value }, set: { saveTrigger(make($0)) })
    }

    private func triggerIntBinding(_ value: Int, range: ClosedRange<Int>, make: @escaping (Int) -> AutomationTrigger) -> Binding<Int> {
        Binding(get: { value }, set: { saveTrigger(make(min(max($0, range.lowerBound), range.upperBound))) })
    }

    private func triggerStringBinding(_ value: String, make: @escaping (String) -> AutomationTrigger) -> Binding<String> {
        Binding(get: { value }, set: { saveTrigger(make($0)) })
    }

    private func optionalTriggerStringBinding(_ value: String?, make: @escaping (String?) -> AutomationTrigger) -> Binding<String> {
        Binding(get: { value ?? "" }, set: { saveTrigger(make($0.isEmpty ? nil : $0)) })
    }

    private func weekdayEditor(_ weekdays: [Int], make: @escaping ([Int]) -> AutomationTrigger) -> some View {
        HStack(spacing: 4) {
            ForEach(1 ... 7, id: \.self) { weekday in
                Button(weekdayTitle(weekday)) {
                    var updated = Set(weekdays)
                    if updated.contains(weekday), updated.count > 1 {
                        updated.remove(weekday)
                    } else {
                        updated.insert(weekday)
                    }
                    saveTrigger(make(updated.sorted()))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(weekdays.contains(weekday) ? .accentColor : .secondary)
            }
        }
    }

    private var triggerIcon: String {
        switch rule.trigger.kind {
        case .schedule: "clock"
        case .calendar: "calendar"
        case .application: "app"
        case .power: "bolt"
        case .display: "display"
        case .network: "network"
        }
    }

    private var triggerSummary: String {
        switch rule.trigger {
        case let .schedule(value): "每周指定日期 \(twoDigits(value.hour)):\(twoDigits(value.minute))"
        case let .calendar(value): "日历事件\(value.phase == .starts ? "开始" : "结束")"
        case let .application(value): "\(value.bundleIdentifier) \(value.event == .launches ? "启动" : "激活")"
        case let .power(value): powerEventTitle(value.event)
        case let .display(value): "显示器\(value.event == .connected ? "连接" : "断开")"
        case let .network(value): "网络变为\(value.status == .available ? "可用" : "不可用")"
        }
    }

    private var conditionSummary: String {
        rule.conditions.isEmpty ? "" : "，且满足 \(rule.conditions.count) 个条件"
    }
}

private struct AutomationConditionEditor: View {
    let condition: AutomationCondition
    let onChange: (AutomationCondition) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            conditionFields
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var conditionFields: some View {
        switch condition {
        case let .frontmostApplication(value):
            Text("当前应用")
            Picker("匹配", selection: binding(value.isExcluded) { .frontmostApplication(replacing(value, isExcluded: $0)) }) {
                Text("是").tag(false)
                Text("不是").tag(true)
            }
            .labelsHidden()
            .frame(width: 70)
            TextField("Bundle ID", text: binding(value.bundleIdentifier) { .frontmostApplication(replacing(value, bundleIdentifier: $0)) })
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 280)
        case let .power(value):
            Text("电源")
            Picker("来源", selection: powerSourceBinding(value)) {
                Text("任意").tag("any")
                Text("电源适配器").tag(AutomationPowerSource.adapter.rawValue)
                Text("电池").tag(AutomationPowerSource.battery.rawValue)
            }
            .labelsHidden()
            .frame(width: 130)
            Stepper("最低 \(value.minimumBatteryLevel ?? 0)%", value: optionalLevelBinding(value, minimum: true), in: 0 ... 100)
            Stepper("最高 \(value.maximumBatteryLevel ?? 100)%", value: optionalLevelBinding(value, minimum: false), in: 0 ... 100)
        case let .connectedDisplay(value):
            Text("显示器已连接")
            TextField("名称包含", text: optionalStringBinding(value.displayNameContains) { .connectedDisplay(replacing(value, displayNameContains: $0)) })
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 240)
        case let .timeRange(value):
            Text("时间")
            Stepper("从 \(minuteTitle(value.startMinute))", value: binding(value.startMinute) { .timeRange(replacing(value, startMinute: $0)) }, in: 0 ... 1_439, step: 15)
            Stepper("至 \(minuteTitle(value.endMinute))", value: binding(value.endMinute) { .timeRange(replacing(value, endMinute: $0)) }, in: 0 ... 1_439, step: 15)
        case let .network(value):
            Text("网络")
            Picker("状态", selection: binding(value.status) { .network(replacing(value, status: $0)) }) {
                Text("可用").tag(AutomationNetworkStatus.available)
                Text("不可用").tag(AutomationNetworkStatus.unavailable)
            }
            .labelsHidden()
            Picker("接口", selection: binding(value.interface) { .network(replacing(value, interface: $0)) }) {
                ForEach(AutomationNetworkInterface.allCases, id: \.self) { interface in
                    Text(networkInterfaceTitle(interface)).tag(interface)
                }
            }
            .labelsHidden()
        }
    }

    private func binding<Value>(_ value: Value, make: @escaping (Value) -> AutomationCondition) -> Binding<Value> {
        Binding(get: { value }, set: { onChange(make($0)) })
    }

    private func optionalStringBinding(_ value: String?, make: @escaping (String?) -> AutomationCondition) -> Binding<String> {
        Binding(get: { value ?? "" }, set: { onChange(make($0.isEmpty ? nil : $0)) })
    }

    private func powerSourceBinding(_ value: PowerAutomationCondition) -> Binding<String> {
        Binding(
            get: { value.source?.rawValue ?? "any" },
            set: { rawValue in
                onChange(.power(replacing(value, source: AutomationPowerSource(rawValue: rawValue))))
            }
        )
    }

    private func optionalLevelBinding(_ value: PowerAutomationCondition, minimum: Bool) -> Binding<Int> {
        Binding(
            get: { minimum ? (value.minimumBatteryLevel ?? 0) : (value.maximumBatteryLevel ?? 100) },
            set: { level in
                if minimum {
                    onChange(.power(replacing(value, minimumBatteryLevel: min(level, value.maximumBatteryLevel ?? 100))))
                } else {
                    onChange(.power(replacing(value, maximumBatteryLevel: max(level, value.minimumBatteryLevel ?? 0))))
                }
            }
        )
    }
}

private func replacing(_ value: ScheduleAutomationTrigger, hour: Int? = nil, minute: Int? = nil, weekdays: [Int]? = nil) -> ScheduleAutomationTrigger {
    ScheduleAutomationTrigger(hour: hour ?? value.hour, minute: minute ?? value.minute, weekdays: weekdays ?? value.weekdays)
}

private func replacing(_ value: CalendarAutomationTrigger, phase: CalendarAutomationPhase? = nil, titleContains: String?? = nil, offsetMinutes: Int? = nil) -> CalendarAutomationTrigger {
    CalendarAutomationTrigger(phase: phase ?? value.phase, calendarIdentifier: value.calendarIdentifier, titleContains: titleContains ?? value.titleContains, offsetMinutes: offsetMinutes ?? value.offsetMinutes)
}

private func replacing(_ value: ApplicationAutomationTrigger, event: ApplicationAutomationEvent? = nil, bundleIdentifier: String? = nil) -> ApplicationAutomationTrigger {
    ApplicationAutomationTrigger(event: event ?? value.event, bundleIdentifier: bundleIdentifier ?? value.bundleIdentifier)
}

private func replacing(_ value: PowerAutomationTrigger, event: PowerAutomationEvent? = nil, batteryLevel: Int? = nil) -> PowerAutomationTrigger {
    PowerAutomationTrigger(event: event ?? value.event, batteryLevel: batteryLevel ?? value.batteryLevel)
}

private func replacing(_ value: DisplayAutomationTrigger, event: DisplayAutomationEvent? = nil, displayNameContains: String?? = nil) -> DisplayAutomationTrigger {
    DisplayAutomationTrigger(event: event ?? value.event, displayIdentifier: value.displayIdentifier, displayNameContains: displayNameContains ?? value.displayNameContains)
}

private func replacing(_ value: NetworkAutomationTrigger, status: AutomationNetworkStatus? = nil, interface: AutomationNetworkInterface? = nil) -> NetworkAutomationTrigger {
    NetworkAutomationTrigger(status: status ?? value.status, interface: interface ?? value.interface)
}

private func replacing(_ value: FrontmostApplicationCondition, isExcluded: Bool? = nil, bundleIdentifier: String? = nil) -> FrontmostApplicationCondition {
    FrontmostApplicationCondition(bundleIdentifier: bundleIdentifier ?? value.bundleIdentifier, isExcluded: isExcluded ?? value.isExcluded)
}

private func replacing(_ value: PowerAutomationCondition, source: AutomationPowerSource?? = nil, minimumBatteryLevel: Int?? = nil, maximumBatteryLevel: Int?? = nil) -> PowerAutomationCondition {
    PowerAutomationCondition(source: source ?? value.source, minimumBatteryLevel: minimumBatteryLevel ?? value.minimumBatteryLevel, maximumBatteryLevel: maximumBatteryLevel ?? value.maximumBatteryLevel)
}

private func replacing(_ value: ConnectedDisplayCondition, displayNameContains: String?? = nil) -> ConnectedDisplayCondition {
    ConnectedDisplayCondition(displayIdentifier: value.displayIdentifier, displayNameContains: displayNameContains ?? value.displayNameContains)
}

private func replacing(_ value: TimeRangeAutomationCondition, startMinute: Int? = nil, endMinute: Int? = nil) -> TimeRangeAutomationCondition {
    TimeRangeAutomationCondition(startMinute: startMinute ?? value.startMinute, endMinute: endMinute ?? value.endMinute, weekdays: value.weekdays)
}

private func replacing(_ value: NetworkAutomationCondition, status: AutomationNetworkStatus? = nil, interface: AutomationNetworkInterface? = nil) -> NetworkAutomationCondition {
    NetworkAutomationCondition(status: status ?? value.status, interface: interface ?? value.interface)
}

private func twoDigits(_ value: Int) -> String { String(format: "%02d", value) }
private func minuteTitle(_ value: Int) -> String { "\(twoDigits(value / 60)):\(twoDigits(value % 60))" }
private func weekdayTitle(_ value: Int) -> String { ["日", "一", "二", "三", "四", "五", "六"][max(1, min(7, value)) - 1] }

private func networkInterfaceTitle(_ value: AutomationNetworkInterface) -> String {
    switch value {
    case .any: "任意"
    case .wifi: "Wi-Fi"
    case .wiredEthernet: "以太网"
    case .cellular: "蜂窝网络"
    case .other: "其他"
    }
}

private func powerEventTitle(_ value: PowerAutomationEvent) -> String {
    switch value {
    case .adapterConnected: "接入电源"
    case .adapterDisconnected: "断开电源"
    case .batteryAtOrBelow: "电量降至阈值"
    }
}

private struct WorkflowStepEditor: View {
    @ObservedObject var automation: AutomationController
    let workflow: WorkflowDefinition
    let step: WorkflowStep
    let index: Int
    let canMoveUp: Bool
    let canMoveDown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Text("\(index + 1)")
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(actionTitle)
                        .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    Text(step.reference.key.id)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !availability.isAvailable {
                        Text(availability.reason ?? "操作不可用。")
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ControlGroup {
                    Button { automation.moveStep(workflowID: workflow.id, stepID: step.id, offset: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(!canMoveUp)
                    Button { automation.moveStep(workflowID: workflow.id, stepID: step.id, offset: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(!canMoveDown)
                    Button(role: .destructive) {
                        automation.removeStep(workflowID: workflow.id, stepID: step.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                .controlSize(.small)
            }

            if let definition = automation.definition(for: step.reference),
               !definition.parameters.isEmpty {
                WorkflowParameterEditor(
                    automation: automation,
                    workflowID: workflow.id,
                    step: step,
                    definitions: definition.parameters
                )
                .padding(.leading, 30)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    stepOptions
                }
                VStack(alignment: .leading, spacing: 8) { stepOptions }
            }
            .padding(.leading, 30)
        }
        .pluginSettingsListRowPadding(interactive: true)
        .accessibilityIdentifier("mactools.workflow.step.\(step.id.uuidString)")
    }

    @ViewBuilder
    private var stepOptions: some View {
        TextField(
            "步骤名称（可选）",
            text: Binding(
                get: { step.label ?? "" },
                set: { update(label: $0) }
            )
        )
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 150, idealWidth: 190, maxWidth: 240)

        HStack(spacing: 6) {
            Text("延迟")
            TextField(
                "秒",
                value: Binding(
                    get: { step.delaySeconds },
                    set: { update(delay: $0) }
                ),
                format: .number.precision(.fractionLength(0 ... 1))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
            Text("秒")
        }

        Picker(
            "失败时",
            selection: Binding(
                get: { step.errorPolicy },
                set: { update(policy: $0) }
            )
        ) {
            Text("停止").tag(WorkflowStepErrorPolicy.stop)
            Text("继续").tag(WorkflowStepErrorPolicy.continueRunning)
        }
        .frame(minWidth: 130, maxWidth: 170)
    }

    private var actionTitle: String {
        automation.catalogEntry(for: step.reference)?.title
            ?? automation.definition(for: step.reference)?.title
            ?? step.reference.key.id
    }

    private var availability: ActionAvailability {
        automation.availability(for: step.reference)
    }

    private func update(
        label: String? = nil,
        delay: Double? = nil,
        policy: WorkflowStepErrorPolicy? = nil
    ) {
        automation.updateStep(
            workflowID: workflow.id,
            stepID: step.id,
            label: label ?? step.label,
            delaySeconds: delay ?? step.delaySeconds,
            errorPolicy: policy ?? step.errorPolicy
        )
    }
}

private struct WorkflowParameterEditor: View {
    @ObservedObject var automation: AutomationController
    let workflowID: UUID
    let step: WorkflowStep
    let definitions: [ActionParameterDefinition]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(definitions) { definition in
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Text(definition.title)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .frame(width: 90, alignment: .trailing)
                    editor(for: definition)
                }
            }
        }
    }

    @ViewBuilder
    private func editor(for definition: ActionParameterDefinition) -> some View {
        switch definition.kind {
        case .boolean:
            Toggle(
                "",
                isOn: Binding(
                    get: {
                        guard case let .boolean(value)? = step.reference.parameters[definition.id]
                        else { return false }
                        return value
                    },
                    set: { update(definition.id, value: .boolean($0)) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        case .string:
            let binding = Binding(
                get: {
                    guard case let .string(value)? = step.reference.parameters[definition.id]
                    else { return "" }
                    return value
                },
                set: { update(definition.id, value: .string($0)) }
            )
            if definition.privacy == .sensitive {
                SecureField(definition.title, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160, maxWidth: 280)
            } else {
                TextField(definition.title, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160, maxWidth: 280)
            }
        case .integer:
            TextField(
                definition.title,
                value: Binding(
                    get: {
                        guard case let .integer(value)? = step.reference.parameters[definition.id]
                        else { return Int64(0) }
                        return value
                    },
                    set: { update(definition.id, value: .integer($0)) }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
        case .double:
            TextField(
                definition.title,
                value: Binding(
                    get: {
                        guard case let .double(value)? = step.reference.parameters[definition.id]
                        else { return 0 }
                        return value
                    },
                    set: { update(definition.id, value: .double($0)) }
                ),
                format: .number
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 120)
        }
    }

    private func update(_ name: String, value: ActionParameterValue) {
        var values = Dictionary(
            uniqueKeysWithValues: step.reference.parameters.entries.map { ($0.name, $0.value) }
        )
        values[name] = value
        guard let parameters = try? ActionParameterSet(values) else {
            return
        }
        automation.replaceStepReference(
            workflowID: workflowID,
            stepID: step.id,
            reference: ActionReference(
                key: step.reference.key,
                schemaVersion: step.reference.schemaVersion,
                parameters: parameters
            )
        )
    }
}

private struct WorkflowRunRow: View {
    let run: WorkflowRun

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(run.stepResults) { result in
                    HStack {
                        Image(systemName: stepStatusImage(result.status))
                            .foregroundStyle(stepStatusColor(result.status))
                        Text(result.title)
                        Spacer()
                        Text(stepStatusTitle(result.status))
                            .foregroundStyle(.secondary)
                    }
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    if let message = result.message {
                        Text(message)
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Label(runStatusTitle(run.status), systemImage: runStatusImage(run.status))
                    .foregroundStyle(runStatusColor(run.status))
                Text(run.startedAt, style: .relative)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(run.stepResults.count) 个步骤")
                    .foregroundStyle(.secondary)
            }
            .font(PluginSettingsTheme.Typography.rowDescription)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }
}

private func runStatusTitle(_ status: WorkflowRunStatus) -> String {
    switch status {
    case .running: "运行中"
    case .succeeded: "成功"
    case .failed: "失败"
    case .cancelled: "已取消"
    case .interrupted: "已中断"
    case .skipped: "已跳过"
    }
}

private func runStatusImage(_ status: WorkflowRunStatus) -> String {
    switch status {
    case .running: "progress.indicator"
    case .succeeded: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .cancelled: "stop.circle.fill"
    case .interrupted: "exclamationmark.circle.fill"
    case .skipped: "forward.end.circle"
    }
}

private func runStatusColor(_ status: WorkflowRunStatus) -> Color {
    switch status {
    case .succeeded: .green
    case .running: .blue
    case .failed, .interrupted: .red
    case .cancelled, .skipped: .secondary
    }
}

private func stepStatusTitle(_ status: WorkflowStepRunStatus) -> String {
    switch status {
    case .succeeded: "成功"
    case .failed: "失败"
    case .cancelled: "已取消"
    case .timedOut: "超时"
    case .unavailable: "不可用"
    case .skipped: "已跳过"
    }
}

private func stepStatusImage(_ status: WorkflowStepRunStatus) -> String {
    switch status {
    case .succeeded: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .cancelled: "stop.circle.fill"
    case .timedOut: "clock.badge.exclamationmark"
    case .unavailable: "questionmark.circle.fill"
    case .skipped: "forward.end.circle"
    }
}

private func stepStatusColor(_ status: WorkflowStepRunStatus) -> Color {
    switch status {
    case .succeeded: .green
    case .failed, .timedOut, .unavailable: .red
    case .cancelled, .skipped: .secondary
    }
}
