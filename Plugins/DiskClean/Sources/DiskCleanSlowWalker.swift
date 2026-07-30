import Darwin
import Foundation

/// 回退 sizer：`fdopendir` / `readdir` + 逐条 `fstatat(AT_SYMLINK_NOFOLLOW)`（设计 §3.5）。
///
/// 用于 `getattrlistbulk` 对个别卷（部分 FUSE）直接返回错误的场景。**不使用 `FileManager`**：
/// 那会丢掉 no-follow 与设备约束，并可能跨挂载点仍报 complete。本 walker 与 FastWalker
/// 共用同一遍历骨架，因此挂载防护、硬链接去重、EPERM 跳过、deadline/取消、根身份语义完全一致；
/// 同样跑在 WorkerPool 内，受同一放弃预算管辖。
struct DiskCleanSlowWalker: DiskCleanDirectorySizing {
    private let core: DiskCleanDirectoryTreeWalker

    init(
        opener: DiskCleanRootOpener = DiskCleanRootOpener(),
        batchSize: Int = 128
    ) {
        self.core = DiskCleanDirectoryTreeWalker(
            opener: opener,
            sourceFactory: DiskCleanDirectoryStreamEntrySourceFactory(batchSize: batchSize)
        )
    }

    func size(ofItemAt path: String, context: DiskCleanSizingContext) -> DiskCleanSizeResult {
        core.size(ofItemAt: path, context: context)
    }
}

struct DiskCleanDirectoryStreamEntrySourceFactory: DiskCleanDirectoryEntrySourceFactory {
    /// 分批只为让上层能按批检查取消与 deadline；readdir 本身是逐条的。
    let batchSize: Int

    init(batchSize: Int = 128) {
        self.batchSize = max(batchSize, 1)
    }

    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        // fdopendir 失败时不消费 fd，按协议约定由调用方 close。
        guard let stream = fdopendir(fileDescriptor) else {
            throw DiskCleanPOSIXError(code: errno)
        }
        return DiskCleanDirectoryStreamEntrySource(stream: stream, batchSize: batchSize)
    }
}

final class DiskCleanDirectoryStreamEntrySource: DiskCleanDirectoryEntrySource {
    private let stream: UnsafeMutablePointer<DIR>
    private let batchSize: Int
    private var isFinished = false
    private var isClosed = false

    init(stream: UnsafeMutablePointer<DIR>, batchSize: Int) {
        self.stream = stream
        self.batchSize = batchSize
    }

    deinit {
        if !isClosed {
            closedir(stream)
        }
    }

    /// `closedir` 会连带关闭底层 fd，故 `close()` 不额外 close 这个 fd。
    var directoryFileDescriptor: Int32 {
        dirfd(stream)
    }

    func nextBatch() throws -> [DiskCleanWalkEntry]? {
        guard !isFinished, !isClosed else { return nil }

        var entries: [DiskCleanWalkEntry] = []
        entries.reserveCapacity(batchSize)

        while entries.count < batchSize {
            errno = 0
            guard let directoryEntry = readdir(stream) else {
                let code = errno
                if code != 0 {
                    throw DiskCleanPOSIXError(code: code)
                }
                isFinished = true
                break
            }

            guard let nameBytes = Self.nameBytes(of: directoryEntry), !Self.isDotEntry(nameBytes) else {
                continue
            }
            entries.append(
                DiskCleanEntryStatFallback.resolve(
                    nameBytes: nameBytes,
                    directoryFileDescriptor: directoryFileDescriptor
                )
            )
        }

        return entries.isEmpty ? nil : entries
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        closedir(stream)
    }

    private static func nameBytes(of entry: UnsafeMutablePointer<dirent>) -> [CChar]? {
        let length = Int(entry.pointee.d_namlen)
        guard length > 0 else { return nil }
        return withUnsafePointer(to: entry.pointee.d_name) { tuplePointer in
            let characters = UnsafeRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
            var bytes = Array(UnsafeBufferPointer(start: characters, count: length))
            bytes.append(0)
            return bytes
        }
    }

    private static func isDotEntry(_ nameBytes: [CChar]) -> Bool {
        let dot = CChar(UInt8(ascii: "."))
        switch nameBytes.count {
        case 2: return nameBytes[0] == dot
        case 3: return nameBytes[0] == dot && nameBytes[1] == dot
        default: return false
        }
    }
}
