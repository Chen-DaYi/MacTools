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

    // MARK: - 行为契约（与 FastWalker 共用同一份断言）

    func testSumsKnownTree() throws {
        try DiskCleanWalkerContract.assertSumsKnownTree(walker, in: temporaryDirectory)
    }

    func testDoesNotFollowDirectorySymlink() throws {
        try DiskCleanWalkerContract.assertDoesNotFollowDirectorySymlink(walker, in: temporaryDirectory)
    }

    func testReportsPermissionDenied() throws {
        try XCTSkipIf(getuid() == 0, "以 root 运行时无法构造 EACCES")
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

    // MARK: - SlowWalker 专属

    /// readdir 会返回 "." 与 ".."，必须过滤掉——否则不仅重复计数，还会无限递归。
    func testSkipsDotEntries() throws {
        try temporaryDirectory.makeFile("Root/only.bin", bytes: 64)

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Root").path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.fileCount, 1, "\".\" 与 \"..\" 不得被计入")
        XCTAssertEqual(result.estimatedBytes, 64)
    }

    func testCountsHardLinkedFileOnce() throws {
        try temporaryDirectory.makeFile("Root/original.bin", bytes: 512)
        try temporaryDirectory.makeHardLink("Root/alias.bin", to: "Root/original.bin")

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Root").path, context: .test())

        XCTAssertEqual(result.estimatedBytes, 512)
        XCTAssertEqual(result.fileCount, 1)
    }

    /// 极小 batchSize 强制多批读取，验证分批边界无漏条或重复。
    func testSingleEntryBatchesStillProduceSameTotal() throws {
        let root = try DiskCleanKnownTree.build(in: temporaryDirectory)

        let result = DiskCleanSlowWalker(batchSize: 1).size(ofItemAt: root, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, DiskCleanKnownTree.expectedBytes)
        XCTAssertEqual(result.fileCount, DiskCleanKnownTree.expectedFileCount)
    }

    // MARK: - 与 FastWalker 交叉验证

    /// 两个 walker 对同一棵树必须给出完全一致的结果——这是"回退不降低语义"的核心保证。
    func testAgreesWithFastWalkerOnKnownTree() throws {
        let root = try DiskCleanKnownTree.build(in: temporaryDirectory)

        let slow = walker.size(ofItemAt: root, context: .test())
        let fast = DiskCleanFastWalker().size(ofItemAt: root, context: .test())

        XCTAssertEqual(slow.estimatedBytes, fast.estimatedBytes)
        XCTAssertEqual(slow.fileCount, fast.fileCount)
        XCTAssertEqual(slow.completeness, fast.completeness)
        XCTAssertEqual(slow.rootIdentity, fast.rootIdentity)
    }

    /// 降级场景也必须一致：EPERM 子树下两者的字节数与完整性原因集合都要相同。
    func testAgreesWithFastWalkerOnPermissionDeniedTree() throws {
        try XCTSkipIf(getuid() == 0, "以 root 运行时无法构造 EACCES")
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
