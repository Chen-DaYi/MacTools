import Darwin
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanFastWalkerTests: XCTestCase {
    private var temporaryDirectory: DiskCleanTempDirectory!
    private var walker: DiskCleanFastWalker!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try DiskCleanTempDirectory(name: "DiskCleanFastWalkerTests")
        walker = DiskCleanFastWalker()
    }

    override func tearDownWithError() throws {
        temporaryDirectory?.remove()
        temporaryDirectory = nil
        walker = nil
        try super.tearDownWithError()
    }

    // MARK: - Behavioral contract (shared assertions with SlowWalker)

    func testSumsKnownTree() throws {
        try DiskCleanWalkerContract.assertSumsKnownTree(walker, in: temporaryDirectory)
    }

    func testDoesNotFollowDirectorySymlink() throws {
        try DiskCleanWalkerContract.assertDoesNotFollowDirectorySymlink(walker, in: temporaryDirectory)
    }

    func testReportsPermissionDenied() throws {
        try XCTSkipIf(getuid() == 0, "cannot construct EACCES when running as root")
        try DiskCleanWalkerContract.assertReportsPermissionDenied(walker, in: temporaryDirectory)
    }

    func testHandlesEmptyDirectory() throws {
        try DiskCleanWalkerContract.assertHandlesEmptyDirectory(walker, in: temporaryDirectory)
    }

    func testExpiredDeadlineReportsTimeout() throws {
        try DiskCleanWalkerContract.assertExpiredDeadlineReportsTimeout(walker, in: temporaryDirectory)
    }

    func testCancellationReportsTimeout() throws {
        try DiskCleanWalkerContract.assertCancellationReportsTimeout(walker, in: temporaryDirectory)
    }

    func testBlockedDeviceIsRefused() throws {
        try DiskCleanWalkerContract.assertBlockedDeviceIsRefused(walker, in: temporaryDirectory)
    }

    func testMissingPathReportsWalkError() {
        DiskCleanWalkerContract.assertMissingPathReportsWalkError(walker, in: temporaryDirectory)
    }

    func testSizesRegularFileRoot() throws {
        try DiskCleanWalkerContract.assertSizesRegularFileRoot(walker, in: temporaryDirectory)
    }

    // MARK: - FastWalker-specific

    /// Focused hard-link dedupe assertion: the same inode twice in one directory counts once.
    func testCountsHardLinkedFileOnce() throws {
        try temporaryDirectory.makeFile("Root/original.bin", bytes: 512)
        try temporaryDirectory.makeHardLink("Root/alias.bin", to: "Root/original.bin")

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Root").path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, 512)
        XCTAssertEqual(result.fileCount, 1)
    }

    /// Regular files with link count 1 must not be hurt by dedupe (same size still counts separately).
    func testCountsDistinctFilesWithIdenticalSizes() throws {
        try temporaryDirectory.makeFile("Root/one.bin", bytes: 256)
        try temporaryDirectory.makeFile("Root/two.bin", bytes: 256)

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Root").path, context: .test())

        XCTAssertEqual(result.estimatedBytes, 512)
        XCTAssertEqual(result.fileCount, 2)
    }

    /// Directories exceeding the single-batch 64KB buffer must accumulate correctly across batches.
    func testSumsDirectoryLargerThanOneBatch() throws {
        let fileCount = 900
        for index in 0..<fileCount {
            try temporaryDirectory.makeFile("Bulk/file-\(index).bin", bytes: 10)
        }

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Bulk").path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.fileCount, fileCount)
        XCTAssertEqual(result.estimatedBytes, Int64(fileCount * 10))
    }

    /// Tiny buffer forces few entries per batch; verify batch boundaries neither drop nor double-count.
    func testTinyBufferStillProducesSameTotal() throws {
        let root = try DiskCleanKnownTree.build(in: temporaryDirectory)

        let tinyBufferWalker = DiskCleanFastWalker(bufferSize: 1)
        let result = tinyBufferWalker.size(ofItemAt: root, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, DiskCleanKnownTree.expectedBytes)
        XCTAssertEqual(result.fileCount, DiskCleanKnownTree.expectedFileCount)
    }

    /// Symlink root: count the link itself, do not follow.
    func testSizesSymlinkRootAsLinkItself() throws {
        try temporaryDirectory.makeFile("target.bin", bytes: 50_000)
        try temporaryDirectory.makeSymlink("alias", destination: "target.bin")

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("alias").path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, Int64("target.bin".utf8.count))
        XCTAssertEqual(result.rootIdentity?.fileType, .symlink)
    }

    /// Deep nesting.
    ///
    /// Depth limit comes from the **test fixture**, not the walker: `FileManager` creates directories with absolute paths
    /// and fails past PATH_MAX(1024); 60 levels (~640 chars) is a safe constructible size. The walker uses relative
    /// fd addressing end-to-end and is not bound by PATH_MAX.
    func testHandlesDeepNesting() throws {
        var relativePath = "Deep"
        for level in 0..<60 {
            relativePath += "/level-\(level)"
        }
        try temporaryDirectory.makeFile("\(relativePath)/leaf.bin", bytes: 33)

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Deep").path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, 33)
        XCTAssertEqual(result.fileCount, 1)
    }

    /// Must still accumulate correctly when sibling directory count far exceeds one batch.
    ///
    /// Note: this only checks correctness and **cannot** prove bounded fd use — the test process RLIMIT_NOFILE is
    /// millions, so holding an fd per sibling never hits the limit. fd upper bound is asserted by
    /// `DiskCleanDirectoryTreeWalkerTests.testKeepsOpenDirectoryCountBoundedByDepth`.
    func testSumsManySiblingDirectories() throws {
        let directoryCount = 600
        for index in 0..<directoryCount {
            try temporaryDirectory.makeFile("Wide/dir-\(index)/leaf.bin", bytes: 4)
        }

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Wide").path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.fileCount, directoryCount)
        XCTAssertEqual(result.estimatedBytes, Int64(directoryCount * 4))
    }

    func testObservedAtUsesInjectedClock() throws {
        try temporaryDirectory.makeDirectory("Root")
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        let result = walker.size(
            ofItemAt: temporaryDirectory.resolve("Root").path,
            context: DiskCleanSizingContext(
                deadline: fixedNow.addingTimeInterval(60),
                now: { fixedNow }
            )
        )

        XCTAssertEqual(result.observedAt, fixedNow)
    }
}
