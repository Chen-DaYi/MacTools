import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 启动 reconciliation（设计 §7.6）。真实临时目录 + 真实改名。
final class DiskCleanStagingReconcilerTests: XCTestCase {
    private var temporary: DiskCleanTempDirectory!
    private var storage: DiskCleanTempDirectory!
    private var journal: DiskCleanStagingJournal!
    private var auditLog: DiskCleanAuditLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporary = try DiskCleanTempDirectory(name: "diskclean-reconcile")
        storage = try DiskCleanTempDirectory(name: "diskclean-reconcile-state")
        journal = DiskCleanStagingJournal(directory: storage.url)
        auditLog = DiskCleanAuditLog(directory: storage.url)
    }

    override func tearDown() {
        temporary?.remove()
        storage?.remove()
        temporary = nil
        storage = nil
        journal = nil
        auditLog = nil
        super.tearDown()
    }

    /// 崩溃在 rename 之后、完成记录之前 → 孤儿暂存对象改回原名。
    func testOrphanStagedObjectIsRolledBackToOriginalPath() throws {
        let stagedName = DiskCleanRemovalPrimitive.stagedNamePrefix + "orphan"
        try temporary.makeFile("\(stagedName)/a.bin", bytes: 10)
        try journal.begin(entry(stagedName: stagedName, originalName: "Cache"))

        let outcomes = DiskCleanStagingReconciler().reconcile(journal: journal, auditLog: auditLog)

        XCTAssertEqual(outcomes, [.rolledBack(originalPath: temporary.resolve("Cache").path)])
        assertExists(temporary.resolve("Cache/a.bin").path)
        assertMissing(temporary.resolve(stagedName).path)
        XCTAssertTrue(journal.incompleteEntries().isEmpty, "恢复完成即销账")
    }

    /// 崩溃在 rename 之前 → 没有暂存对象，条目直接销账，不留下永久待办。
    func testEntryWithoutStagedObjectIsClosedOut() throws {
        try journal.begin(entry(stagedName: DiskCleanRemovalPrimitive.stagedNamePrefix + "never", originalName: "Cache"))

        let outcomes = DiskCleanStagingReconciler().reconcile(journal: journal, auditLog: auditLog)

        XCTAssertEqual(outcomes, [.absent(stagedName: DiskCleanRemovalPrimitive.stagedNamePrefix + "never")])
        XCTAssertTrue(journal.incompleteEntries().isEmpty)
    }

    func testEntryWithMissingParentDirectoryIsClosedOut() throws {
        let stagedName = DiskCleanRemovalPrimitive.stagedNamePrefix + "gone"
        try journal.begin(
            DiskCleanStagingJournal.Entry(
                id: "gone",
                timestamp: Date(timeIntervalSince1970: 1_000),
                parentPath: temporary.resolve("no-such-parent").path,
                originalName: "Cache",
                stagedName: stagedName,
                mode: DiskCleanRemovalMode.permanent.rawValue
            )
        )

        let outcomes = DiskCleanStagingReconciler().reconcile(journal: journal, auditLog: auditLog)

        XCTAssertEqual(outcomes, [.absent(stagedName: stagedName)])
        XCTAssertTrue(journal.incompleteEntries().isEmpty)
    }

    /// 原路径已被重建 → 绝不覆盖：暂存对象保留，条目保持未完成以便持续提示。
    func testRollbackIsBlockedWhenOriginalPathWasRecreated() throws {
        let stagedName = DiskCleanRemovalPrimitive.stagedNamePrefix + "blocked"
        try temporary.makeFile("\(stagedName)/a.bin", bytes: 10)
        try temporary.makeFile("Cache/rebuilt.bin", bytes: 20)
        try journal.begin(entry(stagedName: stagedName, originalName: "Cache"))

        let outcomes = DiskCleanStagingReconciler().reconcile(journal: journal, auditLog: auditLog)

        XCTAssertEqual(
            outcomes,
            [.blocked(stagedName: stagedName, originalPath: temporary.resolve("Cache").path)]
        )
        assertExists(temporary.resolve("Cache/rebuilt.bin").path, "重建的原路径必须完好")
        assertExists(temporary.resolve("\(stagedName)/a.bin").path, "暂存对象必须保留")
        XCTAssertEqual(
            journal.incompleteEntries().map(\.stagedName),
            [stagedName],
            "未解决的条目要留着，下次启动继续提示"
        )
    }

    func testAuditRecordsEveryOutcome() throws {
        let rolledBack = DiskCleanRemovalPrimitive.stagedNamePrefix + "rolled"
        let blocked = DiskCleanRemovalPrimitive.stagedNamePrefix + "blocked"
        try temporary.makeFile("\(rolledBack)/a.bin", bytes: 10)
        try temporary.makeFile("\(blocked)/a.bin", bytes: 10)
        try temporary.makeDirectory("Occupied")
        try journal.begin(
            entry(id: "one", stagedName: rolledBack, originalName: "Restored", timestamp: Date(timeIntervalSince1970: 1))
        )
        try journal.begin(
            entry(id: "two", stagedName: blocked, originalName: "Occupied", timestamp: Date(timeIntervalSince1970: 2))
        )

        _ = DiskCleanStagingReconciler().reconcile(journal: journal, auditLog: auditLog)

        let statuses = Set(auditLog.recentRecords(limit: 10).map(\.status))
        XCTAssertEqual(statuses, ["reconciledRolledBack", "rollbackBlocked"])
    }

    func testReconcileWithEmptyJournalDoesNothing() {
        let outcomes = DiskCleanStagingReconciler().reconcile(journal: journal, auditLog: auditLog)

        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertTrue(auditLog.recentRecords(limit: 10).isEmpty)
    }

    // MARK: - 夹具

    private func entry(
        id: String = "one",
        stagedName: String,
        originalName: String,
        timestamp: Date = Date(timeIntervalSince1970: 1_000)
    ) -> DiskCleanStagingJournal.Entry {
        DiskCleanStagingJournal.Entry(
            id: id,
            timestamp: timestamp,
            parentPath: temporary.path,
            originalName: originalName,
            stagedName: stagedName,
            mode: DiskCleanRemovalMode.permanent.rawValue
        )
    }

    private func assertExists(_ path: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0, message, file: file, line: line)
    }

    private func assertMissing(_ path: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        var status = stat()
        XCTAssertNotEqual(lstat(path, &status), 0, message, file: file, line: line)
    }
}
