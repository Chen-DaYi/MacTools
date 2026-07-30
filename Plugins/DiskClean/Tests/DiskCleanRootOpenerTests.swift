import Darwin
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanRootOpenerTests: XCTestCase {
    private var temporaryDirectory: DiskCleanTempDirectory!
    private var opener: DiskCleanRootOpener!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try DiskCleanTempDirectory(name: "DiskCleanRootOpenerTests")
        opener = DiskCleanRootOpener()
    }

    override func tearDownWithError() throws {
        temporaryDirectory?.remove()
        temporaryDirectory = nil
        opener = nil
        try super.tearDownWithError()
    }

    // MARK: - 分型

    func testOpensDirectoryAndReportsIdentity() throws {
        let directory = try temporaryDirectory.makeDirectory("Caches")

        let outcome = opener.open(path: directory.path)

        guard case let .directory(fileDescriptor, identity) = outcome else {
            return XCTFail("目录应走 walker 分支，实际 \(outcome)")
        }
        defer { close(fileDescriptor) }

        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)
        XCTAssertEqual(identity.fileType, .directory)
        XCTAssertEqual(identity, expectedIdentity(of: directory.path))
    }

    /// 普通文件（安装包、日志）直接从同一 fd 取 st_size，不进 walker。
    func testResolvesRegularFileDirectlyFromDescriptor() throws {
        let file = try temporaryDirectory.makeFile("installer.dmg", bytes: 4096)

        let outcome = opener.open(path: file.path)

        guard case let .resolved(bytes, identity) = outcome else {
            return XCTFail("普通文件应直接定大小，实际 \(outcome)")
        }
        XCTAssertEqual(bytes, 4096)
        XCTAssertEqual(identity.fileType, .regularFile)
        XCTAssertEqual(identity, expectedIdentity(of: file.path))
    }

    /// symlink 按**链接本身**计（大小 = 目标字符串长度），绝不跟随。
    func testResolvesSymlinkAsLinkItself() throws {
        try temporaryDirectory.makeFile("target.bin", bytes: 9999)
        let link = try temporaryDirectory.makeSymlink("link", destination: "target.bin")

        let outcome = opener.open(path: link.path)

        guard case let .resolved(bytes, identity) = outcome else {
            return XCTFail("symlink 应按链接本身解析，实际 \(outcome)")
        }
        XCTAssertEqual(identity.fileType, .symlink)
        XCTAssertEqual(bytes, Int64("target.bin".utf8.count), "绝不能跟随到 9999 字节的目标")
        XCTAssertEqual(identity, expectedIdentity(of: link.path))
    }

    /// 指向目录的 symlink 同样按链接本身计，不得下潜进目标目录。
    func testSymlinkToDirectoryIsNotFollowed() throws {
        try temporaryDirectory.makeFile("RealDir/huge.bin", bytes: 8192)
        let link = try temporaryDirectory.makeSymlink("DirLink", destination: "RealDir")

        let outcome = opener.open(path: link.path)

        guard case let .resolved(bytes, identity) = outcome else {
            return XCTFail("目录 symlink 应按链接本身解析，实际 \(outcome)")
        }
        XCTAssertEqual(identity.fileType, .symlink)
        XCTAssertEqual(bytes, Int64("RealDir".utf8.count))
    }

    // MARK: - O_NOFOLLOW_ANY：拒绝路径任意一级的符号链接

    /// 中间级目录被换成 symlink → 必须拒绝。这是"把中间目录换成指向 Documents 的 symlink"
    /// 这类攻击的防线。
    func testRejectsSymlinkInIntermediateComponent() throws {
        try temporaryDirectory.makeFile("RealDir/payload.bin", bytes: 128)
        try temporaryDirectory.makeSymlink("DirLink", destination: "RealDir")

        let outcome = opener.open(path: temporaryDirectory.resolve("DirLink/payload.bin").path)

        XCTAssertEqual(outcome, .failed(reason: .walkError))
    }

    /// 关键回归：中间级是 symlink **且**末级也是 symlink。
    ///
    /// 朴素 `lstat` 在这种布局下会成功并报告"末级是 symlink"，于是中间级替换被放过。
    /// 父目录 fd 锚定（先用 O_NOFOLLOW_ANY 打开父目录）才能识破。
    func testRejectsSymlinkChainWhereFinalComponentIsAlsoSymlink() throws {
        try temporaryDirectory.makeFile("RealDir/target.bin", bytes: 128)
        try temporaryDirectory.makeSymlink("RealDir/inner", destination: "target.bin")
        try temporaryDirectory.makeSymlink("DirLink", destination: "RealDir")

        let victimPath = temporaryDirectory.resolve("DirLink/inner").path

        // 前提确认：朴素 lstat 确实会被这套布局骗过。
        var status = stat()
        XCTAssertEqual(lstat(victimPath, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFLNK, "lstat 会把它报成合法 symlink 候选")

        XCTAssertEqual(opener.open(path: victimPath), .failed(reason: .walkError))
    }

    func testRejectsDeepSymlinkChainInAncestor() throws {
        try temporaryDirectory.makeFile("a/b/c/payload.bin", bytes: 32)
        try temporaryDirectory.makeSymlink("a/b/hop", destination: "c")

        let outcome = opener.open(path: temporaryDirectory.resolve("a/b/hop/payload.bin").path)

        XCTAssertEqual(outcome, .failed(reason: .walkError))
    }

    // MARK: - 错误映射

    func testMissingPathMapsToWalkError() {
        let outcome = opener.open(path: temporaryDirectory.resolve("does-not-exist").path)

        XCTAssertEqual(outcome, .failed(reason: .walkError))
    }

    func testUnreadableDirectoryMapsToPermissionDenied() throws {
        try temporaryDirectory.makeDirectory("Locked")
        try temporaryDirectory.denyAccess(to: "Locked")

        // root 会无视权限位，此时该断言无意义。
        try XCTSkipIf(getuid() == 0, "以 root 运行时无法构造 EACCES")

        let outcome = opener.open(path: temporaryDirectory.resolve("Locked").path)

        XCTAssertEqual(outcome, .failed(reason: .permissionDenied))
    }

    func testRootPathIsRejectedRatherThanTreatedAsCandidate() {
        // "/" 没有父目录，也不可能是候选；此处只要求不崩、不误判为可清理。
        let outcome = opener.open(path: "/")

        if case let .directory(fileDescriptor, identity) = outcome {
            close(fileDescriptor)
            XCTAssertEqual(identity.fileType, .directory)
        }
    }

    // MARK: - ParentAnchoredPath

    func testParentAnchoredPathSplitsPaths() throws {
        let nested = try XCTUnwrap(ParentAnchoredPath(path: "/Users/someone/Library/Caches"))
        XCTAssertEqual(nested.parentPath, "/Users/someone/Library")
        XCTAssertEqual(nested.name, "Caches")

        let trailingSlash = try XCTUnwrap(ParentAnchoredPath(path: "/Users/someone/Library/Caches/"))
        XCTAssertEqual(trailingSlash.parentPath, "/Users/someone/Library")
        XCTAssertEqual(trailingSlash.name, "Caches")

        let topLevel = try XCTUnwrap(ParentAnchoredPath(path: "/single"))
        XCTAssertEqual(topLevel.parentPath, "/")
        XCTAssertEqual(topLevel.name, "single")

        XCTAssertNil(ParentAnchoredPath(path: "/"))
        XCTAssertNil(ParentAnchoredPath(path: ""))
        XCTAssertNil(ParentAnchoredPath(path: "/a/.."))
    }

    // MARK: - 辅助

    private func expectedIdentity(of path: String) -> DiskCleanRootIdentity {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0, "无法 lstat \(path)")
        return DiskCleanRootIdentity(stat: status)
    }
}
