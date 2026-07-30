import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DiskCleanPlugin

/// 逐项徽标（设计 §8.3、§10）。
final class DiskCleanBadgeTests: XCTestCase {
    private let localization = PluginLocalization(bundle: .main)

    // MARK: - P2 附注徽标

    /// 未提交改动与未推送提交是两件事，用户要去仓库里做的处理也不同。
    func testRepositoryBadgeDistinguishesDirtyReasons() {
        XCTAssertEqual(
            badgeTexts(notes: [.repositoryHasChanges(repositoryPath: "/code", reason: .uncommittedChanges)]),
            ["仓库有未提交改动"]
        )
        XCTAssertEqual(
            badgeTexts(notes: [.repositoryHasChanges(repositoryPath: "/code", reason: .unpushedCommits)]),
            ["仓库有未推送提交"]
        )
    }

    /// git 查不出来按"有改动"处理，但**不能写成"有未提交改动"**——那是在编造一个用户
    /// 去仓库里找不到的事实。
    func testInspectionFailureSaysItCouldNotCheckRatherThanClaimingChanges() {
        let texts = badgeTexts(
            notes: [.repositoryHasChanges(repositoryPath: "/code", reason: .inspectionFailed("git 检查超时"))]
        )

        XCTAssertEqual(texts, ["无法确认仓库状态：git 检查超时"])
    }

    func testInstallerNotesRenderTheirOwnBadges() {
        XCTAssertEqual(badgeTexts(notes: [.mayNotBeInstaller]), ["未必是安装包"])
        XCTAssertEqual(
            badgeTexts(notes: [.recentlyDownloaded(modifiedAt: Date(timeIntervalSince1970: 1_000))]).count,
            1
        )
    }

    /// 所属工程是定位信息不是警示，出徽标会把真正需要注意的"仓库有改动"挤没。
    func testProjectNoteDoesNotProduceABadge() {
        XCTAssertTrue(badgeTexts(notes: [.developerProject(path: "/code/app", marker: "package.json")]).isEmpty)
    }

    func testNoteBadgesComeBeforeSafetyBadges() {
        let badges = DiskCleanBadge.badges(
            for: candidate(
                notes: [.repositoryHasChanges(repositoryPath: "/code", reason: .uncommittedChanges)],
                safety: .inUse(processName: "node")
            ),
            outcome: nil,
            localization: localization
        )

        XCTAssertEqual(badges.map(\.id), ["repositoryHasChanges", "inUse"])
    }

    // MARK: - 与既有徽标共存

    func testCandidateWithoutNotesIsUnchanged() {
        let badges = DiskCleanBadge.badges(
            for: candidate(notes: [], safety: .allowed),
            outcome: nil,
            localization: localization
        )

        XCTAssertTrue(badges.isEmpty)
    }

    func testSizingBadgeStillWinsWhenSizeIsUnknown() {
        let badges = DiskCleanBadge.badges(
            for: candidate(notes: [.mayNotBeInstaller], safety: .allowed, sizeResult: nil),
            outcome: nil,
            localization: localization
        )

        XCTAssertEqual(badges.map(\.id), ["mayNotBeInstaller", "sizing"])
    }

    // MARK: - 辅助

    private func badgeTexts(notes: [DiskCleanCandidateNote]) -> [String] {
        DiskCleanBadge.badges(
            for: candidate(notes: notes, safety: .allowed),
            outcome: nil,
            localization: localization
        )
        .map(\.text)
    }

    private func candidate(
        notes: [DiskCleanCandidateNote],
        safety: DiskCleanSafetyStatus,
        sizeResult: DiskCleanSizeResult? = .testComplete()
    ) -> DiskCleanCandidate {
        DiskCleanCandidate(
            id: "purge.node_modules::/code/app/node_modules",
            targetID: DiskCleanPurgeKind.nodeModules.targetID,
            legacyRuleID: DiskCleanPurgeKind.nodeModules.targetID,
            category: .developerArtifacts,
            path: "/code/app/node_modules",
            risk: .low,
            safety: safety,
            notes: notes,
            sizeResult: sizeResult
        )
    }
}
