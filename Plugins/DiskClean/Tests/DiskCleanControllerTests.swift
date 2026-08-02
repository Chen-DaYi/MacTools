import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

@MainActor
final class DiskCleanControllerTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 10_000)

    // MARK: - Event stream consumption

    func testConsumesStreamAndPublishesScannedResult() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }

        let candidate = makeCandidate(id: "a", path: "/cache/a")
        engine.emit(.candidateFound(candidate))
        engine.emit(.candidateSized(id: candidate.id, result: .testComplete(bytes: 2_048, observedAt: observedAt)))
        engine.emit(.finished(makeSummary(candidates: [candidate.applying(.testComplete(bytes: 2_048, observedAt: observedAt))])))

        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }
        let result = try XCTUnwrap(controller.snapshot.scanResult)
        XCTAssertEqual(result.cleanableCandidates.map(\.id), ["a"])
        XCTAssertEqual(result.cleanableSizeBytes, 2_048)
        XCTAssertNotNil(result.artifact, "finished scan must carry an artifact — M4 clean entry only accepts artifacts")
        XCTAssertTrue(controller.snapshot.canClean)
    }

    func testStreamingCandidatesAreVisibleBeforeScanFinishes() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(.candidateFound(makeCandidate(id: "a", path: "/cache/a")))

        // Throttled publish: appearing within ~250ms is expected; not required to be immediately visible.
        await waitUntil("streaming candidates visible") { controller.snapshot.scanResult?.candidates.count == 1 }
        XCTAssertEqual(controller.snapshot.phase, .scanning)
        XCTAssertFalse(controller.snapshot.canClean, "cannot clean while scanning")
    }

    func testPropagatesLimitationsFromSummary() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(
            .finished(
                makeSummary(candidates: [], limitations: [.walkerCircuitBroken, .threadsAbandoned(count: 2)])
            )
        )

        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }
        let result = try XCTUnwrap(controller.snapshot.scanResult)
        XCTAssertEqual(result.limitations, [.walkerCircuitBroken, .threadsAbandoned(count: 2)])
        XCTAssertTrue(result.isLimited)
    }

    func testScanFailurePublishesErrorMessage() async {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.fail(with: FakeDiskCleanExpansionError(message: "engine exploded"))

        await waitUntil("failure published") { controller.snapshot.errorMessage != nil }
        XCTAssertEqual(controller.snapshot.phase, .idle)
        XCTAssertEqual(controller.snapshot.errorMessage, "engine exploded")
    }

    // MARK: - operationID generations

    func testEventsFromSupersededOperationAreDiscarded() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        // Cancel scan → previous operationID is invalidated.
        controller.cancelCurrentOperation()
        XCTAssertEqual(controller.snapshot.phase, .idle)

        // Tail events from a superseded operation must never push state back to scanned.
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
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        controller.cancelCurrentOperation()

        await waitUntil("engine stream terminated") { engine.didTerminate }
    }

    func testRescanUsesFreshOperationAndResetsLog() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("first round finished") { controller.snapshot.phase == .scanned }

        controller.scan()

        XCTAssertEqual(engine.scanCallCount, 2)
        XCTAssertEqual(controller.snapshot.scanLogEntries.count, 1, "a new scan starts with a clean log")
        XCTAssertNil(controller.snapshot.scanResult)
    }

    // MARK: - Expiry gate

    func testExpiryClockFlipsCanCleanAndNotifiesStateChange() async throws {
        let clock = TestDiskCleanClock(now: observedAt)
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine, clock: clock)
        var stateChangeCount = 0
        controller.onStateChange = { stateChangeCount += 1 }

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }
        XCTAssertTrue(controller.snapshot.canClean)

        let changesBeforeExpiry = stateChangeCount
        clock.advance(by: DiskCleanScanFreshness.window)

        await waitUntil("expiry gate fired") { controller.snapshot.isResultExpired }
        XCTAssertFalse(controller.snapshot.canClean, "cannot clean after expiry")
        XCTAssertGreaterThan(
            stateChangeCount,
            changesBeforeExpiry,
            "expiry is time-driven: notify host to refresh when due, without waiting for a user click"
        )
        XCTAssertEqual(controller.snapshot.subtitle, "结果已过期，请重新扫描")
    }

    func testExpiryDeadlineUsesEarliestObservedAtAmongCleanableCandidates() async throws {
        let clock = TestDiskCleanClock(now: observedAt)
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine, clock: clock)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(
            .finished(
                makeSummary(candidates: [
                    makeSizedCandidate(id: "old", path: "/cache/old", observedAt: observedAt),
                    makeSizedCandidate(id: "new", path: "/cache/new", observedAt: observedAt.addingTimeInterval(100))
                ])
            )
        )
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }

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
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }
        XCTAssertEqual(engine.lastForceRefresh, false)

        clock.advance(by: DiskCleanScanFreshness.window)
        await waitUntil("expiry gate fired") { controller.snapshot.isResultExpired }
        controller.scan()

        XCTAssertEqual(
            engine.lastForceRefresh,
            true,
            "rescan after expiry must bypass cache, or it loops: expired → rescan → hit stale cache → still expired"
        )
    }

    func testCleanDropsCandidatesWithIncompleteSize() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let executor = FakeDiskCleanExecutor()
        let controller = makeController(engine: engine, executor: executor)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        let complete = makeSizedCandidate(id: "complete", path: "/cache/complete")
        let partial = makeCandidate(id: "partial", path: "/cache/partial")
            .applying(.testPartial(reasons: [.timedOut], observedAt: observedAt))
        let unsized = makeCandidate(id: "unsized", path: "/cache/unsized")
        engine.emit(.finished(makeSummary(candidates: [complete, partial, unsized])))
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }

        controller.clean()
        await waitUntil("clean finished") { controller.snapshot.phase == .completed }

        XCTAssertEqual(
            executor.lastSelectedIDs,
            ["complete"],
            "unknown-size and partial candidates never enter the clean set (first line of §3.1 invariants)"
        )
    }

    func testCleanIsIgnoredWhenNothingIsSelectable() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let executor = FakeDiskCleanExecutor()
        let controller = makeController(engine: engine, executor: executor)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        let partial = makeCandidate(id: "partial", path: "/cache/partial")
            .applying(.testPartial(reasons: [.permissionDenied], observedAt: observedAt))
        engine.emit(.finished(makeSummary(candidates: [partial])))
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }

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
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }
        clock.advance(by: DiskCleanScanFreshness.window)
        await waitUntil("expiry gate fired") { controller.snapshot.isResultExpired }

        controller.clean()

        XCTAssertEqual(executor.callCount, 0)
    }

    // MARK: - Selection commands (§8.1)
    func testStreamingCandidateJoinsSelectionOnlyOnceItsSizeIsKnown() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        let candidate = makeCandidate(id: "a", path: "/cache/a")
        engine.emit(.candidateFound(candidate))
        await waitUntil("candidates visible") { controller.snapshot.scanResult?.candidates.count == 1 }

        XCTAssertTrue(
            controller.snapshot.selection.isEmpty,
            "unknown-size candidates cannot be selected; default policy must not pull them in"
        )

        engine.emit(.candidateSized(id: candidate.id, result: .testComplete(bytes: 512, observedAt: observedAt)))

        await waitUntil("auto-selected by default policy after sizing") { controller.snapshot.selection.selectedIDs == ["a"] }
    }

    func testCleanSubmitsExactlyTheSelectedSet() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let executor = FakeDiskCleanExecutor()
        let controller = makeController(engine: engine, executor: executor)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(
            .finished(
                makeSummary(candidates: [
                    makeSizedCandidate(id: "keep", path: "/cache/keep"),
                    makeSizedCandidate(id: "drop", path: "/cache/drop")
                ])
            )
        )
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }

        controller.setCandidateSelected("drop", isSelected: false)
        controller.clean()
        await waitUntil("clean finished") { controller.snapshot.phase == .completed }

        XCTAssertEqual(executor.lastSelectedIDs, ["keep"], "menu bar and detail page share the same selection set")
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
        XCTAssertEqual(executor.callCount, 0, "once selection changes, the frozen plan no longer matches any user intent")
    }

    func testChangingScopeMarksResultStale() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }

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
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }

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

    // MARK: - P2 section scope (design §10)

    /// One Controller type serves three sections; replace the whole scan scope — P2 needs no separate state machine.
    func testScanForwardsDeveloperArtifactRootsToEngine() async {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.setScope(.developerArtifacts(roots: ["/code"]))
        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }

        XCTAssertEqual(engine.lastScope, .developerArtifacts(roots: ["/code"]))
    }

    /// Adding/removing scan roots is the same as changing groups: when results no longer match current scope, prompt for rescan.
    func testChangingDeveloperArtifactRootsMarksResultStale() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)
        controller.setScope(.developerArtifacts(roots: ["/code"]))

        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(
            .finished(
                makeSummary(
                    candidates: [makeSizedCandidate(id: "a", path: "/code/app/node_modules")],
                    scope: .developerArtifacts(roots: ["/code"])
                )
            )
        )
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }
        XCTAssertTrue(controller.snapshot.canClean)

        controller.setScope(.developerArtifacts(roots: ["/code", "/work"]))

        XCTAssertTrue(controller.snapshot.isResultStale)
        XCTAssertFalse(controller.snapshot.canClean)
    }

    /// With no scan roots configured, scan entry must be disabled, or the user would click and nothing happens.
    func testScanIsRejectedWhenDeveloperArtifactRootsAreEmpty() {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine)

        controller.setScope(.developerArtifacts(roots: []))
        controller.scan()

        XCTAssertFalse(controller.snapshot.canScan)
        XCTAssertEqual(engine.scanCallCount, 0)
    }

    /// Installer section scope is fixed and always scannable.
    func testTrashModeExecutesInOneStepWithoutConfirmation() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .trash)

        controller.clean()
        await waitUntil("clean finished") { controller.snapshot.phase == .completed }

        XCTAssertEqual(executor.callCount, 1, "Trash is recoverable, so execute in one step")
        XCTAssertEqual(executor.lastMode, .trash)
    }

    func testPermanentModeEntersConfirmingWithFrozenSummary() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent)

        controller.clean()

        XCTAssertEqual(controller.snapshot.phase, .confirming)
        XCTAssertEqual(executor.callCount, 0, "not a single byte may be deleted before confirmation")
        let pending = try XCTUnwrap(controller.snapshot.pendingPlan)
        XCTAssertEqual(pending.itemCount, 1)
        XCTAssertEqual(pending.totalEstimatedBytes, 1_024)
        XCTAssertEqual(pending.mode, .permanent)
        XCTAssertFalse(controller.snapshot.canScan, "no new scans accepted during confirmation")
    }

    func testConfirmingExecutesTheFrozenPlan() async throws {
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent)
        controller.clean()

        controller.confirmPendingClean()
        await waitUntil("clean finished") { controller.snapshot.phase == .completed }

        XCTAssertEqual(executor.callCount, 1)
        XCTAssertEqual(executor.lastMode, .permanent)
        XCTAssertEqual(executor.lastSelectedIDs, ["a"])
        XCTAssertNil(controller.snapshot.pendingPlan, "plan is no longer attached to the snapshot after execution")
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
        XCTAssertEqual(executor.callCount, 0, "plan is voided; confirmation must not take effect again")
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
        XCTAssertEqual(executor.callCount, 0, "removal mode is a frozen field; changing it requires reminting")
    }

    func testConfirmationWindowExpiresAfterSixtySeconds() async throws {
        let clock = TestDiskCleanClock(now: observedAt)
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent, clock: clock)
        controller.clean()
        XCTAssertEqual(controller.snapshot.phase, .confirming)

        clock.advance(by: DiskCleanController.confirmationWindow)

        await waitUntil("confirmation window expired") { controller.snapshot.phase == .scanned }
        XCTAssertNil(controller.snapshot.pendingPlan)
        XCTAssertEqual(controller.snapshot.errorMessage, "确认已超时，请重新发起清理")
        XCTAssertEqual(executor.callCount, 0)
    }

    /// Confirmation window must not cross expiry: enter confirmation 10s before the gate, window is 10s not 60s.
    func testConfirmationWindowNeverOutlivesTheExpiryGate() async throws {
        let clock = TestDiskCleanClock(now: observedAt)
        let executor = FakeDiskCleanExecutor()
        let controller = try await makeScannedController(executor: executor, mode: .permanent, clock: clock)
        clock.advance(by: DiskCleanScanFreshness.window - 10)
        controller.clean()
        XCTAssertEqual(controller.snapshot.phase, .confirming)

        clock.advance(by: 10)

        await waitUntil("voided when expiry gate fires") { controller.snapshot.phase == .scanned }
        XCTAssertNil(controller.snapshot.pendingPlan)
        XCTAssertEqual(executor.callCount, 0, "confirmation window must never push execution past the expiry gate")
    }

    func testPlanMintingFailureSurfacesErrorAndSkipsExecution() async throws {
        let engine = ControlledDiskCleanScanEngine()
        let executor = FakeDiskCleanExecutor()
        // Planned path covers a locked candidate → ancestor assertion rejects.
        let parent = DiskCleanPlanFactory.candidate(path: "/cache/app", bytes: 1_024)
        let lockedChild = DiskCleanPlanFactory.candidate(
            path: "/cache/app/inner",
            safety: .inUse(processName: "App")
        )
        let controller = makeController(engine: engine, executor: executor)
        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [parent, lockedChild])))
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }

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
        await waitUntil("execution failure published") { controller.snapshot.errorMessage != nil }

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

        XCTAssertEqual(controller.snapshot.removalMode, .permanent, "load previous choice at startup")

        controller.setRemovalMode(.trash)

        XCTAssertEqual(store.savedMode, .trash)
        XCTAssertEqual(controller.snapshot.removalMode, .trash)
    }

    // MARK: - Fixtures

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

    /// Controller after one finished scan with a single cleanable candidate (1024 bytes).
    private func makeScannedController(
        executor: any DiskCleanExecuting,
        mode: DiskCleanRemovalMode,
        clock: any DiskCleanClock = TestDiskCleanClock()
    ) async throws -> DiskCleanController {
        let engine = ControlledDiskCleanScanEngine()
        let controller = makeController(engine: engine, executor: executor, clock: clock, mode: mode)
        controller.scan()
        await waitUntil("scan started") { controller.snapshot.phase == .scanning }
        engine.emit(.finished(makeSummary(candidates: [makeSizedCandidate(id: "a", path: "/cache/a")])))
        await waitUntil("scan finished") { controller.snapshot.phase == .scanned }
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
