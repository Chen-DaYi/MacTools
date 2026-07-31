import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

// MARK: - Plan minting

/// Plans have a single minting point (`ValidatedPlan.init` is fileprivate); tests are no exception —
/// this uses the same product `makePlan`, so fixtures themselves re-check minting validation.
@MainActor
enum DiskCleanPlanFactory {
    static let observedAt = Date(timeIntervalSince1970: 10_000)
    static let targetID = "test.target"

    struct Item {
        let path: String
        let identity: DiskCleanRootIdentity
        let bytes: Int64

        init(path: String, identity: DiskCleanRootIdentity, bytes: Int64 = 0) {
            self.path = path
            self.identity = identity
            self.bytes = bytes
        }
    }

    static func catalog(
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = []
    ) -> DiskCleanRuleCatalogV2 {
        DiskCleanRuleCatalogV2(targets: [
            .test(
                id: targetID,
                reservedRootPaths: [],
                lockedByBundleIDs: lockedByBundleIDs,
                skipWhenProcessIsRunning: skipWhenProcessIsRunning
            )
        ])
    }

    static func candidate(
        path: String,
        identity: DiskCleanRootIdentity? = nil,
        bytes: Int64 = 0,
        observedAt: Date = DiskCleanPlanFactory.observedAt,
        safety: DiskCleanSafetyStatus = .allowed,
        sizeResult: DiskCleanSizeResult? = nil
    ) -> DiskCleanCandidate {
        DiskCleanCandidate(
            id: DiskCleanCandidate.makeID(targetID: targetID, path: path),
            targetID: targetID,
            legacyRuleID: targetID,
            category: .appCaches,
            path: path,
            risk: .low,
            safety: safety,
            sizeResult: sizeResult ?? .testComplete(
                bytes: bytes,
                identity: identity ?? .test(),
                observedAt: observedAt
            )
        )
    }

    static func artifact(
        candidates: [DiskCleanCandidate],
        reservedRootPaths: [String] = []
    ) -> DiskCleanScanArtifact {
        DiskCleanScanArtifact(
            scope: .rules(choices: Set(DiskCleanChoice.allCases)),
            candidates: candidates,
            reservedRootPaths: reservedRootPaths,
            limitations: [],
            startedAt: observedAt,
            finishedAt: observedAt
        )
    }

    /// Mint a plan from real filesystem objects: identity comes from current `lstat`, matching the scanner.
    static func makePlan(
        paths: [String],
        mode: DiskCleanRemovalMode = .permanent,
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = [],
        now: Date = DiskCleanPlanFactory.observedAt
    ) throws -> DiskCleanValidatedPlan {
        let candidates = try paths.map { path -> DiskCleanCandidate in
            let identity = try XCTUnwrap(
                currentIdentity(ofItemAt: path),
                "could not read identity of \(path)"
            )
            return candidate(
                path: path,
                identity: identity,
                bytes: currentSize(ofItemAt: path)
            )
        }
        return try DiskCleanPlanner.makePlan(
            artifact: artifact(candidates: candidates),
            selectedIDs: Set(candidates.map(\.id)),
            mode: mode,
            now: now,
            catalog: catalog(
                lockedByBundleIDs: lockedByBundleIDs,
                skipWhenProcessIsRunning: skipWhenProcessIsRunning
            )
        )
    }

    /// Mint a plan from in-memory identities (for executor tests that do not need real objects).
    static func makePlan(
        items: [Item],
        mode: DiskCleanRemovalMode = .permanent,
        lockedByBundleIDs: [String] = [],
        skipWhenProcessIsRunning: [String] = [],
        now: Date = DiskCleanPlanFactory.observedAt
    ) throws -> DiskCleanValidatedPlan {
        let candidates = items.map {
            candidate(path: $0.path, identity: $0.identity, bytes: $0.bytes)
        }
        return try DiskCleanPlanner.makePlan(
            artifact: artifact(candidates: candidates),
            selectedIDs: Set(candidates.map(\.id)),
            mode: mode,
            now: now,
            catalog: catalog(
                lockedByBundleIDs: lockedByBundleIDs,
                skipWhenProcessIsRunning: skipWhenProcessIsRunning
            )
        )
    }

    static func currentIdentity(ofItemAt path: String) -> DiskCleanRootIdentity? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return DiskCleanRootIdentity(stat: status)
    }

    static func currentSize(ofItemAt path: String) -> Int64 {
        var status = stat()
        guard lstat(path, &status) == 0 else { return 0 }
        return status.st_size
    }
}

// MARK: - Primitive seam fakes

