import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import DiskCleanPlugin

/// 专用扫描器 → 统一管线的适配（设计 §10）。
///
/// 关注两件事：候选被挂到**真实存在的合成 target** 上（否则 `makePlan` 会拒绝），
/// 以及"默认勾不勾"的事实被如实翻译成风险覆盖与附注。
final class DiskCleanExternalExpansionTests: XCTestCase {
    private let catalog = DiskCleanRuleCatalogV2.current
    private let localization = PluginLocalization(bundle: .main)

    // MARK: - 开发产物：风险覆盖与附注

    func testCleanRepositoryCandidateBecomesLowRiskWithProjectNote() {
        let facts = DiskCleanDeveloperArtifactExpansion.facts(
            for: candidate(gitState: .clean(repositoryPath: "/code/app"))
        )

        XCTAssertEqual(facts.risk, .low, "仓库干净的产物应当默认勾选")
        XCTAssertEqual(
            facts.notes,
            [.developerProject(path: "/code/app", marker: "package.json")]
        )
    }

    func testCandidateOutsideRepositoryIsStillLowRisk() {
        let facts = DiskCleanDeveloperArtifactExpansion.facts(for: candidate(gitState: .notInRepository))

        XCTAssertEqual(facts.risk, .low)
        XCTAssertEqual(facts.notes.count, 1, "不在仓库里就没有仓库徽标")
    }

    /// 脏仓库不给覆盖值 → 沿用合成 target 的 medium → 不默认勾选（设计 §10.1）。
    func testDirtyRepositoryCandidateKeepsTargetRiskAndCarriesBadge() {
        let facts = DiskCleanDeveloperArtifactExpansion.facts(
            for: candidate(
                gitState: .dirty(repositoryPath: "/code/app", reason: .uncommittedChanges)
            )
        )

        XCTAssertNil(facts.risk, "不覆盖即沿用 target 的 medium，方向 fail-safe")
        XCTAssertEqual(
            facts.notes,
            [
                .developerProject(path: "/code/app", marker: "package.json"),
                .repositoryHasChanges(repositoryPath: "/code/app", reason: .uncommittedChanges)
            ]
        )
    }

    /// git 查不出来同样按"有改动"处理，但徽标要说清楚是"没查出来"而不是"确实有改动"。
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

    // MARK: - 开发产物：整体展开

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

    /// 保留根语义（设计 §10.1）：根本身不是删除对象，但"根下未被候选覆盖的部分从未审查过"，
    /// 因此全体已配置的根都进保留集，与遍历成功与否无关。
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

    /// 根整个打不开必须上报——"扫过但没有候选"与"根本没扫到"对用户是两件事。
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
            return XCTFail("应上报 scanRootUnreadable")
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

    // MARK: - 残留安装包

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

        XCTAssertNil(facts.risk, ".zip 永不默认勾选")
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
            "五个 target 声明的是同一个 ~/Downloads，去重后只留一条"
        )
    }

    /// TCC 拒绝时目录里可能躺着几十 GB，绝不能降级成"没有可清理项"。
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

    // MARK: - 辅助

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

    /// 退出码 0 + 空输出 = 工作区干净且没有未推送提交。
    private func cleanGitRunner() -> FakeDiskCleanSubprocessRunner {
        FakeDiskCleanSubprocessRunner(exitCode: 0, standardOutput: "")
    }

    private func makeTemporaryDirectory() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diskclean-expansion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        // 临时目录常在 /var（本身是符号链接）下，而扫描根一律以 O_NOFOLLOW_ANY 打开。
        return DiskCleanPhysicalPath.realpath(of: url.path) ?? url.path
    }

    private func makeProject(in root: String, named name: String, artifact: String, marker: String) throws {
        let project = root + "/" + name
        try FileManager.default.createDirectory(atPath: project + "/" + artifact, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: project + "/" + marker))
    }
}
