import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class KeepAwakePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        KeepAwakePluginProvider(context: context)
    }
}

@MainActor
private struct KeepAwakePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let helperURL = context.resourceBundle.resourceURL?
            .appendingPathComponent("VirtualDisplayHelper", isDirectory: true)
            .appendingPathComponent("mactools-keep-awake-virtual-display-helper")
        let virtualDisplayManager = KeepAwakeVirtualDisplayManager(
            helperURL: helperURL,
            localization: localization
        )
        let userActivityMaintainer = KeepAwakeUserActivityMaintainer(
            localization: localization
        )
        return [
            KeepAwakePlugin(
                localization: localization,
                virtualDisplayManager: virtualDisplayManager,
                userActivityMaintainer: userActivityMaintainer
            )
        ]
    }
}

@MainActor
final class KeepAwakePlugin:
    MacToolsPlugin,
    PluginPrimaryPanel,
    PluginPrimaryPanelCompactIndicatorProviding,
    PluginSettingsSearchProviding,
    DisplayTopologyRefreshing
{
    typealias SessionFactory = (
        PluginLocalization,
        @escaping (KeepAwakeSession.EndReason) -> Void
    ) -> any KeepAwakeSessionManaging

    private enum Timing {
        static let secondsPerMinute: TimeInterval = 60
    }

    private enum Symbol {
        static let screenTools = NSImage(
            systemSymbolName: "rectangle.and.hand.point.up.left",
            accessibilityDescription: nil
        ) == nil ? "display" : "rectangle.and.hand.point.up.left"
    }

    private enum StorageKey {
        static let persistentEnabled = "persistent-enabled"
        static let preferenceVersion = "behavior-preference-version"
        static let behavior = "display-behavior"

        enum Legacy {
            static let keepDisplayOn = "keep-display-on"
            static let preventAutomaticScreenLock = "prevent-automatic-screen-lock"
            static let awakeMode = "awake-mode"
            static let customPreventDisplaySleep = "custom-prevent-display-sleep"
            static let customPreventAutomaticScreenLock = "custom-prevent-automatic-screen-lock"
            static let customContinueWithLidClosed = "custom-continue-with-lid-closed"
            static let customKeepScreenBasedToolsWorking = "custom-keep-screen-based-tools-working"
            static let keepAwakeWithLidClosed = "keep-awake-with-lid-closed"
            static let keepDesktopAvailableWithLidClosed = "keep-desktop-available-with-lid-closed"
        }
    }

    private enum PreferenceVersion {
        static let current = 3
    }

    private struct PreferenceLoadResult {
        let preferences: KeepAwakePreferences
        let preservesFuturePayload: Bool
    }

    private enum ControlID {
        static let duration = "duration"
    }

    private enum VirtualDisplayIdentity {
        static let name = "MacTools Virtual Display"
        static let vendorNumber: UInt32 = 505
    }

    private enum DurationPreset: String {
        case forever
        case thirtyMinutes
        case oneHour
        case twoHours
        case fiveHours

        var timeInterval: TimeInterval? {
            switch self {
            case .forever:
                return nil
            case .thirtyMinutes:
                return 30 * 60
            case .oneHour:
                return 60 * 60
            case .twoHours:
                return 2 * 60 * 60
            case .fiveHours:
                return 5 * 60 * 60
            }
        }
    }

    private enum DurationOptionID {
        static let forever = DurationPreset.forever.rawValue
        static let thirtyMinutes = DurationPreset.thirtyMinutes.rawValue
        static let oneHour = DurationPreset.oneHour.rawValue
        static let twoHours = DurationPreset.twoHours.rawValue
        static let fiveHours = DurationPreset.fiveHours.rawValue
    }

    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "KeepAwakePlugin")
    private let localization: PluginLocalization
    private let sessionFactory: SessionFactory
    private let powerSourceMonitor: any KeepAwakePowerSourceMonitoring
    private let virtualDisplayManager: any KeepAwakeVirtualDisplayManaging
    private let userActivityMaintainer: any KeepAwakeUserActivityMaintaining
    private let displayProvider: any DisplayProviding
    private var storage: PluginStorage
    private var lastErrorMessage: String?
    private var session: (any KeepAwakeSessionManaging)?
    private var selectedDurationPreset: DurationPreset = .forever
    private var preferences: KeepAwakePreferences
    private var preservesFuturePreferencePayload: Bool
    private var powerSourceState: KeepAwakePowerSourceState
    private var hasActiveExternalDisplay: Bool
    private var virtualDisplayIsDesired = false
    private var virtualDisplayStartGeneration = 0
    private var virtualDisplayStartTask: Task<Void, Never>?
    private var isPreventingDisplaySleep = false
    private var scheduledEndDate: Date?
    private var timedStateRefreshTimer: Timer?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "keep-awake"),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        powerSourceMonitor: (any KeepAwakePowerSourceMonitoring)? = nil,
        virtualDisplayManager: (any KeepAwakeVirtualDisplayManaging)? = nil,
        userActivityMaintainer: (any KeepAwakeUserActivityMaintaining)? = nil,
        displayProvider: any DisplayProviding = SystemDisplayService(),
        sessionFactory: @escaping SessionFactory = { localization, onEnd in
            KeepAwakeSession(localization: localization, onEnd: onEnd)
        }
    ) {
        let resolvedPowerSourceMonitor = powerSourceMonitor ?? KeepAwakePowerSourceMonitor()
        self.localization = localization
        self.storage = context.storage
        self.sessionFactory = sessionFactory
        self.powerSourceMonitor = resolvedPowerSourceMonitor
        self.displayProvider = displayProvider
        self.virtualDisplayManager = virtualDisplayManager ?? KeepAwakeVirtualDisplayManager(
            helperURL: nil,
            localization: localization
        )
        self.userActivityMaintainer = userActivityMaintainer
            ?? KeepAwakeUserActivityMaintainer(localization: localization)
        self.powerSourceState = resolvedPowerSourceMonitor.currentState
        self.hasActiveExternalDisplay = Self.detectActiveExternalDisplay(
            using: displayProvider
        )
        let preferenceLoadResult = Self.loadPreferences(from: context.storage)
        self.preferences = preferenceLoadResult.preferences
        self.preservesFuturePreferencePayload = preferenceLoadResult.preservesFuturePayload
        self.metadata = PluginMetadata(
            id: "keep-awake",
            title: localization.string("metadata.title", defaultValue: "阻止休眠"),
            iconName: "moon",
            iconTint: Color(nsColor: .systemOrange),
            order: 50,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "保持 Mac 唤醒；可选保持屏幕常亮或让屏幕工具继续工作。MacBook 合盖运行要求连接电源"
            )
        )

        resolvedPowerSourceMonitor.onChange = { [weak self] state in
            self?.handlePowerSourceChange(state)
        }
        self.virtualDisplayManager.onUnexpectedTermination = { [weak self] in
            self?.handleVirtualDisplayTermination()
        }
        self.userActivityMaintainer.onFailure = { [weak self] error in
            self?.handleUserActivityFailure(error)
        }
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: session != nil,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: panelDetail,
            errorMessage: lastErrorMessage
        )
    }

    var primaryPanelCompactIndicator: PluginPrimaryPanelCompactIndicator? {
        guard session != nil else {
            return nil
        }

        let icon: PluginPrimaryPanelIndicatorIcon
        switch preferences.behavior {
        case .keepScreenBasedToolsWorking:
            icon = PluginPrimaryPanelIndicatorIcon(
                systemImage: Symbol.screenTools,
                label: localization.string(
                    "panel.screenTools.indicator",
                    defaultValue: "屏幕工具"
                ),
                accessibilityLabel: localization.string(
                    "settings.mode.screenTools.title",
                    defaultValue: "让屏幕工具继续工作"
                )
            )
        case .keepDisplayOn:
            icon = PluginPrimaryPanelIndicatorIcon(
                systemImage: "display",
                label: localization.string(
                    "panel.display.indicator",
                    defaultValue: "屏幕常亮"
                ),
                accessibilityLabel: localization.string(
                    "settings.display.keepOn",
                    defaultValue: "保持常亮"
                )
            )
        case .allowDisplayToTurnOff:
            return nil
        }

        return PluginPrimaryPanelCompactIndicator(icons: [icon])
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }

    var settingsSections: [PluginSettingsSection] { [] }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsSearchEntries: [PluginSettingsSearchEntry] {
        [
            PluginSettingsSearchEntry(
                id: KeepAwakeSettingsSearchEntryID.behavior,
                title: localization.string(
                    "settings.mode.section",
                    defaultValue: "行为"
                ),
                description: localization.string(
                    "settings.mode.search.description",
                    defaultValue: "选择阻止休眠运行时保持可用的内容。"
                ),
                keywords: [
                    localization.string(
                        "settings.mode.keepMacAwake.title",
                        defaultValue: "允许屏幕关闭"
                    ),
                    localization.string(
                        "settings.display.keepOn",
                        defaultValue: "保持常亮"
                    ),
                    localization.string(
                        "settings.virtualDisplay.keepDesktopAvailable",
                        defaultValue: "让屏幕相关工具继续工作"
                    ),
                    localization.string(
                        "settings.lidClose.keepAwake",
                        defaultValue: "合盖保持唤醒"
                    ),
                ],
                systemImage: "slider.horizontal.3"
            )
        ]
    }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [weak self, localization] _ in
            KeepAwakeSettingsView(
                behavior: Binding(
                    get: { self?.preferences.behavior ?? .allowDisplayToTurnOff },
                    set: { [weak self] in self?.setBehavior($0) }
                ),
                isVirtualDisplayAvailable: self?.virtualDisplayManager.isAvailable ?? false,
                powerSourceState: self?.powerSourceState ?? KeepAwakePowerSourceState(
                    isPortableMac: false,
                    isOnExternalPower: false
                ),
                localization: localization
            )
        }
    }

    func activate(context: PluginRuntimeContext) {
        storage = context.storage
        powerSourceMonitor.start()
        powerSourceState = powerSourceMonitor.currentState
        hasActiveExternalDisplay = Self.detectActiveExternalDisplay(using: displayProvider)
        let preferenceLoadResult = Self.loadPreferences(from: storage)
        preferences = preferenceLoadResult.preferences
        preservesFuturePreferencePayload = preferenceLoadResult.preservesFuturePayload

        guard storage.bool(forKey: StorageKey.persistentEnabled) else {
            return
        }

        selectedDurationPreset = .forever
        scheduledEndDate = nil
        applyKeepAwakeConfiguration()
    }

    func refresh() {
        scheduleTimedStateRefreshIfNeeded()
    }

    func deactivate(reason: PluginDeactivationReason) {
        powerSourceMonitor.stop()
        userActivityMaintainer.stop()
        cancelVirtualDisplayStart()
        virtualDisplayManager.stop()
        guard reason.requiresStateCleanup else { return }
        session?.requestStop(reason: .userRequested)
    }

    func refreshDisplayTopology() {
        let hasExternalDisplay = Self.detectActiveExternalDisplay(using: displayProvider)
        guard hasExternalDisplay != hasActiveExternalDisplay else {
            return
        }

        hasActiveExternalDisplay = hasExternalDisplay
        reconcileVirtualDisplay()
        notifyChange()
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setSwitch(isEnabled):
            setKeepAwakeEnabled(isEnabled)
        case .setDisclosureExpanded, .setNavigationSelection, .clearNavigationSelection:
            return
        case let .setSelection(controlID, optionID):
            guard controlID == ControlID.duration else {
                return
            }
            updateDurationPreset(using: optionID)
        case .setDate, .setSlider, .invokeAction:
            return
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}

    func handleSettingsAction(id: String) {}

    func handleShortcutAction(id: String) {}

    private var panelSubtitle: String {
        guard session != nil else {
            return metadata.defaultDescription
        }

        if closedLidOperationIsWaitingForPower {
            return localization.string(
                "panel.subtitle.closedLidWaitingForPower",
                defaultValue: "合盖运行已暂停 · 正在等待电源"
            )
        }

        if let scheduledEndDate {
            let referenceDate = Date()
            let remaining = remainingTimeDescription(
                until: scheduledEndDate,
                referenceDate: referenceDate
            )
            let stopAt = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
                until: scheduledEndDate,
                referenceDate: referenceDate,
                localization: localization
            )
            return localization.format(
                "panel.subtitle.timedFormat",
                defaultValue: "%@ · %@",
                remaining,
                stopAt
            )
        }

        return localization.string(
            "panel.duration.noAutomaticStop",
            defaultValue: "不会自动停止"
        )
    }

    private var panelDetail: PluginPanelDetail? {
        guard session != nil else {
            return nil
        }

        return PluginPanelDetail(
            primaryControls: [
                PluginPanelControl(
                    id: ControlID.duration,
                    kind: .segmented,
                    options: [
                        PluginPanelControlOption(
                            id: DurationOptionID.forever,
                            title: localization.string("panel.duration.forever", defaultValue: "永不")
                        ),
                        PluginPanelControlOption(id: DurationOptionID.thirtyMinutes, title: "30min"),
                        PluginPanelControlOption(id: DurationOptionID.oneHour, title: "1h"),
                        PluginPanelControlOption(id: DurationOptionID.twoHours, title: "2h"),
                        PluginPanelControlOption(id: DurationOptionID.fiveHours, title: "5h")
                    ],
                    selectedOptionID: selectedDurationPreset.rawValue,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: nil,
                    isEnabled: true
                )
            ],
            secondaryPanel: nil
        )
    }

    private func setKeepAwakeEnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            lastErrorMessage = nil
            clearPersistentEnabled()
            session?.requestStop(reason: .userRequested)

            if session == nil {
                resetSelectionToDefaults()
                notifyChange()
            }

            return
        }

        selectedDurationPreset = .forever
        lastErrorMessage = nil
        applyKeepAwakeConfiguration()
    }

    private func updateDurationPreset(using optionID: String) {
        guard let preset = DurationPreset(rawValue: optionID) else {
            return
        }

        selectedDurationPreset = preset
        lastErrorMessage = nil
        persistCurrentSelectionIfRunning()

        guard session != nil else {
            notifyChange()
            return
        }

        applyKeepAwakeConfiguration()
    }

    func setBehavior(_ behavior: KeepAwakeBehavior) {
        guard preferences.behavior != behavior else {
            return
        }

        lastErrorMessage = nil
        let previousPreferences = preferences
        preferences.behavior = behavior

        guard session != nil else {
            preservesFuturePreferencePayload = false
            persistPreferences()
            notifyChange()
            return
        }

        do {
            try reconcileRuntimeConfiguration()
            preservesFuturePreferencePayload = false
            persistPreferences()
            notifyChange()
        } catch {
            preferences = previousPreferences
            try? reconcileRuntimeConfiguration()
            logger.error("keep-awake behavior update failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            notifyChange()
        }
    }

    private func applyKeepAwakeConfiguration() {
        let hadRunningSession = session != nil
        let session = session ?? sessionFactory(localization) { [weak self] reason in
            self?.handleSessionEnd(reason)
        }
        let endDate = resolvedScheduledEndDate(referenceDate: Date())
        let capabilities = activeCapabilities
        let shouldPreventLidCloseSleep = capabilities.continueWithLidClosed
            && powerSourceState.canPreventLidCloseSleep
        let shouldPreventDisplaySleep = displaySleepPreventionShouldRun(
            capabilities: capabilities
        )

        do {
            try session.start(
                until: endDate,
                preventDisplaySleep: hadRunningSession ? shouldPreventDisplaySleep : false,
                preventLidCloseSleep: hadRunningSession ? shouldPreventLidCloseSleep : false
            )
            self.session = session
            isPreventingDisplaySleep = session.isPreventingDisplaySleep
            scheduledEndDate = endDate
            persistCurrentSelectionIfRunning()
            scheduleTimedStateRefreshIfNeeded()
            lastErrorMessage = nil
            do {
                try reconcileRuntimeConfiguration()
            } catch {
                handleRuntimeConfigurationFailure(error)
            }
            notifyChange()
        } catch {
            logger.error("keep-awake session update failed: \(error.localizedDescription, privacy: .public)")
            if !hadRunningSession {
                userActivityMaintainer.stop()
                cancelVirtualDisplayStart()
                virtualDisplayManager.stop()
            }
            lastErrorMessage = error.localizedDescription
            notifyChange()
        }
    }

    private var virtualDisplayShouldBePrepared: Bool {
        let capabilities = activeCapabilities
        return capabilities.keepScreenBasedToolsWorking
            && capabilities.continueWithLidClosed
            && powerSourceState.canRunVirtualDisplay
            && !hasActiveExternalDisplay
    }

    private var virtualDisplayShouldRun: Bool {
        session != nil && virtualDisplayShouldBePrepared
    }

    private var closedLidScreenServicesCanRun: Bool {
        return !powerSourceState.isPortableMac
            || !powerSourceState.isLidClosed
            || powerSourceState.isOnExternalPower
    }

    private var activeCapabilities: KeepAwakeCapabilities {
        preferences.capabilities
    }

    private func displaySleepPreventionShouldRun(
        capabilities: KeepAwakeCapabilities
    ) -> Bool {
        closedLidScreenServicesCanRun
            && (capabilities.preventDisplaySleep || virtualDisplayShouldBePrepared)
    }

    private func automaticLockPreventionShouldRun(
        capabilities: KeepAwakeCapabilities
    ) -> Bool {
        closedLidScreenServicesCanRun
            && capabilities.preventAutomaticScreenLock
    }

    private var closedLidOperationIsWaitingForPower: Bool {
        session != nil
            && activeCapabilities.continueWithLidClosed
            && powerSourceState.isPortableMac
            && powerSourceState.isLidClosed
            && !powerSourceState.isOnExternalPower
    }

    private func reconcileRuntimeConfiguration() throws {
        guard let session else {
            userActivityMaintainer.stop()
            stopVirtualDisplayIfNeeded()
            return
        }

        let capabilities = activeCapabilities
        do {
            try session.setPreventLidCloseSleep(
                capabilities.continueWithLidClosed
                    && powerSourceState.canPreventLidCloseSleep
            )
        } catch {
            throw KeepAwakeRuntimeServiceError.lidClose(error)
        }

        do {
            try updateDisplaySleepAssertion(
                displaySleepPreventionShouldRun(capabilities: capabilities),
                session: session
            )
        } catch {
            throw KeepAwakeRuntimeServiceError.display(error)
        }

        guard automaticLockPreventionShouldRun(capabilities: capabilities) else {
            userActivityMaintainer.stop()
            reconcileVirtualDisplay()
            return
        }

        do {
            try userActivityMaintainer.start()
        } catch {
            throw KeepAwakeRuntimeServiceError.userActivity(error)
        }
        reconcileVirtualDisplay()
    }

    private func reconcileVirtualDisplay() {
        guard virtualDisplayShouldRun else {
            stopVirtualDisplayIfNeeded()
            return
        }

        guard !virtualDisplayIsDesired
                || (!virtualDisplayManager.isActive && virtualDisplayStartTask == nil)
        else {
            return
        }

        virtualDisplayIsDesired = true
        cancelVirtualDisplayStart()

        guard let session else {
            return
        }

        do {
            try updateDisplaySleepAssertion(true, session: session)
        } catch {
            failVirtualDisplayStart(error)
            return
        }

        let generation = virtualDisplayStartGeneration
        virtualDisplayStartTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.virtualDisplayManager.start()
                try Task.checkCancellation()

                guard generation == self.virtualDisplayStartGeneration,
                      self.virtualDisplayIsDesired,
                      self.virtualDisplayShouldRun
                else {
                    self.virtualDisplayManager.stop()
                    return
                }

                self.virtualDisplayStartTask = nil
                self.notifyChange()
            } catch is CancellationError {
                guard generation == self.virtualDisplayStartGeneration else {
                    return
                }
                self.virtualDisplayStartTask = nil
            } catch {
                guard generation == self.virtualDisplayStartGeneration,
                      self.virtualDisplayIsDesired
                else {
                    return
                }
                self.virtualDisplayStartTask = nil
                self.failVirtualDisplayStart(error)
            }
        }
    }

    private func stopVirtualDisplayIfNeeded() {
        guard virtualDisplayIsDesired
                || virtualDisplayStartTask != nil
                || virtualDisplayManager.isActive
        else {
            return
        }

        virtualDisplayIsDesired = false
        cancelVirtualDisplayStart()
        virtualDisplayManager.stop()
    }

    private func failVirtualDisplayStart(_ error: Error) {
        logger.error(
            "software display start failed: \(error.localizedDescription, privacy: .public)"
        )
        preferences.behavior = .keepDisplayOn
        persistPreferences()
        userActivityMaintainer.stop()
        virtualDisplayIsDesired = false
        cancelVirtualDisplayStart()
        virtualDisplayManager.stop()

        try? reconcileRuntimeConfiguration()
        lastErrorMessage = error.localizedDescription
        notifyChange()
    }

    private func handleRuntimeConfigurationFailure(_ error: Error) {
        if let runtimeError = error as? KeepAwakeRuntimeServiceError {
            switch runtimeError {
            case .lidClose:
                preferences.behavior = .keepDisplayOn
            case .display:
                preferences.behavior = .allowDisplayToTurnOff
            case .userActivity:
                preferences.behavior = .keepDisplayOn
            }
        }

        persistPreferences()
        userActivityMaintainer.stop()
        stopVirtualDisplayIfNeeded()
        try? reconcileRuntimeConfiguration()
        lastErrorMessage = error.localizedDescription
        notifyChange()
    }

    private func cancelVirtualDisplayStart() {
        virtualDisplayStartGeneration += 1
        virtualDisplayStartTask?.cancel()
        virtualDisplayStartTask = nil
    }

    private func updateDisplaySleepAssertion(
        _ shouldPreventDisplaySleep: Bool,
        session: any KeepAwakeSessionManaging
    ) throws {
        guard isPreventingDisplaySleep != shouldPreventDisplaySleep else {
            return
        }

        try session.setPreventDisplaySleep(shouldPreventDisplaySleep)
        isPreventingDisplaySleep = shouldPreventDisplaySleep
    }

    private static func detectActiveExternalDisplay(
        using displayProvider: any DisplayProviding
    ) -> Bool {
        displayProvider.listConnectedDisplays().contains { display in
            guard !display.isBuiltin else {
                return false
            }

            return display.name != VirtualDisplayIdentity.name
                || display.vendorNumber != VirtualDisplayIdentity.vendorNumber
        }
    }

    private func resolvedScheduledEndDate(referenceDate: Date) -> Date? {
        selectedDurationPreset.timeInterval.map(referenceDate.addingTimeInterval)
    }

    private func remainingTimeDescription(
        until endDate: Date,
        referenceDate: Date
    ) -> String {
        let remainingDuration = max(endDate.timeIntervalSince(referenceDate), 0)
        let remainingMinutes = max(
            Int(ceil(remainingDuration / Timing.secondsPerMinute)),
            1
        )

        let hours = remainingMinutes / 60
        let minutes = remainingMinutes % 60

        if hours == 0 {
            return localization.format(
                "panel.duration.remainingMinutesFormat",
                defaultValue: "剩余 %d 分钟",
                remainingMinutes
            )
        }

        if minutes == 0 {
            return localization.format(
                "panel.duration.remainingHoursFormat",
                defaultValue: "剩余 %d 小时",
                hours
            )
        }

        return localization.format(
            "panel.duration.remainingHoursMinutesFormat",
            defaultValue: "剩余 %d 小时 %d 分钟",
            hours,
            minutes
        )
    }

    private func scheduleTimedStateRefreshIfNeeded() {
        invalidateTimedStateRefreshTimer()

        guard session != nil, let scheduledEndDate else {
            return
        }

        let remainingDuration = scheduledEndDate.timeIntervalSinceNow

        guard remainingDuration > 0 else {
            return
        }

        let remainder = remainingDuration.truncatingRemainder(dividingBy: Timing.secondsPerMinute)
        let nextRefreshInterval = remainder > 0 ? remainder : Timing.secondsPerMinute

        let timer = Timer(
            timeInterval: nextRefreshInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTimedStateRefreshTimerFired()
            }
        }
        timer.tolerance = min(1, nextRefreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        timedStateRefreshTimer = timer
    }

    private func handleTimedStateRefreshTimerFired() {
        guard session != nil, scheduledEndDate != nil else {
            invalidateTimedStateRefreshTimer()
            return
        }

        notifyChange()
        scheduleTimedStateRefreshIfNeeded()
    }

    private func invalidateTimedStateRefreshTimer() {
        timedStateRefreshTimer?.invalidate()
        timedStateRefreshTimer = nil
    }

    private func handleSessionEnd(_ reason: KeepAwakeSession.EndReason) {
        session = nil
        isPreventingDisplaySleep = false
        userActivityMaintainer.stop()
        virtualDisplayIsDesired = false
        cancelVirtualDisplayStart()
        virtualDisplayManager.stop()
        resetSelectionToDefaults()

        switch reason {
        case .userRequested, .completed:
            lastErrorMessage = nil
        }

        notifyChange()
    }

    private func persistCurrentSelectionIfRunning() {
        guard session != nil, selectedDurationPreset == .forever else {
            clearPersistentEnabled()
            return
        }

        storage.set(true, forKey: StorageKey.persistentEnabled)
    }

    private func clearPersistentEnabled() {
        storage.removeObject(forKey: StorageKey.persistentEnabled)
    }

    private func persistPreferences() {
        guard !preservesFuturePreferencePayload else {
            return
        }
        Self.persist(preferences, to: storage)
    }

    private static func loadPreferences(from storage: PluginStorage) -> PreferenceLoadResult {
        let storedVersion = storage.integer(forKey: StorageKey.preferenceVersion)
        let storedBehavior = storage.string(forKey: StorageKey.behavior)
            .flatMap(KeepAwakeBehavior.init(rawValue:))

        if storedVersion > PreferenceVersion.current {
            return PreferenceLoadResult(
                preferences: KeepAwakePreferences(
                    behavior: storedBehavior ?? .allowDisplayToTurnOff
                ),
                preservesFuturePayload: true
            )
        }

        if storedVersion == PreferenceVersion.current,
           let storedBehavior {
            let behavior = storedBehavior
            let preferences = KeepAwakePreferences(behavior: behavior)
            removeLegacyPreferences(from: storage)
            return PreferenceLoadResult(
                preferences: preferences,
                preservesFuturePayload: false
            )
        }

        let behavior: KeepAwakeBehavior
        if let storedBehavior {
            // The replacement payload is written before the version marker. If
            // the process stopped between those writes, finish that migration.
            behavior = storedBehavior
        } else if storedVersion == 2 {
            behavior = migratedBehavior(
                keepDisplayOn: storage.bool(forKey: StorageKey.Legacy.keepDisplayOn),
                keepScreenBasedToolsWorking: storage.bool(
                    forKey: StorageKey.Legacy.preventAutomaticScreenLock
                )
            )
        } else {
            var keepDisplayOn = storage.bool(forKey: StorageKey.Legacy.keepDisplayOn)
                || storage.bool(forKey: StorageKey.Legacy.customPreventDisplaySleep)
            var keepScreenBasedToolsWorking = storage.bool(
                forKey: StorageKey.Legacy.preventAutomaticScreenLock
            )
                || storage.bool(forKey: StorageKey.Legacy.customPreventAutomaticScreenLock)
                || storage.bool(forKey: StorageKey.Legacy.customContinueWithLidClosed)
                || storage.bool(forKey: StorageKey.Legacy.customKeepScreenBasedToolsWorking)
                || storage.bool(forKey: StorageKey.Legacy.keepAwakeWithLidClosed)
                || storage.bool(forKey: StorageKey.Legacy.keepDesktopAvailableWithLidClosed)

            switch storage.string(forKey: StorageKey.Legacy.awakeMode) {
            case "keep-mac-awake":
                keepDisplayOn = false
                keepScreenBasedToolsWorking = false
            case "screen-based-tools":
                keepDisplayOn = true
                keepScreenBasedToolsWorking = true
            default:
                break
            }

            behavior = migratedBehavior(
                keepDisplayOn: keepDisplayOn,
                keepScreenBasedToolsWorking: keepScreenBasedToolsWorking
            )
        }

        let preferences = KeepAwakePreferences(behavior: behavior)

        // Write the complete replacement before deleting any legacy values so a
        // partially completed migration never loses the user's configuration.
        persist(preferences, to: storage)
        removeLegacyPreferences(from: storage)
        return PreferenceLoadResult(
            preferences: preferences,
            preservesFuturePayload: false
        )
    }

    private static func persist(
        _ preferences: KeepAwakePreferences,
        to storage: PluginStorage
    ) {
        storage.set(preferences.behavior.rawValue, forKey: StorageKey.behavior)
        storage.set(PreferenceVersion.current, forKey: StorageKey.preferenceVersion)
    }

    private static func removeLegacyPreferences(from storage: PluginStorage) {
        storage.removeObject(forKey: StorageKey.Legacy.keepDisplayOn)
        storage.removeObject(forKey: StorageKey.Legacy.preventAutomaticScreenLock)
        storage.removeObject(forKey: StorageKey.Legacy.awakeMode)
        storage.removeObject(forKey: StorageKey.Legacy.customPreventDisplaySleep)
        storage.removeObject(forKey: StorageKey.Legacy.customPreventAutomaticScreenLock)
        storage.removeObject(forKey: StorageKey.Legacy.customContinueWithLidClosed)
        storage.removeObject(forKey: StorageKey.Legacy.customKeepScreenBasedToolsWorking)
        storage.removeObject(forKey: StorageKey.Legacy.keepAwakeWithLidClosed)
        storage.removeObject(forKey: StorageKey.Legacy.keepDesktopAvailableWithLidClosed)
    }

    private static func migratedBehavior(
        keepDisplayOn: Bool,
        keepScreenBasedToolsWorking: Bool
    ) -> KeepAwakeBehavior {
        if keepScreenBasedToolsWorking {
            return .keepScreenBasedToolsWorking
        }
        if keepDisplayOn {
            return .keepDisplayOn
        }
        return .allowDisplayToTurnOff
    }

    private func handlePowerSourceChange(_ state: KeepAwakePowerSourceState) {
        guard state != powerSourceState else {
            return
        }

        powerSourceState = state

        guard session != nil else {
            reconcileVirtualDisplay()
            notifyChange()
            return
        }

        do {
            lastErrorMessage = nil
            try reconcileRuntimeConfiguration()
            notifyChange()
        } catch {
            logger.error("failed to reconcile keep-awake preferences after power change: \(error.localizedDescription, privacy: .public)")
            handleRuntimeConfigurationFailure(error)
        }
    }

    private func handleVirtualDisplayTermination() {
        guard activeCapabilities.keepScreenBasedToolsWorking else {
            return
        }

        let error = KeepAwakeRuntimeError(
            message: localization.string(
                "error.virtualDisplay.terminated",
                defaultValue: "软件显示器已停止；已切换为保持屏幕常亮。"
            )
        )
        preferences.behavior = .keepDisplayOn
        persistPreferences()
        try? reconcileRuntimeConfiguration()
        lastErrorMessage = error.localizedDescription
        notifyChange()
    }

    private func handleUserActivityFailure(_ error: Error) {
        guard activeCapabilities.preventAutomaticScreenLock else {
            return
        }

        logger.error(
            "automatic screen-lock prevention failed: \(error.localizedDescription, privacy: .public)"
        )
        preferences.behavior = .keepDisplayOn
        persistPreferences()
        try? reconcileRuntimeConfiguration()
        lastErrorMessage = error.localizedDescription
        notifyChange()
    }

    private func resetSelectionToDefaults() {
        selectedDurationPreset = .forever
        scheduledEndDate = nil
        invalidateTimedStateRefreshTimer()
    }

    private func notifyChange() {
        onStateChange?()
    }
}

