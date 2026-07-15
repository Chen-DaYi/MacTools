import AppKit
import SwiftUI
import MacToolsPluginKit

enum MenuBarPanelLayout {
    static let baseWidth: CGFloat = 316
    static let secondaryPanelWidth: CGFloat = 216
    static let maximumPanelHeight: CGFloat = 720
    static let minimumPanelHeight: CGFloat = 220
    static let featureListMaximumHeight: CGFloat = 860
    static let featurePanelScreenHeightRatio: CGFloat = 0.75
    static let screenVerticalMargin: CGFloat = 48
    static let cornerRadius: CGFloat = 12
    static let panelSpacing: CGFloat = 10
    static let outerPadding: CGFloat = 6
    static let contentTopPadding: CGFloat = 4
    static let rootSpacing: CGFloat = 0
    static let toolbarHeight: CGFloat = 30
    static let featureRowSpacing: CGFloat = 5
    static let rowHeaderHeight: CGFloat = 31
    static let rowVerticalPadding: CGFloat = 16
    static let detailSpacing: CGFloat = 8
    static let detailControlSpacing: CGFloat = 8
    static let emptyContentHeight: CGFloat = 150
    static let actionRowVerticalPadding: CGFloat = 8
    static let actionRowSectionTitleHeight: CGFloat = 30
    static let actionRowSectionTitleSpacing: CGFloat = 4
    static let navigationSectionTitleHeight: CGFloat = 15
    static let navigationSectionTitleSpacing: CGFloat = 3
    static let selectRowVerticalPadding: CGFloat = 5
    static let sliderVerticalPadding: CGFloat = 9
    static let navigationRowHeight: CGFloat = 52
    static let secondaryPanelMinimumHeight: CGFloat = 148
    static let secondaryPanelScreenMargin: CGFloat = 8
    static let secondaryPanelContentChromeHeight: CGFloat = 40

    static var surfaceWidth: CGFloat {
        baseWidth - (outerPadding * 2)
    }

    static var topChromeHeight: CGFloat {
        outerPadding + toolbarHeight + rootSpacing
    }

    static var contentBottomPadding: CGFloat {
        outerPadding
    }

    static var contentVerticalPadding: CGFloat {
        contentTopPadding + contentBottomPadding
    }

    static func contentBodyHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
        max(0, contentHeight - contentVerticalPadding)
    }

    static var minimumContentHeight: CGFloat {
        max(0, minimumPanelHeight - topChromeHeight)
    }

    static func maximumContentHeight(for screen: NSScreen?) -> CGFloat {
        max(
            minimumContentHeight,
            maximumPanelHeight(for: screen) - topChromeHeight
        )
    }

    static func panelHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
        topChromeHeight + contentHeight
    }

    static func width(for panelItems: [PluginPanelItem]) -> CGFloat {
        baseWidth
    }

    static func contentSize(for panelItems: [PluginPanelItem]) -> NSSize {
        NSSize(
            width: width(for: panelItems),
            height: preferredPanelHeight(for: panelItems, screen: nil)
        )
    }

    static func height(for panelItems: [PluginPanelItem]) -> CGFloat {
        preferredPanelHeight(for: panelItems, screen: nil)
    }

    static func featureContentHeight(for panelItems: [PluginPanelItem]) -> CGFloat {
        let rowContentHeight = panelItems.reduce(CGFloat(0)) { partialResult, item in
            partialResult + rowHeight(for: item)
        }
        let featureSpacing = CGFloat(max(panelItems.count - 1, 0)) * featureRowSpacing
        return panelItems.isEmpty
            ? emptyContentHeight
            : rowContentHeight + featureSpacing
    }

    static func availableFeatureHeight(forPanelHeight panelHeight: CGFloat) -> CGFloat {
        max(0, panelHeight - topChromeHeight - contentVerticalPadding)
    }

    static func preferredPanelHeight(for panelItems: [PluginPanelItem], screen: NSScreen?) -> CGFloat {
        panelHeight(
            forContentHeight: preferredFeatureContentHeight(for: panelItems, screen: screen)
        )
    }

    static func preferredFeatureContentHeight(for panelItems: [PluginPanelItem], screen: NSScreen?) -> CGFloat {
        max(
            featureListHeight(for: panelItems, screen: screen) + contentVerticalPadding,
            minimumContentHeight
        )
    }

    static func featureListHeight(for panelItems: [PluginPanelItem], screen: NSScreen?) -> CGFloat {
        min(featureContentHeight(for: panelItems), maximumFeatureListHeight(for: screen))
    }

    static func featureListHeight(featureContentHeight: CGFloat, maximumFeatureListHeight: CGFloat) -> CGFloat {
        min(featureContentHeight, maximumFeatureListHeight)
    }

    static func preferredPanelHeight(
        featureContentHeight: CGFloat,
        maximumFeatureListHeight: CGFloat
    ) -> CGFloat {
        panelHeight(
            forContentHeight: preferredFeatureContentHeight(
                featureContentHeight: featureContentHeight,
                maximumFeatureListHeight: maximumFeatureListHeight
            )
        )
    }

    static func preferredFeatureContentHeight(
        featureContentHeight: CGFloat,
        maximumFeatureListHeight: CGFloat
    ) -> CGFloat {
        max(
            featureListHeight(
                featureContentHeight: featureContentHeight,
                maximumFeatureListHeight: maximumFeatureListHeight
            ) + contentVerticalPadding,
            minimumContentHeight
        )
    }

    static func maximumFeatureListHeight(for screen: NSScreen?) -> CGFloat {
        maximumFeatureListHeight(visibleFrameHeight: screen?.visibleFrame.height)
    }

    static func maximumFeatureListHeight(visibleFrameHeight: CGFloat?) -> CGFloat {
        guard let visibleFrameHeight else {
            return featureListMaximumHeight
        }

        let screenMaximum = (visibleFrameHeight * featurePanelScreenHeightRatio)
            - topChromeHeight
            - contentVerticalPadding
        return max(0, min(featureListMaximumHeight, screenMaximum))
    }

    static func maximumPanelHeight(for screen: NSScreen?) -> CGFloat {
        maximumPanelHeight(visibleFrameHeight: screen?.visibleFrame.height)
    }

    static func maximumPanelHeight(visibleFrameHeight: CGFloat?) -> CGFloat {
        guard let visibleFrameHeight else {
            return maximumPanelHeight
        }

        return max(minimumPanelHeight, visibleFrameHeight * featurePanelScreenHeightRatio)
    }

    private static func rowHeight(for item: PluginPanelItem) -> CGFloat {
        guard let detail = displayedDetail(for: item) else {
            return rowHeaderHeight + rowVerticalPadding
        }

        return rowHeaderHeight
            + detailSpacing
            + detailHeight(for: detail.primaryControls)
            + rowVerticalPadding
    }

    private static func displayedDetail(for item: PluginPanelItem) -> PluginPanelDetail? {
        guard let detail = item.detail else {
            return nil
        }

        if item.controlStyle == .disclosure && !item.isExpanded {
            return nil
        }

        return detail
    }

    private static func detailHeight(for controls: [PluginPanelControl]) -> CGFloat {
        controls.enumerated().reduce(CGFloat(0)) { partialResult, element in
            let (index, control) = element
            let controlSpacing = index == 0 ? CGFloat(0) : detailControlSpacing
            let dividerHeight = control.showsLeadingDivider ? CGFloat(8) : CGFloat(0)
            return partialResult + controlSpacing + dividerHeight + controlHeight(for: control)
        }
    }

    private static func controlHeight(for control: PluginPanelControl) -> CGFloat {
        switch control.kind {
        case .segmented:
            return 24
        case .datePicker:
            switch control.datePickerStyle ?? .compact {
            case .compact:
                return 26
            case .dateTimeCard:
                return 64
            }
        case .selectList:
            let titleHeight = control.sectionTitle == nil ? CGFloat(0) : CGFloat(15)
            return titleHeight + CGFloat(control.options.count) * 26
        case .navigationList:
            let titleHeight = control.sectionTitle == nil ? CGFloat(0) : navigationSectionTitleHeight
            let titleSpacing = titleHeight > 0 ? navigationSectionTitleSpacing : CGFloat(0)
            return titleHeight + titleSpacing + CGFloat(control.options.count) * navigationRowHeight
        case .slider:
            let titleHeight = control.sectionTitle == nil && control.valueLabel == nil ? CGFloat(0) : CGFloat(15)
            let titleSpacing = titleHeight > 0 ? CGFloat(6) : CGFloat(0)
            return titleHeight + titleSpacing + 18 + sliderVerticalPadding * 2
        case .switchRow:
            return 20 + actionRowVerticalPadding * 2
        case .actionRow:
            let titleHeight = control.sectionTitle == nil ? CGFloat(0) : actionRowSectionTitleHeight
            let titleSpacing = titleHeight > 0 ? actionRowSectionTitleSpacing : CGFloat(0)
            return titleHeight + titleSpacing + 16 + actionRowVerticalPadding * 2
        }
    }

}

