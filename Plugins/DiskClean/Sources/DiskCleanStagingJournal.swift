import Darwin
import Foundation

/// 暂存事务 journal（设计 §7.6）。
///
/// **写入顺序铁律：`begin` 落盘并 fsync 之后才允许 rename。** 进程若在 rename 后、
/// 完成记录前崩溃，启动 reconciliation 靠 journal 找回孤儿暂存对象；顺序反过来
/// 就会出现"无记录的 `.mactools-staged-*`"——SafetyPolicy 会保护它不被扫描收走，
/// 但没人知道它的原名，用户数据事实上失踪。
final class DiskCleanStagingJournal: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let timestamp: Date
        /// 父目录物理路径。
        let parentPath: String
        let originalName: String
        let stagedName: String
        let mode: DiskCleanRemovalMode.RawValue
    }

    /// journal 行。begin 与 completion 共用一个文件，按 `kind` 区分。
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

    private let directory: URL
    private let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// **不在 init 里碰文件系统**：默认构造的插件（含测试里的插件）会连带建出
    /// `~/Library/Application Support/...`，那是真实用户目录。目录改为首次写入时创建。
    init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// 记录暂存开始。**必须在 rename 之前调用且成功返回**；写入后 fsync。
    func begin(_ entry: Entry) throws {
        try append(
            Line(kind: .begin, entry: entry, entryID: nil, status: nil, timestamp: entry.timestamp),
            synchronize: true
        )
    }

    /// 记录暂存处置完成（删除成功 / 已回滚 / partiallyDeleted 等）。
    func complete(entryID: String, status: String, at timestamp: Date = Date()) {
        try? append(
            Line(kind: .end, entry: nil, entryID: entryID, status: status, timestamp: timestamp),
            synchronize: true
        )
    }

    /// 未完成条目：有 begin、无 end。启动 reconciliation 的输入。
    func incompleteEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return incompleteEntriesLocked()
    }

    /// 前置条件：已持有 `lock`。
    private func incompleteEntriesLocked() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var beginsByID: [String: Entry] = [:]
        var completedIDs: Set<String> = []

        for lineData in data.split(separator: UInt8(ascii: "\n")) {
            guard let line = try? decoder.decode(Line.self, from: Data(lineData)) else {
                // 半行（崩溃时写到一半）或损坏行：跳过。begin 损坏意味着 rename 尚未发生
                //（顺序铁律），不会因此漏掉孤儿。
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

    /// 压实：只保留仍未完成的条目。reconciliation 收尾时调用，防 journal 无限增长。
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
            // fsync 语义：rename 之前 begin 必须真正在盘上（§7.6 铁律）。
            try handle.synchronize()
            if didCreateFile {
                // 文件内容落盘不代表**目录项**落盘。第一条 begin 恰好创建 journal 时，
                // 少了这一步就可能出现"暂存对象在、journal 文件整个不在"的崩溃后状态。
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