private struct KeepAwakeRuntimeError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private enum KeepAwakeRuntimeServiceError: LocalizedError {
    case lidClose(Error)
    case display(Error)
    case userActivity(Error)

    var errorDescription: String? {
        switch self {
        case let .lidClose(error), let .display(error), let .userActivity(error):
            return error.localizedDescription
        }
    }
}

/// Formats the scheduled stop moment for Keep Awake subtitles.
enum KeepAwakeStopScheduleFormatting {
    static func absoluteStopLabel(
        until endDate: Date,
        referenceDate: Date,
        calendar: Calendar = .current,
        localization: PluginLocalization,
        locale: Locale = .current
    ) -> String {
        let timeZone = calendar.timeZone
        let timeText = timeString(from: endDate, locale: locale, timeZone: timeZone)

        if calendar.isDate(endDate, inSameDayAs: referenceDate) {
            return timeText
        }

        if let tomorrowStart = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: referenceDate)
        ), calendar.isDate(endDate, inSameDayAs: tomorrowStart) {
            return localization.format(
                "panel.subtitle.stopTomorrowAtTimeFormat",
                defaultValue: "明天 %@",
                timeText
            )
        }

        let dateText = dateString(
            from: endDate,
            referenceDate: referenceDate,
            calendar: calendar,
            locale: locale,
            timeZone: timeZone
        )
        return localization.format(
            "panel.subtitle.stopAtDateTimeFormat",
            defaultValue: "%@ %@",
            dateText,
            timeText
        )
    }

    private static func timeString(from date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        // Follow the user's locale and preferred 12/24-hour clock while keeping minutes explicit.
        if let format = DateFormatter.dateFormat(fromTemplate: "jm", options: 0, locale: locale) {
            formatter.dateFormat = format
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        }
        return formatter.string(from: date)
    }

    private static func dateString(
        from date: Date,
        referenceDate: Date,
        calendar: Calendar,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: referenceDate)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }
}
