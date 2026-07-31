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

    // MARK: - Panel equivalence mapping

    /// The three v1 panel groups are decided by legacyRuleID prefix — the only equivalence check for v1/v2 scan scope.
    func testChoiceIsDerivedFromLegacyRuleIDPrefix() {
        XCTAssertEqual(DiskCleanChoice(legacyRuleID: "cache.user-essentials"), .cache)
        XCTAssertEqual(DiskCleanChoice(legacyRuleID: "developer.homebrew"), .developer)
        XCTAssertEqual(DiskCleanChoice(legacyRuleID: "browser.safari"), .browser)
        XCTAssertNil(DiskCleanChoice(legacyRuleID: "unknown.thing"))
    }

    /// Every v2 target must map to a panel group, or it would silently drop out of scan scope.
    func testEveryRuleTargetMapsToAPanelChoice() {
        for target in DiskCleanRuleCatalogV2.current.ruleTargets {
            XCTAssertNotNil(
                DiskCleanChoice(legacyRuleID: target.legacyRuleID),
                "target \(target.id) legacyRuleID \(target.legacyRuleID) has no panel mapping"
            )
        }
    }

    /// P2 synthetic targets **must not** have a panel mapping: regular three-group scans
    /// filter targets by `DiskCleanChoice`, which is the second safeguard against
    /// accidentally including developer artifacts and installers
    /// (the first is `ScanEngine.scopedTargets(for:)` splitting by scope).
    func testExternalTargetsHaveNoPanelChoice() {
        let external = DiskCleanRuleCatalogV2.current.targets.filter(\.isExternallyDiscovered)
        XCTAssertFalse(external.isEmpty)
        for target in external {
            XCTAssertNil(
                DiskCleanChoice(legacyRuleID: target.legacyRuleID),
                "P2 target \(target.id) must not have a panel mapping, or regular scans would include it"
            )
        }
    }

    /// Category cannot replace legacy prefix for scope: some targets have category and panel
    /// from different sources (`browser.service-worker.editors` is developer category;
    /// `aiTools` spans both cache.* and developer.*).
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

    // MARK: - Candidate invariants (§3.1)

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
                "partial(\(reason)) candidates are not cleanable"
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

    // MARK: - Scan result projection

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
