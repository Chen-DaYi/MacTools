import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanScanEngineTests: XCTestCase {
    private let home = "/Users/diskclean-tester"

    // MARK: - 事件流

    func testEmitsEveryCandidateFoundBeforeAnyCandidateSized() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems(
            [.testDirectory("\(home)/Library/Caches/A"), .testDirectory("\(home)/Library/Caches/B")],
            forPattern: "\(home)/Library/Caches/*"
        )
        let engine = makeEngine(
            fileSystem: fileSystem,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        let events = try await collect(engine)

        let lastFoundIndex = try XCTUnwrap(events.lastIndex { $0.isCandidateFound })
        let firstSizedIndex = try XCTUnwrap(events.firstIndex { $0.isCandidateSized })
        XCTAssertLessThan(
            lastFoundIndex,
            firstSizedIndex,
            "展开阶段必须先把全部条目流式发出，用户才能在 1-2 秒内看到内容"
        )
        XCTAssertEqual(events.filter(\.isCandidateFound).count, 2)
        XCTAssertEqual(events.filter(\.isCandidateSized).count, 2)
    }

    func testFoundCandidatesCarryNoSizeAndAreNotCleanable() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("\(home)/Library/Caches/A")], forPattern: "\(home)/Library/Caches/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        let events = try await collect(engine)
        let found = try XCTUnwrap(events.compactMap(\.candidateFound).first)

        XCTAssertNil(found.sizeResult)
        XCTAssertFalse(found.isCleanable, "大小未知的候选不可勾选（§3.1 不变量）")
        XCTAssertEqual(found.id, "cache.a::\(home)/Library/Caches/A")
        XCTAssertEqual(found.legacyRuleID, "cache.a")
        XCTAssertEqual(found.choice, .cache)
    }

    func testFinishedSummaryCountsOnlyCompleteCandidatesAsCleanable() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems(
            [
                .testDirectory("\(home)/Library/Caches/Complete"),
                .testDirectory("\(home)/Library/Caches/Partial")
            ],
            forPattern: "\(home)/Library/Caches/*"
        )
        let executor = FakeDiskCleanSizingExecutor()
        executor.setResult(.testComplete(bytes: 500), forPath: "\(home)/Library/Caches/Complete")
        executor.setResult(
            .testPartial(reasons: [.permissionDenied]),
            forPath: "\(home)/Library/Caches/Partial"
        )
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: executor,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        let summary = try await finish(engine)

        XCTAssertEqual(summary.candidateCount, 2)
        XCTAssertEqual(summary.cleanableCount, 1)
        XCTAssertEqual(summary.cleanableEstimatedBytes, 500)
        XCTAssertEqual(
            summary.artifact.exclusionPaths,
            ["\(home)/Library/Caches/Partial"],
            "非 complete 的候选必须进排除集，供 M4 Planner 做祖先断言"
        )
    }

    func testEmitsCategoryFinishedForEveryScopedCategory() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("\(home)/Library/Caches/A")], forPattern: "\(home)/Library/Caches/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            targets: [
                .test(id: "cache.a", category: .appCaches, globs: ["\(home)/Library/Caches/*"]),
                // 一条命中为空的 target：分类同样要收尾，否则 UI 会永远停在"扫描中"。
                .test(id: "cache.b", category: .logs, globs: ["\(home)/Library/Logs/*"])
            ]
        )

        let events = try await collect(engine)
        let finishedCategories = events.compactMap(\.finishedCategory)

        XCTAssertEqual(Set(finishedCategories), [.appCaches, .logs])
    }

    // MARK: - 并发与超时

    func testLimitsConcurrentSizingToConfiguredMaximum() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        let items = (0..<12).map { DiskCleanFileItem.testDirectory("\(home)/Library/Caches/Item\($0)") }
        fileSystem.setItems(items, forPattern: "\(home)/Library/Caches/*")
        let executor = FakeDiskCleanSizingExecutor(delay: .milliseconds(30))
        var configuration = DiskCleanScanEngineConfiguration()
        configuration.maximumConcurrentSizing = 3
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: executor,
            configuration: configuration,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        _ = try await finish(engine)

        XCTAssertEqual(executor.requestedPaths.count, 12)
        XCTAssertLessThanOrEqual(executor.peakConcurrency, 3)
        XCTAssertGreaterThan(executor.peakConcurrency, 1, "并发窗口必须真的滑动，不能退化成串行")
    }

    func testPassesItemDeadlineClampedByGlobalDeadline() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("\(home)/Library/Caches/A")], forPattern: "\(home)/Library/Caches/*")
        let executor = FakeDiskCleanSizingExecutor()
        var configuration = DiskCleanScanEngineConfiguration()
        configuration.itemTimeout = 20
        configuration.globalTimeout = 5
        let startedAt = Date(timeIntervalSince1970: 50_000)
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: executor,
            configuration: configuration,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])],
            now: { startedAt }
        )

        _ = try await finish(engine)

        XCTAssertEqual(
            executor.deadlines,
            [startedAt.addingTimeInterval(5)],
            "单项 deadline 不得越过全局 deadline"
        )
    }

    func testGlobalDeadlineAlreadyPassedStillReportsTimedOutInsteadOfHanging() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("\(home)/Library/Caches/A")], forPattern: "\(home)/Library/Caches/*")
        let executor = FakeDiskCleanSizingExecutor()
        var configuration = DiskCleanScanEngineConfiguration()
        configuration.globalTimeout = 0
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: executor,
            configuration: configuration,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        let summary = try await finish(engine)

        XCTAssertTrue(executor.requestedPaths.isEmpty, "全局超时后不再提交 sizing")
        XCTAssertEqual(
            summary.artifact.candidates.first?.sizeResult?.completeness,
            .partial(reasons: [.timedOut]),
            "仍必须出事件，否则 UI 永远停在计算中"
        )
    }

    /// 真实 WorkerPool + 阻塞 sizer：单项 deadline 到期必须降级为 partial([.timedOut])。
    func testItemTimeoutProducesPartialResultThroughRealWorkerPool() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("\(home)/Library/Caches/Slow")], forPattern: "\(home)/Library/Caches/*")
        // 放弃预算给足：这里要测的是超时降级，不是熔断。
        let pool = DiskCleanWorkerPool(maxThreadCount: 3, abandonBudget: 1_000)
        defer { pool.shutDown() }
        var configuration = DiskCleanScanEngineConfiguration()
        configuration.itemTimeout = 0.2
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: pool,
            sizer: FakeDiskCleanSizer(blockingDuration: 1.5),
            configuration: configuration,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        let summary = try await finish(engine)

        XCTAssertEqual(
            summary.artifact.candidates.first?.sizeResult?.completeness,
            .partial(reasons: [.timedOut])
        )
        XCTAssertEqual(summary.cleanableCount, 0, "超时候选不可清理")
    }

    // MARK: - 取消

    func testCancellingConsumerStopsDerivingNewSizingTasks() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        let items = (0..<20).map { DiskCleanFileItem.testDirectory("\(home)/Library/Caches/Item\($0)") }
        fileSystem.setItems(items, forPattern: "\(home)/Library/Caches/*")
        let executor = FakeDiskCleanSizingExecutor(delay: .milliseconds(20))
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: executor,
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        // 消费方在收到第一个 sized 后就退出循环 → onTermination → 引擎根任务取消。
        var sizedCount = 0
        do {
            for try await event in engine.scan(choices: [.cache], forceRefresh: false) {
                if event.isCandidateSized {
                    sizedCount += 1
                    break
                }
            }
        } catch is CancellationError {
            // 取消传导本身就是预期行为。
        }
        XCTAssertEqual(sizedCount, 1)

        // 给已在飞的任务留出收尾时间，再确认没有继续派生。
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertLessThan(
            executor.requestedPaths.count,
            items.count,
            "取消后不得继续派生新的 sizing 任务"
        )
    }

    func testCancelledTaskFinishesStreamWithCancellationError() async {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("\(home)/Library/Caches/A")], forPattern: "\(home)/Library/Caches/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: FakeDiskCleanSizingExecutor(delay: .milliseconds(200)),
            targets: [.test(id: "cache.a", globs: ["\(home)/Library/Caches/*"])]
        )

        let task = Task { () -> Error? in
            do {
                for try await _ in engine.scan(choices: [.cache], forceRefresh: false) {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        let error = await task.value
        XCTAssertTrue(error is CancellationError)
    }

    // MARK: - 扫描范围（面板等价）

    func testScopeFiltersTargetsByLegacyRuleIDPrefix() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("/cache/item")], forPattern: "/cache/*")
        fileSystem.setItems([.testDirectory("/developer/item")], forPattern: "/developer/*")
        fileSystem.setItems([.testDirectory("/browser/item")], forPattern: "/browser/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            targets: [
                .test(id: "cache.x", legacyRuleID: "cache.x", globs: ["/cache/*"]),
                // 分类是 developer，但 legacy 前缀是 browser——面板归属必须跟 legacy 前缀走，
                // 这正是"按分类选择"会改变扫描覆盖面的那类 target。
                .test(
                    id: "browser.service-worker.editors",
                    legacyRuleID: "browser.service-worker",
                    category: .developer,
                    globs: ["/browser/*"]
                ),
                .test(id: "developer.y", legacyRuleID: "developer.y", category: .developer, globs: ["/developer/*"])
            ]
        )

        let summary = try await finish(engine, choices: [.browser])

        XCTAssertEqual(summary.artifact.candidates.map(\.path), ["/browser/item"])
    }

    // MARK: - limitations

    func testReportsFullDiskAccessRestrictionWithReservedRootsInArtifact() async throws {
        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            fullDiskAccess: FakeDiskCleanFullDiskAccess(hasFullDiskAccess: false),
            targets: [
                .test(
                    id: "cache.system",
                    globs: ["/private/var/log/*"],
                    reservedRootPaths: ["/private/var/log"],
                    requiresFullDiskAccess: true
                )
            ]
        )

        let summary = try await finish(engine)

        XCTAssertEqual(summary.limitations, [.fdaRestricted(skippedTargetIDs: ["cache.system"])])
        XCTAssertEqual(
            summary.artifact.reservedRootPaths,
            ["/private/var/log"],
            "被跳过 target 的保留根必须进工件：未扫描子树的祖先绝不可被删"
        )
    }

    func testReportsDynamicRuleFailureAndKeepsScanningOtherTargets() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("/cache/item")], forPattern: "/cache/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            targets: [
                .test(
                    id: "cache.dynamic",
                    provider: FakeFailingDynamicRuleProvider(),
                    reservedRootPaths: ["/dynamic/root"]
                ),
                .test(id: "cache.static", globs: ["/cache/*"])
            ]
        )

        let summary = try await finish(engine)

        XCTAssertEqual(
            summary.limitations,
            [.dynamicRuleFailed(targetID: "cache.dynamic", reason: "provider exploded")]
        )
        XCTAssertEqual(summary.artifact.reservedRootPaths, ["/dynamic/root"])
        XCTAssertEqual(summary.artifact.candidates.map(\.path), ["/cache/item"], "一条规则失败不阻塞其它规则")
    }

    func testReportsPathExpansionFailureSeparatelyFromDynamicFailure() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setError(FakeDiskCleanExpansionError(message: "glob blew up"), forPattern: "/cache/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            targets: [.test(id: "cache.static", globs: ["/cache/*"], reservedRootPaths: ["/cache"])]
        )

        let summary = try await finish(engine)

        XCTAssertEqual(
            summary.limitations,
            [.targetExpansionFailed(targetID: "cache.static", reason: "glob blew up")]
        )
        XCTAssertEqual(summary.artifact.reservedRootPaths, ["/cache"])
    }

    func testReportsVolumeSkippedFromSizeResults() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("/cache/item")], forPattern: "/cache/*")
        let executor = FakeDiskCleanSizingExecutor()
        executor.setResult(.testPartial(reasons: [.unsupportedVolume]), forPath: "/cache/item")
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: executor,
            targets: [.test(id: "cache.a", globs: ["/cache/*"])]
        )

        let summary = try await finish(engine)

        XCTAssertEqual(summary.limitations, [.volumeSkipped(path: "/cache/item")])
    }

    func testDerivesCircuitBreakerAndAbandonedThreadsFromPoolState() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("/cache/item")], forPattern: "/cache/*")
        let executor = FakeDiskCleanSizingExecutor()
        executor.setPoolState(isCircuitBroken: true, abandonedThreads: 3)
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: executor,
            targets: [.test(id: "cache.a", globs: ["/cache/*"])]
        )

        let summary = try await finish(engine)

        XCTAssertTrue(summary.limitations.contains(.walkerCircuitBroken))
        XCTAssertTrue(summary.limitations.contains(.threadsAbandoned(count: 3)))
    }

    func testCapsVolumeSkippedReportsSoLimitationsStayBounded() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        let items = (0..<30).map { DiskCleanFileItem.testDirectory("/cache/item\($0)") }
        fileSystem.setItems(items, forPattern: "/cache/*")
        let executor = FakeDiskCleanSizingExecutor()
        executor.setDefaultResult(.testPartial(reasons: [.unsupportedVolume]))
        var configuration = DiskCleanScanEngineConfiguration()
        configuration.maximumVolumeSkippedReports = 4
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: executor,
            configuration: configuration,
            targets: [.test(id: "cache.a", globs: ["/cache/*"])]
        )

        let summary = try await finish(engine)

        XCTAssertEqual(summary.limitations.count, 4)
    }

    // MARK: - 锁定判定

    func testLockedTargetProducesInUseCandidatesThatAreNotCleanable() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("/cache/chrome")], forPattern: "/cache/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            runningAppLock: FakeDiskCleanRunningAppLock(
                snapshot: DiskCleanRunningAppSnapshot(runningBundleIDs: ["com.google.chrome"])
            ),
            targets: [
                .test(id: "cache.a", globs: ["/cache/*"], lockedByBundleIDs: ["com.google.Chrome"])
            ]
        )

        let summary = try await finish(engine)
        let candidate = try XCTUnwrap(summary.artifact.candidates.first)

        XCTAssertEqual(candidate.safety, .inUse(processName: "com.google.Chrome"))
        XCTAssertFalse(candidate.isCleanable)
    }

    func testQueriesRunningProcessNamesOfScopedTargetsOnlyOnce() async throws {
        final class RecordingLock: DiskCleanRunningAppSnapshotting, @unchecked Sendable {
            private let storage = NSLock()
            private var requests: [[String]] = []
            var recordedRequests: [[String]] { storage.withLock { requests } }

            func makeSnapshot(processNames: [String]) async -> DiskCleanRunningAppSnapshot {
                storage.withLock { requests.append(processNames) }
                return DiskCleanRunningAppSnapshot()
            }
        }

        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("/cache/a")], forPattern: "/cache/*")
        let lock = RecordingLock()
        let engine = makeEngine(
            fileSystem: fileSystem,
            runningAppLock: lock,
            targets: [
                .test(id: "cache.a", globs: ["/cache/*"], skipWhenProcessIsRunning: ["Docker", "Xcode"]),
                .test(id: "cache.b", globs: ["/other/*"], skipWhenProcessIsRunning: ["Docker"])
            ]
        )

        _ = try await finish(engine)

        XCTAssertEqual(
            lock.recordedRequests,
            [["Docker", "Xcode"]],
            "一次快照查全部进程名，替换 v1 的每规则一次 pgrep"
        )
    }

    // MARK: - 缓存接线

    func testSizeCacheHitSkipsSizerAndPreservesObservedAt() async throws {
        let path = "/cache/item"
        let identity = DiskCleanRootIdentity.test(devid: 7, fileID: 9)
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let cache = DiskCleanSizeCache()
        cache.store(
            path: path,
            result: .testComplete(bytes: 4_096, identity: identity, observedAt: observedAt),
            now: observedAt
        )
        let sizer = FakeDiskCleanSizer()
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory(path)], forPattern: "/cache/*")
        let readAt = observedAt.addingTimeInterval(10)
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: DirectDiskCleanSizingExecutor(now: { readAt }),
            sizer: sizer,
            sizeCache: cache,
            identityProbe: FakeDiskCleanRootIdentityProbe(identitiesByPath: [path: identity]),
            targets: [.test(id: "cache.a", globs: ["/cache/*"])],
            now: { readAt }
        )

        let summary = try await finish(engine)

        XCTAssertTrue(sizer.calledPaths.isEmpty, "命中缓存不得再遍历目录")
        XCTAssertEqual(summary.artifact.candidates.first?.sizeResult?.estimatedBytes, 4_096)
        XCTAssertEqual(
            summary.artifact.candidates.first?.sizeResult?.observedAt,
            observedAt,
            "observedAt 必须传导缓存条目的原始观测时刻，否则过期门被架空"
        )
    }

    func testForceRefreshBypassesSizeCache() async throws {
        let path = "/cache/item"
        let identity = DiskCleanRootIdentity.test()
        let cache = DiskCleanSizeCache()
        cache.store(path: path, result: .testComplete(bytes: 4_096, identity: identity), now: Date())
        let sizer = FakeDiskCleanSizer()
        sizer.setResult(.testComplete(bytes: 8_192, identity: identity), forPath: path)
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory(path)], forPattern: "/cache/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            sizingExecutor: DirectDiskCleanSizingExecutor(),
            sizer: sizer,
            sizeCache: cache,
            identityProbe: FakeDiskCleanRootIdentityProbe(identitiesByPath: [path: identity]),
            targets: [.test(id: "cache.a", globs: ["/cache/*"])]
        )

        let summary = try await finish(engine, forceRefresh: true)

        XCTAssertEqual(sizer.calledPaths, [path])
        XCTAssertEqual(summary.artifact.candidates.first?.sizeResult?.estimatedBytes, 8_192)
    }

    // MARK: - P2 分段接入统一管线（设计 §10）

    /// 核心断言：专用扫描器发现的候选与规则候选**走的是同一条管线**——
    /// 同样求大小、同样判定完整性、同样进工件，因此同样能被 `makePlan` 铸造成计划。
    /// 任何绕开这条管线的删除路径都会让这个测试失去意义。
    func testDeveloperArtifactCandidatesFlowThroughSizingIntoTheArtifact() async throws {
        let target = DiskCleanRuleTarget.testExternal(id: DiskCleanPurgeKind.nodeModules.targetID)
        let executor = FakeDiskCleanSizingExecutor()
        executor.setResult(.testComplete(bytes: 4_096), forPath: "/code/app/node_modules")

        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            sizingExecutor: executor,
            developerArtifactExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(
                        target: target,
                        item: .testDirectory("/code/app/node_modules"),
                        specificity: 0,
                        facts: DiskCleanCandidateFacts(
                            risk: .low,
                            notes: [.developerProject(path: "/code/app", marker: "package.json")]
                        )
                    )
                ],
                reservedRootPaths: ["/code"]
            ),
            targets: [target]
        )

        let summary = try await finish(engine, scope: .developerArtifacts(roots: ["/code"]))
        let candidate = try XCTUnwrap(summary.artifact.candidates.first)

        XCTAssertEqual(executor.requestedPaths, ["/code/app/node_modules"], "P2 候选必须经统一 sizing")
        XCTAssertEqual(candidate.path, "/code/app/node_modules")
        XCTAssertEqual(candidate.targetID, DiskCleanPurgeKind.nodeModules.targetID)
        XCTAssertEqual(candidate.category, .developerArtifacts)
        XCTAssertEqual(candidate.estimatedBytes, 4_096)
        XCTAssertTrue(candidate.isCleanable)
        XCTAssertEqual(candidate.notes, [.developerProject(path: "/code/app", marker: "package.json")])
    }

    /// 展开来源给的风险覆盖 target 的兜底值；不给就沿用 target（fail-safe 到"不默认勾选"）。
    func testExpansionFactsOverrideTargetRiskPerCandidate() async throws {
        let target = DiskCleanRuleTarget.testExternal(id: DiskCleanPurgeKind.nodeModules.targetID, risk: .medium)
        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            developerArtifactExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(
                        target: target,
                        item: .testDirectory("/code/clean/node_modules"),
                        specificity: 0,
                        facts: DiskCleanCandidateFacts(risk: .low)
                    ),
                    DiskCleanTargetHit(
                        target: target,
                        item: .testDirectory("/code/dirty/node_modules"),
                        specificity: 0,
                        facts: DiskCleanCandidateFacts(
                            notes: [.repositoryHasChanges(repositoryPath: "/code/dirty", reason: .uncommittedChanges)]
                        )
                    )
                ],
                reservedRootPaths: ["/code"]
            ),
            targets: [target]
        )

        let summary = try await finish(engine, scope: .developerArtifacts(roots: ["/code"]))
        let risksByPath = Dictionary(
            summary.artifact.candidates.map { ($0.path, $0.risk) },
            uniquingKeysWith: { first, _ in first }
        )

        XCTAssertEqual(risksByPath["/code/clean/node_modules"], .low)
        XCTAssertEqual(risksByPath["/code/dirty/node_modules"], .medium)
        XCTAssertEqual(
            DiskCleanSelectionModel().projection(for: summary.artifact.candidates).selectedIDs.count,
            1,
            "只有低风险那条默认勾选"
        )
    }

    func testDeveloperArtifactScanReservesConfiguredRoots() async throws {
        let target = DiskCleanRuleTarget.testExternal(id: DiskCleanPurgeKind.nodeModules.targetID)
        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            developerArtifactExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(
                        target: target,
                        item: .testDirectory("/code/app/node_modules"),
                        specificity: 0
                    )
                ],
                reservedRootPaths: ["/code", "/work"]
            ),
            targets: [target]
        )

        let summary = try await finish(engine, scope: .developerArtifacts(roots: ["/code", "/work"]))

        XCTAssertEqual(summary.artifact.reservedRootPaths, ["/code", "/work"])
        XCTAssertEqual(summary.artifact.scope, .developerArtifacts(roots: ["/code", "/work"]))
    }

    /// 保留的扫描根让 Planner 的祖先断言覆盖到 P2：候选在根**之内**照常可删，
    /// 而任何以根为后代的路径（例如根的父目录）一律拒绝。
    func testPlannerAcceptsCandidatesInsideReservedRootsButRejectsTheirAncestors() async throws {
        let target = DiskCleanRuleTarget.testExternal(id: DiskCleanPurgeKind.nodeModules.targetID)
        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            developerArtifactExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(
                        target: target,
                        item: .testDirectory("/code/app/node_modules"),
                        specificity: 0,
                        facts: DiskCleanCandidateFacts(risk: .low)
                    )
                ],
                reservedRootPaths: ["/code"]
            ),
            targets: [target]
        )

        let artifact = try await finish(engine, scope: .developerArtifacts(roots: ["/code"])).artifact
        let candidate = try XCTUnwrap(artifact.candidates.first)

        let plan = try await MainActor.run {
            try DiskCleanPlanner.makePlan(
                artifact: artifact,
                selectedIDs: [candidate.id],
                mode: .trash,
                now: candidate.observedAt ?? Date(),
                catalog: DiskCleanRuleCatalogV2(targets: [target])
            )
        }
        XCTAssertEqual(plan.items.map(\.path), ["/code/app/node_modules"])
        XCTAssertEqual(plan.reservedPrefixes, ["/code"])

        // 同一份证据下，"删掉扫描根的父目录"必须被祖先断言拒绝。
        XCTAssertThrowsError(
            try DiskCleanPlanner.assertNoAncestorViolation(
                plannedPaths: ["/"],
                exclusionPaths: [],
                reservedPrefixes: plan.reservedPrefixes
            )
        ) { error in
            XCTAssertEqual(
                error as? DiskCleanPlanError,
                .ancestorViolation(plannedPath: "/", protectedPath: "/code")
            )
        }
    }

    func testInstallerScopeUsesInstallerExpansionOnly() async throws {
        let installerTarget = DiskCleanRuleTarget.testExternal(
            id: DiskCleanInstallerKind.diskImage.targetID,
            category: .installers,
            reservedRootPaths: ["/downloads"]
        )
        let purgeTarget = DiskCleanRuleTarget.testExternal(id: DiskCleanPurgeKind.nodeModules.targetID)
        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            developerArtifactExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(target: purgeTarget, item: .testDirectory("/code/x/node_modules"), specificity: 0)
                ]
            ),
            installerExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(target: installerTarget, item: .testFile("/downloads/Tool.dmg"), specificity: 0)
                ],
                reservedRootPaths: ["/downloads"]
            ),
            targets: [installerTarget, purgeTarget]
        )

        let summary = try await finish(engine, scope: .installers)

        XCTAssertEqual(summary.artifact.candidates.map(\.path), ["/downloads/Tool.dmg"])
        XCTAssertEqual(summary.artifact.candidates.first?.category, .installers)
    }

    /// 常规三分组扫描**绝不**顺手带上 P2：开发产物要遍历用户工程目录、安装包会触发
    /// `~/Downloads` 的 TCC 弹窗，两者都必须由用户在各自分段里显式发起。
    func testRuleScanNeverInvokesExternalExpansionOrExternalTargets() async throws {
        let fileSystem = FakeDiskCleanFileSystem()
        fileSystem.setItems([.testDirectory("/cache/item")], forPattern: "/cache/*")
        let engine = makeEngine(
            fileSystem: fileSystem,
            developerArtifactExpansion: FakeDiskCleanExternalExpansion(
                hits: [
                    DiskCleanTargetHit(
                        target: .testExternal(id: DiskCleanPurgeKind.nodeModules.targetID),
                        item: .testDirectory("/code/app/node_modules"),
                        specificity: 0
                    )
                ],
                reservedRootPaths: ["/code"]
            ),
            targets: [
                .test(id: "cache.a", globs: ["/cache/*"]),
                .testExternal(id: DiskCleanPurgeKind.nodeModules.targetID),
                .testExternal(id: DiskCleanInstallerKind.diskImage.targetID, category: .installers)
            ]
        )

        let summary = try await finish(engine, choices: Set(DiskCleanChoice.allCases))

        XCTAssertEqual(summary.artifact.candidates.map(\.path), ["/cache/item"])
        XCTAssertFalse(summary.artifact.reservedRootPaths.contains("/code"))
    }

    /// 扫描根不可读要如实上报：`~/Downloads` 被 TCC 拒绝时里面可能有几十 GB，
    /// 报"没有可清理项"是在骗用户。
    func testExternalExpansionLimitationsReachTheSummary() async throws {
        let engine = makeEngine(
            fileSystem: FakeDiskCleanFileSystem(),
            installerExpansion: FakeDiskCleanExternalExpansion(
                reservedRootPaths: ["/downloads"],
                limitations: [.scanRootUnreadable(path: "/downloads", reason: .permissionDenied)]
            ),
            targets: [
                .testExternal(
                    id: DiskCleanInstallerKind.diskImage.targetID,
                    category: .installers,
                    reservedRootPaths: ["/downloads"]
                )
            ]
        )

        let summary = try await finish(engine, scope: .installers)

        XCTAssertEqual(
            summary.limitations,
            [.scanRootUnreadable(path: "/downloads", reason: .permissionDenied)]
        )
        XCTAssertTrue(summary.artifact.candidates.isEmpty)
        XCTAssertEqual(summary.artifact.reservedRootPaths, ["/downloads"])
    }

    // MARK: - 夹具

    private func makeEngine(
        fileSystem: any DiskCleanFileSystemProviding,
        sizingExecutor: any DiskCleanSizingExecuting = FakeDiskCleanSizingExecutor(),
        sizer: any DiskCleanDirectorySizing = FakeDiskCleanSizer(),
        sizeCache: DiskCleanSizeCache = DiskCleanSizeCache(),
        identityProbe: any DiskCleanRootIdentityProbing = FakeDiskCleanRootIdentityProbe(identitiesByPath: [:]),
        runningAppLock: any DiskCleanRunningAppSnapshotting = FakeDiskCleanRunningAppLock(),
        fullDiskAccess: any DiskCleanFullDiskAccessProbing = FakeDiskCleanFullDiskAccess(hasFullDiskAccess: true),
        developerArtifactExpansion: any DiskCleanExternalExpanding = FakeDiskCleanExternalExpansion(),
        installerExpansion: any DiskCleanExternalExpanding = FakeDiskCleanExternalExpansion(),
        configuration: DiskCleanScanEngineConfiguration = DiskCleanScanEngineConfiguration(),
        targets: [DiskCleanRuleTarget],
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> DiskCleanScanEngine {
        DiskCleanScanEngine(
            catalog: DiskCleanRuleCatalogV2(targets: targets),
            fileSystem: fileSystem,
            safetyPolicy: DiskCleanSafetyPolicy(
                homeDirectory: home,
                whitelistStore: DiskCleanWhitelistStore(homeDirectory: home, includeDefaults: false)
            ),
            sizer: sizer,
            sizingExecutor: sizingExecutor,
            sizeCache: sizeCache,
            identityProbe: identityProbe,
            runningAppLock: runningAppLock,
            fullDiskAccess: fullDiskAccess,
            developerArtifactExpansion: developerArtifactExpansion,
            installerExpansion: installerExpansion,
            configuration: configuration,
            now: now
        )
    }

    private func collect(
        _ engine: DiskCleanScanEngine,
        choices: Set<DiskCleanChoice> = Set(DiskCleanChoice.allCases),
        forceRefresh: Bool = false
    ) async throws -> [DiskCleanScanEvent] {
        try await collect(engine, scope: .rules(choices: choices), forceRefresh: forceRefresh)
    }

    private func collect(
        _ engine: DiskCleanScanEngine,
        scope: DiskCleanScanScope,
        forceRefresh: Bool = false
    ) async throws -> [DiskCleanScanEvent] {
        var events: [DiskCleanScanEvent] = []
        for try await event in engine.scan(scope: scope, forceRefresh: forceRefresh) {
            events.append(event)
        }
        return events
    }

    private func finish(
        _ engine: DiskCleanScanEngine,
        choices: Set<DiskCleanChoice> = Set(DiskCleanChoice.allCases),
        forceRefresh: Bool = false
    ) async throws -> DiskCleanScanSummary {
        try await finish(engine, scope: .rules(choices: choices), forceRefresh: forceRefresh)
    }

    private func finish(
        _ engine: DiskCleanScanEngine,
        scope: DiskCleanScanScope,
        forceRefresh: Bool = false
    ) async throws -> DiskCleanScanSummary {
        let events = try await collect(engine, scope: scope, forceRefresh: forceRefresh)
        return try XCTUnwrap(events.compactMap(\.summary).last)
    }
}

// MARK: - 事件投影

extension DiskCleanScanEvent {
    var isCandidateFound: Bool {
        candidateFound != nil
    }

    var candidateFound: DiskCleanCandidate? {
        guard case let .candidateFound(candidate) = self else { return nil }
        return candidate
    }

    var isCandidateSized: Bool {
        guard case .candidateSized = self else { return false }
        return true
    }

    var finishedCategory: DiskCleanCategoryID? {
        guard case let .categoryFinished(category) = self else { return nil }
        return category
    }

    var summary: DiskCleanScanSummary? {
        guard case let .finished(summary) = self else { return nil }
        return summary
    }

    var logMessage: DiskCleanScanLogMessage? {
        guard case let .log(message) = self else { return nil }
        return message
    }
}
