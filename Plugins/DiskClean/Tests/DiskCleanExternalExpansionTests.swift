import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DiskCleanPlugin

/// Adapter from specialized scanners into the unified pipeline (design §10).
///
/// Two concerns: candidates attach to **real synthetic targets** (else `makePlan` rejects them),
/// and default-selection facts are translated faithfully into risk overrides and notes.
final class DiskCleanExternalExpansionTests: XCTestCase {
    private let catalog = DiskCleanRuleCatalogV2.current
    private let localization = PluginLocalization(bundle: .main)

    // MARK: - Developer artifacts: risk overrides and notes

    func testCleanRepositoryCandidateBecomesLowRiskWithProjectNote() {
        let facts = DiskCleanDeveloperArtifactExpansion.facts(
            for: candidate(gitState: .clean(repositoryPath: "/code/app"))
        )

        XCTAssertEqual(facts.risk, .low, "artifacts from a clean repo should be selected by default")
        XCTAssertEqual(
            facts.notes,
            [.developerProject(path: "/code/app", marker: "package.json")]
        )
    }

    func testCandidateOutsideRepositoryIsStillLowRisk() {
        let facts = DiskCleanDeveloperArtifactExpansion.facts(for: candidate(gitState: .notInRepository))

        XCTAssertEqual(facts.risk, .low)
        XCTAssertEqual(facts.notes.count, 1, "no repo badge when not inside a repository")
    }

    /// Dirty repo yields no override → keep synthetic target medium → not selected by default (design §10.1).
    func testDirtyRepositoryCandidateKeepsTargetRiskAndCarriesBadge() {
        let facts = DiskCleanDeveloperArtifactExpansion.facts(
            for: candidate(
                gitState: .dirty(repositoryPath: "/code/app", reason: .uncommittedChanges)
            )
        )

        XCTAssertNil(facts.risk, "no override keeps target medium; fail-safe direction")
        XCTAssertEqual(
            facts.notes,
            [
                .developerProject(path: "/code/app", marker: "package.json"),
                .repositoryHasChanges(repositoryPath: "/code/app", reason: .uncommittedChanges)
            ]
        )
    }

    /// Failed git inspection is also treated as "has changes", but the badge must say "could not check", not "definitely dirty".
    func testGitInspectionFailureIsTreatedAsDirtyWithItsOwnReason() {
        let facts = DiskCleanDeveloperArtifactExpansion.facts(
            for: candidate(
                gitState: .dirty(repositoryPath: "/code/app", reason: .inspectionFailed("git 检查超时"))
            )
        )

        XCTAssertNil(facts.risk)
        XCTAssertTrue(
            facts.notes.contains(
                .repositoryHasChanges(repositoryPath: "/code/app", reason: .inspectionFailed("git 检查超时"))
            )
        )
    }

    // MARK: - Developer artifacts: full expansion

    func testExpandsDiscoveredCandidatesOntoCatalogTargets() async throws {
        let root = try makeTemporaryDirectory()
        try makeProject(in: root, named: "app", artifact: "node_modules", marker: "package.json")

        let expansion = await DiskCleanDeveloperArtifactExpansion(
            scanner: DiskCleanPurgeScanner(inspector: DiskCleanGitStatusInspector(runner: cleanGitRunner()))
        ).expand(
            scope: .developerArtifacts(roots: [root]),
            catalog: catalog,
            localization: localization
        )

        XCTAssertEqual(expansion.hits.count, 1)
        let hit = try XCTUnwrap(expansion.hits.first)
        XCTAssertEqual(hit.target.id, DiskCleanPurgeKind.nodeModules.targetID)
        XCTAssertTrue(hit.target.isExternallyDiscovered)
        XCTAssertEqual(hit.item.path, root + "/app/node_modules")
        XCTAssertTrue(hit.item.isDirectory)
    }

    /// Reserved-root semantics (design §10.1): the root itself is not a deletion target, but
    /// "parts under the root not covered by candidates were never reviewed", so every configured root
    /// enters the reserved set regardless of walk success.
    func testReservesEveryConfiguredRootRegardlessOfOutcome() async throws {
        let root = try makeTemporaryDirectory()
        let missing = root + "/does-not-exist"

        let expansion = await DiskCleanDeveloperArtifactExpansion().expand(
            scope: .developerArtifacts(roots: [root, missing]),
            catalog: catalog,
            localization: localization
        )

        XCTAssertEqual(expansion.reservedRootPaths, [root, missing])
    }

    /// Unreadable roots must be reported — "scanned with no candidates" and "never scanned" are different for the user.
    func testUnreadableRootIsReportedAsLimitation() async throws {
        let root = try makeTemporaryDirectory()
        let missing = root + "/does-not-exist"

        let expansion = await DiskCleanDeveloperArtifactExpansion().expand(
            scope: .developerArtifacts(roots: [missing]),
            catalog: catalog,
            localization: localization
        )

        XCTAssertTrue(expansion.hits.isEmpty)
        XCTAssertEqual(expansion.limitations.count, 1)
        guard case let .scanRootUnreadable(path, _) = try XCTUnwrap(expansion.limitations.first) else {
            return XCTFail("should report scanRootUnreadable")
        }
        XCTAssertEqual(path, missing)
    }

