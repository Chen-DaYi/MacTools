import Foundation
import MacToolsPluginKit

@MainActor
final class ActivityBarCodingSessionStore: ObservableObject {
    private enum StorageKey {
        static let days = "activity-bar.coding.days.v1"
    }

    /// A flush has no matching hook event proving that the tool is still busy.
    /// Keep a short trailing window for in-progress UI updates without turning a
    /// lost Stop/SessionEnd event into hours or days of phantom activity.
    private static let unconfirmedActivityLimit: TimeInterval = 30 * 60

    /// A later event normally confirms the interval since the preceding event.
    /// Very large gaps indicate a suspended machine or an abandoned session and
    /// must not be charged as continuous coding time.
    private static let maximumEventGap: TimeInterval = 6 * 60 * 60

    private struct ActiveSession: Equatable {
        var project: String
        var tool: String
        var status: ActivityBarHookStatus
        var lastEventAt: Date
        var accountedThrough: Date
    }

    private struct IntervalCoverage {
        private struct Interval {
            var start: Date
            var end: Date
        }

        private var intervals: [Interval] = []

        mutating func insert(from start: Date, to end: Date) -> TimeInterval {
            guard end > start else {
                return 0
            }

            let previousDuration = intervals.reduce(0) { result, interval in
                result + interval.end.timeIntervalSince(interval.start)
            }
            let candidates = (intervals + [Interval(start: start, end: end)])
                .sorted { $0.start < $1.start }
            var merged: [Interval] = []

            for candidate in candidates {
                guard var last = merged.last else {
                    merged.append(candidate)
                    continue
                }

                if candidate.start <= last.end {
                    last.end = max(last.end, candidate.end)
                    merged[merged.count - 1] = last
                } else {
                    merged.append(candidate)
                }
            }

            intervals = merged
            let currentDuration = intervals.reduce(0) { result, interval in
                result + interval.end.timeIntervalSince(interval.start)
            }
            return max(currentDuration - previousDuration, 0)
        }
    }

    @Published private(set) var days: [String: ActivityBarCodingDailyStats]
    @Published private(set) var activeSessionCount = 0

    private var activeSessions: [String: ActiveSession] = [:]
    private let storage: PluginStorage
    private let calendar: Calendar
    private let dateProvider: () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var dailyIntervalCoverage: [String: IntervalCoverage] = [:]
    private var projectIntervalCoverage: [String: [String: IntervalCoverage]] = [:]
    private var toolIntervalCoverage: [String: [String: IntervalCoverage]] = [:]

    init(
        storage: PluginStorage,
        calendar: Calendar = .current,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.storage = storage
        self.calendar = calendar
        self.dateProvider = dateProvider
        self.days = Self.loadDays(storage: storage, decoder: decoder)
        sanitizeStoredDurations()
    }

    var today: ActivityBarCodingDailyStats {
        days[dateKey(for: dateProvider())] ?? ActivityBarCodingDailyStats(date: dateKey(for: dateProvider()))
    }

    var sortedDateKeys: [String] {
        days.keys.sorted()
    }

    func stats(for date: String) -> ActivityBarCodingDailyStats {
        days[date] ?? ActivityBarCodingDailyStats(date: date)
    }