/// Call-recording primitive fake. Executor tests assert "zero calls on preflight failure" with it.
final class FakeDiskCleanRemovalPrimitive: DiskCleanPlanItemRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(path: String, mode: DiskCleanRemovalMode)] = []
    private var dispositionsByPath: [String: DiskCleanRemovalDisposition] = [:]
    private var defaultDisposition: DiskCleanRemovalDisposition

    init(defaultDisposition: DiskCleanRemovalDisposition = .removed) {
        self.defaultDisposition = defaultDisposition
    }

    func setDisposition(_ disposition: DiskCleanRemovalDisposition, forPath path: String) {
        lock.withLock { dispositionsByPath[path] = disposition }
    }

    var removedPaths: [String] { lock.withLock { calls.map(\.path) } }
    var callCount: Int { lock.withLock { calls.count } }
    var lastMode: DiskCleanRemovalMode? { lock.withLock { calls.last?.mode } }

    func remove(
        _ item: DiskCleanValidatedPlan.PlanItem,
        mode: DiskCleanRemovalMode
    ) -> DiskCleanRemovalDisposition {
        lock.withLock {
            calls.append((path: item.path, mode: mode))
            return dispositionsByPath[item.path] ?? defaultDisposition
        }
    }
}

/// Trash fake: records paths and really deletes the object (simulates "left original location"); never touches the real Trash.
final class FakeDiskCleanTrash: DiskCleanTrashing, @unchecked Sendable {
    struct TrashFailure: LocalizedError {
        var errorDescription: String? { "trash unavailable" }
    }

    private let lock = NSLock()
    private var paths: [String] = []
    private let shouldFail: Bool
    /// Side effect while trashing, to simulate "another process recreates the original path".
    private let duringTrash: (@Sendable () -> Void)?

    init(shouldFail: Bool = false, duringTrash: (@Sendable () -> Void)? = nil) {
        self.shouldFail = shouldFail
        self.duringTrash = duringTrash
    }

    var trashedPaths: [String] { lock.withLock { paths } }

    func trashItem(atPath path: String) throws {
        lock.withLock { paths.append(path) }
        duringTrash?()
        if shouldFail {
            throw TrashFailure()
        }
        try FileManager.default.removeItem(atPath: path)
    }
}

/// Device-id fake: forges device ids by entry name to construct mount crossings impossible on a real FS.
struct FakeDiskCleanStagedEntryDeviceResolver: DiskCleanStagedEntryDeviceResolving {
    /// Entries with these names are reported on a different device.
    let crossedMountEntryNames: Set<String>

    func deviceID(ofEntry nameBytes: [CChar], statResult: stat) -> UInt64 {
        let realDevice = UInt64(UInt32(bitPattern: statResult.st_dev))
        let name = nameBytes.withUnsafeBufferPointer { buffer -> String in
            buffer.baseAddress.map { String(cString: $0) } ?? ""
        }
        return crossedMountEntryNames.contains(name) ? realDevice &+ 1 : realDevice
    }
}

/// Records whether reconciliation was triggered.
final class SpyDiskCleanStagingReconciler: DiskCleanStagingReconciling, @unchecked Sendable {
    private let lock = NSLock()
    private var directories: [URL] = []

    var reconciledDirectories: [URL] { lock.withLock { directories } }

    func reconcile(storageDirectory: URL) async {
        lock.withLock { directories.append(storageDirectory) }
    }
}

// MARK: - Running-app snapshot fake

/// Snapshot source that can set preflight snapshot and "per-item refresh" results separately.
///
/// Dual-time locking means "preflight once, then refresh bundle IDs per item"; only separating them makes that testable.
final class ProgrammableDiskCleanRunningAppLock: DiskCleanRunningAppSnapshotting, @unchecked Sendable {
    private let lock = NSLock()
    private let initialSnapshot: DiskCleanRunningAppSnapshot
    private let refreshedBundleIDs: Set<String>?
    private var refreshCount = 0
    private var requestedProcessNames: [[String]] = []

    init(
        snapshot: DiskCleanRunningAppSnapshot = DiskCleanRunningAppSnapshot(),
        refreshedBundleIDs: Set<String>? = nil
    ) {
        self.initialSnapshot = snapshot
        self.refreshedBundleIDs = refreshedBundleIDs
    }

    var refreshCallCount: Int { lock.withLock { refreshCount } }
    var lastRequestedProcessNames: [String]? { lock.withLock { requestedProcessNames.last } }

    func makeSnapshot(processNames: [String]) async -> DiskCleanRunningAppSnapshot {
        lock.withLock { requestedProcessNames.append(processNames.sorted()) }
        return initialSnapshot
    }

    func refreshingBundleIDs(in snapshot: DiskCleanRunningAppSnapshot) async -> DiskCleanRunningAppSnapshot {
        lock.withLock { refreshCount += 1 }
        guard let refreshedBundleIDs else { return snapshot }
        return snapshot.replacingBundleIDs(refreshedBundleIDs, observedAt: snapshot.observedAt)
    }
}

// MARK: - Assertion helpers

extension XCTestCase {
    func assertPathExists(
        _ path: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0, message, file: file, line: line)
    }

    func assertPathDoesNotExist(
        _ path: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var status = stat()
        XCTAssertNotEqual(lstat(path, &status), 0, message, file: file, line: line)
    }

    /// Staged leftover names in a directory. `rollbackBlocked` / `partiallyDeleted` are proven by their presence.
    func stagedNames(in directoryPath: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryPath)) ?? []
        return names.filter { $0.hasPrefix(DiskCleanRemovalPrimitive.stagedNamePrefix) }.sorted()
    }
}
