import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanSizeCacheTests: XCTestCase {
    private let path = "/cache/item"

    // MARK: - 命中条件

    func testHitRequiresFullIdentityTriple() {
        let cache = DiskCleanSizeCache()
        let stored = DiskCleanRootIdentity.test(devid: 1, fileID: 2, mtime: Date(timeIntervalSince1970: 500))
        cache.store(path: path, result: .testComplete(identity: stored), now: Date())

        XCTAssertNotNil(cache.result(forPath: path, identity: stored, now: Date()))
    }

    /// 目录被删掉重建、mtime 被刻意保留：只比 mtime 会复用旧结果，fileID 必须参与判定。
    func testDirectoryReplacedWithSameMtimeDoesNotHit() {
        let cache = DiskCleanSizeCache()
        let mtime = Date(timeIntervalSince1970: 500)
        cache.store(
            path: path,
            result: .testComplete(identity: .test(devid: 1, fileID: 2, mtime: mtime)),
            now: Date()
        )

        let replaced = DiskCleanRootIdentity.test(devid: 1, fileID: 99, mtime: mtime)

        XCTAssertNil(cache.result(forPath: path, identity: replaced, now: Date()))
    }

    func testDifferentDeviceDoesNotHit() {
        let cache = DiskCleanSizeCache()
        cache.store(path: path, result: .testComplete(identity: .test(devid: 1)), now: Date())

        XCTAssertNil(cache.result(forPath: path, identity: .test(devid: 2), now: Date()))
    }

    func testDifferentMtimeDoesNotHit() {
        let cache = DiskCleanSizeCache()
        cache.store(
            path: path,
            result: .testComplete(identity: .test(mtime: Date(timeIntervalSince1970: 500))),
            now: Date()
        )

        XCTAssertNil(
            cache.result(
                forPath: path,
                identity: .test(mtime: Date(timeIntervalSince1970: 501)),
                now: Date()
            )
        )
    }

    func testMissDropsStaleEntry() {
        let cache = DiskCleanSizeCache()
        cache.store(path: path, result: .testComplete(identity: .test(fileID: 2)), now: Date())

        _ = cache.result(forPath: path, identity: .test(fileID: 3), now: Date())

        XCTAssertEqual(cache.count, 0, "身份不符的条目已无价值，命中判定顺手清掉它")
    }

    // MARK: - TTL 与容量

    func testEntryExpiresAfterTimeToLive() {
        let cache = DiskCleanSizeCache(timeToLive: 240)
        let storedAt = Date(timeIntervalSince1970: 10_000)
        let identity = DiskCleanRootIdentity.test()
        cache.store(path: path, result: .testComplete(identity: identity), now: storedAt)

        XCTAssertNotNil(
            cache.result(forPath: path, identity: identity, now: storedAt.addingTimeInterval(239))
        )
        XCTAssertNil(
            cache.result(forPath: path, identity: identity, now: storedAt.addingTimeInterval(240))
        )
    }

    func testTimeToLiveIsStrictlyShorterThanFreshnessWindow() {
        XCTAssertLessThan(
            DiskCleanSizeCache.timeToLive,
            DiskCleanScanFreshness.window,
            "TTL 不小于过期窗口会让'过期 → 重扫 → 命中旧缓存 → 仍过期'成为死循环"
        )
    }

    func testEvictsOldestEntryBeyondCapacity() {
        let cache = DiskCleanSizeCache(capacity: 2)
        let identity = DiskCleanRootIdentity.test()
        let now = Date()
        cache.store(path: "/a", result: .testComplete(identity: identity), now: now)
        cache.store(path: "/b", result: .testComplete(identity: identity), now: now)
        cache.store(path: "/c", result: .testComplete(identity: identity), now: now)

        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.result(forPath: "/a", identity: identity, now: now))
        XCTAssertNotNil(cache.result(forPath: "/c", identity: identity, now: now))
    }

    // MARK: - 只缓存 complete

    func testPartialResultIsNeverStored() {
        let cache = DiskCleanSizeCache()
        cache.store(
            path: path,
            result: .testPartial(reasons: [.timedOut], identity: .test()),
            now: Date()
        )

        XCTAssertEqual(cache.count, 0, "缓存 partial 等于把一次降级永久化")
    }

    func testResultWithoutRootIdentityIsNeverStored() {
        let cache = DiskCleanSizeCache()
        cache.store(
            path: path,
            result: DiskCleanSizeResult(
                estimatedBytes: 10,
                fileCount: 1,
                completeness: .complete,
                rootIdentity: nil,
                observedAt: Date()
            ),
            now: Date()
        )

        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - 装饰器行为

    func testCachingSizerReturnsCachedResultWithOriginalObservedAt() {
        let identity = DiskCleanRootIdentity.test()
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let cache = DiskCleanSizeCache()
        cache.store(
            path: path,
            result: .testComplete(bytes: 777, identity: identity, observedAt: observedAt),
            now: observedAt
        )
        let base = FakeDiskCleanSizer()
        let sizer = DiskCleanCachingSizer(
            base: base,
            cache: cache,
            identityProbe: FakeDiskCleanRootIdentityProbe(identitiesByPath: [path: identity])
        )

        let result = sizer.size(
            ofItemAt: path,
            context: DiskCleanSizingContext(
                deadline: observedAt.addingTimeInterval(60),
                now: { observedAt.addingTimeInterval(30) }
            )
        )

        XCTAssertEqual(result.estimatedBytes, 777)
        XCTAssertEqual(result.observedAt, observedAt)
        XCTAssertTrue(base.calledPaths.isEmpty)
    }

    func testCachingSizerForceRefreshBypassesReadButStillWrites() {
        let identity = DiskCleanRootIdentity.test()
        let cache = DiskCleanSizeCache()
        cache.store(path: path, result: .testComplete(bytes: 1, identity: identity), now: Date())
        let base = FakeDiskCleanSizer()
        base.setResult(.testComplete(bytes: 42, identity: identity), forPath: path)
        let sizer = DiskCleanCachingSizer(
            base: base,
            cache: cache,
            identityProbe: FakeDiskCleanRootIdentityProbe(identitiesByPath: [path: identity]),
            forceRefresh: true
        )

        let result = sizer.size(ofItemAt: path, context: .test())

        XCTAssertEqual(result.estimatedBytes, 42)
        XCTAssertEqual(base.calledPaths, [path])
        XCTAssertEqual(
            cache.result(forPath: path, identity: identity, now: Date())?.estimatedBytes,
            42,
            "绕过读取但仍写入，下一次普通扫描才能命中新值"
        )
    }

    func testCachingSizerFallsBackToBaseWhenIdentityProbeFails() {
        let cache = DiskCleanSizeCache()
        cache.store(path: path, result: .testComplete(bytes: 1, identity: .test()), now: Date())
        let base = FakeDiskCleanSizer()
        base.setResult(.testPartial(reasons: [.walkError]), forPath: path)
        let sizer = DiskCleanCachingSizer(
            base: base,
            cache: cache,
            identityProbe: FakeDiskCleanRootIdentityProbe(identitiesByPath: [:])
        )

        let result = sizer.size(ofItemAt: path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.walkError]))
        XCTAssertEqual(base.calledPaths, [path], "探不到身份就必须走真实 sizer，由它给出准确的降级原因")
    }
}

