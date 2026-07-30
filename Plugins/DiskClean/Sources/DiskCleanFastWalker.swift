import Darwin
import Foundation

/// 主力 sizer：`getattrlistbulk` 批量读目录属性（设计 §3.3）。
///
/// 遍历骨架与全部安全约束由 `DiskCleanDirectoryTreeWalker` 提供，本类型只负责
/// "如何批量拿到一批条目属性"。
struct DiskCleanFastWalker: DiskCleanDirectorySizing {
    private let core: DiskCleanDirectoryTreeWalker

    init(
        opener: DiskCleanRootOpener = DiskCleanRootOpener(),
        bufferSize: Int = 64 * 1024
    ) {
        self.core = DiskCleanDirectoryTreeWalker(
            opener: opener,
            sourceFactory: DiskCleanBulkEntrySourceFactory(bufferSize: bufferSize)
        )
    }

    func size(ofItemAt path: String, context: DiskCleanSizingContext) -> DiskCleanSizeResult {
        core.size(ofItemAt: path, context: context)
    }
}

struct DiskCleanBulkEntrySourceFactory: DiskCleanDirectoryEntrySourceFactory {
    let bufferSize: Int

    init(bufferSize: Int = 64 * 1024) {
        // 一条目录项最坏也就几百字节，4KB 下限保证单条永远放得下。
        self.bufferSize = max(bufferSize, 4 * 1024)
    }

    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        DiskCleanBulkEntrySource(fileDescriptor: fileDescriptor, bufferSize: bufferSize)
    }
}

/// `getattrlistbulk` 条目来源。
final class DiskCleanBulkEntrySource: DiskCleanDirectoryEntrySource {
    let directoryFileDescriptor: Int32

    private var attributeList = DiskCleanBulkAttributeParser.makeAttributeList()
    private let buffer: UnsafeMutableRawPointer
    private let bufferSize: Int
    private var isFinished = false
    private var isClosed = false

    init(fileDescriptor: Int32, bufferSize: Int) {
        self.directoryFileDescriptor = fileDescriptor
        self.bufferSize = bufferSize
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
    }

    deinit {
        if !isClosed {
            buffer.deallocate()
            Darwin.close(directoryFileDescriptor)
        }
    }

    func nextBatch() throws -> [DiskCleanWalkEntry]? {
        guard !isFinished, !isClosed else { return nil }

        let returnedCount = getattrlistbulk(
            directoryFileDescriptor,
            &attributeList,
            buffer,
            bufferSize,
            0
        )
        if returnedCount < 0 {
            throw DiskCleanPOSIXError(code: errno)
        }
        if returnedCount == 0 {
            isFinished = true
            return nil
        }

        let parsed = DiskCleanBulkAttributeParser.parse(
            buffer: UnsafeRawBufferPointer(start: buffer, count: bufferSize),
            entryCount: Int(returnedCount)
        )

        var entries = parsed.entries.map(resolve(entry:))
        if parsed.isTruncated {
            // 缓冲区结构异常：如实上报，由上层记为 walkError，绝不假装遍历完整。
            entries.append(.unresolved(code: EIO))
        }
        return entries
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        buffer.deallocate()
        Darwin.close(directoryFileDescriptor)
    }

    /// 单条缺关键属性（含布局错位）→ `fstatat(AT_SYMLINK_NOFOLLOW)` 逐条回退（设计 §3.3）。
    private func resolve(entry: DiskCleanBulkAttributeEntry) -> DiskCleanWalkEntry {
        guard let nameBytes = entry.nameBytes else {
            // 连名字都没有，无法回退也无法下潜。
            return .unresolved(code: EIO)
        }

        if entry.isFullyResolved, let fileType = entry.fileType, let devid = entry.devid, let fileID = entry.fileID {
            return .resolved(
                DiskCleanResolvedEntry(
                    nameBytes: nameBytes,
                    fileType: fileType,
                    devid: devid,
                    fileID: fileID,
                    // 目录不携带 ATTR_FILE_*，其 linkCount/dataLength 不参与计数。
                    linkCount: entry.linkCount ?? 1,
                    dataLength: entry.dataLength ?? 0
                )
            )
        }

        return DiskCleanEntryStatFallback.resolve(
            nameBytes: nameBytes,
            directoryFileDescriptor: directoryFileDescriptor
        )
    }
}

/// `fstatat` 逐条解析。Fast 的回退路径与 Slow 的主路径共用，保证两者语义完全一致。
enum DiskCleanEntryStatFallback {
    static func resolve(nameBytes: [CChar], directoryFileDescriptor: Int32) -> DiskCleanWalkEntry {
        var status = stat()
        var failureCode: Int32 = 0
        let succeeded = nameBytes.withUnsafeBufferPointer { pointer -> Bool in
            guard let base = pointer.baseAddress else {
                failureCode = EINVAL
                return false
            }
            if fstatat(directoryFileDescriptor, base, &status, AT_SYMLINK_NOFOLLOW) != 0 {
                failureCode = errno
                return false
            }
            return true
        }
        guard succeeded else {
            return .unresolved(code: failureCode)
        }

        return .resolved(
            DiskCleanResolvedEntry(
                nameBytes: nameBytes,
                fileType: DiskCleanRootIdentity.FileType(mode: status.st_mode),
                devid: UInt64(UInt32(bitPattern: status.st_dev)),
                fileID: status.st_ino,
                linkCount: UInt32(status.st_nlink),
                dataLength: max(status.st_size, 0)
            )
        )
    }
}
