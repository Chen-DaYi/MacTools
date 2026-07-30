import Darwin
import Foundation

/// Primary sizer: bulk directory attributes via `getattrlistbulk` (design §3.3).
///
/// Traversal skeleton and all safety constraints come from `DiskCleanDirectoryTreeWalker`; this type only owns
/// "how to fetch a batch of entry attributes".
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
        // A directory entry is a few hundred bytes at worst; the 4KB floor guarantees a single entry always fits.
        self.bufferSize = max(bufferSize, 4 * 1024)
    }

    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        DiskCleanBulkEntrySource(fileDescriptor: fileDescriptor, bufferSize: bufferSize)
    }
}

/// `getattrlistbulk` entry source.
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
            // Abnormal buffer structure: report honestly so the upper layer records walkError—never pretend the walk was complete.
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

    /// Missing required attributes on one entry (including layout mismatch) → per-entry `fstatat(AT_SYMLINK_NOFOLLOW)` fallback (design §3.3).
    private func resolve(entry: DiskCleanBulkAttributeEntry) -> DiskCleanWalkEntry {
        guard let nameBytes = entry.nameBytes else {
            // Without even a name there is no fallback and no descent.
            return .unresolved(code: EIO)
        }

        if entry.isFullyResolved, let fileType = entry.fileType, let devid = entry.devid, let fileID = entry.fileID {
            return .resolved(
                DiskCleanResolvedEntry(
                    nameBytes: nameBytes,
                    fileType: fileType,
                    devid: devid,
                    fileID: fileID,
                    // Directories omit ATTR_FILE_*; their linkCount/dataLength do not participate in counting.
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

/// Per-entry `fstatat` resolution. Shared by Fast's fallback and Slow's main path so both stay semantically identical.
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
