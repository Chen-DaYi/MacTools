import MacToolsPluginKit
import XCTest
@testable import MacTools

final class SystemAutomationProvidersTests: XCTestCase {
    @MainActor
    func testPowerProviderFailureRelocalizesOnSameInstance() {
        let originalPreference = UserDefaults.standard.string(
            forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey
        )
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }
        let provider = SystemPowerAutomationTriggerProvider(
            notificationSourceFactory: { _ in nil }
        )
        provider.start { _ in }

        PluginRuntimeLocalization.source.setPreference("en")
        XCTAssertEqual(
            provider.availability,
            .unavailable("Unable to monitor power status.")
        )

        PluginRuntimeLocalization.source.setPreference("ar")
        XCTAssertEqual(
            provider.availability,
            .unavailable("غير قادر على مراقبة حالة الطاقة.")
        )
    }

    func testScheduleFindsNextConfiguredWeekdayWithoutCatchUp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let mondayMorning = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 10))
        )
        let configuration = ScheduleAutomationTrigger(hour: 9, minute: 0, weekdays: [2, 4])

        let next = try XCTUnwrap(
            SystemScheduleAutomationTriggerProvider.nextFireDate(
                for: configuration,
                after: mondayMorning,
                calendar: calendar
            )
        )

        XCTAssertEqual(calendar.component(.weekday, from: next), 4)
        XCTAssertEqual(calendar.component(.hour, from: next), 9)
        XCTAssertGreaterThan(next, mondayMorning)
    }

    func testPowerTransitionsEmitSourceAndThresholdCrossingsOnlyOnce() {
        let date = Date(timeIntervalSince1970: 100)
        let events = SystemAutomationTransitions.powerEvents(
            previous: AutomationPowerSnapshot(source: .adapter, batteryLevel: 55),
            current: AutomationPowerSnapshot(source: .battery, batteryLevel: 39),
            thresholds: [20, 40, 50],
            date: date
        )

        XCTAssertEqual(
            events,
            [
                .power(source: .battery, batteryLevel: 39, event: .adapterDisconnected, date: date),
                .power(source: .battery, batteryLevel: 39, event: .batteryAtOrBelow, date: date),
            ]
        )
        XCTAssertTrue(
            SystemAutomationTransitions.powerEvents(
                previous: AutomationPowerSnapshot(source: .battery, batteryLevel: 39),
                current: AutomationPowerSnapshot(source: .battery, batteryLevel: 39),
                thresholds: [40],
                date: date
            ).isEmpty
        )
    }

    func testDisplayTransitionsPreserveDisconnectedDisplayMetadata() {
        let date = Date(timeIntervalSince1970: 100)
        let builtIn = AutomationDisplaySnapshot(identifier: "1", name: "Built-in")
        let oldExternal = AutomationDisplaySnapshot(identifier: "2", name: "Studio")
        let newExternal = AutomationDisplaySnapshot(identifier: "3", name: "Projector")

        let events = SystemAutomationTransitions.displayEvents(
            previous: [builtIn, oldExternal],
            current: [builtIn, newExternal],
            date: date
        )

        XCTAssertEqual(
            events,
            [
                .display(newExternal, event: .connected, date: date),
                .display(oldExternal, event: .disconnected, date: date),
            ]
        )
    }
}
