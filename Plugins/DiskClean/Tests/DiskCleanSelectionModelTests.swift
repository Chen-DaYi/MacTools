import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 选择模型的语义矩阵（设计 §8.1）。
///
/// 这里验证的是"用户操作 × 候选事实"的组合结果，不涉及任何 UI：
/// 详情视图与菜单栏都只是这些结论的两种画法。
final class DiskCleanSelectionModelTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 10_000)

    // MARK: - 可勾选判定

    func testUnselectableCandidatesCoverEverySixReasons() {
        let cases: [(String, DiskCleanCandidate)] = [
            ("锁定", makeCandidate(id: "inUse", safety: .inUse(processName: "Safari"))),
            ("白名单", makeCandidate(id: "whitelisted", safety: .whitelisted(rule: "rule"))),
            ("保护", makeCandidate(id: "protected", safety: .protected(reason: "credentials"))),
            ("非 complete", makeCandidate(id: "partial", completeness: .partial(reasons: [.timedOut]))),
            ("未求大小", makeCandidate(id: "unsized", sized: false)),
            ("含挂载点", makeCandidate(id: "mount", completeness: .partial(reasons: [.crossedMountPoint])))
        ]

        for (reason, candidate) in cases {
            XCTAssertFalse(
                DiskCleanSelectionModel.isSelectable(candidate),
                "\(reason)的候选必须不可勾选"
            )
            XCTAssertFalse(
                DiskCleanSelectionModel.isSelectedByDefault(candidate),
                "\(reason)的候选不能被默认策略勾选"
            )
        }
    }

    func testTogglingUnselectableCandidateIsRejectedAndLeavesNoTrace() {
        var model = DiskCleanSelectionModel()
        let locked = makeCandidate(id: "locked", safety: .inUse(processName: "Safari"))

        XCTAssertFalse(model.setCandidate(locked, isSelected: true), "toggle 必须被拒绝，不是仅 UI 禁用")
        XCTAssertFalse(model.isSelected(locked))

        // 拒绝不留记录：即便这一项日后变得可勾选，也该按默认策略走，而不是沿用一次被拒的点击。
        let unlocked = makeCandidate(id: "locked", risk: .medium)
        XCTAssertFalse(model.isSelected(unlocked))
    }

    // MARK: - 默认策略

    func testDefaultSelectionTakesLowRiskOnly() {
        let model = DiskCleanSelectionModel()

        XCTAssertTrue(model.isSelected(makeCandidate(id: "low", risk: .low)))
        XCTAssertFalse(model.isSelected(makeCandidate(id: "medium", risk: .medium)))
        XCTAssertFalse(model.isSelected(makeCandidate(id: "high", risk: .high)))
    }

    /// 动态规则产物的 target 风险恒 >= medium（设计 §5.5），因此默认策略自动把它们排除，
    /// 不需要在选择模型里再认一次"这是不是动态规则"。
    func testDynamicRuleProductsAreNotSelectedByDefault() {
        let model = DiskCleanSelectionModel()
        let dynamicTargets = DiskCleanRuleCatalogV2.current.targets.filter(\.isDynamic)

        XCTAssertFalse(dynamicTargets.isEmpty, "目录里应当有动态 target，否则这条断言是空转")
        for target in dynamicTargets {
            XCTAssertGreaterThanOrEqual(target.risk, .medium)
            let candidate = makeCandidate(id: target.id, category: target.category, risk: target.risk)
            XCTAssertFalse(model.isSelected(candidate), "\(target.id) 不该被默认勾选")
        }
    }

    // MARK: - 逐项覆盖

    func testExplicitCandidateSelectionOverridesDefaultInBothDirections() {
        var model = DiskCleanSelectionModel()
        let low = makeCandidate(id: "low", risk: .low)
        let medium = makeCandidate(id: "medium", risk: .medium)

        XCTAssertTrue(model.setCandidate(low, isSelected: false))
        XCTAssertTrue(model.setCandidate(medium, isSelected: true))

        XCTAssertFalse(model.isSelected(low))
        XCTAssertTrue(model.isSelected(medium), "用户可以显式选中 medium，只是默认不选")
    }

    // MARK: - 分类三态

    func testCategorySelectAllTakesLowRiskOnlyAndClearsPerItemOverrides() {
        var model = DiskCleanSelectionModel()
        let low = makeCandidate(id: "low", risk: .low)
        let medium = makeCandidate(id: "medium", risk: .medium)
        model.setCandidate(low, isSelected: false)
        model.setCandidate(medium, isSelected: true)

        model.setCategory(.appCaches, isSelected: true)

        XCTAssertTrue(model.isSelected(low), "分类全选清掉本类的逐项取消")
        XCTAssertFalse(model.isSelected(medium), "\"全选\"= 全部低风险项，medium 不被带入")
        XCTAssertEqual(model.explicitOperation(for: .appCaches), .selectAllLowRisk)
    }

    func testCategoryDeselectAllClearsEverythingInThatCategoryOnly() {
        var model = DiskCleanSelectionModel()
        let cacheItem = makeCandidate(id: "cache", category: .appCaches)
        let logItem = makeCandidate(id: "log", category: .logs)

        model.setCategory(.appCaches, isSelected: false)

        XCTAssertFalse(model.isSelected(cacheItem))
        XCTAssertTrue(model.isSelected(logItem), "分类操作只作用于本类")
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
            "全是不可勾选项的分类要能与\"这一类没扫到东西\"区分开"
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
            "本次扫描没有的分类按不可用处理"
        )
    }

    // MARK: - 流式新增 × 显式覆盖矩阵

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
            "显式\"全不选\"是持续生效的意图，不是一次性操作"
        )
        XCTAssertTrue(
            model.isSelected(makeCandidate(id: "otherCategory", category: .logs)),
            "另一个分类不受影响"
        )
    }

    func testNewLowRiskCandidateJoinsAfterExplicitSelectAll() {
        var model = DiskCleanSelectionModel()
        model.setCategory(.appCaches, isSelected: true)

        XCTAssertTrue(model.isSelected(makeCandidate(id: "newLow", risk: .low)))
        XCTAssertFalse(
            model.isSelected(makeCandidate(id: "newMedium", risk: .medium)),
            "medium 永远不会被\"全选\"带入，新到的也一样"
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
            "逐项重新勾选不会撤销分类级的\"全不选\""
        )
    }

    /// 候选先无大小出现、随后被补齐（设计 §4.1、§4.2）：默认策略必须在"变得可勾选"的那一刻生效。
    func testCandidateEntersSelectionOnceSizingCompletes() {
        let model = DiskCleanSelectionModel()
        let unsized = makeCandidate(id: "a", sized: false)

        XCTAssertFalse(model.isSelected(unsized))
        XCTAssertTrue(model.isSelected(unsized.applying(.testComplete(bytes: 10, observedAt: observedAt))))
    }

    /// 反方向：已按默认勾选的候选若被重新求大小成 partial，必须立刻掉出选中集。
    func testCandidateLeavesSelectionWhenItBecomesIncomplete() {
        let model = DiskCleanSelectionModel()
        let sized = makeCandidate(id: "a")

        XCTAssertTrue(model.isSelected(sized))
        XCTAssertFalse(
            model.isSelected(sized.applying(.testPartial(reasons: [.timedOut], observedAt: observedAt)))
        )
    }

    // MARK: - 派生值与重置

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

    // MARK: - 夹具

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
