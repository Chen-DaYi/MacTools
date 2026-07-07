import XCTest
@testable import ActivityBarPlugin

@MainActor
final class ActivityBarStatsStoreTests: XCTestCase {
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
}
