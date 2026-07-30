import Foundation
import SwiftUI
import MacToolsPluginKit

public final class DiskCleanPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DiskCleanPluginProvider(context: context)
    }
}

@MainActor
private struct DiskCleanPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        // journal 与审计日志都落在这里；宿主未提供支持目录时回退到同一约定位置。
        let storageDirectory = DiskCleanStorageLocation.resolve(supportDirectory: context.supportDirectory)
        let engine = DiskCleanScanEngine(localization: localization)
        // 三个分段共用同一个执行器实例：审计日志与暂存 journal 必须是同一份，
        // 否则崩溃恢复只认得其中一个分段留下的暂存对象。
        let executor = DiskCleanExecutor(storageDirectory: storageDirectory)

        func makeController(scope: DiskCleanScanScope) -> DiskCleanController {
            DiskCleanController(
                engine: engine,
                executor: executor,
                initialSnapshot: DiskCleanControllerSnapshot(
                    phase: .idle,
                    scope: scope,
                    scanResult: nil,
                    executionResult: nil,
                    isResultStale: false,
                    errorMessage: nil
                ),
                localization: localization
            )
        }

        let purgeRoots = DiskCleanPurgeRootsModel()
        return [
            DiskCleanPlugin(
                controller: makeController(scope: .rules(choices: Set(DiskCleanChoice.allCases))),
                developerArtifactsController: makeController(scope: purgeRoots.scope),
                installersController: makeController(scope: .installers),
                purgeRoots: purgeRoots,
                localization: localization,
                storageDirectory: storageDirectory
            )
        ]
    }
}

@MainActor
final class DiskCleanPlugin: MacToolsPlugin, PluginPrimaryPanel, PluginConfigurationPresenting {
    enum ControlID {
        static let scan = "disk-clean-scan"
        static let clean = "disk-clean-clean"
        static let confirmClean = "disk-clean-confirm-clean"
        static let cancelClean = "disk-clean-cancel-clean"
        static let openDetails = "disk-clean-open-details"
    }

    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    /// 宿主注入：把设置窗口切到本插件的配置页（"打开详情"的落点）。
    var requestConfigurationPresentation: (() -> Void)?

    private let controller: DiskCleanControlling
    /// 详情页两个 P2 分段的 Controller（设计 §10）。
    ///
    /// 它们只出现在设置页里，**不接 `onStateChange`**：菜单栏面板只反映规则分段，
    /// 让 P2 的每次候选流入都去重建宿主菜单是没有收益的开销。
    private let developerArtifactsController: DiskCleanController
    private let installersController: DiskCleanController
    private let purgeRoots: DiskCleanPurgeRootsModel
    private let localization: PluginLocalization
    private let storageDirectory: URL
    private let reconciler: any DiskCleanStagingReconciling
    private var isExpanded = false

