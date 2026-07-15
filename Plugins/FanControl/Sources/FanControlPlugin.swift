import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

// MARK: - Bundle Factory

public final class FanControlPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        FanControlPluginProvider(context: context)
    }
}

@MainActor
private struct FanControlPluginProvider: PluginProvider {
    let context: PluginRuntimeContext
    func makePlugins() -> [any MacToolsPlugin] {
        [FanControlPlugin(context: context, localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

// MARK: - Control IDs

private enum ControlID {
    static let presetList   = "fan-preset-list"
    static let customSlider = "fan-custom-rpm"
    static let addPreset    = "fan-add-preset"
    static let deletePreset = "fan-delete-preset"
    static let missingHelper = "fan-missing-helper"
}

// MARK: - Plugin

@MainActor
final class FanControlPlugin: MacToolsPlugin, PluginPrimaryPanel {

    // MARK: Metadata

    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    // MARK: Callbacks

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    // MARK: Private State

    let presetStore: FanControlPresetStore
    private let smcReader: any FanControlSMCReading
    private let smcWriter: any FanControlSMCWriting
    private let localization: PluginLocalization
    private let monitoringActiveInterval: Duration
    private let monitoringIdleInterval: Duration

    private var isExpanded = false
    private var fanSnapshot = FanSnapshot.empty
    private var lastErrorMessage: String?
    private var requiresAutoRestore = false
    private var monitoringTask: Task<Void, Never>?
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    // MARK: Init

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "fan-control"),
        smcReader: any FanControlSMCReading = FanControlSMCReader(),
        smcWriter: (any FanControlSMCWriting)? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        monitoringActiveInterval: Duration = .seconds(2),
        monitoringIdleInterval: Duration = .seconds(10)
    ) {
        self.localization = localization
        self.presetStore = FanControlPresetStore(storage: context.storage, localization: localization)
        self.smcReader = smcReader
        self.smcWriter = smcWriter ?? FanControlSMCWriter(
            resourceBundle: context.resourceBundle,
            localization: localization
        )
        self.monitoringActiveInterval = monitoringActiveInterval
        self.monitoringIdleInterval = monitoringIdleInterval
        self.metadata = PluginMetadata(
            id: "fan-control",
            title: localization.string("metadata.title", defaultValue: "风扇控制"),
            iconName: "fan",
            iconTint: Color(nsColor: .systemCyan),
            order: 45,
            defaultDescription: localization.string("metadata.description", defaultValue: "管理风扇转速预设")
        )
    }

    // MARK: - MacToolsPlugin

    func activate(context: PluginRuntimeContext) {
        startMonitoring()
        registerSleepWakeObservers()
        // Re-apply the persisted active preset so fan state is consistent
        // even after the app restarts. Skip if already "auto" to avoid
        // spurious admin prompts on launch.
        let preset = presetStore.activePreset
        if case .auto = preset.strategy { return }
        applyActivePreset()
    }

    func deactivate(reason: PluginDeactivationReason) {
        unregisterSleepWakeObservers()
        stopMonitoring()
        if reason.requiresStateCleanup {
            restoreAutomaticControlIfNeeded(reason: String(describing: reason))
        }
    }

    func refresh() {
        fanSnapshot = smcReader.readSnapshot()
        onStateChange?()
    }

    // MARK: - PluginPrimaryPanel

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: false,
            isExpanded: isExpanded,
            isEnabled: true,
            isVisible: true,
            detail: isExpanded ? buildDetail() : nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [self] _ in
            FanControlPresetManagerView(
                presetStore: self.presetStore,
                fanSnapshot: self.fanSnapshot,
                localization: self.localization
            )
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            guard isExpanded != expanded else { return }
            isExpanded = expanded
            if !expanded { lastErrorMessage = nil }
            restartMonitoringIfRunning()
            onStateChange?()

        case let .setSelection(controlID, optionID):
            guard controlID == ControlID.presetList else { return }
            guard presetStore.allPresets.contains(where: { $0.id == optionID }) else { return }
            presetStore.setActivePreset(id: optionID)
            lastErrorMessage = nil
            onStateChange?()
            applyActivePreset()

        case let .setSlider(controlID, value, phase):
            guard controlID == ControlID.customSlider, phase == .ended else { return }
            let rpm = Int(value)
            let activeID = presetStore.activePresetID
            presetStore.updateCustomPresetRPM(id: activeID, rpm: rpm)
            lastErrorMessage = nil
            onStateChange?()
            applyActivePreset()

        case let .invokeAction(controlID):
            handleInvokeAction(controlID)

        case .setSwitch, .setNavigationSelection, .clearNavigationSelection, .setDate:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    // MARK: - Actions

    private func handleInvokeAction(_ controlID: String) {
        switch controlID {
        case ControlID.addPreset:
            // Navigation to settings page is handled by MenuBarContent;
            // the host intercepts this action ID and calls
            // pluginHost.presentPluginConfiguration(pluginID: "fan-control").
            break

        case ControlID.deletePreset:
            let idToDelete = presetStore.activePresetID
            guard !presetStore.activePreset.isBuiltIn else { return }
            presetStore.deleteCustomPreset(id: idToDelete)
            lastErrorMessage = nil
            onStateChange?()
            // Active preset has been reset to auto by the store
            applyActivePreset()

        default:
            break
        }
    }

    private func applyActivePreset() {
        let preset = presetStore.activePreset
        let snapshot = fanSnapshot.fanCount > 0 ? fanSnapshot : smcReader.readSnapshot()
        let result = smcWriter.apply(strategy: preset.strategy, snapshot: snapshot)
        updateAutoRestoreRequirement(afterApplying: preset.strategy, result: result)
        if let err = result {
            lastErrorMessage = err.localizedDescription(localization: localization)
            FanControlLog.plugin.error("Apply preset failed: \(err.localizedDescription, privacy: .public)")
        } else {
            lastErrorMessage = nil
        }
        onStateChange?()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }

                let snapshot = self.smcReader.readSnapshot()
                if self.updateFanSnapshotIfNeeded(snapshot) {
                    self.onStateChange?()
                }
                try? await Task.sleep(for: self.currentMonitoringInterval)
            }
        }
    }

    private func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    private var currentMonitoringInterval: Duration {
        if isExpanded {
            return monitoringActiveInterval
        }
        return monitoringIdleInterval
    }

    private func updateFanSnapshotIfNeeded(_ snapshot: FanSnapshot) -> Bool {
        guard !fanSnapshot.isMeaningfullyEquivalent(to: snapshot) else {
            return false
        }

        fanSnapshot = snapshot
        return true
    }

    private func restartMonitoringIfRunning() {
        guard monitoringTask != nil else {
            return
        }

        stopMonitoring()
        startMonitoring()
    }

    private func registerSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemWillSleep() }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleSystemDidWake() }
        }
    }

    private func unregisterSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { center.removeObserver(obs) }
        if let obs = wakeObserver { center.removeObserver(obs) }
        sleepObserver = nil
        wakeObserver = nil
    }

    private func handleSystemWillSleep() {
        let preset = presetStore.activePreset
        guard case .auto = preset.strategy else {
            restoreAutomaticControlIfNeeded(reason: "system sleep")
            return
        }
    }

    private func handleSystemDidWake() {
        fanSnapshot = smcReader.readSnapshot()
        let preset = presetStore.activePreset
        if case .auto = preset.strategy { return }
        applyActivePreset()
        FanControlLog.plugin.info("System did wake — re-applied active preset: \(preset.name, privacy: .public)")
    }

    // MARK: - Panel Builder

    private var panelSubtitle: String {
        let preset = presetStore.activePreset
        if let rpm = fanSnapshot.averageSpeed, rpm > 0 {
            return localization.format(
                "panel.subtitle.withRPM",
                defaultValue: "%@ · %@",
                preset.displayName(localization: localization),
                "\(rpm) RPM"
            )
        }
        return preset.displayName(localization: localization)
    }

    private func buildDetail() -> PluginPanelDetail {
        var controls: [PluginPanelControl] = []

        // 1. Preset select list
        let presetOptions = presetStore.allPresets.map {
            PluginPanelControlOption(
                id: $0.id,
                title: $0.displayName(localization: localization),
                subtitle: presetSubtitle(for: $0)
            )
        }
        controls.append(PluginPanelControl(
            id: ControlID.presetList,
            kind: .selectList,
            options: presetOptions,
            selectedOptionID: presetStore.activePresetID,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            isEnabled: true
        ))

        // 2. Slider for the active custom preset
        let activePreset = presetStore.activePreset
        if case let .fixed(rpm) = activePreset.strategy, !activePreset.isBuiltIn {
            let maxSlider = Double(fanSnapshot.globalMaxSpeed > 0
                ? fanSnapshot.globalMaxSpeed
                : FanRPMLimits.fallbackMax)
            controls.append(PluginPanelControl(
                id: ControlID.customSlider,
                kind: .slider,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: localization.string("panel.slider.targetRPM", defaultValue: "目标转速"),
                sliderValue: Double(rpm),
                sliderBounds: Double(FanRPMLimits.absoluteMin)...maxSlider,
                sliderStep: 100,
                valueLabel: "\(rpm) RPM",
                isEnabled: true
            ))

            // 3. Delete button for custom preset
            controls.append(PluginPanelControl(
                id: ControlID.deletePreset,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: localization.string("panel.action.deletePreset", defaultValue: "删除此预设"),
                actionIconSystemName: "trash",
                isEnabled: true
            ))
        }

        // 4. Add custom preset → opens plugin settings page
        controls.append(PluginPanelControl(
            id: ControlID.addPreset,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string("panel.action.managePresets", defaultValue: "管理预设…"),
            actionIconSystemName: "slider.horizontal.3",
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: true,
            isEnabled: true
        ))

        // 5. Helper-not-found warning
        if !smcWriter.isHelperAvailable {
            controls.append(PluginPanelControl(
                id: ControlID.missingHelper,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: localization.string("panel.action.missingHelper", defaultValue: "风扇控制组件缺失"),
                actionIconSystemName: "exclamationmark.triangle",
                actionBehavior: .dismissBeforeHandling,
                showsLeadingDivider: true,
                isEnabled: false
            ))
        }

        return PluginPanelDetail(primaryControls: controls, secondaryPanel: nil)
    }

    private func presetSubtitle(for preset: FanPreset) -> String? {
        switch preset.strategy {
        case .auto:
            return localization.string("preset.auto.subtitle", defaultValue: "由 macOS 管理")
        case .fullSpeed:
            let maxRPM = fanSnapshot.globalMaxSpeed
            return maxRPM > 0
                ? localization.format("preset.fullSpeed.subtitleWithRPM", defaultValue: "最高 %d RPM", maxRPM)
                : localization.string("preset.fullSpeed.subtitle", defaultValue: "最高转速")
        case .fixed(let rpm):
            return "\(rpm) RPM"
        }
    }

    private func updateAutoRestoreRequirement(afterApplying strategy: FanControlStrategy, result: FanWriteError?) {
        switch strategy {
        case .auto:
            if result == nil {
                requiresAutoRestore = false
            }
        case .fullSpeed, .fixed:
            if result == nil || result?.mayHaveChangedFanState == true {
                requiresAutoRestore = true
            }
        }
    }

    private func restoreAutomaticControlIfNeeded(reason: String) {
        guard requiresAutoRestore else {
            FanControlLog.plugin.info("Skipped fan auto restore for \(reason, privacy: .public); no successful manual fan write in this session")
            return
        }

        guard smcWriter.isInstalledHelperAvailable else {
            FanControlLog.plugin.info("Skipped fan auto restore for \(reason, privacy: .public); SMC helper is not installed")
            return
        }

        let snapshot = fanSnapshot.fanCount > 0 ? fanSnapshot : smcReader.readSnapshot()
        let result = smcWriter.apply(strategy: .auto, snapshot: snapshot)
        updateAutoRestoreRequirement(afterApplying: .auto, result: result)

        if let result {
            FanControlLog.plugin.error("Failed to restore fan control to auto for \(reason, privacy: .public): \(result.localizedDescription, privacy: .public)")
        } else {
            FanControlLog.plugin.info("Restored fan control to auto for \(reason, privacy: .public)")
        }
    }
}

private extension FanWriteError {
    var mayHaveChangedFanState: Bool {
        if case .writeFailed = self {
            return true
        }

        return false
    }
}
