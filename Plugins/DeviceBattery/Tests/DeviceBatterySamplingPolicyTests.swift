import XCTest
@testable import DeviceBatteryPlugin

final class DeviceBatterySamplingPolicyTests: XCTestCase {
    func testIncrementalLogWindowIsCappedAfterLongSleep() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let arguments = DeviceBatterySampler.logWindowArguments(
            startDate: referenceDate.addingTimeInterval(-4 * 60 * 60),
            fallbackLookback: "5m",
            referenceDate: referenceDate
        )

        XCTAssertEqual(arguments.first, "--start")
        XCTAssertEqual(
            parseLogDate(arguments[1]),
            referenceDate.addingTimeInterval(-10 * 60)
        )
    }

    func testIncrementalLogWindowKeepsRecentCursor() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        let startDate = referenceDate.addingTimeInterval(-90)
        let arguments = DeviceBatterySampler.logWindowArguments(
            startDate: startDate,
            fallbackLookback: "5m",
            referenceDate: referenceDate
        )

        XCTAssertEqual(parseLogDate(arguments[1]), startDate)
    }

    func testTimedOutLogAttemptIsThrottledWithoutAdvancingCursor() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        var state = DeviceBatteryIncrementalLogState()
        state.recordAttempt(at: referenceDate, completion: .completed)
        let completedCursor = state.cursorDate

        let timeoutDate = referenceDate.addingTimeInterval(5 * 60)
        state.recordAttempt(at: timeoutDate, completion: .timedOut)

        XCTAssertEqual(state.cursorDate, completedCursor)
        XCTAssertEqual(state.lastAttemptDate, timeoutDate)
        XCTAssertFalse(state.shouldRefresh(
            at: timeoutDate.addingTimeInterval(4 * 60),
            interval: 5 * 60
        ))
        XCTAssertTrue(state.shouldRefresh(
            at: timeoutDate.addingTimeInterval(5 * 60),
            interval: 5 * 60
        ))
    }

    func testSupplementalCacheRetainsMissingReadingUntilExpiry() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        var cache = DeviceBatterySupplementalItemCache(itemLifetime: 60)
        let item = makeItem(lastUpdated: referenceDate, groupID: "headphones")

        cache.update(
            with: [item],
            knownTargetGroupIDs: ["headphones"],
            knownTargetNames: [],
            connectedTargetGroupIDs: ["headphones"],
            connectedTargetNames: [],
            referenceDate: referenceDate
        )
        cache.update(
            with: [],
            knownTargetGroupIDs: ["headphones"],
            knownTargetNames: [],
            connectedTargetGroupIDs: ["headphones"],
            connectedTargetNames: [],
            referenceDate: referenceDate.addingTimeInterval(30)
        )

        XCTAssertEqual(try XCTUnwrap(cache.items.first).lastUpdated, referenceDate)

        cache.update(
            with: [],
            knownTargetGroupIDs: ["headphones"],
            knownTargetNames: [],
            connectedTargetGroupIDs: ["headphones"],
            connectedTargetNames: [],
            referenceDate: referenceDate.addingTimeInterval(61)
        )
        XCTAssertTrue(cache.items.isEmpty)
    }

    func testSupplementalCacheDropsDisconnectedTarget() {
        let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        var cache = DeviceBatterySupplementalItemCache()
        cache.update(
            with: [makeItem(lastUpdated: referenceDate, groupID: "headphones")],
            knownTargetGroupIDs: ["headphones"],
            knownTargetNames: [],
            connectedTargetGroupIDs: ["headphones"],
            connectedTargetNames: [],
            referenceDate: referenceDate
        )

        cache.update(
            with: [],
            knownTargetGroupIDs: ["headphones"],
            knownTargetNames: [],
            connectedTargetGroupIDs: [],
            connectedTargetNames: [],
            referenceDate: referenceDate
        )

        XCTAssertTrue(cache.items.isEmpty)
    }

    private func parseLogDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private func makeItem(lastUpdated: Date, groupID: String) -> DeviceBatteryItem {
        DeviceBatteryItem(
            id: "cached-headphones",
            name: "Headphones",
            model: nil,
            kind: .airPodsPart,
            level: 50,
            chargeState: .normal,
            parentName: nil,
            source: "test",
            lastUpdated: lastUpdated,
            isConnected: true,
            detail: nil,
            componentIdentity: DeviceBatteryComponentIdentity(
                groupID: groupID,
                role: .aggregate
            )
        )
    }
}
