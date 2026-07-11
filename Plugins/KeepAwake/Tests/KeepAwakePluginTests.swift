import XCTest
import IOKit.pwr_mgt
import MacToolsPluginKit
@testable import KeepAwakePlugin

@MainActor
final class KeepAwakePluginTests: XCTestCase {
    func testPermanentSessionPersistsAndRestoresAfterHostShutdown() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))

        XCTAssertTrue(firstPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(firstFactory.sessions.count, 1)
        XCTAssertEqual(firstFactory.sessions[0].startedConfigurations.count, 1)
        XCTAssertNil(firstFactory.sessions[0].startedConfigurations[0].endDate)
        XCTAssertFalse(firstFactory.sessions[0].startedConfigurations[0].preventDisplaySleep)

        firstPlugin.deactivate(reason: .hostShutdown)

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(firstFactory.sessions[0].stopRequestCount, 1)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertTrue(secondPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(secondFactory.sessions.count, 1)
        XCTAssertEqual(secondFactory.sessions[0].startedConfigurations.count, 1)
        XCTAssertNil(secondFactory.sessions[0].startedConfigurations[0].endDate)
        XCTAssertFalse(secondFactory.sessions[0].startedConfigurations[0].preventDisplaySleep)
    }

    func testTemporarySessionDoesNotRestoreAfterHostShutdown() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))
        firstPlugin.handleAction(.setSelection(controlID: "duration", optionID: "oneHour"))

        XCTAssertTrue(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])
        XCTAssertEqual(firstFactory.sessions.count, 1)
        XCTAssertEqual(firstFactory.sessions[0].startedConfigurations.count, 2)
        XCTAssertNotNil(firstFactory.sessions[0].startedConfigurations[1].endDate)

        firstPlugin.deactivate(reason: .hostShutdown)

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertFalse(secondPlugin.primaryPanelState.isOn)
        XCTAssertTrue(secondFactory.sessions.isEmpty)
    }

    func testManualSwitchOffClearsPermanentRestoreState() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)

        firstPlugin.handleAction(.setSwitch(false))

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])
        XCTAssertEqual(firstFactory.sessions[0].stopRequestCount, 1)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertFalse(secondPlugin.primaryPanelState.isOn)
        XCTAssertTrue(secondFactory.sessions.isEmpty)
    }

    func testKeepDisplayOnSettingDefaultsToOffAndUpdatesRunningSession() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(factory.sessions[0].startedConfigurations.last?.preventDisplaySleep, false)
        XCTAssertNil(storage.values["keep-display-on"])
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "不会自动停止")
        XCTAssertEqual(plugin.primaryPanelState.detail?.primaryControls.map(\.id), ["duration"])
        XCTAssertNotNil(plugin.configuration)
        XCTAssertNil(plugin.primaryPanelIndicator)

        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(factory.sessions[0].startedConfigurations.count, 1)
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true])
        XCTAssertEqual(storage.values["keep-display-on"] as? Bool, true)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "不会自动停止")
        XCTAssertEqual(
            plugin.primaryPanelIndicator,
            PluginPrimaryPanelIndicator(text: "屏幕常亮", systemImage: "display")
        )

        plugin.setKeepDisplayOn(false)

        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false])
        XCTAssertNil(storage.values["keep-display-on"])
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "不会自动停止")
        XCTAssertNil(plugin.primaryPanelIndicator)
    }

    func testKeepDisplayOnSettingAppliesToFutureSession() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(storage.values["keep-display-on"] as? Bool, true)
        XCTAssertTrue(factory.sessions.isEmpty)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelIndicator)

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(factory.sessions[0].startedConfigurations.last?.preventDisplaySleep, true)
        XCTAssertNotNil(plugin.primaryPanelIndicator)
    }

    func testKeepDisplayOnUpdatePreservesTimedSessionEndDate() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        plugin.handleAction(.setSelection(controlID: "duration", optionID: "oneHour"))

        let session = factory.sessions[0]
        let scheduledEndDate = session.startedConfigurations.last?.endDate
        XCTAssertNotNil(scheduledEndDate)

        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(session.startedConfigurations.count, 2)
        XCTAssertEqual(session.startedConfigurations.last?.endDate, scheduledEndDate)
        XCTAssertEqual(session.displaySleepPreventionUpdates, [true])
    }

    func testFailedKeepDisplayOnUpdateKeepsAppliedPreferenceAndCanRetry() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        let session = factory.sessions[0]
        session.displayUpdateError = MockKeepAwakeSessionError.displayUpdateFailed

        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(session.displaySleepPreventionUpdates, [true])
        XCTAssertNil(storage.values["keep-display-on"])
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "不会自动停止")
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)

        session.displayUpdateError = nil
        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(session.displaySleepPreventionUpdates, [true, true])
        XCTAssertEqual(storage.values["keep-display-on"] as? Bool, true)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "不会自动停止")
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testKeepDisplayOnPreferenceRestoresWithPermanentSession() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))
        firstPlugin.setKeepDisplayOn(true)
        firstPlugin.deactivate(reason: .hostShutdown)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertTrue(secondPlugin.primaryPanelState.isOn)
        XCTAssertEqual(secondFactory.sessions[0].startedConfigurations.last?.preventDisplaySleep, true)
        XCTAssertEqual(storage.values["keep-display-on"] as? Bool, true)
    }

    func testKeepDisplayOnPreferenceSurvivesSessionOff() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        plugin.setKeepDisplayOn(true)
        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(storage.values["keep-display-on"] as? Bool, true)

        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(factory.sessions.last?.startedConfigurations.last?.preventDisplaySleep, true)
    }

    func testTimedSessionSubtitleKeepsRemainingAndAbsoluteStopCompact() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        plugin.handleAction(.setSelection(controlID: "duration", optionID: "twoHours"))

        let subtitle = plugin.primaryPanelState.subtitle
        XCTAssertTrue(subtitle.contains(":"), subtitle)
        XCTAssertTrue(subtitle.contains("·"), subtitle)
        XCTAssertTrue(subtitle.contains("剩余"), subtitle)
        XCTAssertEqual(subtitle.filter { $0 == "·" }.count, 1, subtitle)
    }

    private static func context(storage: KeepAwakeMemoryStorage) -> PluginRuntimeContext {
        PluginRuntimeContext(pluginID: "keep-awake", storage: storage)
    }
}