enum SecondaryPanelPlacement: Equatable {
    case right(CGRect)
    case left(CGRect)
    case inline

    static func resolve(
        anchorRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> Self {
        let availableFrame = visibleFrame.insetBy(
            dx: MenuBarPanelLayout.secondaryPanelScreenMargin,
            dy: MenuBarPanelLayout.secondaryPanelScreenMargin
        )

        guard
            panelSize.width <= availableFrame.width,
            panelSize.height <= availableFrame.height
        else {
            return .inline
        }

        let y = min(
            max(anchorRect.maxY - panelSize.height, availableFrame.minY),
            availableFrame.maxY - panelSize.height
        )
        let rightFrame = CGRect(
            x: anchorRect.maxX + MenuBarPanelLayout.panelSpacing,
            y: y,
            width: panelSize.width,
            height: panelSize.height
        )
        if rightFrame.maxX <= availableFrame.maxX {
            return .right(rightFrame)
        }

        let leftFrame = CGRect(
            x: anchorRect.minX - MenuBarPanelLayout.panelSpacing - panelSize.width,
            y: y,
            width: panelSize.width,
            height: panelSize.height
        )
        if leftFrame.minX >= availableFrame.minX {
            return .left(leftFrame)
        }

        return .inline
    }
}

private enum FeatureRowLayout {
    static let iconSize: CGFloat = 26
    static let iconCornerRadius: CGFloat = 10
    static let rowSpacing: CGFloat = 10
    static let detailControlHorizontalPadding: CGFloat = 10
    static let detailLeadingInset: CGFloat = iconSize + rowSpacing - detailControlHorizontalPadding
    static let rowHorizontalPadding: CGFloat = 10
    static let rowVerticalPadding: CGFloat = MenuBarPanelLayout.rowVerticalPadding / 2
    static let chevronSize: CGFloat = 14
}

private enum MenuBarHoverStyle {
    static let cornerRadius: CGFloat = MenuBarPanelLayout.cornerRadius
    static let fill = Color.primary.opacity(0.06)
    static let inset: CGFloat = 1
    static let navigationCornerRadius: CGFloat = 8
    static let navigationFill = Color.primary.opacity(0.10)
    static let navigationSelectedFill = Color.primary.opacity(0.13)
}

@MainActor
final class HoverSecondaryPanelCoordinator: ObservableObject {
    struct Activation: Equatable, Hashable {
        let pluginID: String
        let controlID: String
        let optionID: String
    }

    @Published private(set) var activeActivation: Activation?
    @Published private(set) var selectedRowFrame: CGRect?

    var onDismissRequest: ((Activation) -> Void)?

    private let dismissDelay: Duration
    private let activationDelay: Duration?
    private var activationTask: Task<Void, Never>?
    private var pendingActivation: Activation?
    private var dismissTask: Task<Void, Never>?
    private var pinnedActivation: Activation?
    private var isPanelHovered = false
    private var rowFrames: [Activation: CGRect] = [:]

    init(
        dismissDelay: Duration = .milliseconds(160),
        activationDelay: Duration? = .milliseconds(60)
    ) {
        self.dismissDelay = dismissDelay
        self.activationDelay = activationDelay
    }

    func hoverBegan(
        pluginID: String,
        controlID: String,
        optionID: String
    ) {
        let activation = Activation(
            pluginID: pluginID,
            controlID: controlID,
            optionID: optionID
        )

        cancelDismissal()
        isPanelHovered = false

        guard pinnedActivation == nil || pinnedActivation == activation else {
            return
        }

        guard activeActivation != activation else {
            selectedRowFrame = rowFrames[activation]
            return
        }

        cancelPendingActivation()

        guard let activationDelay else {
            activate(activation)
            return
        }

        pendingActivation = activation
        activationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: activationDelay)
            guard !Task.isCancelled else {
                return
            }

            self?.activate(activation)
        }
    }

    func pin(
        pluginID: String,
        controlID: String,
        optionID: String
    ) {
        let activation = Activation(
            pluginID: pluginID,
            controlID: controlID,
            optionID: optionID
        )

        cancelPendingActivation()
        cancelDismissal()
        pinnedActivation = activation
        isPanelHovered = false
        activeActivation = activation
        selectedRowFrame = rowFrames[activation]
    }

    private func activate(_ activation: Activation) {
        cancelPendingActivation()
        activeActivation = activation
        selectedRowFrame = rowFrames[activation]
    }

    func hoverEnded(
        pluginID: String,
        controlID: String,
        optionID: String
    ) {
        let activation = Activation(
            pluginID: pluginID,
            controlID: controlID,
            optionID: optionID
        )

        if pendingActivation == activation {
            cancelPendingActivation()
            scheduleDismissIfNeeded(expectedActivation: activeActivation)
            return
        }

        scheduleDismissIfNeeded(expectedActivation: activation)
    }

    func setPanelHovered(_ isHovered: Bool) {
        isPanelHovered = isHovered

        if isHovered {
            cancelDismissal()
        } else {
            scheduleDismissIfNeeded(expectedActivation: activeActivation)
        }
    }

    func updateRowFrame(_ frame: CGRect?, for activation: Activation) {
        if let frame {
            rowFrames[activation] = frame
        } else {
            rowFrames.removeValue(forKey: activation)
        }

        guard activeActivation == activation else {
            return
        }

        selectedRowFrame = frame
    }

    func dismissImmediately() {
        cancelPendingActivation()
        dismissInternal(notify: true)
    }

    private func scheduleDismissIfNeeded(expectedActivation: Activation?) {
        cancelDismissal()

        guard
            let expectedActivation,
            activeActivation == expectedActivation,
            pinnedActivation != expectedActivation
        else {
            return
        }

        dismissTask = Task { [dismissDelay] in
            try? await Task.sleep(for: dismissDelay)
            guard !Task.isCancelled else {
                return
            }

            dismissIfNeeded(expectedActivation)
        }
    }

    private func dismissIfNeeded(_ expectedActivation: Activation) {
        guard
            activeActivation == expectedActivation,
            !isPanelHovered
        else {
            return
        }

        dismissInternal(notify: true)
    }

    private func dismissInternal(notify: Bool) {
        cancelDismissal()

        guard let activation = activeActivation else {
            selectedRowFrame = nil
            isPanelHovered = false
            return
        }

        activeActivation = nil
        selectedRowFrame = nil
        pinnedActivation = nil
        isPanelHovered = false

        if notify {
            onDismissRequest?(activation)
        }
    }

    private func cancelDismissal() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func cancelPendingActivation() {
        activationTask?.cancel()
        activationTask = nil
        pendingActivation = nil
    }
}

struct MenuBarContent: View {
    static let diskCleanWindowID = "disk-clean"
    static let diskCleanOpenDetailsActionID = "disk-clean-open-details"
    static let launchControlWindowID = "launch-control"
    static let launchControlOpenManagerActionID = "launch-control-open-manager"
    static let fanControlPluginID = "fan-control"
    static let fanControlManagePresetsActionID = "fan-add-preset"
    static let zshConfigPluginID = "zsh-config"
    static let zshConfigOpenSettingsActionID = "execute"
    static let batteryChargeLimitPluginID = "battery-charge-limit"
    static let batteryChargeLimitManageSettingsActionID = "battery-manage-settings"
    static let ipOverviewPluginID = "ip-overview"
    static let ipOverviewCopyIPActionID = "ip-overview-copy-ip"

