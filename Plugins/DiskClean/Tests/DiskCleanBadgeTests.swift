import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DiskCleanPlugin

/// Per-item badges (design §8.3, §10).
final class DiskCleanBadgeTests: XCTestCase {
    private let localization = PluginLocalization(bundle: .main)

    // MARK: - P2 note badges

    /// Uncommitted changes and unpushed commits are different; the user acts differently in the repo.
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

    /// When git inspection fails, treat as "has changes", but **must not** say
    /// "has uncommitted changes" — that invents a fact the user cannot find in the repo.
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

    /// Project affiliation is location info, not a warning; badging it would bury the real "repo has changes" signal.
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

    // MARK: - Coexistence with existing badges

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

    // MARK: - Helpers

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
