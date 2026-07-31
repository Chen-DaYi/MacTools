import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Audit log field completeness and rotation (design §7.8).
final class DiskCleanAuditLogTests: XCTestCase {
    private var storage: DiskCleanTempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try DiskCleanTempDirectory(name: "diskclean-audit")
    }

    override func tearDown() {
        storage?.remove()
        storage = nil
        super.tearDown()
    }

    func testInitDoesNotTouchFileSystem() {
        let untouched = storage.resolve("never-created")

        _ = DiskCleanAuditLog(directory: untouched)

        XCTAssertFalse(FileManager.default.fileExists(atPath: untouched.path))
    }

    func testRecordRoundTripsEveryField() throws {
        let log = DiskCleanAuditLog(directory: storage.url)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        log.append(
            DiskCleanAuditLog.Record(
                timestamp: timestamp,
                action: .delete,
                targetID: "cache.example",
                legacyRuleID: "cache.legacy",
                category: DiskCleanCategoryID.appCaches.rawValue,
                path: "/cache/app",
                stagedName: ".mactools-staged-abc",
                estimatedBytes: 4_096,
                status: "partiallyDeleted",
                skipReason: nil,
                error: "Failed to delete file (Permission denied)"
            )
        )

        let record = try XCTUnwrap(log.recentRecords(limit: 1).first)
        XCTAssertEqual(record.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(record.action, .delete)
        XCTAssertEqual(record.targetID, "cache.example")
        XCTAssertEqual(record.legacyRuleID, "cache.legacy")
        XCTAssertEqual(record.category, "appCaches")
        XCTAssertEqual(record.path, "/cache/app")
        XCTAssertEqual(record.stagedName, ".mactools-staged-abc")
        XCTAssertEqual(record.estimatedBytes, 4_096)
        XCTAssertEqual(record.status, "partiallyDeleted")
        XCTAssertNil(record.skipReason)
        XCTAssertEqual(record.error, "Failed to delete file (Permission denied)")
    }

    func testRecentRecordsAreNewestFirstAndRespectLimit() {
        let log = DiskCleanAuditLog(directory: storage.url)
        for index in 0..<5 {
            log.append(record(status: "ok-\(index)", secondsSinceEpoch: Double(1_000 + index * 10)))
        }

        let records = log.recentRecords(limit: 3)

        XCTAssertEqual(records.map(\.status), ["ok-4", "ok-3", "ok-2"])
    }

    /// Rotate to `.1` when the threshold is hit (tests inject a small value); keep 2 generations.
    func testRotatesAtThresholdAndKeepsTwoGenerations() throws {
        let log = DiskCleanAuditLog(directory: storage.url, maximumFileSizeBytes: 400)

        for index in 0..<12 {
            log.append(record(status: "gen-\(index)", secondsSinceEpoch: Double(1_000 + index)))
        }

        let currentExists = FileManager.default.fileExists(
            atPath: storage.resolve(DiskCleanAuditLog.fileName).path
        )
        let rotatedExists = FileManager.default.fileExists(
            atPath: storage.resolve(DiskCleanAuditLog.rotatedFileName).path
        )
        XCTAssertTrue(currentExists)
        XCTAssertTrue(rotatedExists, "must rotate to .1 once the threshold is exceeded")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: storage.path).sorted(),
            [DiskCleanAuditLog.fileName, DiskCleanAuditLog.rotatedFileName].sorted(),
            "keep only 2 generations; must not pile up .2 / .3"
        )
    }

    /// After rotation, "recent records" must still read across both generations,
    /// otherwise cleanup history would go blank at the rotation boundary.
    ///
    /// Keeping 2 generations means older records are **supposed** to be discarded,
    /// so the assertion is "read content spans beyond the current file",
    /// not "the earliest record is still present".
    func testRecentRecordsSpanRotatedGeneration() throws {
        let log = DiskCleanAuditLog(directory: storage.url, maximumFileSizeBytes: 400)
        for index in 0..<12 {
            log.append(record(status: "gen-\(index)", secondsSinceEpoch: Double(1_000 + index)))
        }

        let statuses = log.recentRecords(limit: 50).map(\.status)
        let currentGeneration = try String(
            contentsOf: storage.resolve(DiskCleanAuditLog.fileName),
            encoding: .utf8
        )

        XCTAssertEqual(statuses.first, "gen-11", "newest record comes first")
        XCTAssertTrue(
            statuses.contains { !currentGeneration.contains("\"status\":\"\($0)\"") },
            "the generation rotated to .1 must still be readable, or history would go blank at rotation"
        )
        let indices = statuses.compactMap { Int($0.dropFirst("gen-".count)) }
        XCTAssertEqual(indices, indices.sorted(by: >), "merged generations must remain reverse-chronological")
    }

    private func record(status: String, secondsSinceEpoch: Double) -> DiskCleanAuditLog.Record {
        DiskCleanAuditLog.Record(
            timestamp: Date(timeIntervalSince1970: secondsSinceEpoch),
            action: .trash,
            targetID: "cache.example",
            path: "/cache/app",
            estimatedBytes: 1,
            status: status
        )
    }
}