    @StateObject private var secondaryPanelController = SecondaryPanelController()
    @StateObject private var hoverCoordinator = HoverSecondaryPanelCoordinator()
    @StateObject private var deferredActionDispatcher = DeferredPanelActionDispatcher()

    @ObservedObject var pluginHost: PluginHost
    let contentBodyHeight: CGFloat
    let maximumFeatureListHeight: CGFloat
    let isPanelVisible: Bool
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void
    let onPresentDiskCleanConfiguration: () -> Void
    let onPresentLaunchControlConfiguration: () -> Void

    var body: some View {
        content
        .background(
            MenuWindowAccessor { window in
                secondaryPanelController.setHostWindow(isPanelVisible ? window : nil)
                if isPanelVisible {
                    syncSecondaryPanelWindow()
                }
            }
        )
        .onAppear {
            hoverCoordinator.onDismissRequest = { activation in
                pluginHost.clearPanelNavigationSelection(
                    controlID: activation.controlID,
                    for: activation.pluginID
                )
            }

            secondaryPanelController.onHostWindowDismissRequest = {
                hoverCoordinator.dismissImmediately()
            }
        }
        .animation(.easeOut(duration: 0.18), value: activeSecondaryPanelSignature)
        .onChange(of: activeSecondaryPanelSignature) {
            syncSecondaryPanelWindowIfVisible()
        }
        .onChange(of: hoverCoordinator.selectedRowFrame) {
            syncSecondaryPanelWindowIfVisible()
        }
        .onChange(of: hoverCoordinator.activeActivation) {
            syncSecondaryPanelWindowIfVisible()
        }
        .onReceive(pluginHost.$settingsPresentationRequestCount.dropFirst()) { _ in
            if isPanelVisible {
                presentSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppAppearancePreference.didChangeNotification)) { _ in
            secondaryPanelController.applyCurrentAppearance()
        }
        .onChange(of: isPanelVisible) { _, isVisible in
            if isVisible {
                syncSecondaryPanelWindow()
            } else {
                hoverCoordinator.dismissImmediately()
                secondaryPanelController.setHostWindow(nil)
            }
        }
        .onDisappear {
            flushDeferredActionsIfNeeded()
            hoverCoordinator.dismissImmediately()
            hoverCoordinator.onDismissRequest = nil
            secondaryPanelController.onHostWindowDismissRequest = nil
            secondaryPanelController.setHostWindow(nil)
        }
    }

