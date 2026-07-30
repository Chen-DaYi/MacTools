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

    // MARK: - 行为契约（与 SlowWalker 共用同一份断言）

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

    // MARK: - FastWalker 专属

    /// 硬链接去重的聚焦断言：同一 inode 在同一目录出现两次，只能计一次。
    func testCountsHardLinkedFileOnce() throws {
        try temporaryDirectory.makeFile("Root/original.bin", bytes: 512)
        try temporaryDirectory.makeHardLink("Root/alias.bin", to: "Root/original.bin")

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Root").path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, 512)
        XCTAssertEqual(result.fileCount, 1)
    }

    /// 链接数为 1 的普通文件不得被去重逻辑误伤（大小相同也必须各自计入）。
    func testCountsDistinctFilesWithIdenticalSizes() throws {
        try temporaryDirectory.makeFile("Root/one.bin", bytes: 256)
        try temporaryDirectory.makeFile("Root/two.bin", bytes: 256)

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("Root").path, context: .test())

        XCTAssertEqual(result.estimatedBytes, 512)
        XCTAssertEqual(result.fileCount, 2)
    }

    /// 超过单批 64KB 缓冲区容量的目录必须跨多批正确累加。
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

    /// 极小缓冲区强制每批只回极少条目，验证分批边界没有漏条或重复计数。
    func testTinyBufferStillProducesSameTotal() throws {
        let root = try DiskCleanKnownTree.build(in: temporaryDirectory)

        let tinyBufferWalker = DiskCleanFastWalker(bufferSize: 1)
        let result = tinyBufferWalker.size(ofItemAt: root, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, DiskCleanKnownTree.expectedBytes)
        XCTAssertEqual(result.fileCount, DiskCleanKnownTree.expectedFileCount)
    }

    /// symlink 根：按链接本身计，不跟随。
    func testSizesSymlinkRootAsLinkItself() throws {
        try temporaryDirectory.makeFile("target.bin", bytes: 50_000)
        try temporaryDirectory.makeSymlink("alias", destination: "target.bin")

        let result = walker.size(ofItemAt: temporaryDirectory.resolve("alias").path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, Int64("target.bin".utf8.count))
        XCTAssertEqual(result.rootIdentity?.fileType, .symlink)
    }

    /// 深层嵌套。
    ///
    /// 深度上限来自**测试夹具**而非 walker：`FileManager` 用绝对路径建目录，一旦超过
    /// PATH_MAX(1024) 就失败；60 层约 640 字符，是能安全构造的量级。walker 自身全程
    /// fd 相对寻址，不受 PATH_MAX 约束。
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

    /// 兄弟目录数量远超单批容量时仍需正确累加。
    ///
    /// 注意：本条只验证正确性，**不能**证明 fd 占用有界——测试进程的 RLIMIT_NOFILE 高达
    /// 百万，即使每个兄弟目录都攥着 fd 也撞不到上限。fd 占用上界由
    /// `DiskCleanDirectoryTreeWalkerTests.testKeepsOpenDirectoryCountBoundedByDepth` 断言。
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
