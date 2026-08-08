import XCTest
@testable import MacTools

final class AutomationRuleEvaluatorTests: XCTestCase {
    func testAllSixTriggerKindsMatchOnlyTheirConfiguredEvents() throws {
        let (date, calendar) = try makeDate(hour: 9, minute: 30, weekday: 2)
        let evaluator = AutomationRuleEvaluator(calendar: calendar)
        let display = AutomationDisplaySnapshot(identifier: "42", name: "Studio Display")
        let pairs: [(AutomationTrigger, AutomationTriggerEvent)] = [
            (.schedule(ScheduleAutomationTrigger(hour: 9, minute: 30, weekdays: [2])), .schedule(date)),
            (.calendar(CalendarAutomationTrigger(phase: .starts, calendarIdentifier: "work", titleContains: "standup")), .calendar(identifier: "event", title: "Daily Standup", calendarIdentifier: "work", phase: .starts, date: date)),
            (.application(ApplicationAutomationTrigger(event: .activates, bundleIdentifier: "com.example.editor")), .application(bundleIdentifier: "com.example.editor", event: .activates, date: date)),
            (.power(PowerAutomationTrigger(event: .batteryAtOrBelow, batteryLevel: 30)), .power(source: .battery, batteryLevel: 30, event: .batteryAtOrBelow, date: date)),
            (.display(DisplayAutomationTrigger(event: .connected, displayNameContains: "studio")), .display(display, event: .connected, date: date)),
            (.network(NetworkAutomationTrigger(status: .available, interface: .wifi)), .network(status: .available, interface: .wifi, date: date)),
        ]

        for (trigger, event) in pairs {
            XCTAssertTrue(evaluator.triggerMatches(trigger, event: event), "Expected \(trigger) to match \(event)")
        }
        XCTAssertFalse(evaluator.triggerMatches(pairs[0].0, event: pairs[1].1))
        XCTAssertFalse(
            evaluator.triggerMatches(
                .application(ApplicationAutomationTrigger(event: .launches, bundleIdentifier: "com.example.editor")),
                event: pairs[2].1
            )
        )
    }

    func testAllFiveConditionFamiliesPassAndExposeFirstFailureReason() throws {
        let (date, calendar) = try makeDate(hour: 9, minute: 30, weekday: 2)
        let evaluator = AutomationRuleEvaluator(calendar: calendar)
        let snapshot = AutomationEnvironmentSnapshot(
            date: date,
            frontmostApplicationBundleIdentifier: "com.example.editor",
            batteryLevel: 80,
            powerSource: .adapter,
            connectedDisplays: [AutomationDisplaySnapshot(identifier: "42", name: "Studio Display")],
            networkStatus: .available,
            networkInterface: .wifi
        )
        let conditions: [AutomationCondition] = [
            .frontmostApplication(FrontmostApplicationCondition(bundleIdentifier: "com.example.editor")),
            .power(PowerAutomationCondition(source: .adapter, minimumBatteryLevel: 50, maximumBatteryLevel: 90)),
            .connectedDisplay(ConnectedDisplayCondition(displayIdentifier: "42", displayNameContains: "studio")),
            .timeRange(TimeRangeAutomationCondition(startMinute: 9 * 60, endMinute: 10 * 60, weekdays: [2])),
            .network(NetworkAutomationCondition(status: .available, interface: .wifi)),
        ]

        XCTAssertEqual(evaluator.evaluate(conditions: conditions, snapshot: snapshot), .satisfied)

        var failing = conditions
        failing[2] = .connectedDisplay(ConnectedDisplayCondition(displayIdentifier: "missing"))
        let result = evaluator.evaluate(conditions: failing, snapshot: snapshot)
        XCTAssertFalse(result.isSatisfied)
        XCTAssertEqual(result.reason, FeatureL10n.string("指定显示器未连接。"))
    }