    private func syncSecondaryPanelWindowIfVisible() {
        guard isPanelVisible else {
            return
        }

        syncSecondaryPanelWindow()
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            featureList
                .frame(height: visibleFeatureListHeight, alignment: .topLeading)
                // Keep the navigation rows alive behind the drill-in panel. Their screen frames
                // are also the hover coordinator's anchors; removing them would immediately
                // dismiss the active secondary panel.
                .opacity(secondaryPanelController.isPresentingInline ? 0 : 1)
                .allowsHitTesting(!secondaryPanelController.isPresentingInline)

            if
                secondaryPanelController.isPresentingInline,
                let activeSecondaryPanel
            {
                SecondarySlidingPanel(
                    title: activeSecondaryPanel.panel.title,
                    controls: activeSecondaryPanel.panel.controls,
                    maximumContentHeight: max(
                        0,
                        contentBodyHeight - MenuBarPanelLayout.secondaryPanelContentChromeHeight
                    ),
                    showsDismissButton: true,
                    onDismiss: {
                        hoverCoordinator.dismissImmediately()
                    },
                    onSelectionChange: { controlID, optionID in
                        pluginHost.setPanelSelectionValue(
                            optionID,
                            controlID: controlID,
                            for: activeSecondaryPanel.item.id
                        )
                    },
                    onNavigationSelectionChange: { controlID, optionID in
                        pluginHost.setPanelNavigationSelectionValue(
                            optionID,
                            controlID: controlID,
                            for: activeSecondaryPanel.item.id
                        )
                    },
                    onDateChange: { controlID, date in
                        pluginHost.setPanelDateValue(
                            date,
                            controlID: controlID,
                            for: activeSecondaryPanel.item.id
                        )
                    },
                    onHoverChange: handleSecondaryPanelHoverChange,
                    onSliderChange: { controlID, value, phase in
                        pluginHost.setPanelSliderValue(
                            value,
                            controlID: controlID,
                            for: activeSecondaryPanel.item.id,
                            phase: phase
                        )
                    }
                )
            }
        }
        .frame(
            width: MenuBarPanelLayout.surfaceWidth,
            height: contentBodyHeight,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private var featureList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            featureCards
        }
        .scrollDisabled(!isFeatureListScrollable)
        .background(ScrollViewScrollerVisibilityConfigurator())
    }

    private var featureListHeight: CGFloat {
        MenuBarPanelLayout.featureListHeight(
            featureContentHeight: featureContentHeight,
            maximumFeatureListHeight: maximumFeatureListHeight
        )
    }

    private var visibleFeatureListHeight: CGFloat {
        min(featureListHeight, contentBodyHeight)
    }

    private var isFeatureListScrollable: Bool {
        featureContentHeight > visibleFeatureListHeight
    }

    private var featureContentHeight: CGFloat {
        MenuBarPanelLayout.featureContentHeight(for: pluginHost.panelItems)
    }

    private func presentSettings() {
        onOpenSettings()
        onDismiss()
    }

    private func handlePanelSwitchChange(_ newValue: Bool, for item: PluginPanelItem) {
        switch item.menuActionBehavior {
        case .keepPresented:
            pluginHost.setSwitchValue(newValue, for: item.id)
        case .dismissBeforeHandling:
            deferredActionDispatcher.deferPanelSwitch(
                pluginID: item.id,
                isOn: newValue
            )
            onDismiss()
            flushDeferredActionsAfterDismiss()
        }
    }

    private func handleActionInvoke(
        controlID: String,
        for item: PluginPanelItem,
        behavior: PluginMenuActionBehavior
    ) {
        if isDiskCleanOpenDetailsAction(pluginID: item.id, controlID: controlID) {
            presentDiskCleanDetails()
            onDismiss()
            return
        }

        if isLaunchControlOpenManagerAction(pluginID: item.id, controlID: controlID) {
            presentLaunchControlManager()
            onDismiss()
            return
        }

        if isFanControlManagePresetsAction(pluginID: item.id, controlID: controlID) {
            pluginHost.presentPluginConfiguration(pluginID: Self.fanControlPluginID)
            onDismiss()
            return
        }

        if isZshConfigOpenSettingsAction(pluginID: item.id, controlID: controlID) {
            pluginHost.presentPluginConfiguration(pluginID: Self.zshConfigPluginID)
            onDismiss()
            return
        }

        switch behavior {
        case .keepPresented:
            pluginHost.invokePanelAction(controlID: controlID, for: item.id)
        case .dismissBeforeHandling:
            // Dismiss the popover before running actions that may open a new window.
            deferredActionDispatcher.deferActionInvocation(
                pluginID: item.id,
                controlID: controlID
            )
            onDismiss()
            flushDeferredActionsAfterDismiss()
        }
    }

    private func flushDeferredActionsAfterDismiss() {
        deferredActionDispatcher.flushAfterDismiss(
            switchHandler: performDeferredPanelSwitchAction,
            invocationHandler: performDeferredActionInvocation
        )
    }

    private func flushDeferredActionsIfNeeded() {
        deferredActionDispatcher.flush(
            switchHandler: performDeferredPanelSwitchAction,
            invocationHandler: performDeferredActionInvocation
        )
    }

    private func performDeferredPanelSwitchAction(_ action: DeferredPanelActionDispatcher.PanelSwitchAction) {
        pluginHost.setSwitchValue(
            action.isOn,
            for: action.pluginID
        )
    }

    private func performDeferredActionInvocation(_ action: DeferredPanelActionDispatcher.ActionInvocation) {
        if isDiskCleanOpenDetailsAction(pluginID: action.pluginID, controlID: action.controlID) {
            presentDiskCleanDetails()
            return
        }

        if isLaunchControlOpenManagerAction(pluginID: action.pluginID, controlID: action.controlID) {
            presentLaunchControlManager()
            return
        }

        if isFanControlManagePresetsAction(pluginID: action.pluginID, controlID: action.controlID) {
            pluginHost.presentPluginConfiguration(pluginID: Self.fanControlPluginID)
            return
        }

        if isZshConfigOpenSettingsAction(pluginID: action.pluginID, controlID: action.controlID) {
            pluginHost.presentPluginConfiguration(pluginID: Self.zshConfigPluginID)
            return
        }

        if isBatteryChargeLimitManageSettingsAction(pluginID: action.pluginID, controlID: action.controlID) {
            pluginHost.presentPluginConfiguration(pluginID: Self.batteryChargeLimitPluginID)
            return
        }

        pluginHost.invokePanelAction(
            controlID: action.controlID,
            for: action.pluginID
        )
    }

    private func isDiskCleanOpenDetailsAction(pluginID: String, controlID: String) -> Bool {
        pluginID == Self.diskCleanWindowID && controlID == Self.diskCleanOpenDetailsActionID
    }

    private func isLaunchControlOpenManagerAction(pluginID: String, controlID: String) -> Bool {
        pluginID == Self.launchControlWindowID && controlID == Self.launchControlOpenManagerActionID
    }

    private func isFanControlManagePresetsAction(pluginID: String, controlID: String) -> Bool {
        pluginID == Self.fanControlPluginID && controlID == Self.fanControlManagePresetsActionID
    }

    private func isZshConfigOpenSettingsAction(pluginID: String, controlID: String) -> Bool {
        pluginID == Self.zshConfigPluginID && controlID == Self.zshConfigOpenSettingsActionID
    }

    private func isBatteryChargeLimitManageSettingsAction(pluginID: String, controlID: String) -> Bool {
        pluginID == Self.batteryChargeLimitPluginID && controlID == Self.batteryChargeLimitManageSettingsActionID
    }

    private func isNavigationOptionSelected(
        in controls: [PluginPanelControl],
        controlID: String,
        optionID: String
    ) -> Bool {
        controls.contains { control in
            control.id == controlID
                && control.kind == .navigationList
                && control.selectedOptionID == optionID
        }
    }

    private func presentDiskCleanDetails() {
        onPresentDiskCleanConfiguration()
    }

    private func presentLaunchControlManager() {
        onPresentLaunchControlConfiguration()
    }

    private func syncSecondaryPanelWindow() {
        guard let activeSecondaryPanel, let anchorRect = hoverCoordinator.selectedRowFrame else {
            secondaryPanelController.hide()
            return
        }

        secondaryPanelController.show(
            panel: activeSecondaryPanel.panel,
            anchorRect: anchorRect,
            onSelectionChange: { controlID, optionID in
                pluginHost.setPanelSelectionValue(
                    optionID,
                    controlID: controlID,
                    for: activeSecondaryPanel.item.id
                )
            },
            onNavigationSelectionChange: { controlID, optionID in
                let controls = activeSecondaryPanel.panel.controls
                if isNavigationOptionSelected(in: controls, controlID: controlID, optionID: optionID) {
                    pluginHost.clearPanelNavigationSelection(
                        controlID: controlID,
                        for: activeSecondaryPanel.item.id
                    )
                    hoverCoordinator.dismissImmediately()
                    return
                }

                if activeSecondaryPanel.item.detail?.secondaryPanel(
                    controlID: controlID,
                    optionID: optionID
                ) != nil {
                    hoverCoordinator.pin(
                        pluginID: activeSecondaryPanel.item.id,
                        controlID: controlID,
                        optionID: optionID
                    )
                } else {
                    hoverCoordinator.dismissImmediately()
                }
                pluginHost.setPanelNavigationSelectionValue(
                    optionID,
                    controlID: controlID,
                    for: activeSecondaryPanel.item.id
                )
            },
            onDateChange: { controlID, date in
                pluginHost.setPanelDateValue(
                    date,
                    controlID: controlID,
                    for: activeSecondaryPanel.item.id
                )
            },
            onHoverChange: handleSecondaryPanelHoverChange,
            onSliderChange: { controlID, value, phase in
                pluginHost.setPanelSliderValue(
                    value,
                    controlID: controlID,
                    for: activeSecondaryPanel.item.id,
                    phase: phase
                )
            }
        )
    }

    private func handleNavigationHoverChange(
        pluginID: String,
        controlID: String,
        optionID: String,
        isHovering: Bool
    ) {
        if isHovering {
            hoverCoordinator.hoverBegan(
                pluginID: pluginID,
                controlID: controlID,
                optionID: optionID
            )
            return
        }

        hoverCoordinator.hoverEnded(
            pluginID: pluginID,
            controlID: controlID,
            optionID: optionID
        )
    }

    private func handleSecondaryPanelHoverChange(_ isHovering: Bool) {
        hoverCoordinator.setPanelHovered(isHovering)
    }

    private var activeSecondaryPanelSignature: String? {
        guard let activeSecondaryPanel else {
            return nil
        }

        let controlIDs = activeSecondaryPanel.panel.controls.map(\.id).joined(separator: ",")
        return "\(activeSecondaryPanel.activation.pluginID)|\(activeSecondaryPanel.activation.optionID)|\(activeSecondaryPanel.panel.title)|\(controlIDs)"
    }

    private var activeSecondaryPanel: ActiveSecondaryPanel? {
        guard
            let activation = hoverCoordinator.activeActivation,
            let item = pluginHost.panelItems.first(where: { $0.id == activation.pluginID }),
            let panel = item.detail?.secondaryPanel(
                controlID: activation.controlID,
                optionID: activation.optionID
            )
        else {
            return nil
        }

        return ActiveSecondaryPanel(
            activation: activation,
            item: item,
            panel: panel
        )
    }

    private struct ActiveSecondaryPanel {
        let activation: HoverSecondaryPanelCoordinator.Activation
        let item: PluginPanelItem
        let panel: PluginPanelSecondaryPanel
    }

    private var featureCards: some View {
        VStack(spacing: MenuBarPanelLayout.featureRowSpacing) {
            if pluginHost.panelItems.isEmpty {
                PanelPluginEmptyState(
                    title: AppL10n.plugins("plugin.panel.empty.title", defaultValue: "暂无插件"),
                    systemImage: "shippingbox",
                    iconTint: .blue,
                    onInstall: {
                        pluginHost.presentPluginMarketplace()
                    }
                )
                .frame(minHeight: MenuBarPanelLayout.emptyContentHeight)
            } else {
                ForEach(pluginHost.panelItems) { item in
                    FeatureRowView(
                        item: item,
                        indicator: pluginHost.primaryPanelIndicatorsByID[item.id],
                        isOn: Binding(
                            get: { pluginHost.isSwitchOn(for: item.id) },
                            set: { newValue in
                                handlePanelSwitchChange(newValue, for: item)
                            }
                        ),
                        onDisclosureToggle: { isExpanded in
                            pluginHost.setDisclosureExpanded(isExpanded, for: item.id)
                        },
                        onSelectionChange: { controlID, optionID in
                            pluginHost.setPanelSelectionValue(optionID, controlID: controlID, for: item.id)
                        },
                        onNavigationSelectionChange: { controlID, optionID in
                            if isNavigationOptionSelected(
                                in: item.detail?.primaryControls ?? [],
                                controlID: controlID,
                                optionID: optionID
                            ) {
                                pluginHost.clearPanelNavigationSelection(controlID: controlID, for: item.id)
                                hoverCoordinator.dismissImmediately()
                                return
                            }

                            if item.detail?.secondaryPanel(controlID: controlID, optionID: optionID) != nil {
                                hoverCoordinator.pin(
                                    pluginID: item.id,
                                    controlID: controlID,
                                    optionID: optionID
                                )
                            } else {
                                hoverCoordinator.dismissImmediately()
                            }
                            pluginHost.setPanelNavigationSelectionValue(optionID, controlID: controlID, for: item.id)
                        },
                        onNavigationHoverChange: { controlID, optionID, isHovering in
                            handleNavigationHoverChange(
                                pluginID: item.id,
                                controlID: controlID,
                                optionID: optionID,
                                isHovering: isHovering
                            )
                        },
                        onNavigationRowFrameChange: { controlID, optionID, frame in
                            hoverCoordinator.updateRowFrame(
                                frame,
                                for: HoverSecondaryPanelCoordinator.Activation(
                                    pluginID: item.id,
                                    controlID: controlID,
                                    optionID: optionID
                                )
                            )
                        },
                        onDateChange: { controlID, date in
                            pluginHost.setPanelDateValue(date, controlID: controlID, for: item.id)
                        },
                        onSwitchChange: { newValue in
                            handlePanelSwitchChange(newValue, for: item)
                        },
                        onSliderChange: { controlID, value, phase in
                            pluginHost.setPanelSliderValue(
                                value,
                                controlID: controlID,
                                for: item.id,
                                phase: phase
                            )
                        },
                        onActionInvoke: { controlID, behavior in
                            handleActionInvoke(
                                controlID: controlID,
                                for: item,
                                behavior: behavior
                            )
                        }
                    )
                }
            }
        }
        .frame(width: MenuBarPanelLayout.surfaceWidth, alignment: .leading)
    }

}

