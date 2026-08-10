import XCTest
@testable import ActivityBarPlugin

@MainActor
final class ActivityBarStatsStoreTests: XCTestCase {
    private let inputDaysStorageKey = "activity-bar.input.days.v1"

    func testInputStatsAggregateByDayAndApp() {
        let storage = ActivityBarMemoryStorage()
        let store = ActivityBarStatsStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() }
        )

        store.incrementKeystroke(app: "Terminal")
        store.incrementPointerClick(app: "Terminal")
        store.incrementScroll(app: "Safari")
        store.addScreenTime(65, app: "Terminal")

        XCTAssertEqual(store.today.date, "2026-05-18")
        XCTAssertEqual(store.today.keystrokes, 1)
        XCTAssertEqual(store.today.pointerClicks, 1)
        XCTAssertEqual(store.today.scrollEvents, 1)
        XCTAssertEqual(store.today.totalInputs, 3)
        XCTAssertEqual(store.today.perApp["Terminal"]?.screenTimeSeconds, 65)
        XCTAssertEqual(store.today.topApps.first?.name, "Terminal")
    }

    func testInputStatsPersistThroughStorage() {
        let storage = ActivityBarMemoryStorage()

        let store = ActivityBarStatsStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() }
        )
        store.incrementKeystroke(app: "Xcode")
        store.flushPendingChanges()

        let reloaded = ActivityBarStatsStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() }
        )

        XCTAssertEqual(reloaded.today.keystrokes, 1)
        XCTAssertEqual(reloaded.today.perApp["Xcode"]?.keystrokes, 1)
    }

    func testInputStatsBatchPersistenceUntilFlush() {
        let storage = ActivityBarMemoryStorage()
        let store = ActivityBarStatsStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() },
            persistenceDelay: .seconds(60)
        )

        store.incrementKeystroke(app: "Terminal")
        store.incrementPointerClick(app: "Terminal")
        store.incrementScroll(app: "Safari")

        XCTAssertEqual(store.today.totalInputs, 3)
        XCTAssertEqual(storage.setCallCount(forKey: "activity-bar.input.days.v1"), 0)

        store.flushPendingChanges()

        XCTAssertEqual(storage.setCallCount(forKey: "activity-bar.input.days.v1"), 1)

        let reloaded = ActivityBarStatsStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() }
        )

        XCTAssertEqual(reloaded.today.totalInputs, 3)
    }

    func testResetTodayKeepsCurrentDateButClearsCounters() {
        let storage = ActivityBarMemoryStorage()
        let store = ActivityBarStatsStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() }
        )

        store.incrementKeystroke(app: "Terminal")
        store.resetToday()

        XCTAssertEqual(store.today.date, "2026-05-18")
        XCTAssertEqual(store.today.totalInputs, 0)
        XCTAssertTrue(store.today.perApp.isEmpty)
    }

    func testResetTodayPersistsClearedCountersAfterPreviousFlush() {
        let storage = ActivityBarMemoryStorage()
        let store = ActivityBarStatsStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() },
            persistenceDelay: .seconds(60)
        )

        store.incrementKeystroke(app: "Terminal")
        store.flushPendingChanges()
        store.resetToday()

        let reloaded = ActivityBarStatsStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() }
        )

        XCTAssertEqual(reloaded.today.date, "2026-05-18")
        XCTAssertEqual(reloaded.today.totalInputs, 0)
        XCTAssertTrue(reloaded.today.perApp.isEmpty)
    }

    func testFlushPendingChangesOnlyWritesWhenStatsAreDirty() {
        let storage = ActivityBarMemoryStorage()
        let store = ActivityBarStatsStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() }
        )

        store.flushPendingChanges()

        XCTAssertEqual(storage.setCallCount(forKey: inputDaysStorageKey), 0)

        store.incrementKeystroke(app: "Terminal")
        store.flushPendingChanges()

        XCTAssertEqual(storage.setCallCount(forKey: inputDaysStorageKey), 1)

        store.flushPendingChanges()

        XCTAssertEqual(storage.setCallCount(forKey: inputDaysStorageKey), 1)
    }

    func testUnreadableInputStatsRejectEventsAndFlushWithoutReplacingRawValue() {
        let unreadableValues: [Any] = [
            "wrong-type",
            Data("malformed".utf8),
        ]

        for unreadableValue in unreadableValues {
            let storage = ActivityBarMemoryStorage()
            storage.set(unreadableValue, forKey: inputDaysStorageKey)
            let originalRawValue = storage.object(forKey: inputDaysStorageKey)
            let originalWriteCount = storage.setCallCount(forKey: inputDaysStorageKey)
            let store = ActivityBarStatsStore(
                storage: storage,
                calendar: activityBarTestCalendar(),
                dateProvider: { activityBarTestDate() }
            )

            store.incrementKeystroke(app: "Terminal")
            store.flushPendingChanges()

            XCTAssertNotNil(store.loadError)
            XCTAssertEqual(store.today.totalInputs, 0)
            XCTAssertEqual(storage.setCallCount(forKey: inputDaysStorageKey), originalWriteCount)
            XCTAssertTrue(activityBarStorageValuesMatch(
                storage.object(forKey: inputDaysStorageKey),
                originalRawValue
            ))
        }
    }
}
