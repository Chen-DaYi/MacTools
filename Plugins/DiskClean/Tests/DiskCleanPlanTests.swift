import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 计划铸造的校验矩阵（设计 §6.1）。
///
/// 任一条不过关都必须 `throw`——不产出计划就等于零删除，这是执行链上最省事也最可靠的一道闸。
@MainActor
final class DiskCleanPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let targetID = DiskCleanPlanFactory.targetID

    // MARK: - 通过路径

    func testMintsPlanWithFrozenModeTotalsAndEvidence() throws {
        let first = candidate(path: "/cache/a", bytes: 100)
        let second = candidate(path: "/cache/b", bytes: 250)
        let excluded = candidate(path: "/cache/locked", safety: .inUse(processName: "App"))

        let plan = try makePlan(
            candidates: [first, second, excluded],
            selectedIDs: [first.id, second.id],
            reservedRootPaths: ["/reserved/root"]
        )

        XCTAssertEqual(plan.items.map(\.path), ["/cache/a", "/cache/b"], "执行顺序沿用工件顺序，可复现")
        XCTAssertEqual(plan.totalEstimatedBytes, 350)
        XCTAssertEqual(plan.itemCount, 2)
        XCTAssertEqual(plan.mode, .permanent)
        XCTAssertEqual(plan.minObservedAt, DiskCleanPlanFactory.observedAt)
        XCTAssertEqual(
            plan.expiryDeadline,
            DiskCleanPlanFactory.observedAt.addingTimeInterval(DiskCleanScanFreshness.window)
        )
        XCTAssertEqual(plan.exclusionPaths, ["/cache/locked"], "未入计划的候选全部进排除集")
        XCTAssertEqual(plan.reservedPrefixes, ["/reserved/root"], "保留前缀由工件推导，调用方无法漏传")
    }

    func testPlanItemCarriesTargetLockDeclarations() throws {
        let candidate = candidate(path: "/cache/a")

        let plan = try makePlan(
            candidates: [candidate],
            selectedIDs: [candidate.id],
            lockedByBundleIDs: ["com.example.app"],
            skipWhenProcessIsRunning: ["exampled"]
        )

        XCTAssertEqual(plan.items[0].lockedByBundleIDs, ["com.example.app"])
        XCTAssertEqual(plan.items[0].skipWhenProcessIsRunning, ["exampled"])
        XCTAssertEqual(plan.items[0].parentPath, "/cache")
        XCTAssertEqual(plan.items[0].name, "a")
    }

    func testMinObservedAtUsesEarliestSelectedItem() throws {
        let older = candidate(path: "/cache/old", observedAt: now.addingTimeInterval(-100))
        let newer = candidate(path: "/cache/new", observedAt: now)

        let plan = try makePlan(candidates: [older, newer], selectedIDs: [older.id, newer.id])

        XCTAssertEqual(plan.minObservedAt, now.addingTimeInterval(-100), "过期门取最早观测时刻")
    }

    // MARK: - 拒绝矩阵

    func testEmptySelectionIsRejected() {
        let candidate = candidate(path: "/cache/a")

        assertThrows(.emptySelection) {
            try makePlan(candidates: [candidate], selectedIDs: [])
        }
    }

    /// 越权选择：递进来的 id 不在工件里。
    func testSelectionOutsideArtifactIsRejected() {
        let candidate = candidate(path: "/cache/a")

        assertThrows(.invalidSelection(candidateID: "ghost")) {
            try makePlan(candidates: [candidate], selectedIDs: [candidate.id, "ghost"])
        }
    }

    /// 越权选择：候选存在但不可清理（锁定 / 保护 / 白名单）。
    func testSelectingNonCleanableCandidateIsRejected() {
        let locked = candidate(path: "/cache/locked", safety: .inUse(processName: "App"))

        assertThrows(.invalidSelection(candidateID: locked.id)) {
            try makePlan(candidates: [locked], selectedIDs: [locked.id])
        }
    }

    /// 越权选择：completeness 非 complete，即便安全策略放行。
    func testSelectingPartialCandidateIsRejected() {
        let partial = DiskCleanPlanFactory.candidate(
            path: "/cache/partial",
            sizeResult: .testPartial(reasons: [.crossedMountPoint], identity: .test())
        )

        assertThrows(.invalidSelection(candidateID: partial.id)) {
            try makePlan(candidates: [partial], selectedIDs: [partial.id])
        }
    }

    /// 大小已求出但没有根身份 → 执行侧无从复核，拒绝。
    func testSelectingCandidateWithoutRootIdentityIsRejected() {
        let noIdentity = DiskCleanPlanFactory.candidate(
            path: "/cache/no-identity",
            sizeResult: DiskCleanSizeResult(
                estimatedBytes: 10,
                fileCount: 1,
                completeness: .complete,
                rootIdentity: nil,
                observedAt: DiskCleanPlanFactory.observedAt
            )
        )

        assertThrows(.invalidSelection(candidateID: noIdentity.id)) {
            try makePlan(candidates: [noIdentity], selectedIDs: [noIdentity.id])
        }
    }

    func testUnknownTargetIsRejected() {
        let orphan = DiskCleanCandidate(
            id: "orphan",
            targetID: "target.that.does.not.exist",
            legacyRuleID: "legacy",
            category: .appCaches,
            path: "/cache/orphan",
            risk: .low,
            safety: .allowed,
            sizeResult: .testComplete(identity: .test())
        )

        assertThrows(.unknownTarget(targetID: "target.that.does.not.exist")) {
            try makePlan(candidates: [orphan], selectedIDs: [orphan.id])
        }
    }

    /// 祖先冲突：计划路径覆盖了一个未入计划的候选。
    func testPlannedPathCoveringExcludedCandidateIsRejected() {
        let parent = candidate(path: "/cache/app")
        let lockedChild = candidate(path: "/cache/app/inner", safety: .inUse(processName: "App"))

        assertThrows(.ancestorViolation(plannedPath: "/cache/app", protectedPath: "/cache/app/inner")) {
            try makePlan(candidates: [parent, lockedChild], selectedIDs: [parent.id])
        }
    }

    /// 祖先冲突：计划路径覆盖了被跳过 target 的保留根（那片子树从未被扫描）。
    func testPlannedPathCoveringReservedPrefixIsRejected() {
        let parent = candidate(path: "/cache/app")

        assertThrows(.ancestorViolation(plannedPath: "/cache/app", protectedPath: "/cache/app/unscanned")) {
            try makePlan(
                candidates: [parent],
                selectedIDs: [parent.id],
                reservedRootPaths: ["/cache/app/unscanned"]
            )
        }
    }

    /// 路径相等也算冲突：同一路径既在计划里又被保留，说明证据矛盾。
    func testPlannedPathEqualToReservedPrefixIsRejected() {
        let parent = candidate(path: "/cache/app")

        assertThrows(.ancestorViolation(plannedPath: "/cache/app", protectedPath: "/cache/app")) {
            try makePlan(candidates: [parent], selectedIDs: [parent.id], reservedRootPaths: ["/cache/app"])
        }
    }

    /// 同名前缀不是祖先：`/cache/app-extra` 不在 `/cache/app` 之下。
    func testSiblingWithSharedNamePrefixIsNotAnAncestorViolation() throws {
        let parent = candidate(path: "/cache/app")
        let sibling = candidate(path: "/cache/app-extra", safety: .inUse(processName: "App"))

        let plan = try makePlan(candidates: [parent, sibling], selectedIDs: [parent.id])

        XCTAssertEqual(plan.items.map(\.path), ["/cache/app"])
    }

    func testExpiredResultIsRejected() {
        let candidate = candidate(path: "/cache/a", observedAt: now)

        assertThrows(.resultExpired) {
            try makePlan(
                candidates: [candidate],
                selectedIDs: [candidate.id],
                now: now.addingTimeInterval(DiskCleanScanFreshness.window)
            )
        }
    }

    func testResultOneSecondInsideWindowIsAccepted() throws {
        let candidate = candidate(path: "/cache/a", observedAt: now)

        let plan = try makePlan(
            candidates: [candidate],
            selectedIDs: [candidate.id],
            now: now.addingTimeInterval(DiskCleanScanFreshness.window - 1)
        )

        XCTAssertEqual(plan.itemCount, 1)
    }

    // MARK: - 夹具

    private func candidate(
        path: String,
        bytes: Int64 = 10,
        safety: DiskCleanSafetyStatus = .allowed,
        observedAt: Date = DiskCleanPlanFactory.observedAt
    ) -> DiskCleanCandidate {
        DiskCleanPlanFactory.candidate(
            path: path,
            bytes: bytes,
            observedAt: observedAt,
            safety: safety
        )
    }

    private func makePlan(
        candidates: [DiskCleanCandidate],
        selectedIDs: Set<DiskCleanCandidate.ID>,
        reservedRootPaths: [String] = [],
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = [],
        now: Date? = nil
    ) throws -> DiskCleanValidatedPlan {
        try DiskCleanPlanner.makePlan(
            artifact: DiskCleanPlanFactory.artifact(
                candidates: candidates,
                reservedRootPaths: reservedRootPaths
            ),
            selectedIDs: selectedIDs,
            mode: .permanent,
            now: now ?? self.now,
            catalog: DiskCleanPlanFactory.catalog(
                lockedByBundleIDs: lockedByBundleIDs,
                skipWhenProcessIsRunning: skipWhenProcessIsRunning
            )
        )
    }

    private func assertThrows(
        _ expected: DiskCleanPlanError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> DiskCleanValidatedPlan
    ) {
        do {
            _ = try body()
            XCTFail("期望抛出 \(expected)，但铸造成功了", file: file, line: line)
        } catch let error as DiskCleanPlanError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("期望 DiskCleanPlanError，实际：\(error)", file: file, line: line)
        }
    }
}
