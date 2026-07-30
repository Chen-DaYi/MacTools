import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 清理历史的分类与置顶规则（设计 §7.5、§13-M4-6）。
final class DiskCleanCleanupHistoryTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_000)

    func testStatusParsingCoversEveryStatusWrittenByTheAuditLog() {
        let expected: [String: DiskCleanCleanupHistoryStatus] = [
            "ok": .ok,
            "skipped": .skipped,
            "changedSinceScan": .changedSinceScan,
            "failed": .failed,
            "partiallyDeleted": .partiallyDeleted,
            "rollbackBlocked": .rollbackBlocked,
            "reconciledRolledBack": .reconciledRolledBack,
            "reconciledAbsent": .reconciledAbsent,
            // 父目录整个消失与暂存对象消失是同一个结论：没有需要恢复的东西。
            "reconciledParentMissing": .reconciledAbsent,
            "reconcileFailed": .reconcileFailed
        ]

        for (rawValue, status) in expected {
            XCTAssertEqual(DiskCleanCleanupHistoryStatus(rawValue: rawValue), status, rawValue)
        }
        XCTAssertEqual(DiskCleanCleanupHistoryStatus(rawValue: "brandNew"), .unknown("brandNew"))
    }

    /// 需要关注的只有"磁盘上留了残骸"的三种。普通失败与跳过没有留下任何东西，不该打扰用户。
    func testOnlyLeftoverStatesNeedAttention() {
        let needsAttention: [DiskCleanCleanupHistoryStatus] = [
            .partiallyDeleted, .rollbackBlocked, .reconcileFailed
        ]
        let quiet: [DiskCleanCleanupHistoryStatus] = [
            .ok, .skipped, .changedSinceScan, .failed,
            .reconciledRolledBack, .reconciledAbsent, .unknown("x")
        ]

        for status in needsAttention {
            XCTAssertTrue(status.needsAttention, "\(status) 必须置顶提示")
        }
        for status in quiet {
            XCTAssertFalse(status.needsAttention, "\(status) 不该置顶")
        }
    }

    func testAttentionEntriesArePinnedAboveTheRest() {
        let records = [
            record(status: "ok", path: "/cache/a"),
            record(status: "skipped", path: "/cache/b"),
            record(status: "rollbackBlocked", path: "/cache/c", stagedName: ".mactools-staged-c"),
            record(status: "ok", path: "/cache/d"),
            record(status: "partiallyDeleted", path: "/cache/e", stagedName: ".mactools-staged-e")
        ]

        let entries = DiskCleanCleanupHistoryEntry.entries(from: records)

        XCTAssertEqual(
            entries.map(\.path),
            ["/cache/c", "/cache/e", "/cache/a", "/cache/b", "/cache/d"],
            "残骸条目置顶，其余保持原有的时间倒序"
        )
        XCTAssertEqual(entries.prefix(2).filter(\.needsAttention).count, 2)
    }

    /// 废纸篓里的对象落在暂存名下，不带出这个字段用户就找不回来（设计 §7.4）。
    func testEntryCarriesStagedNameAndOriginalPath() throws {
        let entries = DiskCleanCleanupHistoryEntry.entries(
            from: [record(status: "trashedPlaceholder", path: "/cache/a", stagedName: ".mactools-staged-a")]
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.path, "/cache/a")
        XCTAssertEqual(entry.stagedName, ".mactools-staged-a")
    }

    func testEntriesHaveStableIdentifiersWithinOneLoad() {
        let entries = DiskCleanCleanupHistoryEntry.entries(
            from: [record(status: "ok", path: "/a"), record(status: "ok", path: "/b")]
        )

        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "同一次读取内 id 不得重复")
    }

    private func record(
        status: String,
        path: String,
        stagedName: String? = nil
    ) -> DiskCleanAuditLog.Record {
        DiskCleanAuditLog.Record(
            timestamp: timestamp,
            action: .trash,
            path: path,
            stagedName: stagedName,
            estimatedBytes: 1_024,
            status: status
        )
    }
}
