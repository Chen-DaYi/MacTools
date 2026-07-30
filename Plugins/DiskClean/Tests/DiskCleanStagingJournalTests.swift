import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 暂存 journal 与崩溃点矩阵（设计 §7.6）。
final class DiskCleanStagingJournalTests: XCTestCase {
    private var storage: DiskCleanTempDirectory!
    private var journal: DiskCleanStagingJournal!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try DiskCleanTempDirectory(name: "diskclean-journal")
        journal = DiskCleanStagingJournal(directory: storage.url)
    }

    override func tearDown() {
        storage?.remove()
        storage = nil
        journal = nil
        super.tearDown()
    }

    func testInitDoesNotTouchFileSystem() throws {
        let untouched = storage.resolve("never-created")

        _ = DiskCleanStagingJournal(directory: untouched)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: untouched.path),
            "构造 journal 不得建目录：默认构造的插件会连带在真实用户目录里建出状态目录"
        )
    }

    /// 崩溃点一：begin 已落盘、rename 尚未发生或已发生但完成记录没写 → 条目未完成。
    func testEntryWithoutCompletionIsIncomplete() throws {
        let entry = makeEntry(id: "one")

        try journal.begin(entry)

        XCTAssertEqual(journal.incompleteEntries(), [entry])
    }

    /// 崩溃点二：完成记录已落盘 → 条目销账，reconciliation 不会再碰它。
    func testCompletedEntryIsNotIncomplete() throws {
        let entry = makeEntry(id: "one")
        try journal.begin(entry)

        journal.complete(entryID: entry.id, status: "removed")

        XCTAssertTrue(journal.incompleteEntries().isEmpty)
    }

    func testOnlyUncompletedEntriesRemainAndAreSortedByTimestamp() throws {
        let first = makeEntry(id: "first", timestamp: Date(timeIntervalSince1970: 100))
        let second = makeEntry(id: "second", timestamp: Date(timeIntervalSince1970: 300))
        let third = makeEntry(id: "third", timestamp: Date(timeIntervalSince1970: 200))
        try journal.begin(first)
        try journal.begin(second)
        try journal.begin(third)

        journal.complete(entryID: second.id, status: "trashed")

        XCTAssertEqual(journal.incompleteEntries().map(\.id), ["first", "third"])
    }

    /// 崩溃时最后一行可能只写了一半。半行必须被跳过，且不影响其它条目。
    func testTruncatedTrailingLineIsTolerated() throws {
        let entry = makeEntry(id: "one")
        try journal.begin(entry)
        let fileURL = storage.resolve(DiskCleanStagingJournal.fileName)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"kind":"begin","entry":{"id":"tr"#.utf8))
        try handle.close()

        XCTAssertEqual(
            journal.incompleteEntries(),
            [entry],
            "半行只能丢掉它自己。写入顺序铁律保证：begin 没落全 = rename 还没发生 = 没有孤儿"
        )
    }

    func testCorruptedMiddleLineIsSkipped() throws {
        let first = makeEntry(id: "first", timestamp: Date(timeIntervalSince1970: 100))
        let second = makeEntry(id: "second", timestamp: Date(timeIntervalSince1970: 200))
        try journal.begin(first)
        let fileURL = storage.resolve(DiskCleanStagingJournal.fileName)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json at all\n".utf8))
        try handle.close()
        try journal.begin(second)

        XCTAssertEqual(journal.incompleteEntries().map(\.id), ["first", "second"])
    }

    func testCompactKeepsOnlyIncompleteEntries() throws {
        let done = makeEntry(id: "done")
        let pending = makeEntry(id: "pending")
        try journal.begin(done)
        try journal.begin(pending)
        journal.complete(entryID: done.id, status: "removed")

        journal.compact()

        XCTAssertEqual(journal.incompleteEntries(), [pending])
        let contents = try String(contentsOf: storage.resolve(DiskCleanStagingJournal.fileName), encoding: .utf8)
        XCTAssertFalse(contents.contains("done"), "压实后已完成的条目不该继续占地方")
        XCTAssertEqual(contents.split(separator: "\n").count, 1)
    }

    func testCompactOnEmptyJournalLeavesNothingIncomplete() throws {
        let entry = makeEntry(id: "one")
        try journal.begin(entry)
        journal.complete(entryID: entry.id, status: "removed")

        journal.compact()

        XCTAssertTrue(journal.incompleteEntries().isEmpty)
    }

    func testIncompleteEntriesOnMissingFileIsEmpty() {
        let fresh = DiskCleanStagingJournal(directory: storage.resolve("absent"))

        XCTAssertTrue(fresh.incompleteEntries().isEmpty)
    }

    func testBeginThrowsWhenDirectoryPathIsOccupiedByFile() throws {
        try storage.makeFile("occupied", bytes: 1)
        let blocked = DiskCleanStagingJournal(directory: storage.resolve("occupied"))

        XCTAssertThrowsError(
            try blocked.begin(makeEntry(id: "one")),
            "写不进 journal 必须抛错——调用方据此放弃改名"
        )
    }

    private func makeEntry(
        id: String,
        timestamp: Date = Date(timeIntervalSince1970: 1_000)
    ) -> DiskCleanStagingJournal.Entry {
        DiskCleanStagingJournal.Entry(
            id: id,
            timestamp: timestamp,
            parentPath: "/cache",
            originalName: "app",
            stagedName: ".mactools-staged-\(id)",
            mode: DiskCleanRemovalMode.permanent.rawValue
        )
    }
}
