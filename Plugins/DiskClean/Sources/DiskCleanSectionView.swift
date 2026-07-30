import SwiftUI
import MacToolsPluginKit

// MARK: - Section guidance states

/// What a section should say when there are "no candidates to show" (design §10).
///
/// Purely derived, view-free, so it can be asserted directly against snapshots. It exists
/// because several empty states **must stay distinct**: no scan roots configured, never
/// scanned, scanned but access denied, roots unreadable, truly empty — each demands a
/// different next step from the user. Collapsing them into one "nothing here" makes the user guess.
enum DiskCleanSectionGuidance: Equatable, Sendable {
    /// Show the candidate list normally.
    case candidates
    /// Developer-artifacts section has no scan roots configured yet.
    case needsRoots
    /// Not scanned yet.
    case notScanned
    /// Scan root access denied (TCC). **Must never look like "nothing cleanable"** —
    /// `~/Downloads` may hold tens of GB of installers.
    case accessDenied(path: String)
    /// Scan root cannot be opened: deleted, replaced by a file, or on a non-local volume.
    case rootsUnreadable(paths: [String])
    /// Scanned; truly empty.
    case empty

    static func resolve(_ snapshot: DiskCleanControllerSnapshot) -> DiskCleanSectionGuidance {
        if case .developerArtifacts = snapshot.scope, snapshot.scope.isEmpty {
            return .needsRoots
        }
        guard let result = snapshot.scanResult else { return .notScanned }
        // With candidates, show them normally; root problems are reported honestly by the limitation banner and need not own the whole list.
        guard result.candidates.isEmpty else { return .candidates }

        let unreadable = result.limitations.compactMap { limitation -> (String, DiskCleanScanCompleteness.PartialReason)? in
            guard case let .scanRootUnreadable(path, reason) = limitation else { return nil }
            return (path, reason)
        }
        if let denied = unreadable.first(where: { $0.1 == .permissionDenied }) {
            return .accessDenied(path: denied.0)
        }
        if !unreadable.isEmpty {
            return .rootsUnreadable(paths: unreadable.map(\.0))
        }
        return .empty
    }
}

// MARK: - Reusable pieces

/// Banner (shared by limitation, error, and FDA guidance).
struct DiskCleanBanner<Trailing: View>: View {
    let symbolName: String
    let tint: Color
    let title: String
    let lines: [String]
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            trailing()
        }
        .pluginSettingsListRowPadding()
        .pluginSettingsCardBackground(.plugin)
    }
}

extension DiskCleanBanner where Trailing == EmptyView {
    init(symbolName: String, tint: Color, title: String, lines: [String]) {
        self.init(symbolName: symbolName, tint: tint, title: title, lines: lines) { EmptyView() }
    }
}

/// Empty state. Optional action button — if empty state only says "nothing here" while the
/// user still needs a configuration step, that empty state is a dead end.
struct DiskCleanEmptyState<Action: View>: View {
    let symbolName: String
    let text: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                Image(systemName: symbolName)
                    .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
            Spacer()
        }
        .pluginSettingsCardBackground(.plugin)
    }
}

extension DiskCleanEmptyState where Action == EmptyView {
    init(symbolName: String, text: String) {
        self.init(symbolName: symbolName, text: text) { EmptyView() }
    }
}

struct DiskCleanSectionHeader: View {
    let title: String
    let symbolName: String

    var body: some View {
        Label(title, systemImage: symbolName)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }
}

/// Scan / clean / stop + selection summary. Shared by all three sections so behavior and copy cannot diverge.
struct DiskCleanActionBar: View {
    let snapshot: DiskCleanControllerSnapshot
    let localization: PluginLocalization
    let onScan: () -> Void
    let onClean: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Button(action: onScan) {
                Label(
                    localization.string("detail.action.scan", defaultValue: "扫描"),
                    systemImage: "magnifyingglass"
                )
                .font(PluginSettingsTheme.Typography.controlLabel)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!snapshot.canScan)

            Button(action: onClean) {
                Label(
                    DiskCleanFormat.cleanActionTitle(snapshot, localization: localization),
                    systemImage: "trash"
                )
                .font(PluginSettingsTheme.Typography.controlLabel)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!snapshot.canClean)

