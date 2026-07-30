import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

// MARK: - 计划铸造

/// 计划只有一个铸造点（`ValidatedPlan.init` 是 fileprivate），测试也不例外——
/// 这里走的是和产品代码完全相同的 `makePlan`，因此夹具本身就在复核铸造校验。
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

    /// 由真实文件系统对象铸造计划：身份取自对象当下的 `lstat`，与扫描器所见一致。
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
                "无法读取 \(path) 的身份"
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

    /// 由内存身份铸造计划（不需要真实对象的执行器测试用）。
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

// MARK: - 原语接缝的 fake

/// 记录调用的原语 fake。执行器测试断言"preflight 失败时零调用"靠的就是它。
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

/// 废纸篓 fake：记录路径并把对象真删掉（模拟"已离开原处"），绝不碰用户的真实废纸篓。
final class FakeDiskCleanTrash: DiskCleanTrashing, @unchecked Sendable {
    struct TrashFailure: LocalizedError {
        var errorDescription: String? { "trash unavailable" }
    }

    private let lock = NSLock()
    private var paths: [String] = []
    private let shouldFail: Bool
    /// 处置进行中触发的副作用，用来模拟"另一个进程此刻重建了原路径"。
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

/// 设备号 fake：按条目名伪造设备号，用来构造真实文件系统上造不出来的挂载穿越。
struct FakeDiskCleanStagedEntryDeviceResolver: DiskCleanStagedEntryDeviceResolving {
    /// 命中这些名字的条目会被报成另一个设备。
    let crossedMountEntryNames: Set<String>

    func deviceID(ofEntry nameBytes: [CChar], statResult: stat) -> UInt64 {
        let realDevice = UInt64(UInt32(bitPattern: statResult.st_dev))
        let name = nameBytes.withUnsafeBufferPointer { buffer -> String in
            buffer.baseAddress.map { String(cString: $0) } ?? ""
        }
        return crossedMountEntryNames.contains(name) ? realDevice &+ 1 : realDevice
    }
}

/// 记录 reconciliation 是否被触发。
final class SpyDiskCleanStagingReconciler: DiskCleanStagingReconciling, @unchecked Sendable {
    private let lock = NSLock()
    private var directories: [URL] = []

    var reconciledDirectories: [URL] { lock.withLock { directories } }

    func reconcile(storageDirectory: URL) async {
        lock.withLock { directories.append(storageDirectory) }
    }
}

// MARK: - 运行应用快照 fake

/// 可分别设定 preflight 快照与"逐项刷新"结果的快照来源。
///
/// 双时点锁的关键行为是"preflight 一次、逐项再刷 bundle ID"，只有把两者分开才测得出来。
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

// MARK: - 断言工具

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

    /// 目录内的暂存残骸名。`rollbackBlocked` / `partiallyDeleted` 都以它们的存在为证。
    func stagedNames(in directoryPath: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryPath)) ?? []
        return names.filter { $0.hasPrefix(DiskCleanRemovalPrimitive.stagedNamePrefix) }.sorted()
    }
}
