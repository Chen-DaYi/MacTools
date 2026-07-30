import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// FDA capability probe (design §9).
///
/// All via an injected readability seam — **never touch real TCC-protected files**:
/// the machine under test may already have terminal FDA, and assertions would follow the environment.
final class DiskCleanFullDiskAccessTests: XCTestCase {
    private let tccPath = "/Users/diskclean-tests/Library/Application Support/com.apple.TCC/TCC.db"
    private let safariPath = "/Users/diskclean-tests/Library/Safari/Bookmarks.plist"

    // MARK: - Probe matrix

    func testReportsGrantedWhenFirstProbePathOpens() {
        let readability = FakeDiskCleanFileReadability(openablePaths: [tccPath])
        let probe = makeProbe(readability: readability)

        XCTAssertTrue(probe.hasFullDiskAccess)
        XCTAssertEqual(readability.probedPaths, [tccPath], "must not try the second path after the first succeeds")
    }

    /// A brand-new account may not have TCC.db yet. Opening the fallback path still proves FDA.
    func testReportsGrantedWhenOnlyFallbackProbePathOpens() {
        let readability = FakeDiskCleanFileReadability(openablePaths: [safariPath])
        let probe = makeProbe(readability: readability)

        XCTAssertTrue(probe.hasFullDiskAccess)
        XCTAssertEqual(readability.probedPaths, [tccPath, safariPath])
    }

    /// Denial and missing file are the same to the probe: neither proves FDA.
    /// Must fail safe — a false "granted" would let the engine expand protected targets and get empty unreadable candidates.
    func testReportsDeniedWhenNoProbePathOpens() {
        let readability = FakeDiskCleanFileReadability()
        let probe = makeProbe(readability: readability)

        XCTAssertFalse(probe.hasFullDiskAccess)
        XCTAssertEqual(readability.probedPaths, [tccPath, safariPath], "must try all probe paths before concluding")
    }

    func testReportsDeniedWhenProbePathListIsEmpty() {
        let probe = DiskCleanFullDiskAccessProbe(
            probePaths: [],
            readability: FakeDiskCleanFileReadability(openablePaths: [tccPath])
        )

        XCTAssertFalse(probe.hasFullDiskAccess)
    }

    // MARK: - In-process cache

    /// FDA is bound at process launch and does not change at runtime — the reason the status card says "quit and reopen".
    /// Caching also ensures every target in one scan sees the same answer.
    func testCachesResultForTheLifetimeOfTheProcess() {
        let readability = FakeDiskCleanFileReadability(openablePaths: [tccPath])
        let probe = makeProbe(readability: readability)

        XCTAssertTrue(probe.hasFullDiskAccess)
        XCTAssertTrue(probe.hasFullDiskAccess)
        XCTAssertTrue(probe.hasFullDiskAccess)

        XCTAssertEqual(readability.probedPaths, [tccPath], "repeated reads must not re-probe")
    }

    func testCachesNegativeResultToo() {
        let readability = FakeDiskCleanFileReadability()
        let probe = makeProbe(readability: readability)

        XCTAssertFalse(probe.hasFullDiskAccess)
        XCTAssertFalse(probe.hasFullDiskAccess)

        XCTAssertEqual(readability.probedPaths, [tccPath, safariPath])
    }

    // MARK: - Default probe targets

    /// Probe targets must stay in the "silent EPERM" class. Documents / Downloads / Desktop and sandbox
    /// containers **prompt**, so probing them would nag the user on every launch.
    func testDefaultProbePathsStayInSilentlyDeniedLocations() {
        let paths = DiskCleanFullDiskAccessProbe.defaultProbePaths(homeDirectory: "/Users/diskclean-tests")

        XCTAssertEqual(paths, [tccPath, safariPath])
        for path in paths {
            XCTAssertFalse(path.contains("/Documents/"))
            XCTAssertFalse(path.contains("/Downloads/"))
            XCTAssertFalse(path.contains("/Desktop/"))
            XCTAssertFalse(path.contains("/Library/Containers/"))
        }
    }

    // MARK: - Authorization guidance

    func testSettingsURLPointsAtFullDiskAccessPane() {
        XCTAssertEqual(
            DiskCleanFullDiskAccessGuide.settingsURLString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
        XCTAssertNotNil(DiskCleanFullDiskAccessGuide.settingsURL)
    }

    // MARK: - Helpers

    private func makeProbe(readability: FakeDiskCleanFileReadability) -> DiskCleanFullDiskAccessProbe {
        DiskCleanFullDiskAccessProbe(
            probePaths: DiskCleanFullDiskAccessProbe.defaultProbePaths(
                homeDirectory: "/Users/diskclean-tests"
            ),
            readability: readability
        )
    }
}