@MainActor
final class DeferredPanelActionDispatcher: ObservableObject {
    struct PanelSwitchAction: Equatable {
        let pluginID: String
        let isOn: Bool
    }

    struct ActionInvocation: Equatable {
        let pluginID: String
        let controlID: String
    }

    private(set) var pendingPanelSwitchAction: PanelSwitchAction?
    private(set) var pendingActionInvocation: ActionInvocation?
    private var flushTask: Task<Void, Never>?

    func deferPanelSwitch(pluginID: String, isOn: Bool) {
        pendingPanelSwitchAction = PanelSwitchAction(pluginID: pluginID, isOn: isOn)
    }

    func deferActionInvocation(pluginID: String, controlID: String) {
        pendingActionInvocation = ActionInvocation(pluginID: pluginID, controlID: controlID)
    }

    func flushAfterDismiss(
        switchHandler: @escaping @MainActor (PanelSwitchAction) -> Void,
        invocationHandler: @escaping @MainActor (ActionInvocation) -> Void
    ) {
        guard flushTask == nil else {
            return
        }

        flushTask = Task { @MainActor [weak self] in
            await Task.yield()
            self?.flush(
                switchHandler: switchHandler,
                invocationHandler: invocationHandler
            )
        }
    }

    func flush(
        switchHandler: (PanelSwitchAction) -> Void,
        invocationHandler: (ActionInvocation) -> Void
    ) {
        flushTask?.cancel()
        flushTask = nil

        let panelSwitchAction = pendingPanelSwitchAction
        let actionInvocation = pendingActionInvocation
        pendingPanelSwitchAction = nil
        pendingActionInvocation = nil

        if let panelSwitchAction {
            switchHandler(panelSwitchAction)
        }

        if let actionInvocation {
            invocationHandler(actionInvocation)
        }
    }
}

struct FeatureRowView: View {
    let item: PluginPanelItem
    let indicator: PluginPrimaryPanelIndicator?
    @Binding var isOn: Bool
    let onDisclosureToggle: (Bool) -> Void
    let onSelectionChange: (String, String) -> Void
    let onNavigationSelectionChange: (String, String) -> Void
    let onNavigationHoverChange: (String, String, Bool) -> Void
    let onNavigationRowFrameChange: (String, String, CGRect?) -> Void
    let onDateChange: (String, Date) -> Void
    let onSwitchChange: (Bool) -> Void
    let onSliderChange: (String, Double, PluginPanelAction.SliderPhase) -> Void
    let onActionInvoke: (String, PluginMenuActionBehavior) -> Void
    @State private var isHovered = false
    @State private var didPushDisabledCursor = false

    var body: some View {
        VStack(alignment: .leading, spacing: detailToDisplay == nil ? 0 : MenuBarPanelLayout.detailSpacing) {
            switch item.controlStyle {
            case .switch:
                rowHeader
            case .disclosure:
                Button {
                    onDisclosureToggle(!item.isExpanded)
                } label: {
                    rowHeader
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            case .button:
                HStack(alignment: .center, spacing: FeatureRowLayout.rowSpacing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: FeatureRowLayout.iconCornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.08))

                        Image(systemName: item.iconName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: FeatureRowLayout.iconSize, height: FeatureRowLayout.iconSize)

                    rowText
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        if let actionID = item.buttonActionID {
                            onActionInvoke(actionID, item.menuActionBehavior)
                        }
                    } label: {
                        Text(item.buttonTitle ?? AppL10n.plugins("plugin.panel.actionFallback", defaultValue: "操作"))
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .frame(minWidth: 45, minHeight: 21)
                            .background(item.isEnabled ? Color.accentColor : Color(NSColor.secondaryLabelColor))
                            .cornerRadius(15)
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isEnabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())

            }

            if let detail = detailToDisplay {
                PluginPanelDetailView(
                    detail: detail,
                    isOn: $isOn,
                    showsSecondaryPanel: false,
                    onSelectionChange: onSelectionChange,
                    onNavigationSelectionChange: onNavigationSelectionChange,
                    onNavigationHoverChange: onNavigationHoverChange,
                    onNavigationRowFrameChange: onNavigationRowFrameChange,
                    onDateChange: onDateChange,
                    onSwitchChange: onSwitchChange,
                    onSliderChange: onSliderChange,
                    onActionInvoke: onActionInvoke
                )
                .padding(.leading, FeatureRowLayout.detailLeadingInset)
            }
        }
        .padding(.horizontal, FeatureRowLayout.rowHorizontalPadding)
        .padding(.vertical, FeatureRowLayout.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .center) {
            RoundedRectangle(cornerRadius: MenuBarHoverStyle.cornerRadius, style: .continuous)
                .inset(by: MenuBarHoverStyle.inset)
                .fill(item.isEnabled && isHovered ? MenuBarHoverStyle.fill : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: MenuBarHoverStyle.cornerRadius, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
            updateCursorForDisabledState(hovering: hovering)
        }
        .onChange(of: item.isEnabled) { _, _ in
            updateCursorForDisabledState(hovering: isHovered)
        }
        .onDisappear {
            resetDisabledCursorIfNeeded()
        }
        .help(item.helpText)
    }

    private var rowHeader: some View {
        HStack(alignment: .center, spacing: FeatureRowLayout.rowSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: FeatureRowLayout.iconCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.08))

                Image(systemName: item.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: FeatureRowLayout.iconSize, height: FeatureRowLayout.iconSize)

            rowText
            .frame(maxWidth: .infinity, alignment: .leading)

            switch item.controlStyle {
            case .switch:
                Toggle(String(), isOn: $isOn)
                    .labelsHidden()
                    .controlSize(.small)
                    .toggleStyle(.switch)
                    .disabled(!item.isEnabled)
            case .disclosure:
                Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: FeatureRowLayout.chevronSize, height: FeatureRowLayout.chevronSize)
            case .button:
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: FeatureRowLayout.chevronSize, height: FeatureRowLayout.chevronSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MenuBarPanelLayout.rowHeaderHeight, alignment: .center)
        .contentShape(Rectangle())
    }

    private var detailToDisplay: PluginPanelDetail? {
        guard let detail = item.detail else {
            return nil
        }

        if item.controlStyle == .disclosure && !item.isExpanded {
            return nil
        }

        return detail
    }

    private var rowText: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                if let indicator {
                    Label(indicator.text, systemImage: indicator.systemImage)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            HStack(spacing: 3) {
                Text(item.description)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(item.descriptionTone == .error ? Color.red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.helpText)

                if showsIPOverviewCopyButton {
                    Button {
                        onActionInvoke(MenuBarContent.ipOverviewCopyIPActionID, .keepPresented)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10.5, height: 10.5)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                    .help(AppL10n.plugins("plugin.panel.copyIP", defaultValue: "复制 IP"))
                }
            }
        }
    }

    private var showsIPOverviewCopyButton: Bool {
        item.id == MenuBarContent.ipOverviewPluginID
            && !descriptionIsError
            && Self.looksLikeIPAddress(item.description)
    }

    private var descriptionIsError: Bool {
        switch item.descriptionTone {
        case .error:
            return true
        case .secondary:
            return false
        }
    }

    private static func looksLikeIPAddress(_ value: String) -> Bool {
        let allowedCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        return !value.isEmpty
            && value.rangeOfCharacter(from: allowedCharacters.inverted) == nil
            && (value.contains(".") || value.contains(":"))
    }

    private func updateCursorForDisabledState(hovering: Bool) {
        if !item.isEnabled && hovering {
            if !didPushDisabledCursor {
                NSCursor.operationNotAllowed.push()
                didPushDisabledCursor = true
            }
        } else {
            resetDisabledCursorIfNeeded()
        }
    }

    private func resetDisabledCursorIfNeeded() {
        if didPushDisabledCursor {
            NSCursor.pop()
            didPushDisabledCursor = false
        }
    }
}

