import Foundation

enum AutomaticPreferencesBackupWriteResult: Equatable, Sendable {
    case created(URL)
    case unchanged(URL?)
}

struct AutomaticPreferencesBackupRecord: Equatable, Sendable {
    let url: URL
    let date: Date
    let size: Int
}

/// Thread-safe filesystem store used from detached tasks during normal app use
/// and synchronously for the narrow pre-import and termination safety paths.
final class AutomaticPreferencesBackupStore: @unchecked Sendable {
    static let maximumSnapshotCount = 100
    static let maximumTotalSize = 128 * 1024 * 1024

    private static let filePrefix = "MacTools-Automatic-Backup-"
    private let directoryURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        directoryURL: URL = AutomaticPreferencesBackupStore.defaultDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("MacTools", isDirectory: true)
            .appendingPathComponent("Automatic Backups", isDirectory: true)
    }

    func prepareDirectory() throws -> URL {
        try withLock {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            return directoryURL
        }
    }

    func write(_ backup: PreferencesBackup, now: Date = .now) throws -> AutomaticPreferencesBackupWriteResult {
        let data = try backup.encodedJSON()
        _ = try PreferencesBackup.decodeJSON(data)

        return try withLock {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let existingRecords = try records()
            if let latest = existingRecords.max(by: { $0.date < $1.date }),
               let latestData = try? boundedData(contentsOf: latest.url),
               let latestBackup = try? PreferencesBackup.decodeJSON(latestData),
               latestBackup.hasSameMeaningfulContent(as: backup) {
                try rotate(existingRecords, now: now)
                return .unchanged(latest.url)
            }

            let url = directoryURL.appendingPathComponent(
                Self.makeFileName(date: now),
                isDirectory: false
            )
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: url.path
            )

            var updatedRecords = existingRecords
            updatedRecords.append(
                AutomaticPreferencesBackupRecord(url: url, date: now, size: data.count)
            )
            try rotate(updatedRecords, now: now)
            return .created(url)
        }
    }

    static func retainedRecords(
        from records: [AutomaticPreferencesBackupRecord],
        now: Date,
        maximumCount: Int = maximumSnapshotCount,
        maximumTotalSize: Int = maximumTotalSize
    ) -> [AutomaticPreferencesBackupRecord] {
        precondition(maximumCount > 0)
        precondition(maximumTotalSize > 0)

        let sorted = records.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.url.path < rhs.url.path }
            return lhs.date > rhs.date
        }
        var hourlyBuckets = Set<Date>()
        var dailyBuckets = Set<Date>()
        var weeklyBuckets = Set<String>()
        var retained: [AutomaticPreferencesBackupRecord] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        for record in sorted {
            let age = max(0, now.timeIntervalSince(record.date))
            if age < 60 * 60 {
                retained.append(record)
            } else if age < 24 * 60 * 60 {
                let bucket = calendar.dateInterval(of: .hour, for: record.date)?.start
                    ?? record.date
                if hourlyBuckets.insert(bucket).inserted {
                    retained.append(record)
                }
            } else if age < 30 * 24 * 60 * 60 {
                let bucket = calendar.startOfDay(for: record.date)
                if dailyBuckets.insert(bucket).inserted {
                    retained.append(record)
                }
            } else {
                let components = calendar.dateComponents(
                    [.yearForWeekOfYear, .weekOfYear],
                    from: record.date
                )
                let bucket = "\(components.yearForWeekOfYear ?? 0)-\(components.weekOfYear ?? 0)"
                if weeklyBuckets.insert(bucket).inserted {
                    retained.append(record)
                }
            }
        }

        if retained.count > maximumCount {
            retained.removeLast(retained.count - maximumCount)
        }
        var totalSize = retained.reduce(0) { $0 + max(0, $1.size) }
        while retained.count > 1, totalSize > maximumTotalSize {
            totalSize -= max(0, retained.removeLast().size)
        }
        return retained
    }

    private func records() throws -> [AutomaticPreferencesBackupRecord] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  url.lastPathComponent.hasPrefix(Self.filePrefix),
                  let values = try? url.resourceValues(forKeys: [
                      .contentModificationDateKey,
                      .fileSizeKey,
                  ]),
                  let date = values.contentModificationDate,
                  let size = values.fileSize
            else {
                return nil
            }
            return AutomaticPreferencesBackupRecord(url: url, date: date, size: size)
        }
    }

    private func rotate(_ records: [AutomaticPreferencesBackupRecord], now: Date) throws {
        let retainedURLs = Set(Self.retainedRecords(from: records, now: now).map(\.url))
        for record in records where !retainedURLs.contains(record.url) {
            try fileManager.removeItem(at: record.url)
        }
    }

    private func boundedData(contentsOf url: URL) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= PreferencesBackup.maximumFileSize else {
            throw PreferencesBackupError.fileTooLarge(
                maximumBytes: PreferencesBackup.maximumFileSize
            )
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func makeFileName(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return "\(filePrefix)\(timestamp)-\(UUID().uuidString).json"
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

@MainActor
final class AutomaticPreferencesBackupCoordinator {
    static let enabledUserDefaultsKey = "preferencesBackup.automatic.enabled"

    private let userDefaults: UserDefaults
    private let store: AutomaticPreferencesBackupStore
    private let debounceDelay: Duration
    private var pendingTask: Task<Void, Never>?
    private var lastObservedSnapshot: PreferencesBackup?

    var snapshotProvider: (() -> PreferencesBackup?)? {
        didSet {
            lastObservedSnapshot = snapshotProvider?()
        }
    }
    var failureHandler: ((Error) -> Void)?
    private(set) var isEnabled: Bool

    init(
        userDefaults: UserDefaults,
        store: AutomaticPreferencesBackupStore = AutomaticPreferencesBackupStore(),
        debounceDelay: Duration = .seconds(60)
    ) {
        self.userDefaults = userDefaults
        self.store = store
        self.debounceDelay = debounceDelay
        isEnabled = userDefaults.object(forKey: Self.enabledUserDefaultsKey) == nil
            ? true
            : userDefaults.bool(forKey: Self.enabledUserDefaultsKey)
    }

    deinit {
        pendingTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        userDefaults.set(enabled, forKey: Self.enabledUserDefaultsKey)
        if enabled {
            persistentPreferencesDidChange()
        } else {
            pendingTask?.cancel()
            pendingTask = nil
        }
    }

    func persistentPreferencesDidChange() {
        guard isEnabled, let snapshot = snapshotProvider?() else { return }
        guard lastObservedSnapshot?.hasSameMeaningfulContent(as: snapshot) != true else {
            return
        }
        lastObservedSnapshot = snapshot
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounceDelay)
                guard !Task.isCancelled else { return }
                _ = try await createBackupNow()
            } catch is CancellationError {
                return
            } catch {
                failureHandler?(error)
            }
        }
    }

    func createBackupNow() async throws -> AutomaticPreferencesBackupWriteResult {
        pendingTask?.cancel()
        pendingTask = nil
        guard let backup = snapshotProvider?() else {
            throw CocoaError(.fileNoSuchFile)
        }
        lastObservedSnapshot = backup
        let result = try await Task.detached(priority: .utility) { [store] in
            try store.write(backup)
        }.value
        return result
    }

    func prepareBackupDirectory() throws -> URL {
        try store.prepareDirectory()
    }

    /// Imports are synchronous at the mutation point, so the safety snapshot
    /// must complete before any existing preference is replaced.
    func createSafetySnapshotBeforeImport() throws {
        pendingTask?.cancel()
        pendingTask = nil
        guard let backup = snapshotProvider?() else { return }
        lastObservedSnapshot = backup
        _ = try store.write(backup)
    }

    /// AppKit termination does not await asynchronous work. This is the one
    /// shutdown path where the pending snapshot is intentionally flushed inline.
    func flushPendingBackupBeforeTermination() {
        guard isEnabled else { return }
        pendingTask?.cancel()
        pendingTask = nil
        guard let backup = snapshotProvider?() else { return }
        lastObservedSnapshot = backup
        do {
            _ = try store.write(backup)
        } catch {
            failureHandler?(error)
        }
    }
}