// MARK: - 真实身份探针

final class DiskCleanRootIdentityProbeTests: XCTestCase {
    private var temporary: DiskCleanTempDirectory!
    private let probe = DiskCleanRootIdentityProbe()

    override func setUpWithError() throws {
        temporary = try DiskCleanTempDirectory(name: "identity-probe")
    }

    override func tearDown() {
        temporary?.remove()
        temporary = nil
    }

    func testReportsDirectoryIdentity() throws {
        let directory = try temporary.makeDirectory("Cache")

        let identity = try XCTUnwrap(probe.identity(ofItemAt: directory.path))

        XCTAssertEqual(identity.fileType, .directory)
        XCTAssertGreaterThan(identity.fileID, 0)
    }

    /// symlink 必须按链接本身报告，绝不跟随——否则缓存会拿目标的身份给链接背书。
    func testReportsSymlinkItselfWithoutFollowing() throws {
        try temporary.makeDirectory("Real")
        let link = try temporary.makeSymlink("Link", destination: "Real")

        let identity = try XCTUnwrap(probe.identity(ofItemAt: link.path))

        XCTAssertEqual(identity.fileType, .symlink)
    }

    /// 中间级是符号链接 → 拒绝（`O_NOFOLLOW_ANY` 的承诺）。
    func testRejectsSymlinkInParentChain() throws {
        try temporary.makeDirectory("Real/Inner")
        try temporary.makeSymlink("Alias", destination: "Real")

        XCTAssertNil(probe.identity(ofItemAt: temporary.resolve("Alias/Inner").path))
    }

    func testMissingPathHasNoIdentity() {
        XCTAssertNil(probe.identity(ofItemAt: temporary.resolve("nope").path))
    }

    /// 真实文件系统上的"替换目录并保留 mtime"：缓存必须不命中。
    func testReplacedDirectoryWithPreservedMtimeInvalidatesCache() throws {
        // 两次都用同一个固定 mtime 写入，避免比较受 utimes 微秒精度截断影响。
        let pinnedMtime = Date(timeIntervalSince1970: 1_600_000_000)
        let directory = try temporary.makeDirectory("Cache")
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        try FileManager.default.setAttributes([.modificationDate: pinnedMtime], ofItemAtPath: directory.path)
        let originalIdentity = try XCTUnwrap(probe.identity(ofItemAt: directory.path))
        let cache = DiskCleanSizeCache()
        cache.store(
            path: directory.path,
            result: .testComplete(bytes: 10, identity: originalIdentity),
            now: Date()
        )

        try FileManager.default.removeItem(at: directory)
        try temporary.makeDirectory("Cache")
        try FileManager.default.setAttributes([.modificationDate: pinnedMtime], ofItemAtPath: directory.path)
        let replacedIdentity = try XCTUnwrap(probe.identity(ofItemAt: directory.path))

        XCTAssertEqual(replacedIdentity.mtime, originalIdentity.mtime, "mtime 确实被保留下来了")
        XCTAssertNotEqual(replacedIdentity.fileID, originalIdentity.fileID)
        XCTAssertNil(
            cache.result(forPath: directory.path, identity: replacedIdentity, now: Date()),
            "同 mtime 不同 inode 必须视为不同对象"
        )
    }
}
