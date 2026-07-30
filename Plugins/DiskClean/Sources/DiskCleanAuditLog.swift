import Foundation

/// 删除审计日志（设计 §7.8）。
///
/// 追加式 JSONL；单文件上限 5MB，满则轮转为 `.1`，保留 2 代（当前 + 1）。
/// 日志路径位于插件支持目录，受 SafetyPolicy "cleanup tool state" 分支保护。
final class DiskCleanAuditLog: @unchecked Sendable {
    struct Record: Codable, Equatable, Sendable {
        enum Action: String, Codable, Sendable {
            case trash
            case delete
            /// 扫描级事件：熔断、线程放弃、reconciliation 结果。
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
    /// 轮转阈值。测试可注入更小的值。
    let maximumFileSizeBytes: Int

    private let directory: URL
    private let fileURL: URL
    private let rotatedFileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// 与 `DiskCleanStagingJournal` 同理：init 不碰文件系统，目录首次写入时才创建。
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

    /// 追加一条记录。审计失败不阻塞删除流程（best effort），但轮转判定在追加前完成。
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
            // 审计是可观测性，不是安全防线；失败不阻塞删除。
        }
    }

    /// 倒序读取最近记录（清理历史 UI 用）。跨当前文件与 `.1` 一代。
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
