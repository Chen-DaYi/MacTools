import EventKit
import Foundation
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

    @MainActor
    func testPowerProviderDeinitRemovesItsUnretainedRunLoopSource() throws {
        var context = CFRunLoopSourceContext()
        let source = try XCTUnwrap(CFRunLoopSourceCreate(nil, 0, &context))
        var provider: SystemPowerAutomationTriggerProvider? =
            SystemPowerAutomationTriggerProvider(
                notificationSourceFactory: { _ in source }
            )
        weak var weakProvider = provider
        provider?.start { _ in }
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))

        provider = nil

        XCTAssertNil(weakProvider)
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .commonModes))
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
                .power(source: .battery, batteryLevel: 50, event: .batteryAtOrBelow, date: date),
                .power(source: .battery, batteryLevel: 40, event: .batteryAtOrBelow, date: date),
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

    func testPowerTransitionsEmitOnlyThresholdsCrossedSinceThePreviousLevel() {
        let date = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            SystemAutomationTransitions.powerEvents(
                previous: AutomationPowerSnapshot(source: .battery, batteryLevel: 50),
                current: AutomationPowerSnapshot(source: .battery, batteryLevel: 19),
                thresholds: [20, 80],
                date: date
            ),
            [.power(source: .battery, batteryLevel: 20, event: .batteryAtOrBelow, date: date)]
        )
        XCTAssertEqual(
            SystemAutomationTransitions.powerEvents(
                previous: AutomationPowerSnapshot(source: .battery, batteryLevel: 100),
                current: AutomationPowerSnapshot(source: .battery, batteryLevel: 19),
                thresholds: [20, 80],
                date: date
            ),
            [
                .power(source: .battery, batteryLevel: 80, event: .batteryAtOrBelow, date: date),
                .power(source: .battery, batteryLevel: 20, event: .batteryAtOrBelow, date: date),
            ]
        )
    }

    func testNetworkTransitionsSeparateAvailabilityFromInterfaceChanges() {
        let date = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            SystemAutomationTransitions.networkEvents(
                previousStatus: .available,
                previousInterface: .wifi,
                currentStatus: .available,
                currentInterface: .wiredEthernet,
                date: date
            ),
            [.network(status: .available, interface: .wiredEthernet, date: date)]
        )
        XCTAssertEqual(
            SystemAutomationTransitions.networkEvents(
                previousStatus: .unavailable,
                previousInterface: .any,
                currentStatus: .available,
                currentInterface: .wifi,
                date: date
            ),
            [
                .network(status: .available, interface: .any, date: date),
                .network(status: .available, interface: .wifi, date: date),
            ]
        )
    }

    @MainActor
    func testNetworkProviderUsesFreshGenerationAndBaselineAfterRestart() async {
        let first = AutomationNetworkPathMonitorFake()
        let second = AutomationNetworkPathMonitorFake()
        var monitors = [first, second]
        var events: [AutomationTriggerEvent] = []
        let provider = SystemNetworkAutomationTriggerProvider(
            monitorFactory: { monitors.removeFirst() },
            now: { Date(timeIntervalSince1970: 100) }
        )

        provider.start { events.append($0) }
        first.emit(status: .available, interface: .wifi)
        await Task.yield()
        XCTAssertTrue(events.isEmpty)
        first.emit(status: .available, interface: .wiredEthernet)
        await Task.yield()
        XCTAssertEqual(events.count, 1)

        provider.stop()
        XCTAssertTrue(first.wasCancelled)
        XCTAssertEqual(provider.currentStatus, .unavailable)
        XCTAssertEqual(provider.currentInterface, .any)
        provider.start { events.append($0) }
        XCTAssertTrue(second.wasStarted)

        first.emitStale(status: .unavailable, interface: .any)
        await Task.yield()
        XCTAssertEqual(provider.currentStatus, .unavailable)
        XCTAssertEqual(provider.currentInterface, .any)
        XCTAssertEqual(events.count, 1)

        second.emit(status: .available, interface: .wifi)
        await Task.yield()
        XCTAssertEqual(provider.currentStatus, .available)
        XCTAssertEqual(provider.currentInterface, .wifi)
        XCTAssertEqual(events.count, 1)
        second.emit(status: .unavailable, interface: .any)
        await Task.yield()
        XCTAssertEqual(events.count, 2)
    }

    func testCalendarQueryIncludesEndedEventsWithFuturePositiveOffsets() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            SystemCalendarAutomationTriggerProvider.queryStartDate(
                currentDate: now,
                configurations: [
                    CalendarAutomationTrigger(phase: .ends, offsetMinutes: 30),
                    CalendarAutomationTrigger(phase: .starts, offsetMinutes: -10),
                ]
            ),
            now.addingTimeInterval(-30 * 60)
        )
    }

    @MainActor
    func testCalendarProviderDoesNotBlockMainActorWhileQueryIsRunning() async {
        let query = SlowCalendarEventQuery()
        let provider = SystemCalendarAutomationTriggerProvider(
            eventQuery: query,
            authorizationStatus: { .fullAccess }
        )
        let rule = AutomationRule(
            workflowID: UUID(),
            trigger: .calendar(CalendarAutomationTrigger(titleContains: "Review"))
        )
        provider.start { _ in }

        provider.refresh(rules: [rule])
        await query.waitUntilStarted()
        let configurationCount = await query.configurationCount()
        let queryIsSleeping = await query.isSleeping()
        XCTAssertEqual(configurationCount, 1)
        XCTAssertTrue(queryIsSleeping)

        provider.stop()
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

    @MainActor
    func testCalendarPlanBatchesSimultaneousEventsAndExcludesLaterOnes() {
        let now = Date(timeIntervalSince1970: 100)
        let firstDate = now.addingTimeInterval(60)
        let laterDate = now.addingTimeInterval(120)
        let events = [
            calendarEvent(id: "second", date: firstDate),
            calendarEvent(id: "later", date: laterDate),
            calendarEvent(id: "first", date: firstDate),
        ]

        let plan = SystemCalendarAutomationTriggerProvider.SchedulePlan.make(
            candidates: events,
            after: now
        )

        XCTAssertEqual(plan.nextBatch.map(\.identifier), ["first", "second"])
        XCTAssertEqual(plan.dueEvents(at: firstDate), plan.nextBatch)
        XCTAssertTrue(plan.dueEvents(at: firstDate.addingTimeInterval(91)).isEmpty)
    }

    @MainActor
    func testCalendarPlanAlwaysSchedulesMaintenanceWhenNoEventsAreInHorizon() {
        let now = Date(timeIntervalSince1970: 100)

        let plan = SystemCalendarAutomationTriggerProvider.SchedulePlan.make(
            candidates: [],
            after: now
        )

        XCTAssertTrue(plan.nextBatch.isEmpty)
        XCTAssertEqual(plan.maintenanceDate, now.addingTimeInterval(24 * 60 * 60))
        XCTAssertEqual(plan.nextTimerDate, plan.maintenanceDate)
    }

    @MainActor
    func testCalendarPlanUsesOneDeadlineWhenEventAndMaintenanceBecomeDueTogether() {
        let now = Date(timeIntervalSince1970: 100)
        let sharedDeadline = now.addingTimeInterval(60)
        let plan = SystemCalendarAutomationTriggerProvider.SchedulePlan.make(
            candidates: [calendarEvent(id: "wake-event", date: sharedDeadline)],
            after: now,
            maintenanceInterval: 60
        )

        XCTAssertEqual(plan.nextTimerDate, sharedDeadline)
        XCTAssertEqual(
            plan.dueEvents(at: sharedDeadline.addingTimeInterval(30)).map(\.identifier),
            ["wake-event"]
        )
    }

    @MainActor
    func testCalendarPlanSchedulesMaintenanceBeforeADistantEvent() {
        let now = Date(timeIntervalSince1970: 100)
        let plan = SystemCalendarAutomationTriggerProvider.SchedulePlan.make(
            candidates: [calendarEvent(id: "distant", date: now.addingTimeInterval(120))],
            after: now,
            maintenanceInterval: 60
        )

        XCTAssertEqual(plan.nextTimerDate, now.addingTimeInterval(60))
        XCTAssertTrue(plan.dueEvents(at: plan.nextTimerDate).isEmpty)
    }

    @MainActor
    func testCalendarPlanKeepsEverySimultaneousEventBeyondLegacyTimerLimit() {
        let now = Date(timeIntervalSince1970: 100)
        let fireDate = now.addingTimeInterval(60)
        let events = (0..<513).map {
            calendarEvent(id: "event-\($0)", date: fireDate)
        } + [calendarEvent(id: "later", date: fireDate.addingTimeInterval(60))]

        let plan = SystemCalendarAutomationTriggerProvider.SchedulePlan.make(
            candidates: events,
            after: now
        )

        XCTAssertEqual(plan.nextBatch.count, 513)
        XCTAssertFalse(plan.nextBatch.contains(where: { $0.identifier == "later" }))
    }

    @MainActor
    private func calendarEvent(
        id: String,
        date: Date
    ) -> SystemCalendarAutomationTriggerProvider.ScheduledEvent {
        SystemCalendarAutomationTriggerProvider.ScheduledEvent(
            fireDate: date,
            identifier: id,
            title: id,
            calendarIdentifier: nil,
            phase: .starts,
            offsetMinutes: 0
        )
    }
}

