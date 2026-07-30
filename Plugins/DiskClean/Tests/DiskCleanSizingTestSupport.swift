import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Sizing 子系统文件系统测试的临时目录夹具。
///
/// **必须取物理路径**：`FileManager.temporaryDirectory` 位于 `/var/folders/...`，而 `/var`
/// 本身是指向 `private/var` 的符号链接，`O_NOFOLLOW_ANY` 会直接以 ELOOP 拒绝这类路径。
/// 且 `resolvingSymlinksInPath()` 修不了这件事（它不展开 `/var`），只有 `realpath(3)` 可以。
///
/// 一切都建在 `FileManager.temporaryDirectory` 下的独立子目录内，teardown 整体删除，
/// 绝不触碰真实用户目录（仓库硬性要求）。
final class DiskCleanTempDirectory {
    let url: URL
    /// 被改成 000 的目录，teardown 前必须恢复权限，否则删不掉会留垃圾。
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

    // MARK: - 构造布局

    func resolve(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let target = resolve(relativePath)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// 写入 `bytes` 个字节的文件，返回其 URL。逻辑大小恰好等于 `bytes`。
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

    /// 把目录权限改成 000 制造 EPERM 子树，并登记以便 teardown 恢复。
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

/// 已知目录树夹具：跨目录硬链接、symlink、深层嵌套齐备，两个 walker 的期望值完全相同。
enum DiskCleanKnownTree {
    static let plainFileBytes = 100
    static let nestedFileBytes = 250
    static let deepFileBytes = 50
    static let hardLinkedFileBytes = 400
    static let symlinkDestination = "../a.bin"
    static let deepDirectoryDepth = 40

    /// symlink 的逻辑大小是目标字符串长度。
    static var symlinkBytes: Int { symlinkDestination.utf8.count }

    /// 硬链接只计一次：`original.bin` / `HardLinks/copy.bin` / `OtherDir/cross.bin`
    /// 共享同一 (devid, fileID)。
    static var expectedBytes: Int64 {
        Int64(plainFileBytes + nestedFileBytes + deepFileBytes + symlinkBytes + hardLinkedFileBytes)
    }

    /// a.bin / Nested/b.bin / 深层 deep.bin / Links/toA / 硬链接组（计 1）。目录不计数。
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

        // 空目录必须被正常处理（0 字节、不计数、不报错）。
        try temporary.makeDirectory("\(relativeRoot)/Empty")

        return temporary.resolve(relativeRoot).path
    }
}

/// 两个 walker 必须满足的同一份行为契约（设计 §3.5：回退 walker 复用 §3.3 全部约束）。
/// 由 FastWalker / SlowWalker 各自的测试类逐条调用，避免断言重复又保持用例粒度。
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
            "跨目录硬链接必须只计一次，symlink 按链接本身计",
            file: file,
            line: line
        )
        XCTAssertEqual(result.fileCount, DiskCleanKnownTree.expectedFileCount, file: file, line: line)
        XCTAssertEqual(result.rootIdentity?.fileType, .directory, file: file, line: line)
    }

    /// symlink 指向的目录内容绝不能被计入。
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
            "只应计入链接自身长度，绝不能跟随进 100KB 的目标目录",
            file: file,
            line: line
        )
        XCTAssertEqual(result.fileCount, 1, file: file, line: line)
    }

    /// EPERM 子树跳过，但可访问部分仍要如实累加，且完整性降级为 permissionDenied。
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

    /// deadline 已过 → partial([.timedOut])，绝不能报 complete。
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

    /// 设备在熔断黑名单内 → 立即放弃，fail closed。
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
        XCTAssertNil(result.rootIdentity, "打不开根对象时没有身份可言", file: file, line: line)
    }

    /// 普通文件根：直接定大小，无需遍历。
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
    /// 无取消、无设备限制、给足时间的上下文。
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