private struct PluginPanelDetailView: View {
    let detail: PluginPanelDetail
    @Binding var isOn: Bool
    let showsSecondaryPanel: Bool
    let onSelectionChange: (String, String) -> Void
    let onNavigationSelectionChange: (String, String) -> Void
    let onNavigationHoverChange: (String, String, Bool) -> Void
    let onNavigationRowFrameChange: (String, String, CGRect?) -> Void
    let onDateChange: (String, Date) -> Void
    let onSwitchChange: (Bool) -> Void
    let onSliderChange: (String, Double, PluginPanelAction.SliderPhase) -> Void
    let onActionInvoke: (String, PluginMenuActionBehavior) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MenuBarPanelLayout.detailControlSpacing) {
            ForEach(detail.primaryControls) { control in
                if control.showsLeadingDivider {
                    Divider()
                        .padding(.horizontal, FeatureRowLayout.detailControlHorizontalPadding)
                }

                panelControl(control)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func panelControl(_ control: PluginPanelControl) -> some View {
        switch control.kind {
        case .segmented:
            Picker(
                String(),
                selection: Binding(
                    get: { control.selectedOptionID ?? "" },
                    set: { newValue in
                        onSelectionChange(control.id, newValue)
                    }
                )
            ) {
                ForEach(control.options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(!control.isEnabled)
        case .datePicker:
            switch control.datePickerStyle ?? .compact {
            case .compact:
                DatePicker(
                    String(),
                    selection: Binding(
                        get: { control.dateValue ?? Date() },
                        set: { newValue in
                            onDateChange(control.id, newValue)
                        }
                    ),
                    in: (control.minimumDate ?? Date())...,
                    displayedComponents: control.displayedComponents ?? [.date, .hourAndMinute]
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .disabled(!control.isEnabled)
            case .dateTimeCard:
                DateTimeCardPicker(
                    selection: Binding(
                        get: { control.dateValue ?? Date() },
                        set: { newValue in
                            onDateChange(control.id, newValue)
                        }
                    ),
                    minimumDate: control.minimumDate ?? Date(),
                    isEnabled: control.isEnabled
                )
            }
        case .selectList:
            SelectListControl(
                control: control,
                onSelect: { optionID in
                    onSelectionChange(control.id, optionID)
                }
            )
        case .navigationList:
            NavigationListControl(
                control: control,
                onSelect: { optionID in
                    onNavigationSelectionChange(control.id, optionID)
                },
                onHoverChange: { optionID, isHovering in
                    onNavigationHoverChange(control.id, optionID, isHovering)
                },
                onRowFrameChange: { optionID, frame in
                    onNavigationRowFrameChange(control.id, optionID, frame)
                }
            )
        case .slider:
            SliderControl(
                control: control,
                onChange: { value, phase in
                    onSliderChange(control.id, value, phase)
                }
            )
        case .switchRow:
            SwitchRowControl(
                control: control,
                isOn: $isOn,
                onChange: onSwitchChange
            )
        case .actionRow:
            ActionRowControl(
                control: control,
                onInvoke: {
                    onActionInvoke(control.id, control.actionBehavior)
                }
            )
        }
    }
}

private struct SwitchRowControl: View {
    let control: PluginPanelControl
    @Binding var isOn: Bool
    let onChange: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if let iconName = control.actionIconSystemName {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }

            Text(control.actionTitle ?? control.sectionTitle ?? "")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Toggle(String(), isOn: Binding(
                get: { isOn },
                set: { newValue in
                    guard control.isEnabled else { return }
                    onChange(newValue)
                }
            ))
            .labelsHidden()
            .controlSize(.small)
            .toggleStyle(.switch)
            .disabled(!control.isEnabled)
        }
        .padding(.horizontal, FeatureRowLayout.detailControlHorizontalPadding)
        .padding(.vertical, MenuBarPanelLayout.actionRowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(alignment: .center) {
            RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous)
                .inset(by: MenuBarHoverStyle.inset)
                .fill(control.isEnabled && isHovered ? MenuBarHoverStyle.fill : Color.clear)
        }
        .onHover { isHovered = $0 }
    }
}

private struct ActionRowControl: View {
    let control: PluginPanelControl
    let onInvoke: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sectionTitle = control.sectionTitle, !sectionTitle.isEmpty {
                Text(sectionTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, FeatureRowLayout.detailControlHorizontalPadding)
            }

            Button {
                guard control.isEnabled else { return }
                onInvoke()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: control.actionIconSystemName ?? "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(actionIconTint)
                        .frame(width: 14, height: 14)

                    Text(control.actionTitle ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, FeatureRowLayout.detailControlHorizontalPadding)
                .padding(.vertical, MenuBarPanelLayout.actionRowVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(alignment: .center) {
                    RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous)
                        .inset(by: MenuBarHoverStyle.inset)
                        .fill(control.isEnabled && isHovered ? MenuBarHoverStyle.fill : Color.clear)
                }
            }
            .buttonStyle(.plain)
            .disabled(!control.isEnabled)
            .onHover { isHovered = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionIconTint: Color {
        switch control.actionIconSystemName {
        case "checkmark.circle.fill":
            .green
        case "arrow.triangle.2.circlepath.circle.fill", "checkmark.circle":
            .blue
        case "exclamationmark.circle.fill":
            .red
        case "questionmark.circle":
            .orange
        default:
            .secondary
        }
    }
}

private struct SelectListControl: View {
    let control: PluginPanelControl
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = control.sectionTitle {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
                    .padding(.bottom, 1)
            }

            VStack(spacing: 0) {
                ForEach(control.options) { option in
                    SelectListRow(
                        title: option.title,
                        isSelected: option.id == control.selectedOptionID,
                        isEnabled: control.isEnabled,
                        action: { onSelect(option.id) }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct SelectListRow: View {
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard isInteractive else {
                return
            }

            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)

                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, MenuBarPanelLayout.selectRowVerticalPadding)
            .contentShape(Rectangle())
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .inset(by: MenuBarHoverStyle.inset)
                    .fill(isInteractive && isHovered ? MenuBarHoverStyle.fill : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
    }

    private var isInteractive: Bool {
        isEnabled && !isSelected
    }
}

private struct NavigationListControl: View {
    let control: PluginPanelControl
    let onSelect: (String) -> Void
    let onHoverChange: (String, Bool) -> Void
    let onRowFrameChange: (String, CGRect?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MenuBarPanelLayout.navigationSectionTitleSpacing) {
            if let sectionTitle = control.sectionTitle {
                Text(sectionTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, FeatureRowLayout.detailControlHorizontalPadding + 5)
            }

            VStack(spacing: 0) {
                ForEach(control.options) { option in
                    NavigationListRow(
                        title: option.title,
                        subtitle: option.subtitle,
                        leadingIconSystemName: control.actionIconSystemName,
                        leadingIconTint: navigationIconTint,
                        isSelected: option.id == control.selectedOptionID,
                        isEnabled: control.isEnabled,
                        action: { onSelect(option.id) },
                        onHoverChange: { isHovering in
                            onHoverChange(option.id, isHovering)
                        },
                        onRowFrameChange: { frame in
                            onRowFrameChange(option.id, frame)
                        }
                    )
                }
            }
        }
    }

    private var navigationIconTint: Color {
        switch control.actionIconSystemName {
        case "checkmark.circle.fill":
            .green
        case "arrow.triangle.2.circlepath.circle.fill", "checkmark.circle":
            .blue
        case "exclamationmark.circle.fill":
            .red
        default:
            .secondary
        }
    }
}

private struct NavigationListRow: View {
    let title: String
    let subtitle: String?
    let leadingIconSystemName: String?
    let leadingIconTint: Color
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    let onHoverChange: (Bool) -> Void
    let onRowFrameChange: (CGRect?) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            guard isInteractive else {
                return
            }

            action()
        } label: {
            HStack(spacing: 8) {
                if let leadingIconSystemName {
                    Image(systemName: leadingIconSystemName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(leadingIconTint)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(isSelected ? 1 : (isHovered ? 0.55 : 0.35))
            }
            .padding(.horizontal, FeatureRowLayout.detailControlHorizontalPadding)
            .padding(.vertical, 6)
            .frame(minHeight: MenuBarPanelLayout.navigationRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous)
                    .inset(by: MenuBarHoverStyle.inset)
                    .fill(backgroundFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            NavigationRowFrameReader(
                onFrameChange: onRowFrameChange
            )
        }
        .onDisappear {
            onHoverChange(false)
            onRowFrameChange(nil)
        }
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering)
        }
    }

    private var isInteractive: Bool {
        // A second click on a selected row clears its selection and closes the pinned
        // secondary panel. The parent handles that toggle-off action explicitly.
        isEnabled
    }

    private var backgroundFill: Color {
        if isSelected {
            return MenuBarHoverStyle.navigationSelectedFill
        }

        if isHovered && isEnabled {
            return MenuBarHoverStyle.navigationFill
        }

        return .clear
    }
}

private struct SliderControl: View {
    let control: PluginPanelControl
    let onChange: (Double, PluginPanelAction.SliderPhase) -> Void

    @State private var localValue = 0.0
    @State private var isEditing = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if control.sectionTitle != nil || control.valueLabel != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let title = control.sectionTitle, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    if let valueLabel = control.valueLabel {
                        Text(valueLabel)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(alignment: .center, spacing: 8) {
                Slider(
                    value: Binding(
                        get: { isEditing ? localValue : (control.sliderValue ?? localValue) },
                        set: { newValue in
                            let snappedValue = snappedSliderValue(for: newValue)
                            localValue = snappedValue
                            onChange(snappedValue, .changed)
                        }
                    ),
                    in: control.sliderBounds ?? 0...1,
                    onEditingChanged: { isEditing in
                        self.isEditing = isEditing

                        if isEditing {
                            localValue = control.sliderValue ?? localValue
                        } else {
                            onChange(localValue, .ended)
                        }
                    }
                )
                .labelsHidden()
                .disabled(!control.isEnabled)
                .tint(Color(nsColor: .controlAccentColor))
                .accessibilityLabel(control.sectionTitle ?? AppL10n.plugins(
                    "plugin.panel.displayBrightnessFallback",
                    defaultValue: "显示器亮度"
                ))
            }
        }
        .padding(.horizontal, FeatureRowLayout.detailControlHorizontalPadding)
        .padding(.vertical, MenuBarPanelLayout.sliderVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .center) {
            RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous)
                .inset(by: MenuBarHoverStyle.inset)
                .fill(control.isEnabled && isHovered ? MenuBarHoverStyle.fill : Color.clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: MenuBarHoverStyle.navigationCornerRadius, style: .continuous))
        .onHover { isHovered = $0 }
        .onAppear {
            localValue = control.sliderValue ?? 0
        }
        .onChange(of: control.sliderValue) { _, newValue in
            guard !isEditing else {
                return
            }

            localValue = newValue ?? localValue
        }
    }

    private func brightnessGlyph(systemName: String, size: CGFloat) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size + 6, alignment: .center)
            .accessibilityHidden(true)
    }

    private func snappedSliderValue(for value: Double) -> Double {
        let bounds = control.sliderBounds ?? 0...1
        let clampedValue = min(max(value, bounds.lowerBound), bounds.upperBound)

        guard
            let step = control.sliderStep,
            step > 0
        else {
            return clampedValue
        }

        let snappedValue = (clampedValue / step).rounded() * step
        return min(max(snappedValue, bounds.lowerBound), bounds.upperBound)
    }
}

