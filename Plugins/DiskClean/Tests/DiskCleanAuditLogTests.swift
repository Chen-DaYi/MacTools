import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 审计日志字段完整性与轮转（设计 §7.8）。
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
                error: "删除文件失败（Permission denied）"
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
        XCTAssertEqual(record.error, "删除文件失败（Permission denied）")
    }

    func testRecentRecordsAreNewestFirstAndRespectLimit() {
        let log = DiskCleanAuditLog(directory: storage.url)
        for index in 0..<5 {
            log.append(record(status: "ok-\(index)", secondsSinceEpoch: Double(1_000 + index * 10)))
        }

        let records = log.recentRecords(limit: 3)

        XCTAssertEqual(records.map(\.status), ["ok-4", "ok-3", "ok-2"])
    }

    /// 5MB 阈值（测试注入小值）到达即轮转为 `.1`，保留 2 代。
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
        XCTAssertTrue(rotatedExists, "超过阈值必须轮转出 .1")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: storage.path).sorted(),
            [DiskCleanAuditLog.fileName, DiskCleanAuditLog.rotatedFileName].sorted(),
            "只保留 2 代，不得堆出 .2 / .3"
        )
    }

    /// 轮转之后"最近记录"仍要跨两代读取，否则清理历史会在轮转瞬间集体失忆。
    ///
    /// 保留 2 代意味着更早的记录**本就该**被丢弃，所以断言的是"读到的内容超出当前文件"，
    /// 而不是"最早那条还在"。
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

        XCTAssertEqual(statuses.first, "gen-11", "最新一条排在最前")
        XCTAssertTrue(
            statuses.contains { !currentGeneration.contains("\"status\":\"\($0)\"") },
            "已轮转到 .1 的那一代仍须可读，否则历史会在轮转瞬间集体失忆"
        )
        let indices = statuses.compactMap { Int($0.dropFirst("gen-".count)) }
        XCTAssertEqual(indices, indices.sorted(by: >), "跨代合并后仍按时间倒序")
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
