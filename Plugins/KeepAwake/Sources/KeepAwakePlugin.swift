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
final class KeepAwakePlugin: MacToolsPlugin, PluginPrimaryPanel {
    typealias SessionFactory = (
        PluginLocalization,
        @escaping (KeepAwakeSession.EndReason) -> Void
    ) -> any KeepAwakeSessionManaging

    private enum Timing {
        static let secondsPerMinute: TimeInterval = 60
    }

    private enum StorageKey {
        static let persistentEnabled = "persistent-enabled"
        static let keepDisplayOn = "keep-display-on"
    }

    private enum ControlID {
        static let duration = "duration"
        static let keepDisplayOn = "keep-display-on"
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

    private enum KeepDisplayOptionID {
        static let allowSleep = "allow-sleep"
        static let keepOn = "keep-on"
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
    private var storage: PluginStorage
    private var lastErrorMessage: String?
    private var session: (any KeepAwakeSessionManaging)?
    private var selectedDurationPreset: DurationPreset = .forever
    private var keepDisplayOn = false
    private var scheduledEndDate: Date?
    private var subtitleRefreshTimer: Timer?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "keep-awake"),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        sessionFactory: @escaping SessionFactory = { localization, onEnd in
            KeepAwakeSession(localization: localization, onEnd: onEnd)
        }
    ) {
        self.localization = localization
        self.storage = context.storage
        self.sessionFactory = sessionFactory
        self.keepDisplayOn = context.storage.bool(forKey: StorageKey.keepDisplayOn)
        self.metadata = PluginMetadata(
            id: "keep-awake",
            title: localization.string("metadata.title", defaultValue: "阻止休眠"),
            iconName: "moon",
            iconTint: Color(nsColor: .systemOrange),
            order: 50,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "阻止系统空闲休眠；可选保持屏幕常亮"
            )
        )
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

    var permissionRequirements: [PluginPermissionRequirement] { [] }

    var settingsSections: [PluginSettingsSection] { [] }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func activate(context: PluginRuntimeContext) {
        storage = context.storage
        keepDisplayOn = storage.bool(forKey: StorageKey.keepDisplayOn)

        guard storage.bool(forKey: StorageKey.persistentEnabled) else {
            return
        }

        selectedDurationPreset = .forever
        scheduledEndDate = nil
        applyKeepAwakeConfiguration()
    }

    func refresh() {
        scheduleSubtitleRefreshIfNeeded()
    }