    init(
        controller: DiskCleanControlling = DiskCleanController(),
        developerArtifactsController: DiskCleanController = DiskCleanController(),
        installersController: DiskCleanController = DiskCleanController(),
        purgeRoots: DiskCleanPurgeRootsModel = DiskCleanPurgeRootsModel(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        storageDirectory: URL = DiskCleanStorageLocation.fallbackDirectory,
        reconciler: any DiskCleanStagingReconciling = DiskCleanStagingReconciler()
    ) {
        self.controller = controller
        self.developerArtifactsController = developerArtifactsController
        self.installersController = installersController
        self.purgeRoots = purgeRoots
        self.localization = localization
        self.storageDirectory = storageDirectory
        self.reconciler = reconciler
        self.metadata = PluginMetadata(
            id: "disk-clean",
            title: localization.string("metadata.title", defaultValue: "磁盘清理"),
            iconName: "internaldrive",
            iconTint: Color(nsColor: .systemGreen),
            order: 90,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "扫描系统缓存、开发产物与残留安装包，默认移到废纸篓，执行前校验路径安全"
            )
        )
        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
        }
        // 扫描根一变就把新范围推给开发产物分段：范围与结果不一致时 Controller 会标记
        // "请重新扫描"，这条线断了用户会拿旧结果去清理刚移除的文件夹。
        self.purgeRoots.onRootsChange = { [weak developerArtifactsController] roots in
            developerArtifactsController?.setScope(.developerArtifacts(roots: roots))
        }
    }

    var primaryPanelState: PluginPanelState {
        let snapshot = controller.snapshot

        return PluginPanelState(
            subtitle: subtitle(for: snapshot),
            isOn: snapshot.isBusy,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? buildDetail(for: snapshot) : nil,
            errorMessage: snapshot.errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }
    var configuration: PluginConfiguration? {
        guard let controller = controller as? DiskCleanController else {
            return nil
        }

        let localization = localization
        let historyProvider = DiskCleanAuditLogHistoryProvider(directory: storageDirectory)
        let developerArtifactsController = developerArtifactsController
        let installersController = installersController
        let purgeRoots = purgeRoots
        return PluginConfiguration(description: metadata.defaultDescription) { _ in
            DiskCleanDetailView(
                controller: controller,
                developerArtifactsController: developerArtifactsController,
                installersController: installersController,
                purgeRoots: purgeRoots,
                localization: localization,
                historyProvider: historyProvider,
                showsHeader: false,
                contentPadding: 0,
                minimumContentHeight: 0
            )
        }
    }

    func refresh() {}

    /// 启动 reconciliation（设计 §7.6）。
    ///
    /// 上次运行若在"已改名到暂存名、尚未完成处置"之间崩溃，孤儿暂存对象只有 journal 知道它的原名。
    /// 必须在这里找回来：SafetyPolicy 会保护这些对象不被任何扫描收走，除了 reconciliation
    /// 没有第二条路径能碰到它们。文件系统操作不占主线程。
    func activate(context: PluginRuntimeContext) {
        let directory = DiskCleanStorageLocation.resolve(supportDirectory: context.supportDirectory ?? storageDirectory)
        let reconciler = reconciler
        Task.detached(priority: .utility) {
            await reconciler.reconcile(storageDirectory: directory)
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        controller.cancelCurrentOperation()
        developerArtifactsController.cancelCurrentOperation()
        installersController.cancelCurrentOperation()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(value):
            isExpanded = value
            onStateChange?()
        case let .invokeAction(controlID):
            handleInvoke(controlID: controlID)
        case .setSwitch,
             .setSelection,
             .setNavigationSelection,
             .clearNavigationSelection,
             .setDate,
             .setSlider:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    private func handleInvoke(controlID: String) {
        switch controlID {
        case ControlID.scan:
            controller.scan()
        case ControlID.clean:
            controller.clean()
        case ControlID.confirmClean:
            controller.confirmPendingClean()
        case ControlID.cancelClean:
            controller.cancelPendingClean()
        case ControlID.openDetails:
            requestConfigurationPresentation?()
        default:
            break
        }
    }

    private func buildDetail(for snapshot: DiskCleanControllerSnapshot) -> PluginPanelDetail {
        let scanControl = PluginPanelControl(
            id: ControlID.scan,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.scan", defaultValue: "扫描"),
            actionIconSystemName: "magnifyingglass",
            isEnabled: snapshot.canScan
        )

        let cleanControl = PluginPanelControl(
            id: ControlID.clean,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: cleanActionTitle(for: snapshot),
            actionIconSystemName: "trash",
            showsLeadingDivider: true,
            isEnabled: snapshot.canClean
        )

        let openDetailsControl = PluginPanelControl(
            id: ControlID.openDetails,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.openDetails", defaultValue: "打开详情"),
            actionIconSystemName: "arrow.up.right.square",
            actionBehavior: .dismissBeforeHandling,
            isEnabled: true
        )

        // 永久删除是双步：确认期把"清理"换成"确认 / 取消"一对，避免同一个按钮承担两种语义。
        // 完整样式（详情页 confirmationDialog、风险配色）留给 M5。
        let actionControls = snapshot.phase == .confirming
            ? confirmationControls(for: snapshot)
            : [cleanControl]

        return PluginPanelDetail(
            primaryControls: [scanControl] + actionControls + [openDetailsControl],
            secondaryPanel: nil
        )
    }

    /// 清理按钮文案。带上选中项数与估算字节，并按删除方式直说会发生什么——
    /// 废纸篓模式是单步执行，按钮本身就是最后一道说明（设计 §8.4）。
    private func cleanActionTitle(for snapshot: DiskCleanControllerSnapshot) -> String {
        let count = snapshot.selection.selectedCount
        guard count > 0 else {
            return snapshot.removalMode == .trash
                ? localization.string("panel.action.trash", defaultValue: "移到废纸篓")
                : localization.string("panel.action.clean", defaultValue: "清理")
        }

        let bytes = byteText(snapshot.selection.selectedEstimatedBytes)
        switch snapshot.removalMode {
        case .trash:
            return localization.format(
                "panel.action.trashSelected",
                defaultValue: "移到废纸篓 · %d 项 · 约 %@",
                count,
                bytes
            )
        case .permanent:
            return localization.format(
                "panel.action.cleanSelected",
                defaultValue: "清理 · %d 项 · 约 %@",
                count,
                bytes
            )
        }
    }

    private func confirmationControls(for snapshot: DiskCleanControllerSnapshot) -> [PluginPanelControl] {
        let confirmTitle = snapshot.pendingPlan.map { plan in
            localization.format(
                "panel.action.confirmClean",
                defaultValue: "确认永久清理 %d 项 · 约 %@",
                plan.itemCount,
                byteText(plan.totalEstimatedBytes)
            )
        } ?? localization.string("panel.action.confirmCleanFallback", defaultValue: "确认永久清理")

        let confirmControl = PluginPanelControl(
            id: ControlID.confirmClean,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: confirmTitle,
            actionIconSystemName: "exclamationmark.triangle",
            showsLeadingDivider: true,
            isEnabled: true
        )

        let cancelControl = PluginPanelControl(
            id: ControlID.cancelClean,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.cancelClean", defaultValue: "取消"),
            actionIconSystemName: "xmark",
            isEnabled: true
        )

        return [confirmControl, cancelControl]
    }

    private func subtitle(for snapshot: DiskCleanControllerSnapshot) -> String {
        // 扫描中实时累加可回收估算（宿主已按 ~250ms 节流发布快照）。
        if snapshot.phase == .scanning, let result = snapshot.scanResult, !result.candidates.isEmpty {
            return localization.format(
                "panel.subtitle.scanning",
                defaultValue: "正在扫描 · %d 项，约 %@",
                result.cleanableCandidates.count,
                byteText(result.cleanableSizeBytes)
            )
        }

        if snapshot.phase == .scanned,
           !snapshot.isResultStale,
           !snapshot.isResultExpired,
           let result = snapshot.scanResult {
            // "（受限）"一律从 limitations 派生（设计 §4.5、§8.2），
            // 不依赖"恰好扫出了某种被保护候选"。
            let base = localization.format(
                "panel.subtitle.scanned",
                defaultValue: "%d 项，约 %@",
                result.cleanableCandidates.count,
                byteText(result.cleanableSizeBytes)
            )
            guard result.isLimited else { return base }
            return base + localization.string("panel.subtitle.limitedSuffix", defaultValue: "（受限）")
        }

        if snapshot.phase == .confirming, let plan = snapshot.pendingPlan {
            return localization.format(
                "panel.subtitle.confirming",
                defaultValue: "确认永久清理 %d 项 · 约 %@",
                plan.itemCount,
                byteText(plan.totalEstimatedBytes)
            )
        }

        if snapshot.phase == .completed,
           let result = snapshot.executionResult {
            // 废纸篓模式不写"已释放"：对象还在废纸篓里，空间尚未真正回收（设计 §7.7）。
            let defaultValue = result.mode == .trash ? "已移到废纸篓约 %@" : "已清理约 %@"
            return localization.format(
                result.mode == .trash ? "panel.subtitle.trashed" : "panel.subtitle.completed",
                defaultValue: defaultValue,
                byteText(result.reclaimedBytes)
            )
        }

        return snapshot.subtitle(localization: localization)
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
