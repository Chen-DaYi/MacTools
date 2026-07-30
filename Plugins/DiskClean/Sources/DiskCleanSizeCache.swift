import Darwin
import Foundation
import os

/// Root identity probe: no traversal, one identity sample for cache hit checks.
///
/// Constraints match `DiskCleanRootOpener` exactly (design §3.2, §13-3): open the parent
/// with `O_NOFOLLOW_ANY` first (any intermediate symlink fails here), then
/// `fstatat(AT_SYMLINK_NOFOLLOW)` for the leaf identity. Plain `lstat` is wrong — it
/// follows intermediate symlinks and would miss a "middle directory replaced by symlink" attack.
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

/// Size cache (design §4.3).
///
/// - Key = path; **hit requires full root-identity triple equality `(devid, fileID, mtime)`**.
///   mtime alone is not enough: a directory replaced wholesale (delete/recreate or swap)
///   can keep mtime while fileID always changes.
/// - **Cache only complete results**: reusing partial would permanently bake in a degradation.
/// - TTL is 240s, strictly below the 300s stale gate — otherwise "stale → rescan → hit old
///   cache → still stale" loops. `forceRefresh` bypassing the cache is the other half of that
///   insurance (§4.3).
/// - Always propagate the cache entry's original `observedAt`; never refresh it to read time,
///   or the stale gate is bypassed.
///
/// Use a lock, not an actor: hit checks run on `DiskCleanWorkerPool` resident threads (same
/// call as the blocking sizer) where await is not allowed. Only dictionary work runs under
/// the lock; identity probing happens outside it.
final class DiskCleanSizeCache: Sendable {
    static let timeToLive: TimeInterval = 240
    static let defaultCapacity = 500

    private struct Entry {
        let identity: DiskCleanRootIdentity
        let result: DiskCleanSizeResult
        /// Write time. TTL is computed from write time; usually matches `result.observedAt` but is a separate concern.
        let storedAt: Date
    }

    private struct State {
        var entries: [String: Entry] = [:]
        /// Write order for capacity eviction. Rewrites move the path to the tail.
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

    /// On hit return the cached result (preserving original observedAt); on miss return nil and drop any stale entry.
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

    /// Full identity-triple equality. fileType must match too — a directory cannot become
    /// another type at the same inode, but comparing it is a free extra check.
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

/// Cache decorator around any sizer.
///
/// Order matters: **probe identity before consulting the cache**. The reverse
/// (load a cache entry then validate identity) can return a stale result after path
/// replacement. When identity probing fails (path gone, intermediate symlink), fall
/// through to the real sizer so it can report the precise degradation reason.
struct DiskCleanCachingSizer: DiskCleanDirectorySizing {
    let base: any DiskCleanDirectorySizing
    let cache: DiskCleanSizeCache
    let identityProbe: any DiskCleanRootIdentityProbing
    /// true = bypass cache reads (still write). Rescans after the stale gate must take this path.
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
