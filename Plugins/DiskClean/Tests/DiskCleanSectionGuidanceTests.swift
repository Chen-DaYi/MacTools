import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// P2 分段的空态判定（设计 §10）。
///
/// 这些状态之所以必须分开：它们对用户的要求完全不同——先去加文件夹、先去点扫描、
/// 先去授权、文件夹已经没了、以及"真的没有"。合成一个"暂无内容"等于让用户自己猜。
@MainActor
final class DiskCleanSectionGuidanceTests: XCTestCase {
    // MARK: - 无根引导

    func testDeveloperArtifactsWithoutRootsAsksForFolders() {
        let snapshot = makeSnapshot(scope: .developerArtifacts(roots: []), scanResult: nil)

        XCTAssertEqual(DiskCleanSectionGuidance.resolve(snapshot), .needsRoots)
    }

    /// 无根优先于"没扫过"：让用户看到"点扫描"而按钮是灰的，是最让人困惑的组合。
    func testNeedsRootsOutranksNotScanned() {
        let snapshot = makeSnapshot(scope: .developerArtifacts(roots: []), scanResult: nil)

        XCTAssertFalse(snapshot.canScan, "无根时扫描入口必须是禁用的")
        XCTAssertEqual(DiskCleanSectionGuidance.resolve(snapshot), .needsRoots)
    }

    func testDeveloperArtifactsWithRootsFallsBackToNotScanned() {
        let snapshot = makeSnapshot(scope: .developerArtifacts(roots: ["/code"]), scanResult: nil)

        XCTAssertTrue(snapshot.canScan)
        XCTAssertEqual(DiskCleanSectionGuidance.resolve(snapshot), .notScanned)
    }

    func testInstallersNeverAskForRoots() {
        let snapshot = makeSnapshot(scope: .installers, scanResult: nil)

        XCTAssertEqual(DiskCleanSectionGuidance.resolve(snapshot), .notScanned)
        XCTAssertTrue(snapshot.canScan, "安装包段范围固定，永远可以扫描")
    }

    // MARK: - 授权引导

    /// `denied` 与"扫过但没有候选"必须分开：`~/Downloads` 里可能正躺着几十 GB 安装包，
    /// 显示"没有可清理项"是在骗用户。
    func testDeniedScanRootShowsAuthorizationGuidanceInsteadOfEmptyState() {
        let snapshot = makeSnapshot(
            scope: .installers,
            scanResult: makeResult(
                scope: .installers,
                candidates: [],
                limitations: [.scanRootUnreadable(path: "/Users/x/Downloads", reason: .permissionDenied)]
            )
        )

        XCTAssertEqual(
            DiskCleanSectionGuidance.resolve(snapshot),
            .accessDenied(path: "/Users/x/Downloads")
        )
    }

    func testUnreadableRootShowsItsOwnGuidance() {
        let snapshot = makeSnapshot(
            scope: .developerArtifacts(roots: ["/code"]),
            scanResult: makeResult(
                scope: .developerArtifacts(roots: ["/code"]),
                candidates: [],
                limitations: [.scanRootUnreadable(path: "/code", reason: .walkError)]
            )
        )

        XCTAssertEqual(DiskCleanSectionGuidance.resolve(snapshot), .rootsUnreadable(paths: ["/code"]))
    }

    /// 同时有被拒绝与失效的根时先说授权：那是用户唯一能自己解决的一个。
    func testPermissionDeniedOutranksOtherUnreadableReasons() {
        let snapshot = makeSnapshot(
            scope: .developerArtifacts(roots: ["/a", "/b"]),
            scanResult: makeResult(
                scope: .developerArtifacts(roots: ["/a", "/b"]),
                candidates: [],
                limitations: [
                    .scanRootUnreadable(path: "/a", reason: .walkError),
                    .scanRootUnreadable(path: "/b", reason: .permissionDenied)
                ]
            )
        )

        XCTAssertEqual(DiskCleanSectionGuidance.resolve(snapshot), .accessDenied(path: "/b"))
    }

    // MARK: - 有候选时不抢版面

    /// 一个根被拒、另一个扫出了东西：列表照常展示，根的问题交给受限横幅。
    func testCandidatesTakePrecedenceOverRootProblems() {
        let scope = DiskCleanScanScope.developerArtifacts(roots: ["/a", "/b"])
        let snapshot = makeSnapshot(
            scope: scope,
            scanResult: makeResult(
                scope: scope,
                candidates: [candidate(path: "/a/app/node_modules")],
                limitations: [.scanRootUnreadable(path: "/b", reason: .permissionDenied)]
            )
        )

        XCTAssertEqual(DiskCleanSectionGuidance.resolve(snapshot), .candidates)
    }

    func testScannedWithNothingFoundIsAnHonestEmptyState() {
        let snapshot = makeSnapshot(
            scope: .installers,
            scanResult: makeResult(scope: .installers, candidates: [], limitations: [])
        )

        XCTAssertEqual(DiskCleanSectionGuidance.resolve(snapshot), .empty)
    }

    // MARK: - 辅助

    private func makeSnapshot(
        scope: DiskCleanScanScope,
        scanResult: DiskCleanScanResult?
    ) -> DiskCleanControllerSnapshot {
        DiskCleanControllerSnapshot(
            phase: scanResult == nil ? .idle : .scanned,
            scope: scope,
            scanResult: scanResult,
            executionResult: nil,
            isResultStale: false,
            errorMessage: nil
        )
    }

    private func makeResult(
        scope: DiskCleanScanScope,
        candidates: [DiskCleanCandidate],
        limitations: [DiskCleanScanLimitation]
    ) -> DiskCleanScanResult {
        DiskCleanScanResult(
            scope: scope,
            candidates: candidates,
            scannedAt: Date(timeIntervalSince1970: 10_000),
            limitations: limitations,
            artifact: DiskCleanScanArtifact(
                scope: scope,
                candidates: candidates,
                reservedRootPaths: [],
                limitations: limitations,
                startedAt: Date(timeIntervalSince1970: 9_000),
                finishedAt: Date(timeIntervalSince1970: 10_000)
            )
        )
    }

    private func candidate(path: String) -> DiskCleanCandidate {
        DiskCleanCandidate(
            id: DiskCleanCandidate.makeID(targetID: DiskCleanPurgeKind.nodeModules.targetID, path: path),
            targetID: DiskCleanPurgeKind.nodeModules.targetID,
            legacyRuleID: DiskCleanPurgeKind.nodeModules.targetID,
            category: .developerArtifacts,
            path: path,
            risk: .low,
            safety: .allowed,
            sizeResult: .testComplete()
        )
    }
}