    func testCalendarAndPowerTriggersMatchOnlyTheFiredConfigurationIdentity() throws {
        let (date, calendar) = try makeDate(hour: 9, minute: 30, weekday: 2)
        let evaluator = AutomationRuleEvaluator(calendar: calendar)
        let calendarEvent = AutomationTriggerEvent.calendar(
            identifier: "event",
            title: "Planning",
            calendarIdentifier: "work",
            phase: .starts,
            offsetMinutes: -10,
            date: date
        )

        XCTAssertTrue(evaluator.triggerMatches(
            .calendar(CalendarAutomationTrigger(
                phase: .starts,
                calendarIdentifier: "work",
                titleContains: "plan",
                offsetMinutes: -10
            )),
            event: calendarEvent
        ))
        XCTAssertFalse(evaluator.triggerMatches(
            .calendar(CalendarAutomationTrigger(
                phase: .starts,
                calendarIdentifier: "work",
                titleContains: "plan",
                offsetMinutes: 10
            )),
            event: calendarEvent
        ))
        let thresholdEvent = AutomationTriggerEvent.power(
            source: .battery,
            batteryLevel: 20,
            event: .batteryAtOrBelow,
            date: date
        )
        XCTAssertTrue(evaluator.triggerMatches(
            .power(PowerAutomationTrigger(event: .batteryAtOrBelow, batteryLevel: 20)),
            event: thresholdEvent
        ))
        XCTAssertFalse(evaluator.triggerMatches(
            .power(PowerAutomationTrigger(event: .batteryAtOrBelow, batteryLevel: 80)),
            event: thresholdEvent
        ))
    }

    func testAnyNetworkRuleDoesNotMatchAnInterfaceOnlyEvent() throws {
        let (date, calendar) = try makeDate(hour: 9, minute: 30, weekday: 2)
        let evaluator = AutomationRuleEvaluator(calendar: calendar)
        let interfaceEvent = AutomationTriggerEvent.network(
            status: .available,
            interface: .wiredEthernet,
            date: date
        )

        XCTAssertFalse(evaluator.triggerMatches(
            .network(NetworkAutomationTrigger(status: .available, interface: .any)),
            event: interfaceEvent
        ))
        XCTAssertTrue(evaluator.triggerMatches(
            .network(NetworkAutomationTrigger(status: .available, interface: .wiredEthernet)),
            event: interfaceEvent
        ))
    }

    func testOvernightTimeRangeIncludesBothSidesOfMidnight() throws {
        let (lateDate, calendar) = try makeDate(hour: 23, minute: 30, weekday: 2)
        let (earlyDate, _) = try makeDate(hour: 1, minute: 0, weekday: 3)
        let evaluator = AutomationRuleEvaluator(calendar: calendar)
        let condition = AutomationCondition.timeRange(
            TimeRangeAutomationCondition(startMinute: 22 * 60, endMinute: 2 * 60, weekdays: [2, 3])
        )

        XCTAssertTrue(evaluator.evaluate(condition, snapshot: snapshot(date: lateDate)).isSatisfied)
        XCTAssertTrue(evaluator.evaluate(condition, snapshot: snapshot(date: earlyDate)).isSatisfied)
    }

    private func snapshot(date: Date) -> AutomationEnvironmentSnapshot {
        AutomationEnvironmentSnapshot(
            date: date,
            frontmostApplicationBundleIdentifier: nil,
            batteryLevel: nil,
            powerSource: .unknown,
            connectedDisplays: [],
            networkStatus: .unavailable,
            networkInterface: .any
        )
    }

    private func makeDate(hour: Int, minute: Int, weekday: Int) throws -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let base = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let currentWeekday = calendar.component(.weekday, from: base)
        let shifted = try XCTUnwrap(calendar.date(byAdding: .day, value: weekday - currentWeekday, to: base))
        let date = try XCTUnwrap(calendar.date(bySettingHour: hour, minute: minute, second: 0, of: shifted))
        return (date, calendar)
    }
}
