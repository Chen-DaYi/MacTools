import Foundation

/// Deletion audit log (design §7.8).
///
/// Append-only JSONL; rotate to `.1` at 5MB, keep 2 generations (current + one rotated).
/// Log path lives under the plugin support directory, protected by the SafetyPolicy "cleanup tool state" branch.
final class DiskCleanAuditLog: @unchecked Sendable {
    struct Record: Codable, Equatable, Sendable {
        enum Action: String, Codable, Sendable {
            case trash
            case delete
            /// Scan-level events: circuit breakers, thread abandonment, reconciliation results.
            case scanEvent
        }

        let timestamp: Date
        let action: Action
        let targetID: String?
        let legacyRuleID: String?
        let category: String?
        let path: String?
        let stagedName: String?
        let estimatedBytes: Int64?
        /// ok / skipped / failed / partiallyDeleted / rollbackBlocked / reconciled…
        let status: String
        let skipReason: String?
        let error: String?

        init(
            timestamp: Date,
            action: Action,
            targetID: String? = nil,
            legacyRuleID: String? = nil,
            category: String? = nil,
            path: String? = nil,
            stagedName: String? = nil,
            estimatedBytes: Int64? = nil,
            status: String,
            skipReason: String? = nil,
            error: String? = nil
        ) {
            self.timestamp = timestamp
            self.action = action
            self.targetID = targetID
            self.legacyRuleID = legacyRuleID
            self.category = category
            self.path = path
            self.stagedName = stagedName
            self.estimatedBytes = estimatedBytes
            self.status = status
            self.skipReason = skipReason
            self.error = error
        }
    }

    static let fileName = "audit.jsonl"
    static let rotatedFileName = "audit.jsonl.1"
    /// Rotation threshold. Tests may inject a smaller value.
    let maximumFileSizeBytes: Int

    private let directory: URL
    private let fileURL: URL
    private let rotatedFileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Same as `DiskCleanStagingJournal`: init does not touch the filesystem; the directory is created on first write.
    init(directory: URL, maximumFileSizeBytes: Int = 5 * 1024 * 1024) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.rotatedFileURL = directory.appendingPathComponent(Self.rotatedFileName)
        self.maximumFileSizeBytes = maximumFileSizeBytes
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Append one record. Audit failure must not block deletion (best effort), but rotation is decided before the append.
    func append(_ record: Record) {
        lock.lock()
        defer { lock.unlock() }

        rotateIfNeeded()
        guard let data = try? encoder.encode(record) else { return }
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data().write(to: fileURL)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([UInt8(ascii: "\n")]))
        } catch {
            // Audit is observability, not a safety barrier; failure must not block deletion.
        }
    }

    /// Read recent records newest-first (cleanup history UI). Spans the current file and one rotated `.1` generation.
    func recentRecords(limit: Int) -> [Record] {
        lock.lock()
        defer { lock.unlock() }

        var records: [Record] = []
        for url in [fileURL, rotatedFileURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            for lineData in data.split(separator: UInt8(ascii: "\n")) {
                if let record = try? decoder.decode(Record.self, from: Data(lineData)) {
                    records.append(record)
                }
            }
        }
        return Array(records.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    private func rotateIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size >= maximumFileSizeBytes else { return }

        try? FileManager.default.removeItem(at: rotatedFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedFileURL)
    }
}
