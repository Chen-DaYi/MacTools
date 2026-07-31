import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanSizeCacheTests: XCTestCase {
    private let path = "/cache/item"

    // MARK: - Hit conditions

    func testHitRequiresFullIdentityTriple() {
        let cache = DiskCleanSizeCache()
        let stored = DiskCleanRootIdentity.test(devid: 1, fileID: 2, mtime: Date(timeIntervalSince1970: 500))
        cache.store(path: path, result: .testComplete(identity: stored), now: Date())

        XCTAssertNotNil(cache.result(forPath: path, identity: stored, now: Date()))
    }

    /// Directory deleted and recreated with mtime preserved: mtime-only comparison would reuse the old result; fileID must participate.
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

        XCTAssertEqual(cache.count, 0, "identity-mismatched entries are worthless; hit check clears them")
    }

    // MARK: - TTL and capacity

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
            "TTL must be shorter than the expiry window or 'expire → rescan → hit old cache → still expired' becomes a loop"
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

    // MARK: - Cache complete only

    func testPartialResultIsNeverStored() {
        let cache = DiskCleanSizeCache()
        cache.store(
            path: path,
            result: .testPartial(reasons: [.timedOut], identity: .test()),
            now: Date()
        )

        XCTAssertEqual(cache.count, 0, "caching partial permanently freezes a degradation")
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

    // MARK: - Decorator behavior

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
            fallback: nil,
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
            fallback: nil,
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
            "bypass reads but still writes so the next ordinary scan can hit the new value"
        )
    }

    func testCachingSizerFallsBackToBaseWhenIdentityProbeFails() {
        let cache = DiskCleanSizeCache()
        cache.store(path: path, result: .testComplete(bytes: 1, identity: .test()), now: Date())
        let base = FakeDiskCleanSizer()
        base.setResult(.testPartial(reasons: [.walkError]), forPath: path)
        let sizer = DiskCleanCachingSizer(
            base: base,
            fallback: nil,
            cache: cache,
            identityProbe: FakeDiskCleanRootIdentityProbe(identitiesByPath: [:])
        )

        let result = sizer.size(ofItemAt: path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.walkError]))
        XCTAssertEqual(base.calledPaths, [path], "when identity cannot be probed, run the real sizer for an accurate degradation reason")
    }

    /// getattrlistbulk-style pure walkError should retry through SlowWalker (or any injected fallback).
    func testCachingSizerFallsBackOnPureWalkError() {
        let identity = DiskCleanRootIdentity.test()
        let cache = DiskCleanSizeCache()
        let base = FakeDiskCleanSizer()
        base.setResult(.testPartial(reasons: [.walkError]), forPath: path)
        let fallback = FakeDiskCleanSizer()
        fallback.setResult(.testComplete(bytes: 99, identity: identity), forPath: path)
        let sizer = DiskCleanCachingSizer(
            base: base,
            fallback: fallback,
            cache: cache,
            identityProbe: FakeDiskCleanRootIdentityProbe(identitiesByPath: [path: identity]),
            forceRefresh: true
        )

        let result = sizer.size(ofItemAt: path, context: .test())

        XCTAssertEqual(result.estimatedBytes, 99)
        XCTAssertEqual(base.calledPaths, [path])
        XCTAssertEqual(fallback.calledPaths, [path])
    }

    func testCachingSizerDoesNotFallbackOnPermissionDenied() {
        let cache = DiskCleanSizeCache()
        let base = FakeDiskCleanSizer()
        base.setResult(.testPartial(reasons: [.permissionDenied]), forPath: path)
        let fallback = FakeDiskCleanSizer()
        fallback.setResult(.testComplete(bytes: 1), forPath: path)
        let sizer = DiskCleanCachingSizer(
            base: base,
            fallback: fallback,
            cache: cache,
            identityProbe: FakeDiskCleanRootIdentityProbe(identitiesByPath: [:]),
            forceRefresh: true
        )

        let result = sizer.size(ofItemAt: path, context: .test())

        XCTAssertEqual(result.completeness, .partial(reasons: [.permissionDenied]))
        XCTAssertTrue(fallback.calledPaths.isEmpty)
    }
}

// MARK: - Real identity probe

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

    /// Symlinks must report as the link itself and never follow — otherwise the cache would endorse the target identity for the link.
    func testReportsSymlinkItselfWithoutFollowing() throws {
        try temporary.makeDirectory("Real")
        let link = try temporary.makeSymlink("Link", destination: "Real")

        let identity = try XCTUnwrap(probe.identity(ofItemAt: link.path))

        XCTAssertEqual(identity.fileType, .symlink)
    }

    /// Intermediate symlink → refuse (the `O_NOFOLLOW_ANY` guarantee).
    func testRejectsSymlinkInParentChain() throws {
        try temporary.makeDirectory("Real/Inner")
        try temporary.makeSymlink("Alias", destination: "Real")

        XCTAssertNil(probe.identity(ofItemAt: temporary.resolve("Alias/Inner").path))
    }

    func testMissingPathHasNoIdentity() {
        XCTAssertNil(probe.identity(ofItemAt: temporary.resolve("nope").path))
    }

    /// Real-FS "replace directory while preserving mtime": cache must miss.
    func testReplacedDirectoryWithPreservedMtimeInvalidatesCache() throws {
        // Write both with the same fixed mtime so comparisons are not affected by utimes microsecond truncation.
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

        XCTAssertEqual(replacedIdentity.mtime, originalIdentity.mtime, "mtime was preserved")
        XCTAssertNotEqual(replacedIdentity.fileID, originalIdentity.fileID)
        XCTAssertNil(
            cache.result(forPath: directory.path, identity: replacedIdentity, now: Date()),
            "same mtime different inode must be treated as different objects"
        )
    }
}