    func deactivate(reason: PluginDeactivationReason) {
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
            switch controlID {
            case ControlID.duration:
                updateDurationPreset(using: optionID)
            case ControlID.keepDisplayOn:
                updateKeepDisplayOn(using: optionID)
            default:
                return
            }
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
            let remaining = remainingTimeDescription(until: scheduledEndDate, referenceDate: referenceDate)
            let stopAt = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
                until: scheduledEndDate,
                referenceDate: referenceDate,
                localization: localization
            )
            let timedCore = localization.format(
                "panel.subtitle.remainingWithStopFormat",
                defaultValue: "%@（%@）",
                remaining,
                stopAt
            )
            if keepDisplayOn {
                return localization.format(
                    "panel.subtitle.withDisplayFormat",
                    defaultValue: "%@ · 屏幕保持常亮",
                    timedCore
                )
            }
            return localization.format(
                "panel.subtitle.allowDisplaySleepFormat",
                defaultValue: "%@ · 允许屏幕关闭",
                timedCore
            )
        }

        if keepDisplayOn {
            return localization.string(
                "panel.subtitle.enabledWithDisplay",
                defaultValue: "已启用 · 屏幕保持常亮"
            )
        }

        return localization.string(
            "panel.subtitle.enabled",
            defaultValue: "已启用 · 允许屏幕关闭"
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
                ),
                PluginPanelControl(
                    id: ControlID.keepDisplayOn,
                    kind: .selectList,
                    options: [
                        PluginPanelControlOption(
                            id: KeepDisplayOptionID.allowSleep,
                            title: localization.string(
                                "panel.display.allowSleep",
                                defaultValue: "允许关闭"
                            ),
                            subtitle: localization.string(
                                "panel.display.allowSleep.subtitle",
                                defaultValue: "系统保持唤醒，屏幕可按系统设置关闭"
                            )
                        ),
                        PluginPanelControlOption(
                            id: KeepDisplayOptionID.keepOn,
                            title: localization.string(
                                "panel.display.keepOn",
                                defaultValue: "保持常亮"
                            ),
                            subtitle: localization.string(
                                "panel.display.keepOn.subtitle",
                                defaultValue: "系统与屏幕均不因空闲而关闭"
                            )
                        )
                    ],
                    selectedOptionID: keepDisplayOn
                        ? KeepDisplayOptionID.keepOn
                        : KeepDisplayOptionID.allowSleep,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: localization.string(
                        "panel.display.section",
                        defaultValue: "空闲时屏幕"
                    ),
                    showsLeadingDivider: true,
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

    private func updateKeepDisplayOn(using optionID: String) {
        let shouldKeepDisplayOn: Bool
        switch optionID {
        case KeepDisplayOptionID.keepOn:
            shouldKeepDisplayOn = true
        case KeepDisplayOptionID.allowSleep:
            shouldKeepDisplayOn = false
        default:
            return
        }

        guard keepDisplayOn != shouldKeepDisplayOn else {
            return
        }

        keepDisplayOn = shouldKeepDisplayOn
        persistKeepDisplayOnPreference()
        lastErrorMessage = nil

        guard session != nil else {
            notifyChange()
            return
        }

        applyKeepAwakeConfiguration()
    }

    private func applyKeepAwakeConfiguration() {
        let session = session ?? sessionFactory(localization) { [weak self] reason in
            self?.handleSessionEnd(reason)
        }
        let endDate = resolvedScheduledEndDate(referenceDate: Date())

        do {
            try session.start(until: endDate, preventDisplaySleep: keepDisplayOn)
            self.session = session
            scheduledEndDate = endDate
            persistCurrentSelectionIfRunning()
            scheduleSubtitleRefreshIfNeeded()
            lastErrorMessage = nil
            notifyChange()
        } catch {
            logger.error("keep-awake session update failed: \(error.localizedDescription, privacy: .public)")
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
                "panel.subtitle.remainingMinutesFormat",
                defaultValue: "%d 分钟后自动停止",
                remainingMinutes
            )
        }

        if minutes == 0 {
            return localization.format(
                "panel.subtitle.remainingHoursFormat",
                defaultValue: "%d 小时后自动停止",
                hours
            )
        }

        return localization.format(
            "panel.subtitle.remainingHoursMinutesFormat",
            defaultValue: "%d 小时 %d 分钟后自动停止",
            hours,
            minutes
        )
    }

    private func scheduleSubtitleRefreshIfNeeded() {
        invalidateSubtitleRefreshTimer()

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
                self?.handleSubtitleRefreshTimerFired()
            }
        }
        timer.tolerance = min(1, nextRefreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        subtitleRefreshTimer = timer
    }

    private func handleSubtitleRefreshTimerFired() {
        guard session != nil, scheduledEndDate != nil else {
            invalidateSubtitleRefreshTimer()
            return
        }

        notifyChange()
        scheduleSubtitleRefreshIfNeeded()
    }

    private func invalidateSubtitleRefreshTimer() {
        subtitleRefreshTimer?.invalidate()
        subtitleRefreshTimer = nil
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

    private func resetSelectionToDefaults() {
        selectedDurationPreset = .forever
        scheduledEndDate = nil
        invalidateSubtitleRefreshTimer()
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
        formatter.timeStyle = .short
        formatter.dateStyle = .none
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
