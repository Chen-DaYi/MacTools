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
        return "\(workflow.steps.count) 个步骤 · \(state)\(last)"
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
                automaticRulesPlaceholder
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

    private var automaticRulesPlaceholder: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label("自动规则", systemImage: "clock.arrow.circlepath")
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
            Text("当前没有自动规则。手动运行不受规则条件影响。")
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .padding(PluginSettingsTheme.Spacing.cardContent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pluginSettingsCardBackground(.host)
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
