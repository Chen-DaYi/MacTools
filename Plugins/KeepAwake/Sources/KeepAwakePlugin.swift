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
        [KeepAwakePlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class KeepAwakePlugin:
    MacToolsPlugin,
    PluginPrimaryPanel,
    PluginPrimaryPanelCompactIndicatorProviding,
    PluginSettingsSearchProviding
{
    typealias SessionFactory = (
        PluginLocalization,
        @escaping (KeepAwakeSession.EndReason) -> Void
    ) -> any KeepAwakeSessionManaging

    private enum Timing {
        static let secondsPerMinute: TimeInterval = 60
    }

    private enum Symbol {
        static let closedLid = NSImage(
            systemSymbolName: "laptopcomputer.and.arrow.down",
            accessibilityDescription: nil
        ) == nil ? "laptopcomputer" : "laptopcomputer.and.arrow.down"
    }

    private enum StorageKey {
        static let persistentEnabled = "persistent-enabled"
        static let keepDisplayOn = "keep-display-on"
        static let keepAwakeWithLidClosed = "keep-awake-with-lid-closed"
    }

    private enum ControlID {
        static let duration = "duration"
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
    private var storage: PluginStorage
    private var lastErrorMessage: String?
    private var session: (any KeepAwakeSessionManaging)?
    private var selectedDurationPreset: DurationPreset = .forever
    private var keepDisplayOn = false
    private var keepAwakeWithLidClosed = false
    private var powerSourceState: KeepAwakePowerSourceState
    private var scheduledEndDate: Date?
    private var timedStateRefreshTimer: Timer?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "keep-awake"),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        powerSourceMonitor: (any KeepAwakePowerSourceMonitoring)? = nil,
        sessionFactory: @escaping SessionFactory = { localization, onEnd in
            KeepAwakeSession(localization: localization, onEnd: onEnd)
        }
    ) {
        let resolvedPowerSourceMonitor = powerSourceMonitor ?? KeepAwakePowerSourceMonitor()
        self.localization = localization
        self.storage = context.storage
        self.sessionFactory = sessionFactory
        self.powerSourceMonitor = resolvedPowerSourceMonitor
        self.powerSourceState = resolvedPowerSourceMonitor.currentState
        self.keepDisplayOn = context.storage.bool(forKey: StorageKey.keepDisplayOn)
        self.keepAwakeWithLidClosed =
            resolvedPowerSourceMonitor.currentState.isPortableMac
            && context.storage.bool(forKey: StorageKey.keepAwakeWithLidClosed)
        self.metadata = PluginMetadata(
            id: "keep-awake",
            title: localization.string("metadata.title", defaultValue: "阻止休眠"),
            iconName: "moon",
            iconTint: Color(nsColor: .systemOrange),
            order: 50,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "阻止系统空闲休眠；可选保持屏幕常亮，或接通电源时合盖运行"
            )
        )

        resolvedPowerSourceMonitor.onChange = { [weak self] state in
            self?.handlePowerSourceChange(state)
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

        let isClosedLidModeActive =
            keepAwakeWithLidClosed
            && powerSourceState.canPreventLidCloseSleep

        var icons: [PluginPrimaryPanelIndicatorIcon] = []

        if keepDisplayOn {
            icons.append(
                PluginPrimaryPanelIndicatorIcon(
                    systemImage: "display",
                    label: localization.string(
                        "panel.display.indicator",
                        defaultValue: "屏幕"
                    ),
                    accessibilityLabel: localization.string(
                        "settings.display.keepOn",
                        defaultValue: "保持屏幕常亮"
                    )
                )
            )
        }

        if isClosedLidModeActive {
            icons.append(
                PluginPrimaryPanelIndicatorIcon(
                    systemImage: Symbol.closedLid,
                    label: localization.string(
                        "panel.lidClose.indicator",
                        defaultValue: "合盖"
                    ),
                    accessibilityLabel: localization.string(
                        "settings.lidClose.keepAwake",
                        defaultValue: "合盖保持唤醒"
                    )
                )
            )
        }

        return icons.isEmpty ? nil : PluginPrimaryPanelCompactIndicator(icons: icons)
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }

    var settingsSections: [PluginSettingsSection] { [] }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsSearchEntries: [PluginSettingsSearchEntry] {
        var entries = [
            PluginSettingsSearchEntry(
                id: KeepAwakeSettingsSearchEntryID.keepDisplayOn,
                title: localization.string(
                    "settings.display.keepOn",
                    defaultValue: "保持屏幕常亮"
                ),
                description: localization.string(
                    "settings.display.keepOn.description",
                    defaultValue: "阻止休眠运行时，防止屏幕因空闲而关闭。"
                ),
                keywords: [
                    localization.string("settings.display.section", defaultValue: "屏幕")
                ],
                systemImage: "display"
            )
        ]

        if powerSourceState.isPortableMac {
            entries.append(
                PluginSettingsSearchEntry(
                    id: KeepAwakeSettingsSearchEntryID.keepAwakeWithLidClosed,
                    title: localization.string(
                        "settings.lidClose.keepAwake",
                        defaultValue: "合盖保持唤醒"
                    ),
                    description: localization.string(
                        "settings.lidClose.keepAwake.description",
                        defaultValue: "使用电池时暂停，重新接通电源后恢复。"
                    ),
                    keywords: [
                        localization.string(
                            "settings.lidClose.section",
                            defaultValue: "MacBook"
                        )
                    ],
                    systemImage: "laptopcomputer"
                )
            )
        }

        return entries
    }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [weak self, localization] _ in
            KeepAwakeSettingsView(
                keepDisplayOn: Binding(
                    get: { self?.keepDisplayOn ?? false },
                    set: { [weak self] in self?.setKeepDisplayOn($0) }
                ),
                keepAwakeWithLidClosed: Binding(
                    get: { self?.keepAwakeWithLidClosed ?? false },
                    set: { [weak self] in self?.setKeepAwakeWithLidClosed($0) }
                ),
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
        keepDisplayOn = storage.bool(forKey: StorageKey.keepDisplayOn)
        let storedKeepAwakeWithLidClosed = storage.bool(
            forKey: StorageKey.keepAwakeWithLidClosed
        )
        keepAwakeWithLidClosed =
            storedKeepAwakeWithLidClosed
            && powerSourceState.isPortableMac
        if storedKeepAwakeWithLidClosed, !keepAwakeWithLidClosed {
            storage.removeObject(forKey: StorageKey.keepAwakeWithLidClosed)
        }

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
        guard reason.requiresStateCleanup else { return }
        session?.requestStop(reason: .userRequested)
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

    func setKeepDisplayOn(_ shouldKeepDisplayOn: Bool) {
        guard keepDisplayOn != shouldKeepDisplayOn else {
            return
        }

        lastErrorMessage = nil

        guard let session else {
            keepDisplayOn = shouldKeepDisplayOn
            persistKeepDisplayOnPreference()
            notifyChange()
            return
        }

        do {
            try session.setPreventDisplaySleep(shouldKeepDisplayOn)
            keepDisplayOn = shouldKeepDisplayOn
            persistKeepDisplayOnPreference()
            notifyChange()
        } catch {
            logger.error("keep-awake display update failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            notifyChange()
        }
    }

    func setKeepAwakeWithLidClosed(_ shouldKeepAwakeWithLidClosed: Bool) {
        guard keepAwakeWithLidClosed != shouldKeepAwakeWithLidClosed else {
            return
        }

        lastErrorMessage = nil

        if shouldKeepAwakeWithLidClosed, !powerSourceState.isPortableMac {
            lastErrorMessage = localization.string(
                "error.lidCloseRequiresPortableMac",
                defaultValue: "合盖保持唤醒仅适用于 Mac 笔记本电脑。"
            )
            notifyChange()
            return
        }

        guard let session else {
            keepAwakeWithLidClosed = shouldKeepAwakeWithLidClosed
            persistKeepAwakeWithLidClosedPreference()
            notifyChange()
            return
        }

        do {
            try session.setPreventLidCloseSleep(
                shouldKeepAwakeWithLidClosed
                && powerSourceState.canPreventLidCloseSleep
            )
            keepAwakeWithLidClosed = shouldKeepAwakeWithLidClosed
            persistKeepAwakeWithLidClosedPreference()
            notifyChange()
        } catch {
            logger.error("keep-awake closed-lid update failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = error.localizedDescription
            notifyChange()
        }
    }

    private func applyKeepAwakeConfiguration() {
        let session = session ?? sessionFactory(localization) { [weak self] reason in
            self?.handleSessionEnd(reason)
        }
        let endDate = resolvedScheduledEndDate(referenceDate: Date())
        let shouldPreventLidCloseSleep =
            keepAwakeWithLidClosed
            && powerSourceState.canPreventLidCloseSleep

        do {
            try session.start(
                until: endDate,
                preventDisplaySleep: keepDisplayOn,
                preventLidCloseSleep: shouldPreventLidCloseSleep
            )
            self.session = session
            scheduledEndDate = endDate
            persistCurrentSelectionIfRunning()
            scheduleTimedStateRefreshIfNeeded()
            lastErrorMessage = nil
            notifyChange()
        } catch {
            logger.error("keep-awake session update failed: \(error.localizedDescription, privacy: .public)")
            if shouldPreventLidCloseSleep {
                keepAwakeWithLidClosed = false
                persistKeepAwakeWithLidClosedPreference()
            }
            lastErrorMessage = error.localizedDescription
            notifyChange()
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

    private func persistKeepDisplayOnPreference() {
        if keepDisplayOn {
            storage.set(true, forKey: StorageKey.keepDisplayOn)
        } else {
            storage.removeObject(forKey: StorageKey.keepDisplayOn)
        }
    }

    private func persistKeepAwakeWithLidClosedPreference() {
        if keepAwakeWithLidClosed {
            storage.set(true, forKey: StorageKey.keepAwakeWithLidClosed)
        } else {
            storage.removeObject(forKey: StorageKey.keepAwakeWithLidClosed)
        }
    }

    private func handlePowerSourceChange(_ state: KeepAwakePowerSourceState) {
        guard state != powerSourceState else {
            return
        }

        powerSourceState = state

        guard keepAwakeWithLidClosed else {
            notifyChange()
            return
        }

        guard let session else {
            notifyChange()
            return
        }

        do {
            try session.setPreventLidCloseSleep(state.canPreventLidCloseSleep)
            lastErrorMessage = nil
            notifyChange()
        } catch {
            let errorMessage = error.localizedDescription
            logger.error("failed to update closed-lid assertion after power change: \(errorMessage, privacy: .public)")
            keepAwakeWithLidClosed = false
            persistKeepAwakeWithLidClosedPreference()
            if !state.canPreventLidCloseSleep {
                session.requestStop(reason: .userRequested)
            }
            lastErrorMessage = errorMessage
            notifyChange()
        }
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