    func recentDays(count: Int, endingAt endDate: Date? = nil) -> [ActivityBarCodingDailyStats] {
        let end = endDate ?? dateProvider()
        let boundedCount = max(count, 1)

        return (0..<boundedCount).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: end) ?? end
            let key = dateKey(for: date)
            return stats(for: key)
        }
    }

    func handleEvent(_ event: ActivityBarHookEvent) {
        let now = dateProvider()
        let project = projectName(from: event.cwd)
        let sessionID = event.sessionID.isEmpty ? "unknown" : event.sessionID
        let tool = ActivityBarCodingTool.displayName(forSessionID: sessionID)

        closeElapsedTime(for: sessionID, now: now, isConfirmed: true)

        if let prompt = event.userPrompt, event.event == .userPromptSubmit {
            addWords(countWords(prompt), project: project, tool: tool)
        }

        if event.event == .preToolUse {
            addToolCall(project: project, tool: tool)
        }

        switch event.event {
        case .sessionEnd:
            activeSessions.removeValue(forKey: sessionID)
        default:
            activeSessions[sessionID] = ActiveSession(
                project: project,
                tool: tool,
                status: event.status,
                lastEventAt: now,
                accountedThrough: now
            )
        }

        closeAndRemoveStaleSessions(excluding: sessionID, now: now)
        activeSessionCount = activeSessions.count
        persist()
    }

    func flushActiveDurations() {
        let now = dateProvider()
        for sessionID in Array(activeSessions.keys) {
            closeElapsedTime(for: sessionID, now: now, isConfirmed: false)
        }
        removeStaleSessions(now: now)
        activeSessionCount = activeSessions.count
        persist()
    }

    func resetToday() {
        let now = dateProvider()
        let key = dateKey(for: now)

        // Preserve any portion belonging to an earlier calendar day, then cut
        // every active interval at the reset boundary. A later Stop event must
        // only restore activity that happened after the user cleared today.
        for sessionID in Array(activeSessions.keys) {
            closeElapsedTime(for: sessionID, now: now, isConfirmed: false)
            guard var session = activeSessions[sessionID] else {
                continue
            }
            session.accountedThrough = max(session.accountedThrough, now)
            activeSessions[sessionID] = session
        }

        days[key] = ActivityBarCodingDailyStats(date: key)
        dailyIntervalCoverage.removeValue(forKey: key)
        projectIntervalCoverage.removeValue(forKey: key)
        toolIntervalCoverage.removeValue(forKey: key)
        persist()
    }

    private func closeElapsedTime(for sessionID: String, now: Date, isConfirmed: Bool) {
        guard var session = activeSessions[sessionID] else {
            return
        }

        let limit = isConfirmed ? Self.maximumEventGap : Self.unconfirmedActivityLimit
        let boundedEnd = min(now, session.lastEventAt.addingTimeInterval(limit))
        if boundedEnd.timeIntervalSince(session.accountedThrough) > 0.5,
           session.status != .waitingForInput,
           session.status != .ended {
            recordActiveInterval(
                from: session.accountedThrough,
                to: boundedEnd,
                project: session.project,
                tool: session.tool
            )
        }

        session.accountedThrough = max(session.accountedThrough, boundedEnd)
        activeSessions[sessionID] = session
    }

    private func closeAndRemoveStaleSessions(excluding sessionID: String, now: Date) {
        for candidateID in Array(activeSessions.keys) where candidateID != sessionID {
            guard let session = activeSessions[candidateID],
                  now.timeIntervalSince(session.lastEventAt) > Self.maximumEventGap else {
                continue
            }

            closeElapsedTime(for: candidateID, now: now, isConfirmed: false)
            activeSessions.removeValue(forKey: candidateID)
        }
    }

    private func removeStaleSessions(now: Date) {
        for sessionID in Array(activeSessions.keys) {
            guard let session = activeSessions[sessionID],
                  now.timeIntervalSince(session.lastEventAt) > Self.maximumEventGap else {
                continue
            }
            activeSessions.removeValue(forKey: sessionID)
        }
    }

    private func addWords(_ count: Int, project: String, tool: String) {
        guard count > 0 else {
            return
        }

        mutateToday(project: project, tool: tool) { day, projectStats, toolStats in
            day.wordCount += count
            projectStats.wordCount += count
            toolStats.wordCount += count
        }
    }

    private func addToolCall(project: String, tool: String) {
        mutateToday(project: project, tool: tool) { day, projectStats, toolStats in
            day.toolCallCount += 1
            projectStats.toolCallCount += 1
            toolStats.toolCallCount += 1
        }
    }

    private func recordActiveInterval(from start: Date, to end: Date, project rawProject: String, tool rawTool: String) {
        guard end > start else {
            return
        }

        let project = normalizedProject(rawProject)
        let tool = normalizedTool(rawTool)
        var segmentStart = start

        while segmentStart < end {
            let dayStart = calendar.startOfDay(for: segmentStart)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart), nextDay > segmentStart else {
                return
            }

            let segmentEnd = min(end, nextDay)
            let key = dateKey(for: segmentStart)
            let dailyDelta = Self.insertCoverage(
                in: &dailyIntervalCoverage,
                date: key,
                from: segmentStart,
                to: segmentEnd
            )
            let projectDelta = Self.insertCoverage(
                in: &projectIntervalCoverage,
                date: key,
                name: project,
                from: segmentStart,
                to: segmentEnd
            )
            let toolDelta = Self.insertCoverage(
                in: &toolIntervalCoverage,
                date: key,
                name: tool,
                from: segmentStart,
                to: segmentEnd
            )
            let durationLimit = maximumDuration(forDateKey: key)
            var day = days[key] ?? ActivityBarCodingDailyStats(date: key)
            var projectStats = day.perProject[project] ?? ActivityBarProjectStats()
            var toolStats = day.perTool[tool] ?? ActivityBarProjectStats()

            day.durationSeconds = clampedDuration(day.durationSeconds + dailyDelta, limit: durationLimit)
            projectStats.durationSeconds = clampedDuration(
                projectStats.durationSeconds + projectDelta,
                limit: durationLimit
            )
            toolStats.durationSeconds = clampedDuration(
                toolStats.durationSeconds + toolDelta,
                limit: durationLimit
            )

            day.perProject[project] = projectStats
            day.perTool[tool] = toolStats
            days[key] = day
            segmentStart = segmentEnd
        }
    }

    private static func insertCoverage(
        in coverage: inout [String: IntervalCoverage],
        date: String,
        from start: Date,
        to end: Date
    ) -> TimeInterval {
        var dayCoverage = coverage[date] ?? IntervalCoverage()
        let delta = dayCoverage.insert(from: start, to: end)
        coverage[date] = dayCoverage
        return delta
    }

    private static func insertCoverage(
        in coverage: inout [String: [String: IntervalCoverage]],
        date: String,
        name: String,
        from start: Date,
        to end: Date
    ) -> TimeInterval {
        var namedCoverage = coverage[date] ?? [:]
        var intervals = namedCoverage[name] ?? IntervalCoverage()
        let delta = intervals.insert(from: start, to: end)
        namedCoverage[name] = intervals
        coverage[date] = namedCoverage
        return delta
    }

    private func mutateToday(
        project rawProject: String,
        tool rawTool: String,
        update: (inout ActivityBarCodingDailyStats, inout ActivityBarProjectStats, inout ActivityBarProjectStats) -> Void
    ) {
        let project = normalizedProject(rawProject)
        let tool = normalizedTool(rawTool)
        let key = dateKey(for: dateProvider())
        var day = days[key] ?? ActivityBarCodingDailyStats(date: key)
        var projectStats = day.perProject[project] ?? ActivityBarProjectStats()
        var toolStats = day.perTool[tool] ?? ActivityBarProjectStats()

        update(&day, &projectStats, &toolStats)

        day.perProject[project] = projectStats
        day.perTool[tool] = toolStats
        days[key] = day
    }

    private func normalizedProject(_ project: String) -> String {
        project.isEmpty ? "Unknown" : project
    }

    private func normalizedTool(_ tool: String) -> String {
        tool.isEmpty ? ActivityBarCodingTool.claudeCode.rawValue : tool
    }

    private func countWords(_ prompt: String) -> Int {
        prompt
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    private func projectName(from cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else {
            return "Unknown"
        }

        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func dateKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func sanitizeStoredDurations() {
        var changed = false

        for key in Array(days.keys) {
            guard var day = days[key] else {
                continue
            }

            let original = day
            let durationLimit = maximumDuration(forDateKey: key)
            day.durationSeconds = clampedDuration(day.durationSeconds, limit: durationLimit)

            for name in Array(day.perProject.keys) {
                guard var stats = day.perProject[name] else {
                    continue
                }
                stats.durationSeconds = clampedDuration(stats.durationSeconds, limit: durationLimit)
                day.perProject[name] = stats
            }

            for name in Array(day.perTool.keys) {
                guard var stats = day.perTool[name] else {
                    continue
                }
                stats.durationSeconds = clampedDuration(stats.durationSeconds, limit: durationLimit)
                day.perTool[name] = stats
            }

            days[key] = day
            changed = changed || day != original
        }

        if changed {
            persist()
        }
    }

    private func maximumDuration(forDateKey key: String) -> TimeInterval {
        let values = key.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else {
            return 24 * 60 * 60
        }

        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: values[0],
            month: values[1],
            day: values[2]
        )
        guard let date = calendar.date(from: components) else {
            return 24 * 60 * 60
        }

        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return 24 * 60 * 60
        }
        return end.timeIntervalSince(start)
    }

    private func clampedDuration(_ duration: TimeInterval, limit: TimeInterval) -> TimeInterval {
        guard duration.isFinite else {
            return 0
        }
        return min(max(duration, 0), limit)
    }

    private func persist() {
        do {
            let data = try encoder.encode(days)
            storage.set(data, forKey: StorageKey.days)
        } catch {
            ActivityBarLog.hooks.error("Failed to persist coding stats: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadDays(storage: PluginStorage, decoder: JSONDecoder) -> [String: ActivityBarCodingDailyStats] {
        guard let data = storage.data(forKey: StorageKey.days) else {
            return [:]
        }

        do {
            return try decoder.decode([String: ActivityBarCodingDailyStats].self, from: data)
        } catch {
            ActivityBarLog.hooks.error("Failed to load coding stats: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }
}