private struct SecondarySlidingPanel: View {
    private static let cornerRadius: CGFloat = MenuBarPanelLayout.cornerRadius

    let title: String
    let controls: [PluginPanelControl]
    let maximumContentHeight: CGFloat
    let showsDismissButton: Bool
    let onDismiss: (() -> Void)?
    let onSelectionChange: (String, String) -> Void
    let onNavigationSelectionChange: (String, String) -> Void
    let onDateChange: (String, Date) -> Void
    let onHoverChange: (Bool) -> Void
    let onSliderChange: (String, Double, PluginPanelAction.SliderPhase) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if showsDismissButton {
                    Button(action: { onDismiss?() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        AppL10n.settings("secondaryPanel.back", defaultValue: "返回")
                    )
                    .help(
                        AppL10n.settings("secondaryPanel.back", defaultValue: "返回")
                    )
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            ScrollView(.vertical, showsIndicators: true) {
                PluginPanelDetailView(
                    detail: PluginPanelDetail(primaryControls: controls, secondaryPanel: nil),
                    isOn: .constant(false),
                    showsSecondaryPanel: false,
                    onSelectionChange: onSelectionChange,
                    onNavigationSelectionChange: onNavigationSelectionChange,
                    onNavigationHoverChange: { _, _, _ in },
                    onNavigationRowFrameChange: { _, _, _ in },
                    onDateChange: onDateChange,
                    onSwitchChange: { _ in },
                    onSliderChange: onSliderChange,
                    onActionInvoke: { _, _ in }
                )
            }
            .frame(maxHeight: maximumContentHeight, alignment: .top)
        }
        .padding(MenuBarPanelLayout.outerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            PopoverMaterialBackground()
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: Self.cornerRadius,
                style: .continuous
            )
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: Self.cornerRadius,
                style: .continuous
            )
        )
        .onHover(perform: onHoverChange)
    }
}

private final class SecondaryPanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PopoverMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
    }
}

@MainActor
private final class SecondaryPanelController: ObservableObject {
    // The secondary panel must remain a sibling of the MenuBarExtra popover, not a child window.
    //
    // Background: `NSWindow.addChildWindow(_:, ordered:)` binds parent and child key status into the
    // same focus group, so the parent window does not receive `didResignKeyNotification` when the
    // user clicks outside. `MenuBarExtra(.window)` dismissal, implemented by SwiftUI's private
    // `WindowMenuBarExtraBehavior`, relies on the popover's `didResignKey` notification. Once this
    // panel is attached as a child window, the popover never closes itself.
    //
    // Solution: keep it as an independent sibling NSPanel and never call `addChildWindow`. Its
    // placement is computed from `anchorRect` and the anchor screen's visible frame; when neither
    // side has enough room, MenuBarContent renders the same panel as an in-place drill-in view.
    //
    // References:
    // - MenuBarExtraAccess source, which observes `didResignKey` on `MenuBarExtraWindow`
    //   https://github.com/orchetect/MenuBarExtraAccess
    // - Apple Feedback FB11984872: window-style MenuBarExtra cannot be closed programmatically
    // - CocoaDev "HowCanChildWindowBeKey": https://cocoadev.github.io/HowCanChildWindowBeKey/

    private weak var hostWindow: NSWindow?
    private var panelWindow: SecondaryPanelWindow?
    private var panelHostingView: NSHostingView<AnyView>?
    private var hostWindowObservers: [NSObjectProtocol] = []
    @Published private(set) var isPresentingInline = false
    var onHostWindowDismissRequest: (() -> Void)?

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window else {
            return
        }

        removeHostWindowObservers()
        hostWindow = window

        guard window != nil else {
            hide()
            return
        }

