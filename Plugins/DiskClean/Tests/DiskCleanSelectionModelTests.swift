import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Selection-model semantic matrix (design §8.1).
///
/// Verifies the combination of "user action × candidate facts" with no UI:
/// detail view and menu bar are just two renderings of these conclusions.
final class DiskCleanSelectionModelTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 10_000)

    // MARK: - Selectability

    func testUnselectableCandidatesCoverEverySixReasons() {
        let cases: [(String, DiskCleanCandidate)] = [
            ("in use", makeCandidate(id: "inUse", safety: .inUse(processName: "Safari"))),
            ("whitelisted", makeCandidate(id: "whitelisted", safety: .whitelisted(rule: "rule"))),
            ("protected", makeCandidate(id: "protected", safety: .protected(reason: "credentials"))),
            ("not complete", makeCandidate(id: "partial", completeness: .partial(reasons: [.timedOut]))),
            ("unsized", makeCandidate(id: "unsized", sized: false)),
            ("crossed mount point", makeCandidate(id: "mount", completeness: .partial(reasons: [.crossedMountPoint])))
        ]

        for (reason, candidate) in cases {
            XCTAssertFalse(
                DiskCleanSelectionModel.isSelectable(candidate),
                "candidate must be unselectable for: \(reason)"
            )
            XCTAssertFalse(
                DiskCleanSelectionModel.isSelectedByDefault(candidate),
                "candidate must not be default-selected for: \(reason)"
            )
        }
    }

    func testTogglingUnselectableCandidateIsRejectedAndLeavesNoTrace() {
        var model = DiskCleanSelectionModel()
        let locked = makeCandidate(id: "locked", safety: .inUse(processName: "Safari"))

        XCTAssertFalse(model.setCandidate(locked, isSelected: true), "toggle must be rejected, not merely UI-disabled")
        XCTAssertFalse(model.isSelected(locked))

        // Rejection leaves no record: if the item later becomes selectable, default policy applies rather than a rejected click.
        let unlocked = makeCandidate(id: "locked", risk: .medium)
        XCTAssertFalse(model.isSelected(unlocked))
    }

    // MARK: - Default policy

    func testDefaultSelectionTakesLowRiskOnly() {
        let model = DiskCleanSelectionModel()

        XCTAssertTrue(model.isSelected(makeCandidate(id: "low", risk: .low)))
        XCTAssertFalse(model.isSelected(makeCandidate(id: "medium", risk: .medium)))
        XCTAssertFalse(model.isSelected(makeCandidate(id: "high", risk: .high)))
    }

    /// Dynamic-rule product targets always have risk >= medium (design §5.5), so default policy excludes them
    /// without the selection model re-detecting "is this a dynamic rule".
    func testDynamicRuleProductsAreNotSelectedByDefault() {
        let model = DiskCleanSelectionModel()
        let dynamicTargets = DiskCleanRuleCatalogV2.current.targets.filter(\.isDynamic)

        XCTAssertFalse(dynamicTargets.isEmpty, "catalog should have dynamic targets or this assertion is vacuous")
        for target in dynamicTargets {
            XCTAssertGreaterThanOrEqual(target.risk, .medium)
            let candidate = makeCandidate(id: target.id, category: target.category, risk: target.risk)
            XCTAssertFalse(model.isSelected(candidate), "\(target.id) must not be default-selected")
        }
    }

    // MARK: - Per-item overrides

    func testExplicitCandidateSelectionOverridesDefaultInBothDirections() {
        var model = DiskCleanSelectionModel()
        let low = makeCandidate(id: "low", risk: .low)
        let medium = makeCandidate(id: "medium", risk: .medium)

        XCTAssertTrue(model.setCandidate(low, isSelected: false))
        XCTAssertTrue(model.setCandidate(medium, isSelected: true))

        XCTAssertFalse(model.isSelected(low))
        XCTAssertTrue(model.isSelected(medium), "user may explicitly select medium; default simply does not")
    }

    // MARK: - Category three-state

    func testCategorySelectAllTakesLowRiskOnlyAndClearsPerItemOverrides() {
        var model = DiskCleanSelectionModel()
        let low = makeCandidate(id: "low", risk: .low)
        let medium = makeCandidate(id: "medium", risk: .medium)
        model.setCandidate(low, isSelected: false)
        model.setCandidate(medium, isSelected: true)

        model.setCategory(.appCaches, isSelected: true)

        XCTAssertTrue(model.isSelected(low), "category select-all clears per-item deselects in that category")
        XCTAssertFalse(model.isSelected(medium), "\"select all\" means all low-risk items; medium is not included")
        XCTAssertEqual(model.explicitOperation(for: .appCaches), .selectAllLowRisk)
    }

    func testCategoryDeselectAllClearsEverythingInThatCategoryOnly() {
        var model = DiskCleanSelectionModel()
        let cacheItem = makeCandidate(id: "cache", category: .appCaches)
        let logItem = makeCandidate(id: "log", category: .logs)

        model.setCategory(.appCaches, isSelected: false)

        XCTAssertFalse(model.isSelected(cacheItem))
        XCTAssertTrue(model.isSelected(logItem), "category operations only affect that category")
    }

    func testCategoryStateReportsThreeStatesAndUnavailable() {
        var model = DiskCleanSelectionModel()
        let low = makeCandidate(id: "low", risk: .low)
        let medium = makeCandidate(id: "medium", risk: .medium)
        let locked = makeCandidate(id: "locked", category: .logs, safety: .inUse(processName: "App"))

        XCTAssertEqual(
            model.projection(for: [low, medium, locked]).state(of: .appCaches),
            .partiallySelected
        )
        XCTAssertEqual(
            model.projection(for: [low, medium, locked]).state(of: .logs),
            .unavailable,
            "all-unselectable category must be distinct from \"nothing scanned in this category\""
        )
        XCTAssertEqual(
            model.projection(for: [low]).state(of: .appCaches),
            .allSelected
        )

        model.setCategory(.appCaches, isSelected: false)
        XCTAssertEqual(
            model.projection(for: [low, medium]).state(of: .appCaches),
            .noneSelected
        )
        XCTAssertEqual(
            model.projection(for: []).state(of: .browsers),
            .unavailable,
            "categories absent from this scan are unavailable"
        )
    }

    // MARK: - Streaming arrivals × explicit override matrix

    func testNewCandidateFollowsDefaultPolicyWhenCategoryWasNeverTouched() {
        let model = DiskCleanSelectionModel()

        XCTAssertTrue(model.isSelected(makeCandidate(id: "newLow", risk: .low)))
        XCTAssertFalse(model.isSelected(makeCandidate(id: "newMedium", risk: .medium)))
    }

    func testNewCandidateStaysUnselectedAfterExplicitDeselectAll() {
        var model = DiskCleanSelectionModel()
        model.setCategory(.appCaches, isSelected: false)

        XCTAssertFalse(
            model.isSelected(makeCandidate(id: "newLow", risk: .low)),
            "explicit deselect-all is a standing intent, not a one-shot action"
        )
        XCTAssertTrue(
            model.isSelected(makeCandidate(id: "otherCategory", category: .logs)),
            "other categories are unaffected"
        )
    }

    func testNewLowRiskCandidateJoinsAfterExplicitSelectAll() {
        var model = DiskCleanSelectionModel()
        model.setCategory(.appCaches, isSelected: true)

        XCTAssertTrue(model.isSelected(makeCandidate(id: "newLow", risk: .low)))
        XCTAssertFalse(
            model.isSelected(makeCandidate(id: "newMedium", risk: .medium)),
            "medium is never pulled in by select-all, including newly arrived items"
        )
    }

    func testPerItemOverrideSurvivesNewCandidatesArriving() {
        var model = DiskCleanSelectionModel()
        let existing = makeCandidate(id: "existing", risk: .low)
        model.setCandidate(existing, isSelected: false)

        let projection = model.projection(for: [existing, makeCandidate(id: "new", risk: .low)])

        XCTAssertEqual(projection.selectedIDs, ["new"])
    }

    func testDeselectAllRemainsInEffectAfterUserReselectsOneItem() {
        var model = DiskCleanSelectionModel()
        model.setCategory(.appCaches, isSelected: false)
        let picked = makeCandidate(id: "picked", risk: .low)
        model.setCandidate(picked, isSelected: true)

        XCTAssertTrue(model.isSelected(picked))
        XCTAssertFalse(
            model.isSelected(makeCandidate(id: "new", risk: .low)),
            "reselecting one item does not revoke category-level deselect-all"
        )
    }

    /// Candidate appears unsized first, then size completes (design §4.1, §4.2): default policy must apply the moment it becomes selectable.
    func testCandidateEntersSelectionOnceSizingCompletes() {
        let model = DiskCleanSelectionModel()
        let unsized = makeCandidate(id: "a", sized: false)

        XCTAssertFalse(model.isSelected(unsized))
        XCTAssertTrue(model.isSelected(unsized.applying(.testComplete(bytes: 10, observedAt: observedAt))))
    }

    /// Reverse: a default-selected candidate re-sized as partial must leave the selection immediately.
    func testCandidateLeavesSelectionWhenItBecomesIncomplete() {
        let model = DiskCleanSelectionModel()
        let sized = makeCandidate(id: "a")

        XCTAssertTrue(model.isSelected(sized))
        XCTAssertFalse(
            model.isSelected(sized.applying(.testPartial(reasons: [.timedOut], observedAt: observedAt)))
        )
    }

    // MARK: - Derived values and reset

    func testProjectionDerivesCountAndBytesFromSelectedItemsOnly() {
        var model = DiskCleanSelectionModel()
        let candidates = [
            makeCandidate(id: "a", bytes: 1_000),
            makeCandidate(id: "b", bytes: 2_000),
            makeCandidate(id: "c", risk: .medium, bytes: 4_000),
            makeCandidate(id: "d", bytes: 8_000, safety: .whitelisted(rule: "rule"))
        ]
        model.setCandidate(candidates[2], isSelected: true)

        let projection = model.projection(for: candidates)

        XCTAssertEqual(projection.selectedIDs, ["a", "b", "c"])
        XCTAssertEqual(projection.selectedCount, 3)
        XCTAssertEqual(projection.selectedEstimatedBytes, 7_000)
        XCTAssertEqual(projection.selectableIDs, ["a", "b", "c"])
        XCTAssertFalse(projection.isSelectable("d"))
    }

    func testResetReturnsToDefaultPolicy() {
        var model = DiskCleanSelectionModel()
        let low = makeCandidate(id: "low", risk: .low)
        model.setCandidate(low, isSelected: false)
        model.setCategory(.logs, isSelected: false)

        model.reset()

        XCTAssertTrue(model.isSelected(low))
        XCTAssertNil(model.explicitOperation(for: .logs))
    }

    // MARK: - Fixtures

    private func makeCandidate(
        id: String,
        category: DiskCleanCategoryID = .appCaches,
        risk: DiskCleanRisk = .low,
        bytes: Int64 = 1_024,
        safety: DiskCleanSafetyStatus = .allowed,
        completeness: DiskCleanScanCompleteness = .complete,
        sized: Bool = true
    ) -> DiskCleanCandidate {
        let sizeResult: DiskCleanSizeResult? = sized
            ? DiskCleanSizeResult(
                estimatedBytes: bytes,
                fileCount: 1,
                completeness: completeness,
                rootIdentity: completeness.isComplete ? .test() : nil,
                observedAt: observedAt
            )
            : nil
        return DiskCleanCandidate(
            id: id,
            targetID: "test.target",
            legacyRuleID: "test.target",
            category: category,
            path: "/cache/\(id)",
            risk: risk,
            safety: safety,
            sizeResult: sizeResult
        )
    }
}
