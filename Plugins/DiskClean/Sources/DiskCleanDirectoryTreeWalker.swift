import Darwin
import Foundation

struct DiskCleanPOSIXError: Error, Equatable {
    let code: Int32
}

/// One fully resolved directory entry.
struct DiskCleanResolvedEntry: Equatable, Sendable {
    /// NUL-terminated raw name bytes, passed straight back to `openat`/`fstatat`.
    let nameBytes: [CChar]
    let fileType: DiskCleanRootIdentity.FileType
    let devid: UInt64
    let fileID: UInt64
    let linkCount: UInt32
    /// Logical size (equivalent to `st_size`). For symlinks, the length of the link target string.
    let dataLength: Int64
}

enum DiskCleanWalkEntry: Equatable, Sendable {
    case resolved(DiskCleanResolvedEntry)
    /// Attributes missing and the per-entry `fstatat` fallback also failed.
    case unresolved(code: Int32)
}

/// Directory entry source. FastWalker uses `getattrlistbulk`; SlowWalker uses `readdir` + `fstatat`;
/// tests may inject a synthetic entry stream (mount-point crossing cannot be constructed on a real FS).
protocol DiskCleanDirectoryEntrySource: AnyObject {
    /// Directory fd used by `openat` for descent.
    var directoryFileDescriptor: Int32 { get }
    /// Return entries in batches; nil means enumeration of this directory is finished.
    func nextBatch() throws -> [DiskCleanWalkEntry]?
    /// Release the underlying fd / DIR.
    func close()
}

protocol DiskCleanDirectoryEntrySourceFactory: Sendable {
    /// On success, ownership of `fileDescriptor` transfers to the returned source (released by `source.close()`);
    /// on **throw, ownership stays with the caller**, who must close it.
    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource
}

/// Shared sizing skeleton for both walkers: root opener typing (§3.2) + explicit-stack iterative DFS (§3.3).
///
/// The only difference between FastWalker and SlowWalker is the **directory entry source**; every other constraint—mount protection, hard-link dedupe,
/// no symlink following, EPERM skip, cancel/deadline checks per batch, root identity—is implemented here,
/// which is how design §3.5's "fallback walker reuses all §3.3 constraints" is realized.
struct DiskCleanDirectoryTreeWalker: Sendable {
    private let opener: DiskCleanRootOpener
    private let sourceFactory: any DiskCleanDirectoryEntrySourceFactory

    init(opener: DiskCleanRootOpener = DiskCleanRootOpener(), sourceFactory: any DiskCleanDirectoryEntrySourceFactory) {
        self.opener = opener
        self.sourceFactory = sourceFactory
    }

    func size(ofItemAt path: String, context: DiskCleanSizingContext) -> DiskCleanSizeResult {
        let observedAt = context.now()

        switch opener.open(path: path) {
        case let .failed(reason):
            return .unavailable(reasons: [reason], observedAt: observedAt)

        case let .resolved(bytes, identity):
            guard context.admitDevice(identity.devid) else {
                return .unavailable(reasons: [.unsupportedVolume], rootIdentity: identity, observedAt: observedAt)
            }
            return DiskCleanSizeResult(
                estimatedBytes: bytes,
                fileCount: 1,
                completeness: .complete,
                rootIdentity: identity,
                observedAt: observedAt
            )

        case let .directory(fileDescriptor, identity):
            guard context.admitDevice(identity.devid) else {
                close(fileDescriptor)
                return .unavailable(reasons: [.unsupportedVolume], rootIdentity: identity, observedAt: observedAt)
            }
            return walk(
                rootFileDescriptor: fileDescriptor,
                identity: identity,
                context: context,
                observedAt: observedAt
            )
        }
    }

