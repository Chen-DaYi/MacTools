import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanModelsTests: XCTestCase {
    func testCleanupChoiceTitlesMatchFirstVersionScope() {
        XCTAssertEqual(DiskCleanChoice.cache.title, "缓存清理")
        XCTAssertEqual(DiskCleanChoice.developer.title, "开发者缓存清理")
        XCTAssertEqual(DiskCleanChoice.browser.title, "浏览器缓存清理")
        XCTAssertEqual(DiskCleanChoice.allCases, [.cache, .developer, .browser])
    }

    // MARK: - 面板等价映射

    /// v1 的三个面板分组由 legacyRuleID 前缀判定，这是 v1/v2 扫描范围等价性的唯一判定点。
    func testChoiceIsDerivedFromLegacyRuleIDPrefix() {
        XCTAssertEqual(DiskCleanChoice(legacyRuleID: "cache.user-essentials"), .cache)
        XCTAssertEqual(DiskCleanChoice(legacyRuleID: "developer.homebrew"), .developer)
        XCTAssertEqual(DiskCleanChoice(legacyRuleID: "browser.safari"), .browser)
        XCTAssertNil(DiskCleanChoice(legacyRuleID: "unknown.thing"))
    }

    /// 每条 v2 target 都必须能落到某个面板分组，否则它会静默从扫描范围里消失。
    func testEveryRuleTargetMapsToAPanelChoice() {
        for target in DiskCleanRuleCatalogV2.current.ruleTargets {
            XCTAssertNotNil(
                DiskCleanChoice(legacyRuleID: target.legacyRuleID),
                "target \(target.id) 的 legacyRuleID \(target.legacyRuleID) 没有面板归属"
            )
        }
    }

    /// P2 合成 target 反过来**必须**没有面板归属：常规三分组扫描按 `DiskCleanChoice`
    /// 过滤 target，这是"开发产物与安装包不会被顺手带上"的第二道保险
    /// （第一道是 `ScanEngine.scopedTargets(for:)` 按 scope 分流）。
    func testExternalTargetsHaveNoPanelChoice() {
        let external = DiskCleanRuleCatalogV2.current.targets.filter(\.isExternallyDiscovered)
        XCTAssertFalse(external.isEmpty)
        for target in external {
            XCTAssertNil(
                DiskCleanChoice(legacyRuleID: target.legacyRuleID),
                "P2 target \(target.id) 不该有面板归属，否则会被常规扫描带上"
            )
        }
    }

    /// 分类不能代替 legacy 前缀做范围判定：确实存在"分类与面板分组不同源"的 target
    /// （`browser.service-worker.editors` 属 developer 分类，`aiTools` 同时收 cache.* 与 developer.*）。
    func testCategoryIsNotIsomorphicToPanelChoice() {
        func choices(in category: DiskCleanCategoryID) -> Set<DiskCleanChoice> {
            Set(
                DiskCleanRuleCatalogV2.current
                    .targets(in: category)
                    .compactMap { DiskCleanChoice(legacyRuleID: $0.legacyRuleID) }
            )
        }

        XCTAssertEqual(choices(in: .developer), [.developer, .browser])
        XCTAssertEqual(choices(in: .aiTools), [.cache, .developer])
    }

    // MARK: - 候选不变量（§3.1）

    func testCandidateWithoutSizeResultIsNotCleanable() {
        XCTAssertFalse(makeCandidate(sizeResult: nil).isCleanable)
    }

    func testCandidateWithPartialSizeIsNotCleanable() {
        let reasons: [DiskCleanScanCompleteness.PartialReason] = [
            .timedOut, .permissionDenied, .unsupportedVolume, .crossedMountPoint, .walkError
        ]
        for reason in reasons {
            XCTAssertFalse(
                makeCandidate(sizeResult: .testPartial(reasons: [reason], identity: .test())).isCleanable,
                "partial(\(reason)) 的候选不可清理"
            )
        }
    }

    func testCandidateWithoutRootIdentityIsNotCleanable() {
        let result = DiskCleanSizeResult(
            estimatedBytes: 100,
            fileCount: 1,
            completeness: .complete,
            rootIdentity: nil,
            observedAt: Date()
        )

        XCTAssertFalse(makeCandidate(sizeResult: result).isCleanable)
    }

    func testCandidateWithBlockedSafetyIsNotCleanable() {
        XCTAssertFalse(
            makeCandidate(safety: .inUse(processName: "Docker"), sizeResult: .testComplete()).isCleanable
        )
    }

    func testCompleteAndAllowedCandidateIsCleanable() {
        XCTAssertTrue(makeCandidate(sizeResult: .testComplete()).isCleanable)
    }

    // MARK: - 扫描结果投影

    func testScanResultTotalsOnlyCleanableCandidates() {
        let result = DiskCleanScanResult(
            scope: .rules(choices: [.cache]),
            candidates: [
                makeCandidate(id: "a", path: "/tmp/a", sizeResult: .testComplete(bytes: 10)),
                makeCandidate(
                    id: "b",
                    path: "/tmp/b",
                    safety: .protected(reason: "protected"),
                    sizeResult: .testComplete(bytes: 20)
                ),
                makeCandidate(id: "c", path: "/tmp/c", sizeResult: nil)
            ],
            scannedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(result.cleanableSizeBytes, 10)
        XCTAssertEqual(result.cleanableCandidates.map(\.id), ["a"])
    }

    func testExpiryDeadlineIsNilWithoutCleanableCandidates() {
        let result = DiskCleanScanResult(
            scope: .rules(choices: [.cache]),
            candidates: [makeCandidate(sizeResult: nil)],
            scannedAt: Date()
        )

        XCTAssertNil(result.expiryDeadline)
    }

    func testExpiryDeadlineIsEarliestObservedAtPlusWindow() {
        let base = Date(timeIntervalSince1970: 10_000)
        let result = DiskCleanScanResult(
            scope: .rules(choices: [.cache]),
            candidates: [
                makeCandidate(id: "a", path: "/tmp/a", sizeResult: .testComplete(observedAt: base)),
                makeCandidate(
                    id: "b",
                    path: "/tmp/b",
                    sizeResult: .testComplete(observedAt: base.addingTimeInterval(60))
                )
            ],
            scannedAt: base
        )

        XCTAssertEqual(result.expiryDeadline, base.addingTimeInterval(DiskCleanScanFreshness.window))
    }

    private func makeCandidate(
        id: String = "a",
        path: String = "/tmp/a",
        safety: DiskCleanSafetyStatus = .allowed,
        sizeResult: DiskCleanSizeResult?
    ) -> DiskCleanCandidate {
        DiskCleanCandidate(
            id: id,
            targetID: "cache.test",
            legacyRuleID: "cache.test",
            category: .appCaches,
            path: path,
            risk: .low,
            safety: safety,
            sizeResult: sizeResult
        )
    }
}