final class KeepAwakeStopScheduleFormattingTests: XCTestCase {
    private let localization = PluginLocalization(bundle: .main)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var locale: Locale { Locale(identifier: "en_US_POSIX") }

    func testSameDayStopUsesTimeOnly() {
        let reference = date(year: 2026, month: 7, day: 10, hour: 14, minute: 0)
        let end = date(year: 2026, month: 7, day: 10, hour: 16, minute: 30)

        let label = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
            until: end,
            referenceDate: reference,
            calendar: calendar,
            localization: localization,
            locale: locale
        )

        XCTAssertTrue(label.contains("4:30"), label)
        XCTAssertFalse(label.contains("16:30"), label)
    }

    func testSameDayStopUsesLocalePreferred24HourClock() {
        let reference = date(year: 2026, month: 7, day: 10, hour: 14, minute: 0)
        let end = date(year: 2026, month: 7, day: 10, hour: 16, minute: 30)

        let label = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
            until: end,
            referenceDate: reference,
            calendar: calendar,
            localization: localization,
            locale: Locale(identifier: "en_GB")
        )

        XCTAssertTrue(label.contains("16:30"), label)
    }

    func testNextDayStopUsesTomorrowPrefix() {
        let reference = date(year: 2026, month: 7, day: 10, hour: 22, minute: 0)
        let end = date(year: 2026, month: 7, day: 11, hour: 1, minute: 15)

        let label = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
            until: end,
            referenceDate: reference,
            calendar: calendar,
            localization: localization,
            locale: locale
        )

        // PluginLocalization falls back to default Chinese copy when the key is not in the test host bundle.
        XCTAssertTrue(label.contains("1:15"), label)
        XCTAssertTrue(
            label.contains("Tomorrow") || label.contains("明天"),
            label
        )
    }

    func testLaterDayStopIncludesDate() {
        let reference = date(year: 2026, month: 7, day: 10, hour: 12, minute: 0)
        let end = date(year: 2026, month: 7, day: 12, hour: 9, minute: 5)

        let label = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
            until: end,
            referenceDate: reference,
            calendar: calendar,
            localization: localization,
            locale: locale
        )

        XCTAssertTrue(label.contains("9:05"), label)
        XCTAssertFalse(label.contains("Tomorrow") || label.contains("明天"), label)
        XCTAssertTrue(label.contains("Jul") || label.contains("7") || label.contains("12"), label)
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }
}