    private func walk(
        rootFileDescriptor: Int32,
        identity: DiskCleanRootIdentity,
        context: DiskCleanSizingContext,
        observedAt: Date
    ) -> DiskCleanSizeResult {
        var accumulator = DiskCleanCompletenessAccumulator()
        var totalBytes: Int64 = 0
        var fileCount = 0
        var countedHardLinks: Set<HardLinkKey> = []
        var stack: [Frame] = []

        func makeResult() -> DiskCleanSizeResult {
            DiskCleanSizeResult(
                estimatedBytes: totalBytes,
                fileCount: fileCount,
                completeness: accumulator.completeness,
                rootIdentity: identity,
                observedAt: observedAt
            )
        }

        do {
            stack.append(Frame(source: try sourceFactory.makeSource(fileDescriptor: rootFileDescriptor)))
        } catch {
            close(rootFileDescriptor)
            accumulator.add(.walkError)
            return makeResult()
        }
        defer { stack.forEach { $0.source.close() } }

        while let frame = stack.last {
            // Check cancel and deadline between batches (and before each descent).
            if context.shouldStop {
                accumulator.add(.timedOut)
                break
            }

            // Drain already-discovered child directories first so open fd count stays on the order of tree depth,
            // not the fan-out of one directory (the latter can hit EMFILE).
            if let childName = frame.pendingChildDirectories.popLast() {
                descend(
                    into: childName,
                    parent: frame,
                    stack: &stack,
                    accumulator: &accumulator
                )
                continue
            }

            if frame.isExhausted {
                frame.source.close()
                stack.removeLast()
                continue
            }

            let batch: [DiskCleanWalkEntry]?
            do {
                batch = try frame.source.nextBatch()
            } catch let error as DiskCleanPOSIXError {
                accumulator.add(errno: error.code)
                batch = nil
            } catch {
                accumulator.add(.walkError)
                batch = nil
            }

            guard let batch else {
                frame.isExhausted = true
                continue
            }

            for entry in batch {
                switch entry {
                case let .unresolved(code):
                    accumulator.add(errno: code)

                case let .resolved(resolved):
                    // Mount protection: do not descend into or count cross-device entries.
                    guard resolved.devid == identity.devid else {
                        accumulator.add(.crossedMountPoint)
                        continue
                    }

                    guard resolved.fileType != .directory else {
                        frame.pendingChildDirectories.append(resolved.nameBytes)
                        continue
                    }

                    // Hard links are deduped by (devid, fileID)—fileID is not unique across mounts, so devid must be in the key.
                    if resolved.linkCount > 1 {
                        let key = HardLinkKey(devid: resolved.devid, fileID: resolved.fileID)
                        guard countedHardLinks.insert(key).inserted else { continue }
                    }
                    totalBytes += max(resolved.dataLength, 0)
                    fileCount += 1
                }
            }
        }

        return makeResult()
    }

    private func descend(
        into name: [CChar],
        parent: Frame,
        stack: inout [Frame],
        accumulator: inout DiskCleanCompletenessAccumulator
    ) {
        // name is a single path component and the parent is already fd-anchored, so O_NOFOLLOW is enough; never follow symlinks.
        let childDescriptor = name.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return openat(
                parent.source.directoryFileDescriptor,
                base,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard childDescriptor >= 0 else {
            accumulator.add(errno: errno)
            return
        }

        do {
            stack.append(Frame(source: try sourceFactory.makeSource(fileDescriptor: childDescriptor)))
        } catch {
            close(childDescriptor)
            accumulator.add(.walkError)
        }
    }

    private struct HardLinkKey: Hashable {
        let devid: UInt64
        let fileID: UInt64
    }

    /// Stack frame. `pendingChildDirectories` only holds child names discovered in the **current batch**,
    /// so both memory and fd usage stay bounded.
    private final class Frame {
        let source: any DiskCleanDirectoryEntrySource
        var pendingChildDirectories: [[CChar]] = []
        var isExhausted = false

        init(source: any DiskCleanDirectoryEntrySource) {
            self.source = source
        }
    }
}
