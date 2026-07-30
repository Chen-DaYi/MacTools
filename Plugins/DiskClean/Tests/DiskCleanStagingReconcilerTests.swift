import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Startup reconciliation (design §7.6). Real temp directories + real renames.
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

    /// Crash after rename, before completion record → orphan staged object renamed back.
    func testOrphanStagedObjectIsRolledBackToOriginalPath() throws {
        let stagedName = DiskCleanRemovalPrimitive.stagedNamePrefix + "orphan"
        try temporary.makeFile("\(stagedName)/a.bin", bytes: 10)
        try journal.begin(entry(stagedName: stagedName, originalName: "Cache"))

        let outcomes = DiskCleanStagingReconciler().reconcile(journal: journal, auditLog: auditLog)

        XCTAssertEqual(outcomes, [.rolledBack(originalPath: temporary.resolve("Cache").path)])
        assertExists(temporary.resolve("Cache/a.bin").path)
        assertMissing(temporary.resolve(stagedName).path)
        XCTAssertTrue(journal.incompleteEntries().isEmpty, "successful restore clears the journal")
    }

    /// Crash before rename → no staged object; clear the entry with no permanent backlog.
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

    /// Original path was recreated → never overwrite: keep the staged object and leave the entry incomplete for continued prompting.
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
        assertExists(temporary.resolve("Cache/rebuilt.bin").path, "recreated original path must stay intact")
        assertExists(temporary.resolve("\(stagedName)/a.bin").path, "staged object must be retained")
        XCTAssertEqual(
            journal.incompleteEntries().map(\.stagedName),
            [stagedName],
            "unresolved entries must remain so the next launch keeps prompting"
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

    // MARK: - Fixtures

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
