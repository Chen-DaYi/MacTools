import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanModelsTests: XCTestCase {
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
