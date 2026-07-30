import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Temp-directory fixture for sizing-subsystem filesystem tests.
///
/// **Must use physical paths**: `FileManager.temporaryDirectory` lives under `/var/folders/...`, and `/var`
/// itself is a symlink to `private/var`, so `O_NOFOLLOW_ANY` rejects such paths with ELOOP.
/// `resolvingSymlinksInPath()` does not fix this (it does not expand `/var`); only `realpath(3)` does.
///
/// Everything is under an isolated subdirectory of `FileManager.temporaryDirectory`, deleted wholesale on teardown,
/// and never touches real user directories (repo hard requirement).
final class DiskCleanTempDirectory {
    let url: URL
    /// Directories set to 000 must have permissions restored before teardown or cleanup fails.
    private var restrictedDirectories: [URL] = []

    var path: String { url.path }

    init(name: String) throws {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        self.url = URL(fileURLWithPath: Self.physicalPath(of: created.path), isDirectory: true)
    }

    func remove() {
        for directory in restrictedDirectories {
            chmod(directory.path, 0o755)
        }
        restrictedDirectories.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    static func physicalPath(of path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Layout construction

    func resolve(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let target = resolve(relativePath)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// Write a file of `bytes` bytes and return its URL. Logical size equals `bytes` exactly.
    @discardableResult
    func makeFile(_ relativePath: String, bytes: Int) throws -> URL {
        let target = resolve(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: target)
        return target
    }

    @discardableResult
    func makeSymlink(_ relativePath: String, destination: String) throws -> URL {
        let target = resolve(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
        return target
    }

    @discardableResult
    func makeHardLink(_ relativePath: String, to existingRelativePath: String) throws -> URL {
        let target = resolve(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(at: resolve(existingRelativePath), to: target)
        return target
    }

    /// Set directory mode to 000 to create an EPERM subtree and register it for teardown restore.
    func denyAccess(to relativePath: String) throws {
        let target = resolve(relativePath)
        restrictedDirectories.append(target)
        guard chmod(target.path, 0o000) == 0 else {
            throw DiskCleanTestError.chmodFailed(path: target.path, code: errno)
        }
    }
}

enum DiskCleanTestError: Error {
    case chmodFailed(path: String, code: Int32)
}

/// Known directory-tree fixture: cross-directory hard links, symlinks, and deep nesting; both walkers share identical expectations.
enum DiskCleanKnownTree {
    static let plainFileBytes = 100
    static let nestedFileBytes = 250
    static let deepFileBytes = 50
    static let hardLinkedFileBytes = 400
    static let symlinkDestination = "../a.bin"
    static let deepDirectoryDepth = 40

    /// Symlink logical size is the target string length.
    static var symlinkBytes: Int { symlinkDestination.utf8.count }

    /// Hard links counted once: `original.bin` / `HardLinks/copy.bin` / `OtherDir/cross.bin`
    /// share the same (devid, fileID).
    static var expectedBytes: Int64 {
        Int64(plainFileBytes + nestedFileBytes + deepFileBytes + symlinkBytes + hardLinkedFileBytes)
    }

    /// a.bin / Nested/b.bin / deep deep.bin / Links/toA / hard-link group (count 1). Directories not counted.
    static let expectedFileCount = 5

    @discardableResult
    static func build(in temporary: DiskCleanTempDirectory, at relativeRoot: String = "Tree") throws -> String {
        try temporary.makeFile("\(relativeRoot)/a.bin", bytes: plainFileBytes)
        try temporary.makeFile("\(relativeRoot)/Nested/b.bin", bytes: nestedFileBytes)

        var deepPath = "\(relativeRoot)/Nested/deep"
        for level in 0..<deepDirectoryDepth {
            deepPath += "/level-\(level)"
        }
        try temporary.makeFile("\(deepPath)/deep.bin", bytes: deepFileBytes)

        try temporary.makeSymlink("\(relativeRoot)/Links/toA", destination: symlinkDestination)

        try temporary.makeFile("\(relativeRoot)/HardLinks/original.bin", bytes: hardLinkedFileBytes)
        try temporary.makeHardLink(
            "\(relativeRoot)/HardLinks/copy.bin",
            to: "\(relativeRoot)/HardLinks/original.bin"
        )
        try temporary.makeHardLink(
            "\(relativeRoot)/OtherDir/cross.bin",
            to: "\(relativeRoot)/HardLinks/original.bin"
        )

        // Empty directories must be handled normally (0 bytes, no count, no error).
        try temporary.makeDirectory("\(relativeRoot)/Empty")

        return temporary.resolve(relativeRoot).path
    }
}

/// Shared behavior contract both walkers must satisfy (design §3.5: fallback walker reuses all §3.3 constraints).
/// Invoked case-by-case from FastWalker / SlowWalker test classes to avoid duplicated asserts while keeping granularity.
enum DiskCleanWalkerContract {
    static func assertSumsKnownTree(
        _ sizer: any DiskCleanDirectorySizing,
        in temporary: DiskCleanTempDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = try DiskCleanKnownTree.build(in: temporary)

        let result = sizer.size(ofItemAt: root, context: .test())

        XCTAssertEqual(result.completeness, .complete, file: file, line: line)
        XCTAssertEqual(
            result.estimatedBytes,
            DiskCleanKnownTree.expectedBytes,
            "cross-directory hard links must count once; symlinks are measured as the link itself",
            file: file,
            line: line
        )
        XCTAssertEqual(result.fileCount, DiskCleanKnownTree.expectedFileCount, file: file, line: line)
        XCTAssertEqual(result.rootIdentity?.fileType, .directory, file: file, line: line)
    }

    /// Contents of a directory targeted by a symlink must never be counted.
    static func assertDoesNotFollowDirectorySymlink(
        _ sizer: any DiskCleanDirectorySizing,
        in temporary: DiskCleanTempDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try temporary.makeFile("Outside/huge.bin", bytes: 100_000)
        try temporary.makeDirectory("Root")
        try temporary.makeSymlink("Root/escape", destination: "../Outside")

        let result = sizer.size(ofItemAt: temporary.resolve("Root").path, context: .test())

        XCTAssertEqual(result.completeness, .complete, file: file, line: line)
        XCTAssertEqual(
            result.estimatedBytes,
            Int64("../Outside".utf8.count),
            "only the link length should count; never follow into the 100KB target directory",
            file: file,
            line: line
        )
        XCTAssertEqual(result.fileCount, 1, file: file, line: line)
    }

    /// Skip EPERM subtrees but still accumulate accessible parts and degrade completeness to permissionDenied.
    static func assertReportsPermissionDenied(
        _ sizer: any DiskCleanDirectorySizing,
        in temporary: DiskCleanTempDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try temporary.makeFile("Root/readable.bin", bytes: 70)
        try temporary.makeFile("Root/Locked/secret.bin", bytes: 900)
        try temporary.denyAccess(to: "Root/Locked")

        let result = sizer.size(ofItemAt: temporary.resolve("Root").path, context: .test())

        XCTAssertEqual(
            result.completeness,
            .partial(reasons: [.permissionDenied]),
            file: file,
            line: line
        )
        XCTAssertEqual(result.estimatedBytes, 70, file: file, line: line)
    }

    static func assertHandlesEmptyDirectory(
        _ sizer: any DiskCleanDirectorySizing,
        in temporary: DiskCleanTempDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try temporary.makeDirectory("Hollow")

        let result = sizer.size(ofItemAt: temporary.resolve("Hollow").path, context: .test())

        XCTAssertEqual(result.completeness, .complete, file: file, line: line)
        XCTAssertEqual(result.estimatedBytes, 0, file: file, line: line)
        XCTAssertEqual(result.fileCount, 0, file: file, line: line)
    }

    /// Past deadline → partial([.timedOut]); never report complete.
    static func assertExpiredDeadlineReportsTimeout(
        _ sizer: any DiskCleanDirectorySizing,
        in temporary: DiskCleanTempDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = try DiskCleanKnownTree.build(in: temporary)

        let result = sizer.size(
            ofItemAt: root,
            context: .test(deadline: Date().addingTimeInterval(-1))
        )

        XCTAssertEqual(result.completeness, .partial(reasons: [.timedOut]), file: file, line: line)
    }

    static func assertCancellationReportsTimeout(
        _ sizer: any DiskCleanDirectorySizing,
        in temporary: DiskCleanTempDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = try DiskCleanKnownTree.build(in: temporary)

        let result = sizer.size(ofItemAt: root, context: .test(isCancelled: { true }))

        XCTAssertEqual(result.completeness, .partial(reasons: [.timedOut]), file: file, line: line)
    }

    /// Device on the circuit-break blacklist → abandon immediately, fail closed.
    static func assertBlockedDeviceIsRefused(
        _ sizer: any DiskCleanDirectorySizing,
        in temporary: DiskCleanTempDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let root = try DiskCleanKnownTree.build(in: temporary)

        let result = sizer.size(ofItemAt: root, context: .test(admitDevice: { _ in false }))

        XCTAssertEqual(
            result.completeness,
            .partial(reasons: [.unsupportedVolume]),
            file: file,
            line: line
        )
        XCTAssertEqual(result.estimatedBytes, 0, file: file, line: line)
    }

    static func assertMissingPathReportsWalkError(
        _ sizer: any DiskCleanDirectorySizing,
        in temporary: DiskCleanTempDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = sizer.size(ofItemAt: temporary.resolve("nope").path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.walkError]), file: file, line: line)
        XCTAssertNil(result.rootIdentity, "no identity when the root object cannot be opened", file: file, line: line)
    }

    /// Regular-file root: size directly without walking.
    static func assertSizesRegularFileRoot(
        _ sizer: any DiskCleanDirectorySizing,
        in temporary: DiskCleanTempDirectory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try temporary.makeFile("installer.pkg", bytes: 3072)

        let result = sizer.size(ofItemAt: temporary.resolve("installer.pkg").path, context: .test())

        XCTAssertEqual(result.completeness, .complete, file: file, line: line)
        XCTAssertEqual(result.estimatedBytes, 3072, file: file, line: line)
        XCTAssertEqual(result.fileCount, 1, file: file, line: line)
        XCTAssertEqual(result.rootIdentity?.fileType, .regularFile, file: file, line: line)
    }
}

extension DiskCleanSizingContext {
    /// Context with no cancellation, no device limits, and plenty of time.
    static func test(
        deadline: Date = Date().addingTimeInterval(60),
        isCancelled: @escaping @Sendable () -> Bool = { false },
        admitDevice: @escaping @Sendable (UInt64) -> Bool = { _ in true }
    ) -> DiskCleanSizingContext {
        DiskCleanSizingContext(
            deadline: deadline,
            isCancelled: isCancelled,
            admitDevice: admitDevice
        )
    }
}
