import Darwin
import Foundation
import os

/// 根身份探针：不遍历、只取一次身份，供缓存命中判定使用。
///
/// 约束与 `DiskCleanRootOpener` 完全一致（设计 §3.2、§13-3）：先以 `O_NOFOLLOW_ANY` 打开父目录
/// （路径中间级有符号链接就在这一步失败），再 `fstatat(AT_SYMLINK_NOFOLLOW)` 取末级身份。
/// 直接 `lstat` 是错的——它会跟随中间级符号链接，等于放过"中间目录被换成 symlink"的替换攻击。
protocol DiskCleanRootIdentityProbing: Sendable {
    func identity(ofItemAt path: String) -> DiskCleanRootIdentity?
}

struct DiskCleanRootIdentityProbe: DiskCleanRootIdentityProbing {
    init() {}

    func identity(ofItemAt path: String) -> DiskCleanRootIdentity? {
        guard let location = ParentAnchoredPath(path: path) else { return nil }

        let parentDescriptor = Darwin.open(
            location.parentPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK
        )
        guard parentDescriptor >= 0 else { return nil }
        defer { close(parentDescriptor) }

        var status = stat()
        guard fstatat(parentDescriptor, location.name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            return nil
        }
        return DiskCleanRootIdentity(stat: status)
    }
}

/// 大小缓存（设计 §4.3）。
///
/// - 键 = 路径；**命中条件 = 根身份三元组 `(devid, fileID, mtime)` 全等**。只比 mtime 不够：
///   目录被整体替换（删掉重建、或换成另一个目录）时 mtime 可以被保留，fileID 一定变。
/// - **只缓存 complete**：partial 结果复用等于把一次降级永久化。
/// - TTL 240s，严格小于过期门 300s——否则会出现"过期 → 重扫 → 命中旧缓存 → 仍过期"的死循环。
///   `forceRefresh` 绕过缓存是这条链的另一半保险（§4.3）。
/// - `observedAt` 一律传导缓存条目的原始观测时刻，绝不刷新为读取时刻，否则过期门就被架空了。
///
/// 用锁而不用 actor：命中判定跑在 `DiskCleanWorkerPool` 的常驻线程上（与阻塞式 sizer 同一次调用），
/// 那里不能 await。锁内只做字典操作，身份探测在锁外完成。
final class DiskCleanSizeCache: Sendable {
    static let timeToLive: TimeInterval = 240
    static let defaultCapacity = 500

    private struct Entry {
        let identity: DiskCleanRootIdentity
        let result: DiskCleanSizeResult
        /// 写入时刻。TTL 按写入时刻计算，与 `result.observedAt` 一致但语义独立。
        let storedAt: Date
    }

    private struct State {
        var entries: [String: Entry] = [:]
        /// 写入顺序，用于容量上限淘汰。重复写入会把路径移到队尾。
        var insertionOrder: [String] = []
    }

    private let capacity: Int
    private let timeToLive: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        capacity: Int = DiskCleanSizeCache.defaultCapacity,
        timeToLive: TimeInterval = DiskCleanSizeCache.timeToLive
    ) {
        self.capacity = max(capacity, 1)
        self.timeToLive = max(timeToLive, 0)
    }

    /// 命中则返回缓存结果（保留原 observedAt），未命中返回 nil 并顺手清掉失效条目。
    func result(
        forPath path: String,
        identity: DiskCleanRootIdentity,
        now: Date
    ) -> DiskCleanSizeResult? {
        state.withLock { state -> DiskCleanSizeResult? in
            guard let entry = state.entries[path] else { return nil }
            guard now.timeIntervalSince(entry.storedAt) < timeToLive else {
                Self.remove(path: path, from: &state)
                return nil
            }
            guard Self.matches(entry.identity, identity) else {
                Self.remove(path: path, from: &state)
                return nil
            }
            return entry.result
        }
    }

    func store(path: String, result: DiskCleanSizeResult, now: Date) {
        guard result.completeness.isComplete, let identity = result.rootIdentity else { return }

        state.withLock { state in
            if state.entries[path] == nil {
                state.insertionOrder.append(path)
            } else {
                state.insertionOrder.removeAll { $0 == path }
                state.insertionOrder.append(path)
            }
            state.entries[path] = Entry(identity: identity, result: result, storedAt: now)

            while state.insertionOrder.count > capacity {
                let oldest = state.insertionOrder.removeFirst()
                state.entries[oldest] = nil
            }
        }
    }

    var count: Int {
        state.withLock { $0.entries.count }
    }

    func removeAll() {
        state.withLock { state in
            state.entries.removeAll()
            state.insertionOrder.removeAll()
        }
    }

    /// 身份三元组全等。fileType 也必须相同——目录被换成同 inode 的其它类型不可能，
    /// 但比较它是零成本的额外确认。
    private static func matches(_ cached: DiskCleanRootIdentity, _ current: DiskCleanRootIdentity) -> Bool {
        cached.devid == current.devid
            && cached.fileID == current.fileID
            && cached.mtime == current.mtime
            && cached.fileType == current.fileType
    }

    private static func remove(path: String, from state: inout State) {
        state.entries[path] = nil
        state.insertionOrder.removeAll { $0 == path }
    }
}

/// 给任意 sizer 套上缓存的装饰器。
///
/// 顺序很重要：**先探身份再查缓存**。反过来（先查缓存拿到条目再验身份）会在路径已被替换时
/// 返回旧结果。身份探测失败（路径消失、中间级变成 symlink）时直接落到真实 sizer，
/// 由它给出准确的降级原因。
struct DiskCleanCachingSizer: DiskCleanDirectorySizing {
    let base: any DiskCleanDirectorySizing
    let cache: DiskCleanSizeCache
    let identityProbe: any DiskCleanRootIdentityProbing
    /// true = 绕过缓存读取（仍写入）。过期门触发后的重扫必须走这条路径。
    let forceRefresh: Bool

    init(
        base: any DiskCleanDirectorySizing,
        cache: DiskCleanSizeCache,
        identityProbe: any DiskCleanRootIdentityProbing = DiskCleanRootIdentityProbe(),
        forceRefresh: Bool = false
    ) {
        self.base = base
        self.cache = cache
        self.identityProbe = identityProbe
        self.forceRefresh = forceRefresh
    }

    func size(ofItemAt path: String, context: DiskCleanSizingContext) -> DiskCleanSizeResult {
        if !forceRefresh,
           let identity = identityProbe.identity(ofItemAt: path),
           let cached = cache.result(forPath: path, identity: identity, now: context.now()) {
            return cached
        }

        let result = base.size(ofItemAt: path, context: context)
        cache.store(path: path, result: result, now: context.now())
        return result
    }
}