        observeHostWindowIfNeeded()
    }

    func show(
        panel: PluginPanelSecondaryPanel,
        anchorRect: CGRect,
        onSelectionChange: @escaping (String, String) -> Void,
        onNavigationSelectionChange: @escaping (String, String) -> Void,
        onDateChange: @escaping (String, Date) -> Void,
        onHoverChange: @escaping (Bool) -> Void,
        onSliderChange: @escaping (String, Double, PluginPanelAction.SliderPhase) -> Void
    ) {
        guard let hostWindow else { return }
        // `MenuWindowAccessor.updateNSView` can still dispatch async callbacks after `.onDisappear`,
        // which may call `show()` again after `hide()`. When the popover is dismissed, `hostWindow`
        // is already not visible; use that to block the race from re-showing the panel.
        guard hostWindow.isVisible else { return }

        let screen = screenContaining(anchorRect: anchorRect)
        let rootView = AnyView(
            SecondarySlidingPanel(
                title: panel.title,
                controls: panel.controls,
                maximumContentHeight: maximumSecondaryPanelContentHeight(
                    for: screen
                ),
                showsDismissButton: false,
                onDismiss: nil,
                onSelectionChange: onSelectionChange,
                onNavigationSelectionChange: onNavigationSelectionChange,
                onDateChange: onDateChange,
                onHoverChange: onHoverChange,
                onSliderChange: onSliderChange
            )
            .frame(width: MenuBarPanelLayout.secondaryPanelWidth)
        )

        let panelWindow = panelWindow ?? makePanel()
        // Reuse one NSHostingView. Rebuilding `contentView` on every `show()` destroys the SwiftUI
        // Button hit between mouseDown and mouseUp, dropping clicks such as display-resolution
        // selections. Updating `rootView` in place preserves pressed state and hover tracking.
        let hostingView: NSHostingView<AnyView>
        if let existing = panelHostingView, panelWindow.contentView === existing {
            existing.rootView = rootView
            hostingView = existing
        } else {
            let newHosting = NSHostingView(rootView: rootView)
            panelWindow.contentView = newHosting
            panelHostingView = newHosting
            hostingView = newHosting
        }
        applyCurrentAppearance()

        let fittingSize = hostingView.fittingSize
        let width = MenuBarPanelLayout.secondaryPanelWidth
        let height = min(
            max(fittingSize.height, MenuBarPanelLayout.secondaryPanelMinimumHeight),
            maximumSecondaryPanelHeight(for: screen)
        )
        let visibleFrame = screen?.visibleFrame
            ?? hostWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let placement = SecondaryPanelPlacement.resolve(
            anchorRect: anchorRect,
            panelSize: CGSize(width: width, height: height),
            visibleFrame: visibleFrame
        )

        switch placement {
        case let .right(frame), let .left(frame):
            isPresentingInline = false
            panelWindow.setFrame(frame, display: true)
            // Align the panel level to `hostWindow.level + 1` at runtime so it stays above the popover.
            // The MenuBarExtra popover level is a private SwiftUI implementation detail.
            panelWindow.level = NSWindow.Level(rawValue: hostWindow.level.rawValue + 1)
            panelWindow.orderFrontRegardless()
        case .inline:
            isPresentingInline = true
            panelWindow.orderOut(nil)
        }
        self.panelWindow = panelWindow
    }

    func applyCurrentAppearance() {
        let preference = AppAppearancePreference.stored()
        preference.apply(to: panelWindow)
        preference.apply(to: panelHostingView)
    }

    func hide() {
        panelWindow?.orderOut(nil)
        self.panelWindow = nil
        self.panelHostingView = nil
        isPresentingInline = false
    }

    private func screenContaining(anchorRect: CGRect) -> NSScreen? {
        let anchorPoint = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) })
            ?? hostWindow?.screen
            ?? NSScreen.main
    }

    private func maximumSecondaryPanelHeight(for screen: NSScreen?) -> CGFloat {
        let visibleHeight = screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? MenuBarPanelLayout.maximumPanelHeight
        return max(0, visibleHeight - (MenuBarPanelLayout.secondaryPanelScreenMargin * 2))
    }

    private func maximumSecondaryPanelContentHeight(for screen: NSScreen?) -> CGFloat {
        max(
            0,
            maximumSecondaryPanelHeight(for: screen)
                - MenuBarPanelLayout.secondaryPanelContentChromeHeight
        )
    }

    private func makePanel() -> SecondaryPanelWindow {
        let panel = SecondaryPanelWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        MenuBarPanelWindowRegistry.markSecondaryPanel(panel)
        // Keep this false. For an LSUIElement menu-bar app, the app is often inactive while
        // MenuBarExtra is open, but the menu remains interactive. If `hidesOnDeactivate` is enabled,
        // the panel hides immediately after showing, or can end up with `isVisible == true` while no
        // pixels are on screen. Panel lifetime is driven by MenuBarContent's `onDisappear` and
        // `syncSecondaryPanelWindow`.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        AppAppearancePreference.stored().apply(to: panel)
        return panel
    }

    private func observeHostWindowIfNeeded() {
        guard let hostWindow else {
            return
        }

        let notificationCenter = NotificationCenter.default
        hostWindowObservers = [
            notificationCenter.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: hostWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hide()
                    self?.onHostWindowDismissRequest?()
                }
            },
            notificationCenter.addObserver(
                forName: NSWindow.willCloseNotification,
                object: hostWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.hide()
                    self?.onHostWindowDismissRequest?()
                }
            }
        ]
    }

    private func removeHostWindowObservers() {
        let notificationCenter = NotificationCenter.default
        hostWindowObservers.forEach(notificationCenter.removeObserver)
        hostWindowObservers.removeAll()
    }
}

private struct MenuWindowAccessor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onWindowChange(view.window)
        }
        return view
    }

    // Report the window on every re-render. The parent calls `syncSecondaryPanelWindow()`, which is
    // the fallback refresh for cases where screen-resolution changes or short popover visibility
    // gaps cause `onChange` hooks to miss a needed `show()`. This must be paired with NSHostingView
    // reuse in `SecondaryPanelController.show()`; otherwise contentView rebuilds between mouseDown
    // and mouseUp can drop button clicks.
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onWindowChange(nsView.window)
        }
    }
}

private struct NavigationRowFrameReader: NSViewRepresentable {
    let onFrameChange: (CGRect?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            updateFrame(for: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            updateFrame(for: nsView)
        }
    }

    private func updateFrame(for view: NSView) {
        guard let window = view.window else {
            onFrameChange(nil)
            return
        }

        let rectInWindow = view.convert(view.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)
        onFrameChange(rectOnScreen)
    }
}

struct ScrollViewScrollerVisibilityConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configureScrollView(containing: view, remainingRetries: 4)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureScrollView(containing: nsView, remainingRetries: 4)
        }
    }

    private func configureScrollView(containing view: NSView, remainingRetries: Int) {
        guard let scrollView = nearestScrollView(from: view) else {
            guard remainingRetries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                configureScrollView(containing: view, remainingRetries: remainingRetries - 1)
            }
            return
        }

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.contentInsets = zeroInsets
        scrollView.scrollerInsets = zeroInsets
    }

    private func nearestScrollView(from view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }

        if let scrollView = view.enclosingScrollView {
            return scrollView
        }

        var currentView = view.superview
        while let candidate = currentView {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            currentView = candidate.superview
        }

        return nil
    }
}

private struct DateTimeCardPicker: View {
    @Binding var selection: Date
    let minimumDate: Date
    let isEnabled: Bool

    var body: some View {
        DatePicker(
            String(),
            selection: Binding(
                get: { sanitizedDate(selection) },
                set: { newValue in
                    selection = sanitizedDate(newValue)
                }
            ),
            in: minimumDate...,
            displayedComponents: [.date, .hourAndMinute]
        )
        .labelsHidden()
        .datePickerStyle(.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!isEnabled)
        .environment(\.locale, .current)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isEnabled ? 1 : 0.6)
    }

    private func sanitizedDate(_ candidate: Date) -> Date {
        max(candidate, minimumDate)
    }
}
