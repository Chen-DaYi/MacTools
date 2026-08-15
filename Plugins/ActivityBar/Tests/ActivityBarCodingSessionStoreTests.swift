import XCTest
@testable import ActivityBarPlugin

@MainActor
final class ActivityBarCodingSessionStoreTests: XCTestCase {
    func testCodingEventsTrackWordsToolsAndActiveDuration() {
        let storage = ActivityBarMemoryStorage()
        var now = activityBarTestDate(hour: 10)
        let store = ActivityBarCodingSessionStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { now }
        )

        store.handleEvent(
            ActivityBarHookEvent(
                sessionID: "session-1",
                cwd: "/tmp/MacTools",
                event: .userPromptSubmit,
                status: .processing,
                userPrompt: "make the plugin work",
                tool: nil,
                interactive: true
            )
        )

        now = now.addingTimeInterval(10)
        store.handleEvent(
            ActivityBarHookEvent(
                sessionID: "session-1",
                cwd: "/tmp/MacTools",
                event: .preToolUse,
                status: .runningTool,
                userPrompt: nil,
                tool: "Read",
                interactive: true
            )
        )

        now = now.addingTimeInterval(5)
        store.handleEvent(
            ActivityBarHookEvent(
                sessionID: "session-1",
                cwd: "/tmp/MacTools",
                event: .stop,
                status: .waitingForInput,
                userPrompt: nil,
                tool: nil,
                interactive: true
            )
        )