    func testEmptyRootListProducesNothingAtAll() async {
        let expansion = await DiskCleanDeveloperArtifactExpansion().expand(
            scope: .developerArtifacts(roots: []),
            catalog: catalog,
            localization: localization
        )

        XCTAssertTrue(expansion.hits.isEmpty)
        XCTAssertTrue(expansion.reservedRootPaths.isEmpty)
        XCTAssertTrue(expansion.limitations.isEmpty)
    }

    // MARK: - Leftover installers

    func testStaleInstallerBecomesLowRiskWithoutNotes() {
        let facts = DiskCleanInstallerExpansion.facts(
            for: installerCandidate(kind: .diskImage, isSelectedByDefault: true, note: nil)
        )

        XCTAssertEqual(facts.risk, .low)
        XCTAssertTrue(facts.notes.isEmpty)
    }

    func testZipArchiveKeepsTargetRiskAndCarriesItsOwnNote() {
        let facts = DiskCleanInstallerExpansion.facts(
            for: installerCandidate(kind: .zipArchive, isSelectedByDefault: false, note: .mayNotBeInstaller)
        )

        XCTAssertNil(facts.risk, ".zip is never selected by default")
        XCTAssertEqual(facts.notes, [.mayNotBeInstaller])
    }

    func testRecentlyDownloadedInstallerKeepsTargetRisk() {
        let modifiedAt = Date(timeIntervalSince1970: 5_000)
        let facts = DiskCleanInstallerExpansion.facts(
            for: installerCandidate(
                kind: .installerPackage,
                isSelectedByDefault: false,
                note: .recentlyModified,
                modifiedAt: modifiedAt
            )
        )

        XCTAssertNil(facts.risk)
        XCTAssertEqual(facts.notes, [.recentlyDownloaded(modifiedAt: modifiedAt)])
    }

    func testExpandsInstallersOntoCatalogTargetsAndReservesDownloads() async throws {
        let downloads = try makeTemporaryDirectory()
        try Data().write(to: URL(fileURLWithPath: downloads + "/Tool.dmg"))

        let expansion = await DiskCleanInstallerExpansion(
            scanner: DiskCleanInstallerScanner(
                downloadsPath: downloads,
                now: { Date(timeIntervalSince1970: 10_000_000) }
            )
        ).expand(scope: .installers, catalog: catalog, localization: localization)

        XCTAssertEqual(expansion.hits.map(\.target.id), [DiskCleanInstallerKind.diskImage.targetID])
        XCTAssertEqual(expansion.hits.first?.item.isDirectory, false)
        XCTAssertEqual(
            expansion.reservedRootPaths,
            [DiskCleanRuleTarget.expandHome(in: "~/Downloads", homeDirectory: NSHomeDirectory())],
            "five targets declare the same ~/Downloads; dedupe keeps one"
        )
    }

    /// On TCC denial the directory may hold tens of GB; must not degrade to "nothing cleanable".
    func testDeniedDownloadsIsReportedAsPermissionLimitation() async throws {
        let parent = try makeTemporaryDirectory()
        let downloads = parent + "/Downloads"
        try FileManager.default.createDirectory(atPath: downloads, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: downloads)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloads)
        }

        let expansion = await DiskCleanInstallerExpansion(
            scanner: DiskCleanInstallerScanner(downloadsPath: downloads)
        ).expand(scope: .installers, catalog: catalog, localization: localization)

        XCTAssertTrue(expansion.hits.isEmpty)
        XCTAssertEqual(
            expansion.limitations,
            [.scanRootUnreadable(path: downloads, reason: .permissionDenied)]
        )
    }

    // MARK: - Helpers

    private func candidate(gitState: DiskCleanPurgeGitState) -> DiskCleanPurgeCandidate {
        DiskCleanPurgeCandidate(
            item: DiskCleanPurgeDiscoveredItem(
                path: "/code/app/node_modules",
                kind: .nodeModules,
                projectMarker: "package.json",
                projectPath: "/code/app",
                repositoryPath: gitState.repositoryPath
            ),
            gitState: gitState
        )
    }

    private func installerCandidate(
        kind: DiskCleanInstallerKind,
        isSelectedByDefault: Bool,
        note: DiskCleanInstallerCandidate.Note?,
        modifiedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> DiskCleanInstallerCandidate {
        DiskCleanInstallerCandidate(
            path: "/downloads/Tool." + kind.fileExtension,
            kind: kind,
            byteSize: 1_024,
            modifiedAt: modifiedAt,
            isSelectedByDefault: isSelectedByDefault,
            note: note
        )
    }

    /// Exit code 0 + empty output = clean worktree and no unpushed commits.
    private func cleanGitRunner() -> FakeDiskCleanSubprocessRunner {
        FakeDiskCleanSubprocessRunner(exitCode: 0, standardOutput: "")
    }

    private func makeTemporaryDirectory() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskclean-expansion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        // Temp dirs often live under /var (itself a symlink), while scan roots always open with O_NOFOLLOW_ANY.
        return DiskCleanPhysicalPath.realpath(of: url.path) ?? url.path
    }

    private func makeProject(in root: String, named name: String, artifact: String, marker: String) throws {
        let project = root + "/" + name
        try FileManager.default.createDirectory(atPath: project + "/" + artifact, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: project + "/" + marker))
    }
}
