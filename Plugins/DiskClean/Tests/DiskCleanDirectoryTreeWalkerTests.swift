import Darwin
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 通过注入伪造条目流测试遍历骨架的约束。
///
/// 挂载穿越无法在真实文件系统上构造（测试进程不能 mount），因此设计 §11 明确要求
/// "devid 注入 fake 测挂载不下潜"——本文件即该要求的落地。
final class DiskCleanDirectoryTreeWalkerTests: XCTestCase {
    private var temporaryDirectory: DiskCleanTempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try DiskCleanTempDirectory(name: "DiskCleanDirectoryTreeWalkerTests")
    }

    override func tearDownWithError() throws {
        temporaryDirectory?.remove()
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - 挂载防护

    /// 子目录条目的 devid 与根不同（= 该位置挂载了别的卷）→ 不下潜、不计数、加 crossedMountPoint。
    func testDoesNotDescendIntoDirectoryOnAnotherDevice() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        try temporaryDirectory.makeFile("Root/Mounted/should-not-be-counted.bin", bytes: 5000)
        let rootDevice = try deviceID(of: root.path)

        let factory = ScriptedSourceFactory(scripts: [
            [[
                .resolved(entry(name: "Mounted", type: .directory, devid: rootDevice + 1, fileID: 77))
            ]]
        ])
        let walker = DiskCleanDirectoryTreeWalker(sourceFactory: factory)

        let result = walker.size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.crossedMountPoint]))
        XCTAssertEqual(result.estimatedBytes, 0)
        XCTAssertEqual(result.fileCount, 0)
        XCTAssertEqual(factory.createdSourceCount, 1, "跨设备目录不得被 openat 下潜")
    }

    /// 跨设备的普通文件同样不计入。
    func testDoesNotCountFileOnAnotherDevice() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let rootDevice = try deviceID(of: root.path)

        let factory = ScriptedSourceFactory(scripts: [
            [[
                .resolved(entry(name: "local.bin", type: .regularFile, devid: rootDevice, fileID: 1, dataLength: 100)),
                .resolved(entry(name: "foreign.bin", type: .regularFile, devid: rootDevice + 1, fileID: 2, dataLength: 900))
            ]]
        ])

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.crossedMountPoint]))
        XCTAssertEqual(result.estimatedBytes, 100)
        XCTAssertEqual(result.fileCount, 1)
    }

    // MARK: - 条目级失败映射

    func testUnresolvedEntryWithPermissionErrorReportsPermissionDenied() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let factory = ScriptedSourceFactory(scripts: [[[.unresolved(code: EACCES)]]])

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.permissionDenied]))
    }

    func testUnresolvedEntryWithOtherErrorReportsWalkError() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let factory = ScriptedSourceFactory(scripts: [[[.unresolved(code: EIO)]]])

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.walkError]))
    }

    func testThrowingSourceMapsErrnoAndKeepsPartialTotals() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let rootDevice = try deviceID(of: root.path)
        let factory = ScriptedSourceFactory(
            scripts: [[[
                .resolved(entry(name: "counted.bin", type: .regularFile, devid: rootDevice, fileID: 1, dataLength: 42))
            ]]],
            throwAfterScriptedBatches: DiskCleanPOSIXError(code: EACCES)
        )

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.permissionDenied]))
        XCTAssertEqual(result.estimatedBytes, 42, "失败前已累加的部分必须如实保留")
    }

    /// 多个降级原因必须并存，不能相互覆盖。
    func testAccumulatesMultiplePartialReasons() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let rootDevice = try deviceID(of: root.path)
        let factory = ScriptedSourceFactory(scripts: [[[
            .unresolved(code: EACCES),
            .unresolved(code: EIO),
            .resolved(entry(name: "foreign", type: .directory, devid: rootDevice + 1, fileID: 9))
        ]]])

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(
            result.completeness,
            .partial(reasons: [.permissionDenied, .walkError, .crossedMountPoint])
        )
    }

    // MARK: - 硬链接去重

    func testDeduplicatesHardLinksByDeviceAndFileID() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let rootDevice = try deviceID(of: root.path)
        let factory = ScriptedSourceFactory(scripts: [[[
            .resolved(entry(name: "one", type: .regularFile, devid: rootDevice, fileID: 500, linkCount: 3, dataLength: 800)),
            .resolved(entry(name: "two", type: .regularFile, devid: rootDevice, fileID: 500, linkCount: 3, dataLength: 800)),
            .resolved(entry(name: "three", type: .regularFile, devid: rootDevice, fileID: 500, linkCount: 3, dataLength: 800))
        ]]])

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, 800)
        XCTAssertEqual(result.fileCount, 1)
    }

    /// linkCount == 1 的文件不参与去重：即使 fileID 相同也各自计入
    /// （去重键只在 linkCount > 1 时才有意义）。
    func testDoesNotDeduplicateWhenLinkCountIsOne() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let rootDevice = try deviceID(of: root.path)
        let factory = ScriptedSourceFactory(scripts: [[[
            .resolved(entry(name: "one", type: .regularFile, devid: rootDevice, fileID: 42, linkCount: 1, dataLength: 10)),
            .resolved(entry(name: "two", type: .regularFile, devid: rootDevice, fileID: 42, linkCount: 1, dataLength: 10))
        ]]])

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.estimatedBytes, 20)
        XCTAssertEqual(result.fileCount, 2)
    }

    // MARK: - 每批检查 deadline

    /// deadline 必须在**每批之间**生效：第一批已计入，第二批不得再读。
    func testChecksDeadlineBetweenBatches() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let rootDevice = try deviceID(of: root.path)
        let factory = ScriptedSourceFactory(scripts: [[
            [.resolved(entry(name: "first.bin", type: .regularFile, devid: rootDevice, fileID: 1, dataLength: 11))],
            [.resolved(entry(name: "second.bin", type: .regularFile, devid: rootDevice, fileID: 2, dataLength: 22))]
        ]])

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SteppingClock(start: start, step: 1)
        let context = DiskCleanSizingContext(
            deadline: start.addingTimeInterval(1.5),
            now: { clock.next() }
        )

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory).size(
            ofItemAt: root.path,
            context: context
        )

        XCTAssertEqual(result.completeness, .partial(reasons: [.timedOut]))
        XCTAssertEqual(result.estimatedBytes, 11, "只应计入到期前读到的那一批")
        XCTAssertEqual(result.observedAt, start)
    }

    // MARK: - 下潜与 fd 生命周期

    /// 同设备的目录条目要真的经 openat 下潜，并为子目录新建一个 source。
    func testDescendsIntoSameDeviceDirectory() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        try temporaryDirectory.makeDirectory("Root/Child")
        let rootDevice = try deviceID(of: root.path)

        let factory = ScriptedSourceFactory(scripts: [
            [[.resolved(entry(name: "Child", type: .directory, devid: rootDevice, fileID: 10))]],
            [[.resolved(entry(name: "inner.bin", type: .regularFile, devid: rootDevice, fileID: 11, dataLength: 64))]]
        ])

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.estimatedBytes, 64)
        XCTAssertEqual(factory.createdSourceCount, 2, "根与子目录各一个 source")
        XCTAssertTrue(factory.allSourcesClosed, "所有 source 必须被关闭，不得泄漏 fd")
    }

    /// 下潜目标已不存在（扫描期间被删）→ 记 walkError，不崩。
    func testMissingChildDirectoryIsReportedAsWalkError() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let rootDevice = try deviceID(of: root.path)
        let factory = ScriptedSourceFactory(scripts: [
            [[.resolved(entry(name: "vanished", type: .directory, devid: rootDevice, fileID: 12))]]
        ])

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.walkError]))
        XCTAssertEqual(factory.createdSourceCount, 1)
    }

    /// 同时打开的目录数必须是"树深度"量级，而非"某目录的子目录总数"量级。
    ///
    /// 若实现在处理一批条目时就把全部子目录 openat 出来压栈，宽目录（数万子目录）会直接
    /// 撞 EMFILE。真实文件系统测不出这条——测试进程 RLIMIT_NOFILE 有百万——只能靠
    /// source 工厂这个接缝观测"同时存活的 source 数"。
    func testKeepsOpenDirectoryCountBoundedByDepth() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let rootDevice = try deviceID(of: root.path)

        let siblingCount = 20
        var rootBatch: [DiskCleanWalkEntry] = []
        for index in 0..<siblingCount {
            let name = "child-\(index)"
            try temporaryDirectory.makeDirectory("Root/\(name)")
            rootBatch.append(
                .resolved(entry(name: name, type: .directory, devid: rootDevice, fileID: UInt64(100 + index)))
            )
        }

        // 根一批报出全部 20 个子目录；每个子目录自身为空。
        let factory = ScriptedSourceFactory(scripts: [[rootBatch]])

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(factory.createdSourceCount, 1 + siblingCount, "每个子目录都应被下潜")
        XCTAssertEqual(
            factory.peakConcurrentlyOpenSourceCount,
            2,
            "同时最多只应持有根 + 一个子目录，而不是根 + \(siblingCount) 个子目录"
        )
        XCTAssertTrue(factory.allSourcesClosed)
    }

    func testClosesAllSourcesWhenStoppedEarly() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let factory = ScriptedSourceFactory(scripts: [[[]]])

        _ = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test(isCancelled: { true }))

        XCTAssertTrue(factory.allSourcesClosed)
    }

    /// source 创建失败（真实场景：fdopendir 失败）→ walkError，且根 fd 由调用方关闭。
    func testFailingSourceFactoryReportsWalkError() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let factory = FailingSourceFactory()

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.walkError]))
        XCTAssertNotNil(result.rootIdentity, "根已成功打开，身份可知")
    }

    // MARK: - 辅助

    private func deviceID(of path: String) throws -> UInt64 {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return UInt64(UInt32(bitPattern: status.st_dev))
    }

    private func entry(
        name: String,
        type: DiskCleanRootIdentity.FileType,
        devid: UInt64,
        fileID: UInt64,
        linkCount: UInt32 = 1,
        dataLength: Int64 = 0
    ) -> DiskCleanResolvedEntry {
        DiskCleanResolvedEntry(
            nameBytes: Array(name.utf8).map { CChar(bitPattern: $0) } + [0],
            fileType: type,
            devid: devid,
            fileID: fileID,
            linkCount: linkCount,
            dataLength: dataLength
        )
    }
}

