import Darwin
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanSlowWalkerTests: XCTestCase {
    private var temporaryDirectory: DiskCleanTempDirectory!
    private var walker: DiskCleanSlowWalker!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try DiskCleanTempDirectory(name: "DiskCleanSlowWalkerTests")
        walker = DiskCleanSlowWalker()
    }

    override func tearDownWithError() throws {
        temporaryDirectory?.remove()
        temporaryDirectory = nil
        walker = nil
        try super.tearDownWithError()
    }

    // MARK: - Behavior contract (shared asserts with FastWalker)
    func testSkipsDotEntries() throws {
        try temporaryDirectory.makeFile("Root/only.bin", bytes: 64)

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Root").path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.fileCount, 1, "\".\" and \"..\" must not be counted")
        XCTAssertEqual(result.estimatedBytes, 64)
    }

    func testCountsHardLinkedFileOnce() throws {
        try temporaryDirectory.makeFile("Root/original.bin", bytes: 512)
        try temporaryDirectory.makeHardLink("Root/alias.bin", to: "Root/original.bin")

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Root").path, context: .test())

        XCTAssertEqual(result.estimatedBytes, 512)
        XCTAssertEqual(result.fileCount, 1)
    }

    /// Tiny batchSize forces multi-batch reads to verify no misses or duplicates at batch boundaries.
    func testSingleEntryBatchesStillProduceSameTotal() throws {
        let root = try DiskCleanKnownTree.build(in: temporaryDirectory)

        let result = DiskCleanSlowWalker(batchSize: 1).size(ofItemAt: root, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, DiskCleanKnownTree.expectedBytes)
        XCTAssertEqual(result.fileCount, DiskCleanKnownTree.expectedFileCount)
    }

    // MARK: - Cross-check with FastWalker

    /// Both walkers must produce identical results on the same tree — the core guarantee that fallback does not lower semantics.
    func testAgreesWithFastWalkerOnKnownTree() throws {
        let root = try DiskCleanKnownTree.build(in: temporaryDirectory)

        let slow = walker.size(ofItemAt: root, context: .test())
        let fast = DiskCleanFastWalker().size(ofItemAt: root, context: .test())

        XCTAssertEqual(slow.estimatedBytes, fast.estimatedBytes)
        XCTAssertEqual(slow.fileCount, fast.fileCount)
        XCTAssertEqual(slow.completeness, fast.completeness)
        XCTAssertEqual(slow.rootIdentity, fast.rootIdentity)
    }

    /// Degradation scenarios must also match: under an EPERM subtree both share the same byte count and completeness reasons.
    func testAgreesWithFastWalkerOnPermissionDeniedTree() throws {
        try XCTSkipIf(getuid() == 0, "cannot construct EACCES when running as root")
        try temporaryDirectory.makeFile("Root/readable.bin", bytes: 70)
        try temporaryDirectory.makeFile("Root/Locked/secret.bin", bytes: 900)
        try temporaryDirectory.denyAccess(to: "Root/Locked")
        let root = temporaryDirectory.resolve("Root").path

        let slow = walker.size(ofItemAt: root, context: .test())
        let fast = DiskCleanFastWalker().size(ofItemAt: root, context: .test())

        XCTAssertEqual(slow.completeness, fast.completeness)
        XCTAssertEqual(slow.completeness, .partial(reasons: [.permissionDenied]))
        XCTAssertEqual(slow.estimatedBytes, fast.estimatedBytes)
    }

    func testAgreesWithFastWalkerOnSymlinkAndFileRoots() throws {
        try temporaryDirectory.makeFile("target.bin", bytes: 1234)
        try temporaryDirectory.makeSymlink("alias", destination: "target.bin")

        for relativePath in ["target.bin", "alias"] {
            let path = temporaryDirectory.resolve(relativePath).path
            let slow = walker.size(ofItemAt: path, context: .test())
            let fast = DiskCleanFastWalker().size(ofItemAt: path, context: .test())

            XCTAssertEqual(slow.estimatedBytes, fast.estimatedBytes, relativePath)
            XCTAssertEqual(slow.fileCount, fast.fileCount, relativePath)
            XCTAssertEqual(slow.completeness, fast.completeness, relativePath)
            XCTAssertEqual(slow.rootIdentity, fast.rootIdentity, relativePath)
        }
    }
}
