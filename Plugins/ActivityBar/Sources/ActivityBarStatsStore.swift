import Foundation
import MacToolsPluginKit

@MainActor
final class ActivityBarStatsStore: ObservableObject {
    private enum StorageKey {
        static let days = "activity-bar.input.days.v1"
    }

    // Direct observers receive every input mutation and bypass controller-level
    // UI throttling; keep hot-path UI subscriptions on ActivityBarController.
    @Published private(set) var days: [String: ActivityBarDailyStats]

    private let storage: PluginStorage
    private let calendar: Calendar
    private let dateProvider: () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var pendingPersistTask: Task<Void, Never>?
    private var hasPendingChanges = false

    private enum Persistence {
        static let debounceDelay: Duration = .seconds(30)
        static let retainedDayCount = 370
    }

    init(
        storage: PluginStorage,
        calendar: Calendar = .current,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.storage = storage
        self.calendar = calendar
        self.dateProvider = dateProvider
        self.days = Self.prunedDays(Self.loadDays(storage: storage, decoder: decoder))
    }

    var today: ActivityBarDailyStats {
        days[dateKey(for: dateProvider())] ?? ActivityBarDailyStats(date: dateKey(for: dateProvider()))
    }

    var sortedDateKeys: [String] {
        days.keys.sorted()
    }

    func stats(for date: String) -> ActivityBarDailyStats {
        days[date] ?? ActivityBarDailyStats(date: date)
    }

    func recentDays(count: Int, endingAt endDate: Date? = nil) -> [ActivityBarDailyStats] {
        let end = endDate ?? dateProvider()
        let boundedCount = max(count, 1)

        return (0..<boundedCount).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: end) ?? end
            let key = dateKey(for: date)
            return stats(for: key)
        }
    }

    func incrementKeystroke(app: String) {
        mutateToday(app: app) { day, appStats in
            day.keystrokes += 1
            appStats.keystrokes += 1
        }
    }

    func incrementPointerClick(app: String) {
        mutateToday(app: app) { day, appStats in
            day.pointerClicks += 1
            appStats.pointerClicks += 1
        }
    }

    func incrementScroll(app: String) {
        mutateToday(app: app) { day, appStats in
            day.scrollEvents += 1
            appStats.scrollEvents += 1
        }
    }

    func addScreenTime(_ seconds: TimeInterval, app: String) {
        guard seconds > 0 else {
            return
        }

        mutateToday(app: app) { day, appStats in
            day.screenTimeSeconds += seconds
            appStats.screenTimeSeconds += seconds
        }
    }

    func record(_ event: ActivityBarInputEvent) {
        switch event {
        case let .keystroke(app):
            incrementKeystroke(app: app)
        case let .pointerClick(app):
            incrementPointerClick(app: app)
        case let .scroll(app):
            incrementScroll(app: app)
        case let .screenTime(app, seconds):
            addScreenTime(seconds, app: app)
        }
    }

    func resetToday() {
        days[dateKey(for: dateProvider())] = ActivityBarDailyStats(date: dateKey(for: dateProvider()))
        hasPendingChanges = true
        persistNow()
    }

    func flushPendingChanges() {
        persistNow()
    }

    private func mutateToday(
        app rawApp: String,
        update: (inout ActivityBarDailyStats, inout ActivityBarAppStats) -> Void
    ) {
        let app = sanitizedAppName(rawApp)
        let key = dateKey(for: dateProvider())
        var day = days[key] ?? ActivityBarDailyStats(date: key)
        var appStats = day.perApp[app] ?? ActivityBarAppStats()

        update(&day, &appStats)

        day.perApp[app] = appStats
        days[key] = day
        hasPendingChanges = true
        schedulePersist()
    }

    private func sanitizedAppName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private func dateKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func schedulePersist() {
        guard pendingPersistTask == nil else {
            return
        }

        pendingPersistTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Persistence.debounceDelay)
            } catch {
                return
            }

            self?.persistNow()
        }
    }

    private func persistNow() {
        guard hasPendingChanges else {
            return
        }

        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        days = Self.prunedDays(days)

        do {
            let data = try encoder.encode(days)
            storage.set(data, forKey: StorageKey.days)
            hasPendingChanges = false
        } catch {
            ActivityBarLog.input.error("Failed to persist input stats: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadDays(storage: PluginStorage, decoder: JSONDecoder) -> [String: ActivityBarDailyStats] {
        guard let data = storage.data(forKey: StorageKey.days) else {
            return [:]
        }

        do {
            return try decoder.decode([String: ActivityBarDailyStats].self, from: data)
        } catch {
            ActivityBarLog.input.error("Failed to load input stats: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private static func prunedDays(_ days: [String: ActivityBarDailyStats]) -> [String: ActivityBarDailyStats] {
        guard days.count > Persistence.retainedDayCount else {
            return days
        }

        let retainedKeys = Set(days.keys.sorted().suffix(Persistence.retainedDayCount))
        return days.filter { retainedKeys.contains($0.key) }
    }
}