/// 每次调用都前进固定步长的时钟。
private final class SteppingClock: @unchecked Sendable {
    private let start: Date
    private let step: TimeInterval
    private let lock = NSLock()
    private var callCount = 0

    init(start: Date, step: TimeInterval) {
        self.start = start
        self.step = step
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = start.addingTimeInterval(step * Double(callCount))
        callCount += 1
        return value
    }
}

/// 按脚本回放条目批次的伪造 source 工厂。第 n 个被创建的 source 使用 scripts[n]。
private final class ScriptedSourceFactory: DiskCleanDirectoryEntrySourceFactory, @unchecked Sendable {
    private let scripts: [[[DiskCleanWalkEntry]]]
    private let throwAfterScriptedBatches: DiskCleanPOSIXError?
    private let lock = NSLock()
    private var sources: [ScriptedSource] = []
    private var peakOpenCount = 0

    init(
        scripts: [[[DiskCleanWalkEntry]]],
        throwAfterScriptedBatches: DiskCleanPOSIXError? = nil
    ) {
        self.scripts = scripts
        self.throwAfterScriptedBatches = throwAfterScriptedBatches
    }

    var createdSourceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sources.count
    }

    var allSourcesClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sources.allSatisfy(\.isClosed)
    }

    /// 同时处于"已创建且未关闭"状态的 source 峰值。
    var peakConcurrentlyOpenSourceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakOpenCount
    }

    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        lock.lock()
        let index = sources.count
        lock.unlock()

        let source = ScriptedSource(
            fileDescriptor: fileDescriptor,
            batches: index < scripts.count ? scripts[index] : [],
            errorAfterBatches: throwAfterScriptedBatches
        )
        lock.lock()
        sources.append(source)
        peakOpenCount = max(peakOpenCount, sources.filter { !$0.isClosed }.count)
        lock.unlock()
        return source
    }
}

private final class ScriptedSource: DiskCleanDirectoryEntrySource {
    let directoryFileDescriptor: Int32
    private var batches: [[DiskCleanWalkEntry]]
    private let errorAfterBatches: DiskCleanPOSIXError?
    private(set) var isClosed = false

    init(fileDescriptor: Int32, batches: [[DiskCleanWalkEntry]], errorAfterBatches: DiskCleanPOSIXError?) {
        self.directoryFileDescriptor = fileDescriptor
        self.batches = batches
        self.errorAfterBatches = errorAfterBatches
    }

    func nextBatch() throws -> [DiskCleanWalkEntry]? {
        guard !batches.isEmpty else {
            if let errorAfterBatches {
                throw errorAfterBatches
            }
            return nil
        }
        return batches.removeFirst()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        // 遵守协议：source 持有 fd 所有权。
        Darwin.close(directoryFileDescriptor)
    }
}

private struct FailingSourceFactory: DiskCleanDirectoryEntrySourceFactory {
    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        throw DiskCleanPOSIXError(code: EIO)
    }
}
