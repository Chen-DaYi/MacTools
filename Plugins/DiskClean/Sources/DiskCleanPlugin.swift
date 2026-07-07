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
        let controller = DiskCleanController(
            scanner: DiskCleanScanner(localization: localization),
            executor: DiskCleanExecutor(),
            localization: localization
        )
        return [DiskCleanPlugin(controller: controller, localization: localization)]
    }
}

@MainActor
final class DiskCleanPlugin: MacToolsPlugin, PluginPrimaryPanel {
    enum ControlID {
        static let scan = "disk-clean-scan"
        static let clean = "disk-clean-clean"
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

    private let controller: DiskCleanControlling
    private let localization: PluginLocalization
    private var isExpanded = false

    init(
        controller: DiskCleanControlling = DiskCleanController(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.controller = controller
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "disk-clean",
            title: localization.string("metadata.title", defaultValue: "磁盘清理"),
            iconName: "internaldrive",
            iconTint: Color(nsColor: .systemGreen),
            order: 90,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "缓存、开发者缓存和浏览器缓存清理"
            )
        )
        self.controller.onStateChange = { [weak self] in
            self?.onStateChange?()
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
        return PluginConfiguration(description: metadata.defaultDescription) { _ in
            DiskCleanDetailView(
                controller: controller,
                localization: localization,
                showsHeader: false,
                contentPadding: 0,
                minimumContentHeight: 0
            )
        }
    }

    func refresh() {}

    func deactivate(reason: PluginDeactivationReason) {
        controller.cancelCurrentOperation()
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
            controller.cleanSelected(candidateIDs: cleanableCandidateIDs)
        case ControlID.openDetails:
            break
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
            actionTitle: localization.string("panel.action.clean", defaultValue: "清理"),
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

        return PluginPanelDetail(
            primaryControls: [scanControl, cleanControl, openDetailsControl],
            secondaryPanel: nil
        )
    }

    private func subtitle(for snapshot: DiskCleanControllerSnapshot) -> String {
        if snapshot.phase == .scanned,
           !snapshot.isResultStale,
           let result = snapshot.scanResult {
            return localization.format(
                "panel.subtitle.scanned",
                defaultValue: "%d 项，%@",
                result.cleanableCandidates.count,
                byteText(result.cleanableSizeBytes)
            )
        }

        if snapshot.phase == .completed,
           let result = snapshot.executionResult {
            return localization.format(
                "panel.subtitle.completed",
                defaultValue: "已清理 %@",
                byteText(result.reclaimedBytes)
            )
        }

        return snapshot.subtitle(localization: localization)
    }

    private var cleanableCandidateIDs: Set<DiskCleanCandidate.ID> {
        Set(controller.snapshot.scanResult?.cleanableCandidates.map(\.id) ?? [])
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