@MainActor
final class KeepAwakeSessionTests: XCTestCase {
    func testDisplayAssertionFailureDoesNotPreventSessionStart() throws {
        var createdKinds: [KeepAwakeSession.AssertionKind] = []
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                createdKinds.append(kind)
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .display:
                    return (kIOReturnError, 0)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(until: nil, preventDisplaySleep: true)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(createdKinds, [.system, .display])
        XCTAssertEqual(releasedAssertionIDs, [1])
    }

    func testDisplayAssertionCanBeUpdatedWithoutRestartingSystemAssertion() throws {
        var createdKinds: [KeepAwakeSession.AssertionKind] = []
        var releasedAssertionIDs: [IOPMAssertionID] = []
        var nextAssertionID = IOPMAssertionID(1)
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                createdKinds.append(kind)
                defer { nextAssertionID += 1 }
                return (kIOReturnSuccess, nextAssertionID)
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(until: nil, preventDisplaySleep: false)
        try session.setPreventDisplaySleep(true)
        try session.setPreventDisplaySleep(false)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(createdKinds, [.system, .display])
        XCTAssertEqual(releasedAssertionIDs, [2, 1])
    }

    func testFailedDisplayAssertionCreationCanBeRetried() throws {
        var displayCreationAttempts = 0
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .display:
                    displayCreationAttempts += 1
                    return displayCreationAttempts == 1
                        ? (kIOReturnError, 0)
                        : (kIOReturnSuccess, 2)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(until: nil, preventDisplaySleep: false)
        XCTAssertThrowsError(try session.setPreventDisplaySleep(true))
        try session.setPreventDisplaySleep(true)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(displayCreationAttempts, 2)
        XCTAssertEqual(releasedAssertionIDs, [2, 1])
    }

    func testFailedDisplayAssertionReleaseRetainsAssertionForRetry() throws {
        var shouldFailDisplayRelease = true
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .display:
                    return (kIOReturnSuccess, 2)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                if assertionID == 2, shouldFailDisplayRelease {
                    return kIOReturnError
                }
                return kIOReturnSuccess
            }
        )

        try session.start(until: nil, preventDisplaySleep: true)
        XCTAssertThrowsError(try session.setPreventDisplaySleep(false))
        shouldFailDisplayRelease = false
        try session.setPreventDisplaySleep(false)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(releasedAssertionIDs, [2, 2, 1])
    }
}

@MainActor
private final class KeepAwakeSessionFactory {
    private(set) var sessions: [MockKeepAwakeSession] = []

    func makePlugin(storage: KeepAwakeMemoryStorage) -> KeepAwakePlugin {
        KeepAwakePlugin(
            context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage),
            sessionFactory: { [weak self] _, onEnd in
                let session = MockKeepAwakeSession(onEnd: onEnd)
                self?.sessions.append(session)
                return session
            }
        )
    }
}

@MainActor
private final class MockKeepAwakeSession: KeepAwakeSessionManaging {
    struct Configuration: Equatable {
        let endDate: Date?
        let preventDisplaySleep: Bool
    }

    private let onEnd: (KeepAwakeSession.EndReason) -> Void
    private(set) var startedConfigurations: [Configuration] = []
    private(set) var displaySleepPreventionUpdates: [Bool] = []
    private(set) var stopRequestCount = 0
    var displayUpdateError: Error?

    init(onEnd: @escaping (KeepAwakeSession.EndReason) -> Void) {
        self.onEnd = onEnd
    }

    func start(until endDate: Date?, preventDisplaySleep: Bool) throws {
        startedConfigurations.append(
            Configuration(endDate: endDate, preventDisplaySleep: preventDisplaySleep)
        )
    }

    func setPreventDisplaySleep(_ preventDisplaySleep: Bool) throws {
        displaySleepPreventionUpdates.append(preventDisplaySleep)
        if let displayUpdateError {
            throw displayUpdateError
        }
    }

    func requestStop(reason: KeepAwakeSession.EndReason) {
        stopRequestCount += 1
        onEnd(reason)
    }
}

private enum MockKeepAwakeSessionError: LocalizedError {
    case displayUpdateFailed

    var errorDescription: String? {
        "无法更新屏幕状态。"
    }
}

@MainActor
private final class KeepAwakeMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        guard let value else {
            values.removeValue(forKey: key)
            return
        }

        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