private actor SlowCalendarEventQuery: CalendarAutomationEventQuerying {
    private var started = false
    private var sleeping = false
    private var receivedConfigurationCount = 0

    func requestAccess() async -> Bool { true }

    func scheduledEvents(
        currentDate _: Date,
        configurations: [CalendarAutomationTrigger]
    ) async -> [CalendarAutomationScheduledEvent] {
        started = true
        sleeping = true
        receivedConfigurationCount = configurations.count
        try? await Task.sleep(for: .milliseconds(200))
        sleeping = false
        return []
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func configurationCount() -> Int { receivedConfigurationCount }
    func isSleeping() -> Bool { sleeping }
}

private final class AutomationNetworkPathMonitorFake: AutomationNetworkPathMonitoring,
    @unchecked Sendable {
    var updateHandler: (@Sendable (
        AutomationNetworkStatus,
        AutomationNetworkInterface
    ) -> Void)? {
        didSet {
            if let updateHandler { lastInstalledHandler = updateHandler }
        }
    }
    private var lastInstalledHandler: (@Sendable (
        AutomationNetworkStatus,
        AutomationNetworkInterface
    ) -> Void)?
    private(set) var wasStarted = false
    private(set) var wasCancelled = false

    func start(queue _: DispatchQueue) {
        wasStarted = true
    }

    func cancel() {
        wasCancelled = true
    }

    func emit(
        status: AutomationNetworkStatus,
        interface: AutomationNetworkInterface
    ) {
        updateHandler?(status, interface)
    }

    func emitStale(
        status: AutomationNetworkStatus,
        interface: AutomationNetworkInterface
    ) {
        lastInstalledHandler?(status, interface)
    }
}
