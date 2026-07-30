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

    // MARK: - Type branching

    func testOpensDirectoryAndReportsIdentity() throws {
        let directory = try temporaryDirectory.makeDirectory("Caches")

        let outcome = opener.open(path: directory.path)

        guard case let .directory(fileDescriptor, identity) = outcome else {
            return XCTFail("directory should take the walker branch, got \(outcome)")
        }
        defer { close(fileDescriptor) }

        XCTAssertGreaterThanOrEqual(fileDescriptor, 0)
        XCTAssertEqual(identity.fileType, .directory)
        XCTAssertEqual(identity, expectedIdentity(of: directory.path))
    }

    /// Regular files (installers, logs) take st_size from the same fd and skip the walker.
    func testResolvesRegularFileDirectlyFromDescriptor() throws {
        let file = try temporaryDirectory.makeFile("installer.dmg", bytes: 4096)

        let outcome = opener.open(path: file.path)

        guard case let .resolved(bytes, identity) = outcome else {
            return XCTFail("regular file should resolve size directly, got \(outcome)")
        }
        XCTAssertEqual(bytes, 4096)
        XCTAssertEqual(identity.fileType, .regularFile)
        XCTAssertEqual(identity, expectedIdentity(of: file.path))
    }

    /// Symlinks are measured as the **link itself** (size = target string length) and never followed.
    func testResolvesSymlinkAsLinkItself() throws {
        try temporaryDirectory.makeFile("target.bin", bytes: 9999)
        let link = try temporaryDirectory.makeSymlink("link", destination: "target.bin")

        let outcome = opener.open(path: link.path)

        guard case let .resolved(bytes, identity) = outcome else {
            return XCTFail("symlink should resolve as the link itself, got \(outcome)")
        }
        XCTAssertEqual(identity.fileType, .symlink)
        XCTAssertEqual(bytes, Int64("target.bin".utf8.count), "must not follow to the 9999-byte target")
        XCTAssertEqual(identity, expectedIdentity(of: link.path))
    }

    /// A symlink to a directory is also measured as the link; never descend into the target.
    func testSymlinkToDirectoryIsNotFollowed() throws {
        try temporaryDirectory.makeFile("RealDir/huge.bin", bytes: 8192)
        let link = try temporaryDirectory.makeSymlink("DirLink", destination: "RealDir")

        let outcome = opener.open(path: link.path)

        guard case let .resolved(bytes, identity) = outcome else {
            return XCTFail("directory symlink should resolve as the link itself, got \(outcome)")
        }
        XCTAssertEqual(identity.fileType, .symlink)
        XCTAssertEqual(bytes, Int64("RealDir".utf8.count))
    }

    // MARK: - O_NOFOLLOW_ANY: reject symlinks at any path component

    /// Intermediate directory swapped for a symlink → must refuse. Defense against attacks that
    /// replace a middle directory with a symlink into Documents.
    func testRejectsSymlinkInIntermediateComponent() throws {
        try temporaryDirectory.makeFile("RealDir/payload.bin", bytes: 128)
        try temporaryDirectory.makeSymlink("DirLink", destination: "RealDir")

        let outcome = opener.open(path: temporaryDirectory.resolve("DirLink/payload.bin").path)

        XCTAssertEqual(outcome, .failed(reason: .walkError))
    }

    /// Critical regression: intermediate is a symlink **and** the final component is also a symlink.
    ///
    /// Naive `lstat` succeeds and reports "final is symlink", letting the intermediate swap through.
    /// Parent-directory fd anchoring (open parent with O_NOFOLLOW_ANY first) is what catches it.
    func testRejectsSymlinkChainWhereFinalComponentIsAlsoSymlink() throws {
        try temporaryDirectory.makeFile("RealDir/target.bin", bytes: 128)
        try temporaryDirectory.makeSymlink("RealDir/inner", destination: "target.bin")
        try temporaryDirectory.makeSymlink("DirLink", destination: "RealDir")

        let victimPath = temporaryDirectory.resolve("DirLink/inner").path

        // Prerequisite: naive lstat is indeed fooled by this layout.
        var status = stat()
        XCTAssertEqual(lstat(victimPath, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFLNK, "lstat reports it as a legitimate symlink candidate")

        XCTAssertEqual(opener.open(path: victimPath), .failed(reason: .walkError))
    }

    func testRejectsDeepSymlinkChainInAncestor() throws {
        try temporaryDirectory.makeFile("a/b/c/payload.bin", bytes: 32)
        try temporaryDirectory.makeSymlink("a/b/hop", destination: "c")

        let outcome = opener.open(path: temporaryDirectory.resolve("a/b/hop/payload.bin").path)

        XCTAssertEqual(outcome, .failed(reason: .walkError))
    }

    // MARK: - Error mapping

    func testMissingPathMapsToWalkError() {
        let outcome = opener.open(path: temporaryDirectory.resolve("does-not-exist").path)

        XCTAssertEqual(outcome, .failed(reason: .walkError))
    }

    func testUnreadableDirectoryMapsToPermissionDenied() throws {
        try temporaryDirectory.makeDirectory("Locked")
        try temporaryDirectory.denyAccess(to: "Locked")

        // root ignores permission bits, making this assertion meaningless.
        try XCTSkipIf(getuid() == 0, "cannot construct EACCES when running as root")

        let outcome = opener.open(path: temporaryDirectory.resolve("Locked").path)

        XCTAssertEqual(outcome, .failed(reason: .permissionDenied))
    }

    func testRootPathIsRejectedRatherThanTreatedAsCandidate() {
        // "/" has no parent and cannot be a candidate; only require no crash and no false cleanable.
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

    // MARK: - Helpers

    private func expectedIdentity(of path: String) -> DiskCleanRootIdentity {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0, "failed to lstat \(path)")
        return DiskCleanRootIdentity(stat: status)
    }
}
