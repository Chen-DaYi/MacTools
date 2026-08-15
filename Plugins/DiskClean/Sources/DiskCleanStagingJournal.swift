import Darwin
import Foundation

/// Staging transaction journal (design §7.6).
///
/// **Write-order invariant: rename is allowed only after `begin` is durable and fsynced.**
/// If the process crashes after rename but before the completion record, startup
/// reconciliation uses the journal to recover orphan staged objects. Reversing the
/// order yields "unrecorded `.mactools-staged-*`" — SafetyPolicy would still protect
/// it from the scan pipeline, but nobody knows the original name, so user data is
/// effectively lost.
final class DiskCleanStagingJournal: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let timestamp: Date
        /// Physical path of the parent directory.
        let parentPath: String
        let originalName: String
        let stagedName: String
        let mode: DiskCleanRemovalMode.RawValue
    }

    enum RecordKind: String, Codable, Sendable {
        case begin
        case irreversible
        case end
    }

    enum RecoveryPhase: Equatable, Sendable {
        case rollbackEligible
        case irreversible
    }

    struct PendingEntry: Equatable, Sendable {
        let entry: Entry
        let phase: RecoveryPhase
    }

    /// Journal line. Transaction phases share one file and are distinguished by `kind`.
    private struct Line: Codable {
        let kind: RecordKind
        let entry: Entry?
        let entryID: String?
        let status: String?
        let timestamp: Date
    }

    static let fileName = "staging-journal.jsonl"

    let directory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let directorySynchronizer: @Sendable (URL) throws -> Void
    private let beforeAppend: @Sendable (RecordKind) throws -> Void
    /// Entry IDs currently owned by a live cleanup transaction in this process.
    /// Startup reconciliation must not compact these away between begin and complete.
    private var activeEntryIDs: Set<String> = []

    /// **Do not touch the filesystem in init**: a default-constructed plugin (including
    /// in tests) would create `~/Library/Application Support/...`, a real user directory.
    /// Create the directory on first write instead.
    init(
        directory: URL,
        directorySynchronizer: @escaping @Sendable (URL) throws -> Void = DiskCleanStagingJournal.synchronizeDirectory,
        beforeAppend: @escaping @Sendable (RecordKind) throws -> Void = { _ in }
    ) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.directorySynchronizer = directorySynchronizer
        self.beforeAppend = beforeAppend
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Durably record that mutation of the staged object is about to become irreversible.
    /// Recursive deletion must not start unless this write and fsync succeed.
    func markIrreversible(entryID: String, at timestamp: Date = Date()) throws {
        try append(
            Line(kind: .irreversible, entry: nil, entryID: entryID, status: nil, timestamp: timestamp),
            synchronize: true
        )
    }

    /// Record staging begin. **Must be called and succeed before rename**; fsync after write.
    /// Marks the entry active so concurrent reconciliation will not compact it away.
    func begin(_ entry: Entry) throws {
        lock.lock()
        activeEntryIDs.insert(entry.id)
        lock.unlock()
        do {
            try append(
                Line(kind: .begin, entry: entry, entryID: nil, status: nil, timestamp: entry.timestamp),
                synchronize: true
            )
        } catch {
            lock.lock()
            activeEntryIDs.remove(entry.id)
            lock.unlock()
            throw error
        }
    }

    /// Record staging disposition complete (deleted / rolled back / partiallyDeleted, etc.).
    func complete(entryID: String, status: String, at timestamp: Date = Date()) {
        try? append(
            Line(kind: .end, entry: nil, entryID: entryID, status: status, timestamp: timestamp),
            synchronize: true
        )
        releaseActive(entryID: entryID)
    }

    /// Drop the in-process active mark without writing a completion record.
    ///
    /// Used when the transaction ends but the journal entry must stay incomplete
    /// (`rollbackBlocked`): the current process no longer owns the rename, so
    /// reconciliation (same process or next launch) must be allowed to see it.
    func releaseActive(entryID: String) {
        lock.lock()
        activeEntryIDs.remove(entryID)
        lock.unlock()
    }

    /// Unfinished entries: have begin, no end. Includes live in-process transactions.
    func incompleteEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return incompleteEntriesLocked()
    }

    /// Unfinished entries that are safe for startup reconciliation to touch.
    /// Excludes IDs owned by a live cleanup transaction so compact cannot erase an in-flight begin.
    func incompleteEntriesForReconciliation() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return incompleteTransactionsLocked()
            .filter { !activeEntryIDs.contains($0.entry.id) }
            .map(\.entry)
    }

    /// Unfinished transactions plus their durable recovery phase.
    func pendingEntriesForReconciliation() -> [PendingEntry] {
        lock.lock()
        defer { lock.unlock() }
        return incompleteTransactionsLocked().filter { !activeEntryIDs.contains($0.entry.id) }
    }

    /// Precondition: `lock` is already held.
    private func incompleteEntriesLocked() -> [Entry] {
        incompleteTransactionsLocked().map(\.entry)
    }

    /// Precondition: `lock` is already held.
    private func incompleteTransactionsLocked() -> [PendingEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var beginsByID: [String: Entry] = [:]
        var irreversibleIDs: Set<String> = []
        var completedIDs: Set<String> = []

        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard let line = try? decoder.decode(Line.self, from: Data(lineData)) else {
                // Partial line (crash mid-write) or corrupt line: skip. A corrupt begin means
                // rename has not happened yet (write-order invariant), so we do not miss orphans.
                continue
            }
            switch line.kind {
            case .begin:
                if let entry = line.entry {
                    beginsByID[entry.id] = entry
                }
            case .irreversible:
                if let entryID = line.entryID {
                    irreversibleIDs.insert(entryID)
                }
            case .end:
                if let entryID = line.entryID {
                    completedIDs.insert(entryID)
                }
            }
        }

        return beginsByID
            .filter { !completedIDs.contains($0.key) }
            .map { id, entry in
                PendingEntry(
                    entry: entry,
                    phase: irreversibleIDs.contains(id) ? .irreversible : .rollbackEligible
                )
            }
            .sorted { $0.entry.timestamp < $1.entry.timestamp }
    }

    /// Compact: keep unfinished entries (including live in-process transactions).
    /// Called at reconciliation wrap-up to stop unbounded journal growth.
    func compact() throws {
        lock.lock()
        defer { lock.unlock() }
        let remaining = incompleteTransactionsLocked()

        guard FileManager.default.fileExists(atPath: fileURL.path) || !remaining.isEmpty else {
            return
        }

        var data = Data()
        for pending in remaining {
            let entry = pending.entry
            let line = Line(kind: .begin, entry: entry, entryID: nil, status: nil, timestamp: entry.timestamp)
            let encoded = try encoder.encode(line)
            data.append(encoded)
            data.append(UInt8(ascii: "\n"))
            if pending.phase == .irreversible {
                let phaseLine = Line(
                    kind: .irreversible,
                    entry: nil,
                    entryID: entry.id,
                    status: nil,
                    timestamp: entry.timestamp
                )
                data.append(try encoder.encode(phaseLine))
                data.append(UInt8(ascii: "\n"))
            }
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString.lowercased()).tmp")
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw Self.posixError(path: temporaryURL.path)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            close(descriptor)
            if shouldRemoveTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
        try Self.writeAll(data, to: descriptor, path: temporaryURL.path)
        guard fsync(descriptor) == 0 else {
            throw Self.posixError(path: temporaryURL.path)
        }
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw Self.posixError(path: fileURL.path)
        }
        shouldRemoveTemporaryFile = false
        try directorySynchronizer(directory)
    }

    private func append(_ line: Line, synchronize: Bool) throws {
        lock.lock()
        defer { lock.unlock() }

        try beforeAppend(line.kind)
        let data = try encoder.encode(line) + Data([UInt8(ascii: "\n")])
        var didCreateFile = false
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: fileURL)
            didCreateFile = true
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        if synchronize {
            // fsync semantics: begin must be durable before rename (§7.6 invariant).
            try handle.synchronize()
            if didCreateFile {
                // File contents on disk do not imply the **directory entry** is durable.
                // When the first begin also creates the journal, skipping this step can leave
                // "staged object present, journal file entirely missing" after a crash.
                try directorySynchronizer(directory)
            }
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw posixError(path: directory.path)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw posixError(path: directory.path)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw posixError(path: path)
                }
            }
        }
    }

    private static func posixError(path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: path]
        )
    }
}
