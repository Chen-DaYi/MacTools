import Darwin
import Foundation

struct DiskCleanPOSIXError: Error, Equatable {
    let code: Int32
}

/// 一条已完整解析的目录条目。
struct DiskCleanResolvedEntry: Equatable, Sendable {
    /// NUL 结尾的原始字节名，直接回传给 `openat`/`fstatat`。
    let nameBytes: [CChar]
    let fileType: DiskCleanRootIdentity.FileType
    let devid: UInt64
    let fileID: UInt64
    let linkCount: UInt32
    /// 逻辑大小（等价 `st_size`）。symlink 为链接目标字符串长度。
    let dataLength: Int64
}

enum DiskCleanWalkEntry: Equatable, Sendable {
    case resolved(DiskCleanResolvedEntry)
    /// 属性缺失且逐条 `fstatat` 回退也失败。
    case unresolved(code: Int32)
}

/// 目录条目来源。FastWalker 用 `getattrlistbulk`，SlowWalker 用 `readdir` + `fstatat`；
/// 测试可注入伪造条目流（挂载穿越无法在真实文件系统上构造，只能靠注入）。
protocol DiskCleanDirectoryEntrySource: AnyObject {
    /// 供 `openat` 下潜使用的目录 fd。
    var directoryFileDescriptor: Int32 { get }
    /// 逐批返回条目；nil 表示本目录枚举结束。
    func nextBatch() throws -> [DiskCleanWalkEntry]?
    /// 释放底层 fd / DIR。
    func close()
}

protocol DiskCleanDirectoryEntrySourceFactory: Sendable {
    /// 成功时 `fileDescriptor` 所有权移交给返回的 source（由 `source.close()` 释放）；
    /// **抛错时所有权仍归调用方**，由调用方 close。
    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource
}

/// 两个 walker 共用的求大小骨架：根 opener 分型（§3.2）+ 显式栈迭代 DFS（§3.3）。
///
/// FastWalker 与 SlowWalker 的差异**只在目录条目来源**，其余约束——挂载防护、硬链接去重、
/// symlink 不跟随、EPERM 跳过、每批检查取消/deadline、根身份——全部由本类型统一实现，
/// 这正是设计 §3.5 要求"回退 walker 复用 §3.3 全部约束"的落地方式。
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
            // 每批之间（以及每次下潜之前）检查取消与 deadline。
            if context.shouldStop {
                accumulator.add(.timedOut)
                break
            }

            // 先消费已发现的子目录，把同时打开的 fd 数量压到"树深度"量级，
            // 而不是"某一目录的子目录总数"量级（后者会撞 EMFILE）。
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
                    // 挂载防护：跨设备条目不下潜、不计数。
                    guard resolved.devid == identity.devid else {
                        accumulator.add(.crossedMountPoint)
                        continue
                    }

                    guard resolved.fileType != .directory else {
                        frame.pendingChildDirectories.append(resolved.nameBytes)
                        continue
                    }

                    // 硬链接按 (devid, fileID) 去重——跨挂载 fileID 不唯一，devid 必须参与键。
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
        // name 是单级组件且父目录已由 fd 锚定，故 O_NOFOLLOW 足够；symlink 一律不跟随。
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

    /// 栈帧。`pendingChildDirectories` 只保存"当前批次"发现的子目录名，
    /// 因此内存与 fd 占用都有界。
    private final class Frame {
        let source: any DiskCleanDirectoryEntrySource
        var pendingChildDirectories: [[CChar]] = []
        var isExhausted = false

        init(source: any DiskCleanDirectoryEntrySource) {
            self.source = source
        }
    }
}
