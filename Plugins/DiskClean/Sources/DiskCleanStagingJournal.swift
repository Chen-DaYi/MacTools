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

    /// Journal line. Begin and completion share one file and are distinguished by `kind`.
    private struct Line: Codable {
        enum Kind: String, Codable {
            case begin
            case end
        }

        let kind: Kind
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
    /// Entry IDs currently owned by a live cleanup transaction in this process.
    /// Startup reconciliation must not compact these away between begin and complete.
    private var activeEntryIDs: Set<String> = []

    /// **Do not touch the filesystem in init**: a default-constructed plugin (including
    /// in tests) would create `~/Library/Application Support/...`, a real user directory.
    /// Create the directory on first write instead.
    init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
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
        return incompleteEntriesLocked().filter { !activeEntryIDs.contains($0.id) }
    }

    /// Precondition: `lock` is already held.
    private func incompleteEntriesLocked() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var beginsByID: [String: Entry] = [:]
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
            case .end:
                if let entryID = line.entryID {
                    completedIDs.insert(entryID)
                }
            }
        }

        return beginsByID
            .filter { !completedIDs.contains($0.key) }
            .values
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Compact: keep unfinished entries (including live in-process transactions).
    /// Called at reconciliation wrap-up to stop unbounded journal growth.
    func compact() {
        lock.lock()
        defer { lock.unlock() }
        let remaining = incompleteEntriesLocked()

        var data = Data()
        for entry in remaining {
            let line = Line(kind: .begin, entry: entry, entryID: nil, status: nil, timestamp: entry.timestamp)
            guard let encoded = try? encoder.encode(line) else { continue }
            data.append(encoded)
            data.append(UInt8(ascii: "\n"))
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func append(_ line: Line, synchronize: Bool) throws {
        lock.lock()
        defer { lock.unlock() }

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
                synchronizeDirectory()
            }
        }
    }

    private func synchronizeDirectory() {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        fsync(descriptor)
    }
}