            if snapshot.isBusy {
                Button(action: onCancel) {
                    Label(
                        localization.string("detail.action.stop", defaultValue: "停止"),
                        systemImage: "xmark.circle"
                    )
                    .font(PluginSettingsTheme.Typography.controlLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if snapshot.phase == .scanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            }

            Spacer(minLength: 0)

            Text(DiskCleanFormat.selectionSummary(snapshot, localization: localization))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - P2 sections

/// Developer-artifacts / leftover-installers sections (design §8.3 item 4, §10).
///
/// Shares the same `DiskCleanController` as the rules section: candidates, selection, plan
/// minting, and execution all use one pipeline; this view only lays out "scan entry + guidance
/// + candidate list". An **independent scan entry** is a design requirement — developer
/// artifacts walk user project trees and installers may trigger a `~/Downloads` TCC prompt;
/// neither should ride along with ordinary cache scans.
struct DiskCleanCleanupSectionView<Configuration: View>: View {
    @ObservedObject var controller: DiskCleanController
    let title: String
    let symbolName: String
    let localization: PluginLocalization
    /// Section-specific configuration (scan-root management for the developer-artifacts section).
    @ViewBuilder let configuration: () -> Configuration

    @State private var expandedCategories: Set<DiskCleanCategoryID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            DiskCleanSectionHeader(title: title, symbolName: symbolName)

            configuration()

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                DiskCleanActionBar(
                    snapshot: snapshot,
                    localization: localization,
                    onScan: { controller.scan() },
                    onClean: { controller.clean() },
                    onCancel: { controller.cancelCurrentOperation() }
                )
            }
            .pluginSettingsListRowPadding(interactive: true)
            .pluginSettingsCardBackground(.plugin)

            if let errorMessage = snapshot.errorMessage {
                DiskCleanBanner(
                    symbolName: "xmark.octagon.fill",
                    tint: .red,
                    title: localization.string("detail.error.title", defaultValue: "操作未完成"),
                    lines: [errorMessage]
                )
            }

            content
        }
        .confirmationDialog(
            DiskCleanFormat.confirmationTitle(snapshot, localization: localization),
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                controller.confirmPendingClean()
            } label: {
                Text(localization.string("detail.confirm.confirm", defaultValue: "永久删除"))
            }
            Button(role: .cancel) {
                controller.cancelPendingClean()
            } label: {
                Text(localization.string("detail.action.cancelClean", defaultValue: "取消"))
            }
        } message: {
            Text(
                localization.string(
                    "detail.confirm.message",
                    defaultValue: "永久删除不进废纸篓，无法恢复。"
                )
            )
        }
    }

    private var snapshot: DiskCleanControllerSnapshot {
        controller.snapshot
    }

    @ViewBuilder
    private var content: some View {
        switch DiskCleanSectionGuidance.resolve(snapshot) {
        case .candidates:
            DiskCleanCategoryListView(
                groups: DiskCleanCategoryGroup.groups(
                    candidates: snapshot.scanResult?.candidates ?? [],
                    selection: snapshot.selection
                ),
                selection: snapshot.selection,
                outcomesByCandidateID: outcomesByCandidateID,
                localization: localization,
                isInteractionEnabled: !snapshot.isBusy,
                onToggleCandidate: { controller.setCandidateSelected($0, isSelected: $1) },
                onToggleCategory: { controller.setCategorySelection($0, isSelected: $1) },
                expandedCategories: $expandedCategories
            )

        case .needsRoots:
            // Empty state itself has no "add folder" button: the entry lives in the scan-root
            // manager above; putting one in both places would look like two different actions.
            DiskCleanEmptyState(
                symbolName: "folder.badge.plus",
                text: localization.string(
                    "detail.developerArtifacts.needsRoots",
                    defaultValue: "先添加要扫描的工程文件夹，只会扫描你指定的目录"
                )
            )

        case .notScanned:
            DiskCleanEmptyState(
                symbolName: "magnifyingglass",
                text: localization.string(
                    "detail.section.notScanned",
                    defaultValue: "点击「扫描」查看可清理内容"
                )
            )

        case let .accessDenied(path):
            DiskCleanBanner(
                symbolName: "lock.fill",
                tint: .orange,
                title: localization.string(
                    "detail.section.accessDenied.title",
                    defaultValue: "没有访问权限，无法确认里面有什么"
                ),
                lines: [
                    localization.format(
                        "detail.section.accessDenied.message",
                        defaultValue: "系统拒绝了对 %@ 的访问。在系统设置里允许后重新扫描。",
                        path
                    )
                ]
            ) {
                Button {
                    DiskCleanFullDiskAccessGuide.openSettings()
                } label: {
                    Text(localization.string("detail.fda.openSettings", defaultValue: "前往授权"))
                        .font(PluginSettingsTheme.Typography.controlLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        case let .rootsUnreadable(paths):
            DiskCleanBanner(
                symbolName: "questionmark.folder",
                tint: .orange,
                title: localization.string(
                    "detail.section.rootsUnreadable.title",
                    defaultValue: "有文件夹已无法读取"
                ),
                lines: paths.map {
                    localization.format(
                        "detail.section.rootsUnreadable.line",
                        defaultValue: "%@ 已被移除、替换或位于其他卷上。",
                        $0
                    )
                }
            )

        case .empty:
            DiskCleanEmptyState(
                symbolName: "checkmark.circle",
                text: localization.string("detail.candidates.empty", defaultValue: "没有发现可清理项目")
            )
        }
    }

    private var outcomesByCandidateID: [DiskCleanCandidate.ID: DiskCleanExecutionItemResult.Outcome] {
        guard let executionResult = snapshot.executionResult else { return [:] }
        return Dictionary(
            executionResult.itemResults.map { ($0.candidateID, $0.outcome) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { snapshot.phase == .confirming },
            set: { isPresented in
                guard !isPresented else { return }
                controller.cancelPendingClean()
            }
        )
    }
}

extension DiskCleanCleanupSectionView where Configuration == EmptyView {
    init(
        controller: DiskCleanController,
        title: String,
        symbolName: String,
        localization: PluginLocalization
    ) {
        self.init(
            controller: controller,
            title: title,
            symbolName: symbolName,
            localization: localization
        ) {
            EmptyView()
        }
    }
}
