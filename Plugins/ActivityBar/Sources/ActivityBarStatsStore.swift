import Foundation
import MacToolsPluginKit

enum ActivityBarPersistenceMutationResult: Equatable {
    case committed
    case rejected(rollbackSucceeded: Bool)
    case recoveryRequired
}

func activityBarStorageValuesMatch(_ lhs: Any?, _ rhs: Any?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (lhs as NSObject, rhs as NSObject):
        return lhs.isEqual(rhs)
    default:
        return false
    }
}

@MainActor
func restoreActivityBarStorageValue(
    _ value: Any?,
    forKey key: String,
    storage: PluginStorage
) -> Bool {
    if let value {
        storage.set(value, forKey: key)
    } else {
        storage.removeObject(forKey: key)
    }
    return activityBarStorageValuesMatch(storage.object(forKey: key), value)
}

@MainActor
final class ActivityBarStatsStore: ObservableObject {
    private enum StorageKey {
        static let days = "activity-bar.input.days.v1"
    }

    // Direct observers receive every input mutation and bypass controller-level
    // UI throttling; keep hot-path UI subscriptions on ActivityBarController.
    @Published private(set) var days: [String: ActivityBarDailyStats]
    private(set) var loadError: String?

    private let storage: PluginStorage
    private let calendar: Calendar
    private let dateProvider: () -> Date
    private let persistenceDelay: Duration
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var persistenceTask: Task<Void, Never>?
    private var hasPendingChanges = false

    private enum Persistence {
        static let debounceDelay: Duration = .seconds(30)
        static let retainedDayCount = 370
    }

    init(
        storage: PluginStorage,
        calendar: Calendar = .current,
        dateProvider: @escaping () -> Date = Date.init,
        persistenceDelay: Duration = Persistence.debounceDelay
    ) {
        self.storage = storage
        self.calendar = calendar
        self.dateProvider = dateProvider
        self.persistenceDelay = persistenceDelay
        let loaded = Self.loadDays(storage: storage, decoder: decoder)
        self.days = Self.prunedDays(loaded.days)
        self.loadError = loaded.error
    }

    deinit {
        persistenceTask?.cancel()
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

    struct PreparedTodayReset {
        fileprivate let previousDays: [String: ActivityBarDailyStats]
        fileprivate let previousRawValue: Any?
        fileprivate let previousHadPendingChanges: Bool
        fileprivate let candidateDays: [String: ActivityBarDailyStats]
        fileprivate let candidateData: Data
    }

    func prepareTodayReset() -> PreparedTodayReset? {
        guard loadError == nil else { return nil }
        var candidateDays = days
        let key = dateKey(for: dateProvider())
        candidateDays[key] = ActivityBarDailyStats(date: key)
        candidateDays = Self.prunedDays(candidateDays)
        guard let candidateData = try? encoder.encode(candidateDays) else { return nil }
        return PreparedTodayReset(
            previousDays: days,
            previousRawValue: storage.object(forKey: StorageKey.days),
            previousHadPendingChanges: hasPendingChanges,
            candidateDays: candidateDays,
            candidateData: candidateData
        )
    }

    @discardableResult
    func commitTodayReset(_ prepared: PreparedTodayReset) -> ActivityBarPersistenceMutationResult {
        storage.set(prepared.candidateData, forKey: StorageKey.days)
        guard activityBarStorageValuesMatch(storage.object(forKey: StorageKey.days), prepared.candidateData) else {
            let rollbackSucceeded = restoreActivityBarStorageValue(
                prepared.previousRawValue,
                forKey: StorageKey.days,
                storage: storage
            )
            if !rollbackSucceeded {
                reloadFromStorage()
            }
            return .rejected(rollbackSucceeded: rollbackSucceeded)
        }

        persistenceTask?.cancel()
        persistenceTask = nil
        days = prepared.candidateDays
        hasPendingChanges = false
        loadError = nil
        return .committed
    }

    @discardableResult
    func rollbackTodayReset(_ prepared: PreparedTodayReset) -> Bool {
        let succeeded = restoreActivityBarStorageValue(
            prepared.previousRawValue,
            forKey: StorageKey.days,
            storage: storage
        )
        guard succeeded else {
            reloadFromStorage()
            return false
        }

        days = prepared.previousDays
        hasPendingChanges = prepared.previousHadPendingChanges
        loadError = nil
        if hasPendingChanges {
            schedulePersistence()
        }
        return true
    }

    @discardableResult
    func resetToday() -> ActivityBarPersistenceMutationResult {
        guard let prepared = prepareTodayReset() else { return .recoveryRequired }
        return commitTodayReset(prepared)
    }

    func flushPendingChanges() {
        persistPendingChanges()
    }

    private func mutateToday(
        app rawApp: String,
        update: (inout ActivityBarDailyStats, inout ActivityBarAppStats) -> Void
    ) {
        guard loadError == nil else { return }
        let app = sanitizedAppName(rawApp)
        let key = dateKey(for: dateProvider())
        var day = days[key] ?? ActivityBarDailyStats(date: key)
        var appStats = day.perApp[app] ?? ActivityBarAppStats()

        update(&day, &appStats)

        day.perApp[app] = appStats
        days[key] = day
        hasPendingChanges = true
        schedulePersistence()
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

    private func schedulePersistence() {
        guard persistenceTask == nil else {
            return
        }

        persistenceTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: self.persistenceDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self.persistPendingChanges()
        }
    }

    private func persistPendingChanges(force: Bool = false) {
        persistenceTask?.cancel()
        persistenceTask = nil

        guard loadError == nil else { return }
        guard force || hasPendingChanges else {
            return
        }

        days = Self.prunedDays(days)

        do {
            let data = try encoder.encode(days)
            storage.set(data, forKey: StorageKey.days)
            hasPendingChanges = false
        } catch {
            ActivityBarLog.input.error("Failed to persist input stats: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reloadFromStorage() {
        let loaded = Self.loadDays(storage: storage, decoder: decoder)
        days = Self.prunedDays(loaded.days)
        loadError = loaded.error
        hasPendingChanges = false
        persistenceTask?.cancel()
        persistenceTask = nil
    }

    private static func loadDays(
        storage: PluginStorage,
        decoder: JSONDecoder
    ) -> (days: [String: ActivityBarDailyStats], error: String?) {
        guard let rawValue = storage.object(forKey: StorageKey.days) else {
            return ([:], nil)
        }
        guard let data = rawValue as? Data else {
            let message = "Stored input statistics have an invalid format."
            ActivityBarLog.input.error("\(message, privacy: .public)")
            return ([:], message)
        }

        do {
            return (try decoder.decode([String: ActivityBarDailyStats].self, from: data), nil)
        } catch {
            ActivityBarLog.input.error("Failed to load input stats: \(error.localizedDescription, privacy: .public)")
            return ([:], error.localizedDescription)
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