        XCTAssertEqual(store.today.wordCount, 4)
        XCTAssertEqual(store.today.toolCallCount, 1)
        XCTAssertEqual(store.today.durationSeconds, 15, accuracy: 0.1)
        XCTAssertEqual(store.today.topProjects.first?.name, "MacTools")
        XCTAssertEqual(store.activeSessionCount, 1)
    }

    func testSessionEndRemovesActiveSession() {
        let storage = ActivityBarMemoryStorage()
        let store = ActivityBarCodingSessionStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() }
        )

        store.handleEvent(
            ActivityBarHookEvent(
                sessionID: "session-1",
                cwd: "/tmp/MacTools",
                event: .sessionStart,
                status: .waitingForInput,
                userPrompt: nil,
                tool: nil,
                interactive: true
            )
        )
        store.handleEvent(
            ActivityBarHookEvent(
                sessionID: "session-1",
                cwd: "/tmp/MacTools",
                event: .sessionEnd,
                status: .ended,
                userPrompt: nil,
                tool: nil,
                interactive: true
            )
        )

        XCTAssertEqual(store.activeSessionCount, 0)
    }

    func testCodingEventsAggregateByTool() {
        let storage = ActivityBarMemoryStorage()
        var now = activityBarTestDate(hour: 10)
        let store = ActivityBarCodingSessionStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { now }
        )

        store.handleEvent(
            ActivityBarHookEvent(
                sessionID: "cursor-session-1",
                cwd: "/tmp/MacTools",
                event: .userPromptSubmit,
                status: .processing,
                userPrompt: "update the ui",
                tool: nil,
                interactive: true
            )
        )

        now = now.addingTimeInterval(8)
        store.handleEvent(
            ActivityBarHookEvent(
                sessionID: "cursor-session-1",
                cwd: "/tmp/MacTools",
                event: .preToolUse,
                status: .runningTool,
                userPrompt: nil,
                tool: "Read",
                interactive: true
            )
        )

        guard let cursorStats = store.today.perTool["Cursor"] else {
            XCTFail("Expected Cursor stats to be recorded")
            return
        }
        XCTAssertEqual(cursorStats.wordCount, 3)
        XCTAssertEqual(cursorStats.toolCallCount, 1)
        XCTAssertEqual(cursorStats.durationSeconds, 8, accuracy: 0.1)
        XCTAssertEqual(store.today.topTools.first?.name, "Cursor")
    }

    func testUnreadableCodingStatsRejectEventsAndDurationFlushWithoutReplacingRawValue() {
        let storageKey = "activity-bar.coding.days.v1"
        let unreadableValues: [Any] = [
            "wrong-type",
            Data("malformed".utf8),
        ]

        for unreadableValue in unreadableValues {
            let storage = ActivityBarMemoryStorage()
            storage.set(unreadableValue, forKey: storageKey)
            let originalRawValue = storage.object(forKey: storageKey)
            let originalWriteCount = storage.setCallCount(forKey: storageKey)
            let store = ActivityBarCodingSessionStore(
                storage: storage,
                calendar: activityBarTestCalendar(),
                dateProvider: { activityBarTestDate() }
            )

            store.handleEvent(ActivityBarHookEvent(
                sessionID: "session-1",
                cwd: "/tmp/MacTools",
                event: .userPromptSubmit,
                status: .processing,
                userPrompt: "must not overwrite",
                tool: nil,
                interactive: true
            ))
            store.flushActiveDurations()

            XCTAssertNotNil(store.loadError)
            XCTAssertEqual(store.today.wordCount, 0)
            XCTAssertEqual(store.activeSessionCount, 0)
            XCTAssertEqual(storage.setCallCount(forKey: storageKey), originalWriteCount)
            XCTAssertTrue(activityBarStorageValuesMatch(
                storage.object(forKey: storageKey),
                originalRawValue
            ))
        }
    }

    func testParallelSessionsForSameToolCountOverlappingTimeOnce() {
        let storage = ActivityBarMemoryStorage()
        var now = activityBarTestDate(hour: 10)
        let store = ActivityBarCodingSessionStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { now }
        )

        store.handleEvent(makeEvent(sessionID: "codex-session-1", status: .processing))
        now = now.addingTimeInterval(5 * 60)
        store.handleEvent(makeEvent(sessionID: "codex-session-2", status: .processing))
        now = now.addingTimeInterval(5 * 60)
        store.handleEvent(makeEvent(sessionID: "codex-session-1", event: .stop, status: .waitingForInput))
        now = now.addingTimeInterval(5 * 60)
        store.handleEvent(makeEvent(sessionID: "codex-session-2", event: .stop, status: .waitingForInput))

        XCTAssertEqual(store.today.durationSeconds, 15 * 60, accuracy: 0.1)
        XCTAssertEqual(store.today.perTool["Codex"]?.durationSeconds ?? 0, 15 * 60, accuracy: 0.1)
    }

    func testActiveIntervalIsSplitAcrossCalendarDays() {
        let storage = ActivityBarMemoryStorage()
        var now = activityBarTestDate(day: 18, hour: 23, minute: 55)
        let store = ActivityBarCodingSessionStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { now }
        )

        store.handleEvent(makeEvent(sessionID: "codex-session-1", status: .processing))
        now = activityBarTestDate(day: 19, hour: 0, minute: 5)
        store.handleEvent(makeEvent(sessionID: "codex-session-1", event: .stop, status: .waitingForInput))

        XCTAssertEqual(store.stats(for: "2026-05-18").durationSeconds, 5 * 60, accuracy: 0.1)
        XCTAssertEqual(store.stats(for: "2026-05-19").durationSeconds, 5 * 60, accuracy: 0.1)
    }

    func testFlushDoesNotTurnAbandonedSessionIntoMultiDayActivity() {
        let storage = ActivityBarMemoryStorage()
        var now = activityBarTestDate(day: 18, hour: 10)
        let store = ActivityBarCodingSessionStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { now }
        )

        store.handleEvent(makeEvent(sessionID: "codex-session-1", status: .processing))
        now = activityBarTestDate(day: 23, hour: 10)
        store.flushActiveDurations()
        let recordedDuration = store.stats(for: "2026-05-18").durationSeconds

        now = now.addingTimeInterval(60 * 60)
        store.flushActiveDurations()

        XCTAssertEqual(recordedDuration, 30 * 60, accuracy: 0.1)
        XCTAssertEqual(store.stats(for: "2026-05-18").durationSeconds, recordedDuration, accuracy: 0.1)
        XCTAssertEqual(store.stats(for: "2026-05-23").durationSeconds, 0, accuracy: 0.1)
        XCTAssertEqual(store.activeSessionCount, 0)
    }

    func testResetTodayCutsActiveSessionAtResetBoundary() {
        let storage = ActivityBarMemoryStorage()
        var now = activityBarTestDate(hour: 10)
        let store = ActivityBarCodingSessionStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { now }
        )

        store.handleEvent(makeEvent(sessionID: "codex-session-1", status: .processing))
        now = now.addingTimeInterval(10 * 60)
        store.flushActiveDurations()
        XCTAssertEqual(store.today.durationSeconds, 10 * 60, accuracy: 0.1)

        store.resetToday()
        XCTAssertEqual(store.today.durationSeconds, 0, accuracy: 0.1)

        now = now.addingTimeInterval(5 * 60)
        store.handleEvent(
            makeEvent(
                sessionID: "codex-session-1",
                event: .stop,
                status: .waitingForInput
            )
        )

        XCTAssertEqual(store.today.durationSeconds, 5 * 60, accuracy: 0.1)
        XCTAssertEqual(store.today.perProject["MacTools"]?.durationSeconds ?? 0, 5 * 60, accuracy: 0.1)
        XCTAssertEqual(store.today.perTool["Codex"]?.durationSeconds ?? 0, 5 * 60, accuracy: 0.1)
    }

    func testLoadingClampsImpossibleStoredDailyDuration() throws {
        let storage = ActivityBarMemoryStorage()
        let corruptDuration = TimeInterval(112 * 60 * 60 + 42 * 60)
        let corruptDay = ActivityBarCodingDailyStats(
            date: "2026-05-18",
            durationSeconds: corruptDuration,
            perProject: ["MacTools": ActivityBarProjectStats(durationSeconds: corruptDuration)],
            perTool: ["Codex": ActivityBarProjectStats(durationSeconds: corruptDuration)]
        )
        storage.set(
            try JSONEncoder().encode([corruptDay.date: corruptDay]),
            forKey: "activity-bar.coding.days.v1"
        )

        let store = ActivityBarCodingSessionStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { activityBarTestDate() }
        )

        let sanitized = store.stats(for: corruptDay.date)
        XCTAssertEqual(sanitized.durationSeconds, 24 * 60 * 60, accuracy: 0.1)
        XCTAssertEqual(sanitized.perProject["MacTools"]?.durationSeconds ?? 0, 24 * 60 * 60, accuracy: 0.1)
        XCTAssertEqual(sanitized.perTool["Codex"]?.durationSeconds ?? 0, 24 * 60 * 60, accuracy: 0.1)
    }

    private func makeEvent(
        sessionID: String,
        event: ActivityBarHookEventType = .userPromptSubmit,
        status: ActivityBarHookStatus
    ) -> ActivityBarHookEvent {
        ActivityBarHookEvent(
            sessionID: sessionID,
            cwd: "/tmp/MacTools",
            event: event,
            status: status,
            userPrompt: nil,
            tool: nil,
            interactive: true
        )
    }
}
