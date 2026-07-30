import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 执行器的 preflight 与逐项复核链（设计 §7.1、§7.2）。
///
/// 原语在这里是 fake：本类测的是**顺序与闸门**，原语自身的真实 syscall 行为由
/// `DiskCleanRemovalPrimitiveTests` 用真实文件系统覆盖。
@MainActor
final class DiskCleanExecutorTests: XCTestCase {
    private let home = "/Users/tester"
    private var storage: DiskCleanTempDirectory!
    private var auditLog: DiskCleanAuditLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        storage = try DiskCleanTempDirectory(name: "diskclean-executor")
        auditLog = DiskCleanAuditLog(directory: storage.url)
    }

    override func tearDown() {
        storage?.remove()
        storage = nil
        auditLog = nil
        super.tearDown()
    }

    // MARK: - preflight：任一失败零删除

    func testPreflightRejectsExpiredPlanWithoutTouchingAnything() async throws {
        let plan = try makePlan(paths: ["\(home)/Library/Caches/A"])
        let primitive = FakeDiskCleanRemovalPrimitive()
        let executor = makeExecutor(primitive: primitive, now: plan.expiryDeadline)

        await assertThrows(.planExpired) { try await executor.execute(plan: plan) }

        XCTAssertEqual(primitive.callCount, 0, "preflight 失败必须零删除")
    }

    func testPreflightRejectsWholePlanWhenAnyItemIsLockedByRunningApp() async throws {
        let plan = try makePlan(
            paths: ["\(home)/Library/Caches/A", "\(home)/Library/Caches/B"],
            lockedByBundleIDs: ["com.example.app"]
        )
        let primitive = FakeDiskCleanRemovalPrimitive()
        let executor = makeExecutor(
            primitive: primitive,
            runningAppLock: ProgrammableDiskCleanRunningAppLock(
                snapshot: DiskCleanRunningAppSnapshot(runningBundleIDs: ["com.example.app"])
            )
        )

        await assertThrows(
            .lockedDuringPreflight(path: "\(home)/Library/Caches/A", processName: "com.example.app")
        ) { try await executor.execute(plan: plan) }

        XCTAssertEqual(primitive.callCount, 0, "一项被锁 → 整次中止，不是跳过那一项")
    }

    func testPreflightRejectsPlanWhenSafetyPolicyNowRefusesAPath() async throws {
        // 计划铸造后才被加进白名单的路径：preflight 必须拦下整次执行。
        let plan = try makePlan(paths: ["\(home)/Library/Caches/A", "\(home)/.ssh"])
        let primitive = FakeDiskCleanRemovalPrimitive()
        let executor = makeExecutor(primitive: primitive)

        await assertThrowsSafetyRejection(path: "\(home)/.ssh") { try await executor.execute(plan: plan) }

        XCTAssertEqual(primitive.callCount, 0)
    }

    /// 计划自带的证据要能独立复核出祖先冲突——这道闸防的是 Planner 自身的缺陷。
    func testPreflightRerunsAncestorAssertionFromPlanEvidence() async throws {
        let parent = DiskCleanPlanFactory.candidate(path: "\(home)/Library/Caches/App")
        let lockedChild = DiskCleanPlanFactory.candidate(
            path: "\(home)/Library/Caches/App/inner",
            safety: .inUse(processName: "App")
        )
        // 先铸造一个合法计划，再用同一份证据验证断言本身会抓到冲突。
        let plan = try DiskCleanPlanner.makePlan(
            artifact: DiskCleanPlanFactory.artifact(candidates: [parent]),
            selectedIDs: [parent.id],
            mode: .permanent,
            now: DiskCleanPlanFactory.observedAt,
            catalog: DiskCleanPlanFactory.catalog()
        )

        XCTAssertThrowsError(
            try DiskCleanPlanner.assertNoAncestorViolation(
                plannedPaths: plan.items.map(\.path),
                exclusionPaths: [lockedChild.path],
                reservedPrefixes: plan.reservedPrefixes
            )
        ) { error in
            XCTAssertEqual(
                error as? DiskCleanPlanError,
                .ancestorViolation(
                    plannedPath: "\(home)/Library/Caches/App",
                    protectedPath: "\(home)/Library/Caches/App/inner"
                )
            )
        }
    }

    // MARK: - 逐项链

    func testExecutesEveryItemInPlanOrderAndCountsTerminalStates() async throws {
        let paths = (0..<6).map { "\(home)/Library/Caches/Item\($0)" }
        let plan = try makePlan(paths: paths, bytes: 100)
        let primitive = FakeDiskCleanRemovalPrimitive()
        primitive.setDisposition(.trashed(stagedName: ".mactools-staged-1"), forPath: paths[1])
        primitive.setDisposition(.changedSinceScan, forPath: paths[2])
        primitive.setDisposition(.failed(reason: "boom"), forPath: paths[3])
        primitive.setDisposition(.partiallyDeleted(stagedName: ".mactools-staged-4", reason: "io"), forPath: paths[4])
        primitive.setDisposition(.rollbackBlocked(stagedName: ".mactools-staged-5", reason: "occupied"), forPath: paths[5])
        let executor = makeExecutor(primitive: primitive)

        let result = try await executor.execute(plan: plan)

        XCTAssertEqual(primitive.removedPaths, paths, "逐项按计划顺序执行")
        XCTAssertEqual(result.removedCount, 2, "removed + trashed 都算已处置")
        XCTAssertEqual(result.skippedCount, 1, "changedSinceScan 归入跳过：对象未被触碰")
        XCTAssertEqual(result.failedCount, 3, "failed / partiallyDeleted / rollbackBlocked 都不是成功")
        XCTAssertEqual(result.changedSinceScanCount, 1)
        XCTAssertEqual(result.reclaimedBytes, 200, "只有成功处置的项计入估算回收")
        XCTAssertEqual(
            result.attentionResults.map(\.path),
            [paths[4], paths[5]],
            "半删与回滚被挡要在清理历史里置顶"
        )
        XCTAssertEqual(result.mode, .permanent)
    }

    /// 逐项复核锁定：preflight 之后才启动的应用必须能拦下后续项。
    func testItemIsSkippedWhenBundleIDBecomesRunningAfterPreflight() async throws {
        let plan = try makePlan(
            paths: ["\(home)/Library/Caches/A"],
            lockedByBundleIDs: ["com.example.app"]
        )
        let primitive = FakeDiskCleanRemovalPrimitive()
        let runningAppLock = ProgrammableDiskCleanRunningAppLock(
            snapshot: DiskCleanRunningAppSnapshot(),
            refreshedBundleIDs: ["com.example.app"]
        )
        let executor = makeExecutor(primitive: primitive, runningAppLock: runningAppLock)

        let result = try await executor.execute(plan: plan)

        XCTAssertEqual(primitive.callCount, 0, "逐项复核发现锁定 → 跳过该项，不交给原语")
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(
            result.itemResults.first?.outcome,
            .skipped(.inUse(processName: "com.example.app"))
        )
        XCTAssertGreaterThan(runningAppLock.refreshCallCount, 0, "bundle ID 必须逐项刷新")
    }

    /// 进程名快照来自 preflight 那一次，不逐项重跑 pgrep。
    func testProcessNamesAreQueriedOnceDuringPreflight() async throws {
        let plan = try makePlan(
            paths: ["\(home)/Library/Caches/A", "\(home)/Library/Caches/B"],
            skipWhenProcessIsRunning: ["exampled"]
        )
        let runningAppLock = ProgrammableDiskCleanRunningAppLock()
        let executor = makeExecutor(runningAppLock: runningAppLock)

        _ = try await executor.execute(plan: plan)

        XCTAssertEqual(runningAppLock.lastRequestedProcessNames, ["exampled"])
        XCTAssertEqual(runningAppLock.refreshCallCount, 2, "两个计划项各刷新一次 bundle ID")
    }

    func testTrashModeIsForwardedToPrimitive() async throws {
        let plan = try makePlan(paths: ["\(home)/Library/Caches/A"], mode: .trash)
        let primitive = FakeDiskCleanRemovalPrimitive(
            defaultDisposition: .trashed(stagedName: ".mactools-staged-x")
        )
        let executor = makeExecutor(primitive: primitive)

        let result = try await executor.execute(plan: plan)

        XCTAssertEqual(primitive.lastMode, .trash)
        XCTAssertEqual(result.mode, .trash)
        XCTAssertEqual(
            result.itemResults.first?.outcome,
            .trashed(reclaimedBytes: 0, stagedName: ".mactools-staged-x")
        )
    }

    // MARK: - 审计

    func testWritesOneAuditRecordPerItemWithTerminalStatus() async throws {
        let paths = ["\(home)/Library/Caches/A", "\(home)/Library/Caches/B"]
        let plan = try makePlan(paths: paths, bytes: 42)
        let primitive = FakeDiskCleanRemovalPrimitive()
        primitive.setDisposition(
            .partiallyDeleted(stagedName: ".mactools-staged-b", reason: "io error"),
            forPath: paths[1]
        )
        let executor = makeExecutor(primitive: primitive)

        _ = try await executor.execute(plan: plan)

        let records = auditLog.recentRecords(limit: 10)
        XCTAssertEqual(records.count, 2)
        let byPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path ?? "", $0) })
        XCTAssertEqual(byPath[paths[0]]?.status, "ok")
        XCTAssertEqual(byPath[paths[0]]?.action, .delete)
        XCTAssertEqual(byPath[paths[0]]?.estimatedBytes, 42)
        XCTAssertEqual(byPath[paths[0]]?.targetID, DiskCleanPlanFactory.targetID)
        XCTAssertEqual(byPath[paths[1]]?.status, "partiallyDeleted")
        XCTAssertEqual(byPath[paths[1]]?.stagedName, ".mactools-staged-b")
        XCTAssertEqual(byPath[paths[1]]?.error, "io error")
    }

    func testSkippedItemAuditRecordsReason() async throws {
        let plan = try makePlan(
            paths: ["\(home)/Library/Caches/A"],
            lockedByBundleIDs: ["com.example.app"]
        )
        let executor = makeExecutor(
            runningAppLock: ProgrammableDiskCleanRunningAppLock(
                snapshot: DiskCleanRunningAppSnapshot(),
                refreshedBundleIDs: ["com.example.app"]
            )
        )

        _ = try await executor.execute(plan: plan)

        let record = try XCTUnwrap(auditLog.recentRecords(limit: 1).first)
        XCTAssertEqual(record.status, "skipped")
        XCTAssertEqual(record.skipReason, "inUse(com.example.app)")
    }

    // MARK: - 夹具

    private func makePlan(
        paths: [String],
        mode: DiskCleanRemovalMode = .permanent,
        bytes: Int64 = 0,
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = []
    ) throws -> DiskCleanValidatedPlan {
        try DiskCleanPlanFactory.makePlan(
            items: paths.map { DiskCleanPlanFactory.Item(path: $0, identity: .test(), bytes: bytes) },
            mode: mode,
            lockedByBundleIDs: lockedByBundleIDs,
            skipWhenProcessIsRunning: skipWhenProcessIsRunning
        )
    }

    private func makeExecutor(
        primitive: any DiskCleanPlanItemRemoving = FakeDiskCleanRemovalPrimitive(),
        runningAppLock: any DiskCleanRunningAppSnapshotting = ProgrammableDiskCleanRunningAppLock(),
        now: Date = DiskCleanPlanFactory.observedAt
    ) -> DiskCleanExecutor {
        DiskCleanExecutor(
            primitive: primitive,
            safetyPolicy: DiskCleanSafetyPolicy(
                homeDirectory: home,
                whitelistStore: DiskCleanWhitelistStore(homeDirectory: home, includeDefaults: false)
            ),
            runningAppLock: runningAppLock,
            auditLog: auditLog,
            now: { now }
        )
    }

    private func assertThrows(
        _ expected: DiskCleanExecutionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> DiskCleanExecutionResult
    ) async {
        do {
            _ = try await body()
            XCTFail("期望抛出 \(expected)，但执行成功了", file: file, line: line)
        } catch let error as DiskCleanExecutionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("期望 DiskCleanExecutionError，实际：\(error)", file: file, line: line)
        }
    }

    private func assertThrowsSafetyRejection(
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> DiskCleanExecutionResult
    ) async {
        do {
            _ = try await body()
            XCTFail("期望安全校验拒绝 \(path)", file: file, line: line)
        } catch let DiskCleanExecutionError.safetyRejected(rejectedPath, _) {
            XCTAssertEqual(rejectedPath, path, file: file, line: line)
        } catch {
            XCTFail("期望 safetyRejected，实际：\(error)", file: file, line: line)
        }
    }
}
