import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Empty-state resolution for P2 sections (design §10).
///
/// These states must stay distinct: they ask the user for completely different next steps — add folders, start a scan,
/// grant access, roots are gone, or truly empty. Collapsing into one "no content" leaves the user guessing.
@MainActor
final class DiskCleanSectionGuidanceTests: XCTestCase {
    // MARK: - Needs-roots guidance

    func testDeveloperArtifactsWithoutRootsAsksForFolders() {
        let snapshot = makeSnapshot(scope: .developerArtifacts(roots: []), scanResult: nil)

        XCTAssertEqual(DiskCleanSectionGuidance.resolve(snapshot), .needsRoots)
    }

    /// Needs-roots outranks not-scanned: showing "scan" with a disabled button is the most confusing combination.
    func testNeedsRootsOutranksNotScanned() {
        let snapshot = makeSnapshot(scope: .developerArtifacts(roots: []), scanResult: nil)

        XCTAssertFalse(snapshot.canScan, "scan entry must be disabled without roots")
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
        XCTAssertTrue(snapshot.canScan, "installer section has fixed scope and is always scannable")
    }

    // MARK: - Authorization guidance

    /// `denied` must stay distinct from "scanned with no candidates": `~/Downloads` may hold tens of GB of installers;
    /// showing "nothing to clean" would mislead the user.
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

    /// When both denied and invalid roots exist, prefer authorization — the one the user can fix themselves.
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

    // MARK: - Candidates keep the stage

    /// One root denied, another yields candidates: show the list; root problems go to the limited banner.
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

    // MARK: - Helpers

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
