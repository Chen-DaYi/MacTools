import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

@MainActor
final class DiskCleanControllerTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 10_000)

    // MARK: - 事件流消费

    func testConsumesStreamAndPublishesScannedResult() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }

        let candidate = makeCandidate(id: "a", path: "/cache/a")
        engine.emit(.candidateFound(candidate))
        engine.emit(.candidateSized(id: candidate.id, result: .testComplete(bytes: 2_048, observedAt: observedAt)))
        engine.emit(.finished(makeSummary(candidates: [candidate.applying(.testComplete(bytes: 2_048, observedAt: observedAt))])))

        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }
        let result = try XCTUnwrap(controller.snapshot.scanResult)
        XCTAssertEqual(result.cleanableCandidates.map(\.id), ["a"])
        XCTAssertEqual(result.cleanableSizeBytes, 2_048)
        XCTAssertNotNil(result.artifact, "完成后必须带上工件——M4 的清理入口只接受工件")
        XCTAssertTrue(controller.snapshot.canClean)
    }

    func testStreamingCandidatesAreVisibleBeforeScanFinishes() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.candidateFound(makeCandidate(id: "a", path: "/cache/a")))

        // 节流发布：~250ms 内出现即符合预期，不要求同步可见。
        await waitUntil("流式候选可见") { controller.snapshot.scanResult?.candidates.count == 1 }
        XCTAssertEqual(controller.snapshot.phase, .scanning)
        XCTAssertFalse(controller.snapshot.canClean, "扫描中不可清理")
    }

    func testPropagatesLimitationsFromSummary() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(
            .finished(
                makeSummary(candidates: [], limitations: [.walkerCircuitBroken, .threadsAbandoned(count: 2)])
            )
        )

        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }
        let result = try XCTUnwrap(controller.snapshot.scanResult)
        XCTAssertEqual(result.limitations, [.walkerCircuitBroken, .threadsAbandoned(count: 2)])
        XCTAssertTrue(result.isLimited)
    }

    func testScanFailurePublishesErrorMessage() async {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.fail(with: FakeDiskCleanExpansionError(message: "engine exploded"))

        await waitUntil("失败已发布") { controller.snapshot.errorMessage != nil }
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertEqual(controller.snapshot.errorMessage, "engine exploded")
    }

    // MARK: - operationID 世代

    func testEventsFromSupersededOperationAreDiscarded() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        // 停止扫描 → 上一代 operationID 作废。
        controller.cancelCurrentOperation()
        XCTAssertEqual(controller.snapshot.phase, .idle)

        // 过期操作的尾巴：绝不能把状态推回 scanned。
        engine.emit(.candidateFound(makeCandidate(id: "a", path: "/cache/a")))
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertNil(controller.snapshot.scanResult)
    }

    func testCancellingScanTerminatesEngineStream() async {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        controller.cancelCurrentOperation()

        await waitUntil("引擎流已终止") { engine.didTerminate }
    }

    func testRescanUsesFreshOperationAndResetsLog() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("首轮完成") { controller.snapshot.phase == .scanned }

        controller.scan()

        XCTAssertEqual(engine.scanCallCount, 2)
        XCTAssertEqual(controller.snapshot.scanLogEntries.count, 1, "新一轮扫描从干净日志开始")
        XCTAssertNil(controller.snapshot.scanResult)
    }

    // MARK: - 过期门

    func testExpiryClockFlipsCanCleanAndNotifiesStateChange() async throws {
        let clock = TestDiskCleanClock(now: observedAt)
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine, clock: clock)
        var stateChangeCount = 0
        controller.onStateChange = { stateChangeCount += 1 }

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }
        XCTAssertTrue(controller.snapshot.canClean)

        let changesBeforeExpiry = stateChangeCount
        clock.advance(by: DiskCleanScanFreshness.window)

        await waitUntil("过期门到点") { controller.snapshot.isResultExpired }
        XCTAssertFalse(controller.snapshot.canClean, "过期后不可清理")
        XCTAssertGreaterThan(
            stateChangeCount,
            changesBeforeExpiry,
            "过期是时间驱动的：到点即通知宿主刷新，不等用户点击"
        )
        XCTAssertEqual(controller.snapshot.subtitle, "结果已过期，请重新扫描")
    }

    func testExpiryDeadlineUsesEarliestObservedAtAmongCleanableCandidates() async throws {
        let clock = TestDiskCleanClock(now: observedAt)
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine, clock: clock)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(
            .finished(
                makeSummary(candidates: [
                    makeSizedCandidate(id: "old", path: "/cache/old", observedAt: observedAt),
                    makeSizedCandidate(id: "new", path: "/cache/new", observedAt: observedAt.addingTimeInterval(100))
                ])
            )
        )
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }

        XCTAssertEqual(
            controller.snapshot.scanResult?.expiryDeadline,
            observedAt.addingTimeInterval(DiskCleanScanFreshness.window)
        )
    }

    func testExpiredResultTriggersForceRefreshOnRescan() async throws {
        let clock = TestDiskCleanClock(now: observedAt)
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine, clock: clock)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }
        XCTAssertEqual(engine.lastForceRefresh, false)

        clock.advance(by: DiskCleanScanFreshness.window)
        await waitUntil("过期门到点") { controller.snapshot.isResultExpired }
        controller.scan()

        XCTAssertEqual(
            engine.lastForceRefresh,
            true,
            "过期后的重扫必须绕过缓存，否则会陷入'过期 → 重扫 → 命中旧缓存 → 仍过期'"
        )
    }

    func testResultObservedBeforeScanStartIsExpiredImmediately() async throws {
        let clock = TestDiskCleanClock(now: observedAt.addingTimeInterval(DiskCleanScanFreshness.window + 1))
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine, clock: clock)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))

        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }
        XCTAssertTrue(controller.snapshot.isResultExpired, "缓存命中的旧 observedAt 可能一出生就过期")
        XCTAssertFalse(controller.snapshot.canClean)
    }

    // MARK: - 清理集合的不变量

    func testCleanDropsCandidatesWithIncompleteSize() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let executor = FakeDiskCleanExecutor()
        let controller = makeController(engine: engine, executor: executor)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        let complete = makeSizedCandidate(id: "complete", path: "/cache/complete")
        let partial = makeCandidate(id: "partial", path: "/cache/partial")
            .applying(.testPartial(reasons: [.timedOut], observedAt: observedAt))
        let unsized = makeCandidate(id: "unsized", path: "/cache/unsized")
        engine.emit(.finished(makeSummary(candidates: [complete, partial, unsized])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }

        controller.clean()
        await waitUntil("清理完成") { controller.snapshot.phase == .completed }

        XCTAssertEqual(
            executor.lastSelectedIDs,
            ["complete"],
            "未定大小与 partial 的候选绝不进入清理集合（§3.1 不变量的第一道防线）"
        )
    }

    func testCleanIsIgnoredWhenNothingIsSelectable() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let executor = FakeDiskCleanExecutor()
        let controller = makeController(engine: engine, executor: executor)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        let partial = makeCandidate(id: "partial", path: "/cache/partial")
            .applying(.testPartial(reasons: [.permissionDenied], observedAt: observedAt))
        engine.emit(.finished(makeSummary(candidates: [partial])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }

        controller.clean()

        XCTAssertEqual(executor.callCount, 0)
        XCTAssertEqual(controller.snapshot.phase, .scanned)
        XCTAssertFalse(controller.snapshot.canClean)
    }

    func testCleanIsRejectedAfterExpiry() async throws {
        let clock = TestDiskCleanClock(now: observedAt)
        let engine = ControlledDiskCleanScanEngine()
        let executor = FakeDiskCleanExecutor()
        let controller = makeController(engine: engine, executor: executor, clock: clock)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }
        clock.advance(by: DiskCleanScanFreshness.window)
        await waitUntil("过期门到点") { controller.snapshot.isResultExpired }

        controller.clean()

        XCTAssertEqual(executor.callCount, 0)
    }

    // MARK: - 选择命令（§8.1）

    func testDefaultSelectionCoversLowRiskCandidatesOnly() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(
            .finished(
                makeSummary(candidates: [
                    makeSizedCandidate(id: "low", path: "/cache/low"),
                    makeSizedCandidate(id: "medium", path: "/cache/medium", risk: .medium),
                    makeCandidate(id: "unsized", path: "/cache/unsized")
                ])
            )
        )
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }

        XCTAssertEqual(controller.snapshot.selection.selectedIDs, ["low"])
        XCTAssertEqual(controller.snapshot.selection.selectableIDs, ["low", "medium"])
        XCTAssertEqual(controller.snapshot.selection.selectedEstimatedBytes, 1_024)
    }

    func testStreamingCandidateJoinsSelectionOnlyOnceItsSizeIsKnown() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        let candidate = makeCandidate(id: "a", path: "/cache/a")
        engine.emit(.candidateFound(candidate))
        await waitUntil("候选可见") { controller.snapshot.scanResult?.candidates.count == 1 }

        XCTAssertTrue(
            controller.snapshot.selection.isEmpty,
            "大小未知的候选不可勾选，默认策略也不能把它带进来"
        )

        engine.emit(.candidateSized(id: candidate.id, result: .testComplete(bytes: 512, observedAt: observedAt)))

        await waitUntil("求大小完成后自动按默认策略勾选") { controller.snapshot.selection.selectedIDs == ["a"] }
    }

    func testTogglingUnselectableCandidateIsRejected() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        let locked = makeCandidate(id: "locked", path: "/cache/locked", safety: .inUse(processName: "App"))
            .applying(.testComplete(bytes: 1_024, observedAt: observedAt))
        engine.emit(.finished(makeSummary(candidates: [locked])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }

        controller.setCandidateSelected("locked", isSelected: true)

        XCTAssertTrue(controller.snapshot.selection.isEmpty, "锁定候选不可勾选，命令必须被拒绝而不是仅在 UI 上禁用")
        XCTAssertFalse(controller.snapshot.canClean)
    }

    func testCategorySelectAllNeverPullsInMediumRiskCandidates() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(
            .finished(
                makeSummary(candidates: [
                    makeSizedCandidate(id: "low", path: "/cache/low"),
                    makeSizedCandidate(id: "medium", path: "/cache/medium", risk: .medium)
                ])
            )
        )
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }

        controller.setCategorySelection(.appCaches, isSelected: false)
        XCTAssertTrue(controller.snapshot.selection.isEmpty)

        controller.setCategorySelection(.appCaches, isSelected: true)

        XCTAssertEqual(
            controller.snapshot.selection.selectedIDs,
            ["low"],
            "\"全选\"= 选中本类所有低风险项，medium/high 永不被带入"
        )
        XCTAssertEqual(controller.snapshot.selection.state(of: .appCaches), .partiallySelected)
    }

    func testCleanSubmitsExactlyTheSelectedSet() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let executor = FakeDiskCleanExecutor()
        let controller = makeController(engine: engine, executor: executor)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(
            .finished(
                makeSummary(candidates: [
                    makeSizedCandidate(id: "keep", path: "/cache/keep"),
                    makeSizedCandidate(id: "drop", path: "/cache/drop")
                ])
            )
        )
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }

        controller.setCandidateSelected("drop", isSelected: false)
        controller.clean()
        await waitUntil("清理完成") { controller.snapshot.phase == .completed }

        XCTAssertEqual(executor.lastSelectedIDs, ["keep"], "菜单栏与详情页共享同一份选中集")
    }

    func testCleanIsDisabledWhenSelectionIsEmpty() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let executor = FakeDiskCleanExecutor()
        let controller = makeController(engine: engine, executor: executor)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }
        XCTAssertTrue(controller.snapshot.canClean)

        controller.setCandidateSelected("a", isSelected: false)

        XCTAssertFalse(controller.snapshot.canClean, "选中集为空时按钮变灰，而不是回退成\"清理全部\"")
        controller.clean()
        XCTAssertEqual(executor.callCount, 0)
    }

    func testChangingSelectionInvalidatesPendingPlan() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent)
        controller.clean()
        XCTAssertEqual(controller.snapshot.phase, .confirming)

        controller.setCandidateSelected("a", isSelected: false)

        XCTAssertEqual(controller.snapshot.phase, .scanned)
        XCTAssertNil(controller.snapshot.pendingPlan)
        controller.confirmPendingClean()
        XCTAssertEqual(executor.callCount, 0, "选择一变，冻结的计划就不再对应任何用户意图")
    }

    func testCategorySelectionChangeInvalidatesPendingPlan() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent)
        controller.clean()
        XCTAssertEqual(controller.snapshot.phase, .confirming)

        controller.setCategorySelection(.appCaches, isSelected: false)

        XCTAssertEqual(controller.snapshot.phase, .scanned)
        XCTAssertNil(controller.snapshot.pendingPlan)
        XCTAssertEqual(executor.callCount, 0)
    }

    func testRescanStartsFromDefaultSelection() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }
        controller.setCandidateSelected("a", isSelected: false)
        XCTAssertTrue(controller.snapshot.selection.isEmpty)

        controller.scan()
        await waitUntil("第二轮开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("第二轮完成") { controller.snapshot.phase == .scanned }

        XCTAssertEqual(
            controller.snapshot.selection.selectedIDs,
            ["a"],
            "候选 ID 跨扫描稳定，上一轮的取消勾选不该悄悄带进新结果"
        )
    }

    // MARK: - 范围选择

    func testChangingScopeMarksResultStale() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }

        controller.setChoice(.browser, isSelected: false)

        XCTAssertTrue(controller.snapshot.isResultStale)
        XCTAssertFalse(controller.snapshot.canClean)
        XCTAssertEqual(controller.snapshot.subtitle, "清理范围已变化")
    }

    func testScanForwardsSelectedChoicesToEngine() async {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.setChoice(.developer, isSelected: false)
        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }

        XCTAssertEqual(engine.lastChoices, [.cache, .browser])
    }

    func testScanIsRejectedWhenNoScopeSelected() {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        for choice in DiskCleanChoice.allCases {
            controller.setChoice(choice, isSelected: false)
        }
        controller.scan()

        XCTAssertEqual(engine.scanCallCount, 0)
        XCTAssertEqual(controller.snapshot.phase, .idle)
    }

    // MARK: - P2 分段范围（设计 §10）

    /// 同一个 Controller 类型服务三个分段，扫描范围整体替换即可——P2 不需要另一套状态机。
    func testScanForwardsDeveloperArtifactRootsToEngine() async {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.setScope(.developerArtifacts(roots: ["/code"]))
        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }

        XCTAssertEqual(engine.lastScope, .developerArtifacts(roots: ["/code"]))
    }

    /// 增删扫描根与改分组是同一件事：结果不再对应当前范围，就该提示重新扫描。
    func testChangingDeveloperArtifactRootsMarksResultStale() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)
        controller.setScope(.developerArtifacts(roots: ["/code"]))

        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(
            .finished(
                makeSummary(
                    candidates: [makeSizedCandidate(id: "a", path: "/code/app/node_modules")],
                    scope: .developerArtifacts(roots: ["/code"])
                )
            )
        )
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }
        XCTAssertTrue(controller.snapshot.canClean)

        controller.setScope(.developerArtifacts(roots: ["/code", "/work"]))

        XCTAssertTrue(controller.snapshot.isResultStale)
        XCTAssertFalse(controller.snapshot.canClean)
    }

    /// 还没配置扫描根时扫描入口必须是禁用的，否则用户点了什么都不会发生。
    func testScanIsRejectedWhenDeveloperArtifactRootsAreEmpty() {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.setScope(.developerArtifacts(roots: []))
        controller.scan()

        XCTAssertFalse(controller.snapshot.canScan)
        XCTAssertEqual(engine.scanCallCount, 0)
    }

    /// 安装包段范围固定，永远可扫。
    func testInstallerScopeIsAlwaysScannable() {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.setScope(.installers)

        XCTAssertTrue(controller.snapshot.canScan)
        XCTAssertTrue(controller.snapshot.selectedChoices.isEmpty, "非规则范围没有分组概念")
    }

    /// 分组这个概念只对规则段成立。给 P2 段发 `setChoice` 会把整个分段的范围换掉，
    /// 因此必须是空操作。
    func testSetChoiceIsIgnoredOutsideRuleScope() {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)
        controller.setScope(.installers)

        controller.setChoice(.cache, isSelected: false)

        XCTAssertEqual(controller.snapshot.scope, .installers)
    }

    // MARK: - confirming（§8.4）

    func testTrashModeExecutesInOneStepWithoutConfirmation() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .trash)

        controller.clean()
        await waitUntil("清理完成") { controller.snapshot.phase == .completed }

        XCTAssertEqual(executor.callCount, 1, "废纸篓可恢复，故单步执行")
        XCTAssertEqual(executor.lastMode, .trash)
    }

    func testPermanentModeEntersConfirmingWithFrozenSummary() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent)

        controller.clean()

        XCTAssertEqual(controller.snapshot.phase, .confirming)
        XCTAssertEqual(executor.callCount, 0, "确认之前一个字节都不能删")
        let pending = try XCTUnwrap(controller.snapshot.pendingPlan)
        XCTAssertEqual(pending.itemCount, 1)
        XCTAssertEqual(pending.totalEstimatedBytes, 1_024)
        XCTAssertEqual(pending.mode, .permanent)
        XCTAssertFalse(controller.snapshot.canScan, "确认期间不接受新扫描")
    }

    func testConfirmingExecutesTheFrozenPlan() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent)
        controller.clean()

        controller.confirmPendingClean()
        await waitUntil("清理完成") { controller.snapshot.phase == .completed }

        XCTAssertEqual(executor.callCount, 1)
        XCTAssertEqual(executor.lastMode, .permanent)
        XCTAssertEqual(executor.lastSelectedIDs, ["a"])
        XCTAssertNil(controller.snapshot.pendingPlan, "计划执行后不再挂在快照上")
    }

    func testCancellingConfirmationDiscardsPlanAndReturnsToScanned() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent)
        controller.clean()

        controller.cancelPendingClean()

        XCTAssertEqual(controller.snapshot.phase, .scanned)
        XCTAssertNil(controller.snapshot.pendingPlan)
        XCTAssertEqual(executor.callCount, 0)

        controller.confirmPendingClean()
        XCTAssertEqual(executor.callCount, 0, "计划已作废，确认不该再生效")
    }

    func testChangingScopeInvalidatesPendingPlan() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent)
        controller.clean()

        controller.setChoice(.browser, isSelected: false)

        XCTAssertEqual(controller.snapshot.phase, .scanned)
        XCTAssertNil(controller.snapshot.pendingPlan)
        controller.confirmPendingClean()
        XCTAssertEqual(executor.callCount, 0)
    }

    func testChangingRemovalModeInvalidatesPendingPlan() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent)
        controller.clean()

        controller.setRemovalMode(.trash)

        XCTAssertEqual(controller.snapshot.phase, .scanned)
        XCTAssertNil(controller.snapshot.pendingPlan)
        XCTAssertEqual(controller.snapshot.removalMode, .trash)
        controller.confirmPendingClean()
        XCTAssertEqual(executor.callCount, 0, "删除方式是冻结字段，改了就必须重新铸造")
    }

    func testConfirmationWindowExpiresAfterSixtySeconds() async throws {
        let clock = TestDiskCleanClock(now: observedAt)
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent, clock: clock)
        controller.clean()
        XCTAssertEqual(controller.snapshot.phase, .confirming)

        clock.advance(by: DiskCleanController.confirmationWindow)

        await waitUntil("确认窗口到期") { controller.snapshot.phase == .scanned }
        XCTAssertNil(controller.snapshot.pendingPlan)
        XCTAssertEqual(controller.snapshot.errorMessage, "确认已超时，请重新发起清理")
        XCTAssertEqual(executor.callCount, 0)
    }

    /// 确认窗口不得越过过期时刻：在门限前 10 秒进入确认，窗口只剩 10 秒而不是 60 秒。
    func testConfirmationWindowNeverOutlivesTheExpiryGate() async throws {
        let clock = TestDiskCleanClock(now: observedAt)
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent, clock: clock)
        clock.advance(by: DiskCleanScanFreshness.window - 10)
        controller.clean()
        XCTAssertEqual(controller.snapshot.phase, .confirming)

        clock.advance(by: 10)

        await waitUntil("过期门到点即作废") { controller.snapshot.phase == .scanned }
        XCTAssertNil(controller.snapshot.pendingPlan)
        XCTAssertEqual(executor.callCount, 0, "确认窗口绝不能把执行推到过期门之外")
    }

    func testCancelCurrentOperationDiscardsPendingPlan() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent)
        controller.clean()

        controller.cancelCurrentOperation()

        XCTAssertEqual(controller.snapshot.phase, .scanned)
        XCTAssertNil(controller.snapshot.pendingPlan)
    }

    // MARK: - 计划铸造失败

    /// 铸造失败 = 零删除。原因如实上报，不降级成"部分清理"。
    func testPlanMintingFailureSurfacesErrorAndSkipsExecution() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let executor = FakeDiskCleanExecutor()
        // 计划路径覆盖了一个锁定候选 → 祖先断言拒绝。
        let parent = DiskCleanPlanFactory.candidate(path: "/cache/app", bytes: 1_024)
        let lockedChild = DiskCleanPlanFactory.candidate(
            path: "/cache/app/inner",
            safety: .inUse(processName: "App")
        )
        let controller = makeController(engine: engine, executor: executor)
        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [parent, lockedChild])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }

        controller.clean()

        XCTAssertEqual(executor.callCount, 0)
        XCTAssertEqual(controller.snapshot.phase, .scanned)
        XCTAssertEqual(
            controller.snapshot.errorMessage,
            "计划路径 /cache/app 覆盖受保护路径 /cache/app/inner"
        )
    }

    func testPreflightFailureFromExecutorReturnsToScannedWithMessage() async throws {
        let executor = FakeDiskCleanExecutor(failure: DiskCleanExecutionError.planExpired)
        let controller = try await makeScannedController(executor: executor, mode: .trash)

        controller.clean()
        await waitUntil("执行失败已发布") { controller.snapshot.errorMessage != nil }

        XCTAssertEqual(controller.snapshot.phase, .scanned)
        XCTAssertEqual(controller.snapshot.errorMessage, "扫描结果已过期，请重新扫描")
    }

    func testRemovalModeIsLoadedFromStoreAndPersistedOnChange() {
        let store = InMemoryDiskCleanRemovalModeStore(mode: .permanent)
        let controller = DiskCleanController(
            engine: ControlledDiskCleanScanEngine(),
            executor: FakeDiskCleanExecutor(),
            clock: TestDiskCleanClock(),
            removalModeStore: store
        )

        XCTAssertEqual(controller.snapshot.removalMode, .permanent, "启动时沿用上次的选择")

        controller.setRemovalMode(.trash)

        XCTAssertEqual(store.savedMode, .trash)
        XCTAssertEqual(controller.snapshot.removalMode, .trash)
    }

    // MARK: - 夹具

    private func makeController(
        engine: any DiskCleanScanning,
        executor: any DiskCleanExecuting = FakeDiskCleanExecutor(),
        clock: any DiskCleanClock = TestDiskCleanClock(),
        mode: DiskCleanRemovalMode = .trash
    ) -> DiskCleanController {
        DiskCleanController(
            engine: engine,
            executor: executor,
            clock: clock,
            removalModeStore: InMemoryDiskCleanRemovalModeStore(mode: mode),
            catalog: DiskCleanPlanFactory.catalog()
        )
    }

    /// 扫完一轮、只有一个可清理候选（1024 字节）的控制器。
    private func makeScannedController(
        executor: any DiskCleanExecuting,
        mode: DiskCleanRemovalMode,
        clock: any DiskCleanClock = TestDiskCleanClock()
    ) async throws -> DiskCleanController {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine, executor: executor, clock: clock, mode: mode)
        controller.scan()
        await waitUntil("扫描开始") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("扫描完成") { controller.snapshot.phase == .scanned }
        return controller
    }

    private func makeCandidate(
        id: String,
        path: String,
        category: DiskCleanCategoryID = .appCaches,
        risk: DiskCleanRisk = .low,
        safety: DiskCleanSafetyStatus = .allowed
    ) -> DiskCleanCandidate {
        DiskCleanCandidate(
            id: id,
            targetID: DiskCleanPlanFactory.targetID,
            legacyRuleID: DiskCleanPlanFactory.targetID,
            category: category,
            path: path,
            risk: risk,
            safety: safety
        )
    }

    private func makeSizedCandidate(
        id: String,
        path: String,
        bytes: Int64 = 1_024,
        risk: DiskCleanRisk = .low,
        observedAt: Date? = nil
    ) -> DiskCleanCandidate {
        makeCandidate(id: id, path: path, risk: risk)
            .applying(.testComplete(bytes: bytes, observedAt: observedAt ?? self.observedAt))
    }

    private func makeSummary(
        candidates: [DiskCleanCandidate],
        limitations: [DiskCleanScanLimitation] = [],
        scope: DiskCleanScanScope = .rules(choices: Set(DiskCleanChoice.allCases))
    ) -> DiskCleanScanSummary {
        DiskCleanScanSummary(
            artifact: DiskCleanScanArtifact(
                scope: scope,
                candidates: candidates,
                reservedRootPaths: [],
                limitations: limitations,
                startedAt: observedAt,
                finishedAt: observedAt
            )
        )
    }
}
