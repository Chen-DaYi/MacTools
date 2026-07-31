import Darwin
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Tests walk-skeleton constraints via injected fake entry streams.
///
/// Mount crossings cannot be built on a real FS (the test process cannot mount), so design §11 requires
/// "inject devid fakes to prove no descent across mounts" — this file implements that requirement.
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

    // MARK: - Mount protection

    /// Child directory devid differs from root (= another volume mounted there) → no descent, no count, add crossedMountPoint.
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
        XCTAssertEqual(factory.createdSourceCount, 1, "must not openat-descend into a cross-device directory")
    }

    /// Cross-device regular files are likewise not counted.
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

    // MARK: - Entry-level failure mapping

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
        XCTAssertEqual(result.estimatedBytes, 42, "bytes already accumulated before failure must be kept as-is")
    }

    /// Multiple degradation reasons must coexist and must not overwrite each other.
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

    // MARK: - Hard-link dedupe

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

    /// Files with linkCount == 1 do not participate in dedupe: even identical fileIDs count separately
    /// (the dedupe key is only meaningful when linkCount > 1).
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

    // MARK: - Deadline checked each batch

    /// deadline must apply **between batches**: first batch counted, second batch must not be read.
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
        XCTAssertEqual(result.estimatedBytes, 11, "only the batch read before deadline should count")
        XCTAssertEqual(result.observedAt, start)
    }

    // MARK: - Descent and fd lifecycle

    /// Same-device directory entries must truly openat-descend and create a new source for the child.
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
        XCTAssertEqual(factory.createdSourceCount, 2, "one source each for root and child directory")
        XCTAssertTrue(factory.allSourcesClosed, "all sources must be closed; no fd leaks")
    }

    /// Descent target already gone (deleted mid-scan) → record walkError, do not crash.
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

    /// Concurrently open directories must be O(tree depth), not O(children of one directory).
    ///
    /// If the implementation openat-stacks every child while processing one batch, a wide directory
    /// (tens of thousands of children) hits EMFILE. A real FS cannot test this — RLIMIT_NOFILE is millions —
    /// so the source-factory seam observes "concurrent live source count".
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

        // Root batch reports all 20 children; each child is empty.
        let factory = ScriptedSourceFactory(scripts: [[rootBatch]])

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(factory.createdSourceCount, 1 + siblingCount, "every child directory should be descended into")
        XCTAssertEqual(
            factory.peakConcurrentlyOpenSourceCount,
            2,
            "at most root + one child open at once, not root + \(siblingCount) children"
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

    /// Source creation failure (real case: fdopendir fails) → walkError, and the root fd is closed by the caller.
    func testFailingSourceFactoryReportsWalkError() throws {
        let root = try temporaryDirectory.makeDirectory("Root")
        let factory = FailingSourceFactory()

        let result = DiskCleanDirectoryTreeWalker(sourceFactory: factory)
            .size(ofItemAt: root.path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.walkError]))
        XCTAssertNotNil(result.rootIdentity, "root opened successfully so identity is known")
    }

    // MARK: - Helpers

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

/// Clock that advances a fixed step on each call.
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

/// Fake source factory that replays entry batches from scripts. The n-th created source uses scripts[n].
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

    /// Peak concurrent sources in the "created and not yet closed" state.
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
        // Honor the protocol: source owns the fd.
        Darwin.close(directoryFileDescriptor)
    }
}

private struct FailingSourceFactory: DiskCleanDirectoryEntrySourceFactory {
    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        throw DiskCleanPOSIXError(code: EIO)
    }
}
