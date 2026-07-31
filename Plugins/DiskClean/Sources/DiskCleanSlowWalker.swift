import Darwin
import Foundation

/// Fallback sizer: `fdopendir` / `readdir` + per-entry `fstatat(AT_SYMLINK_NOFOLLOW)` (design §3.5).
///
/// Used when `getattrlistbulk` fails outright on some volumes (certain FUSE mounts).
/// **Does not use `FileManager`**: that would drop no-follow and device constraints and
/// could still report complete across mount points. Shares FastWalker's traversal skeleton,
/// so mount guards, hard-link dedup, EPERM skips, deadline/cancel, and root-identity
/// semantics stay identical; also runs inside WorkerPool under the same abandon budget.
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
    /// Batching only so the caller can check cancel and deadline per batch; readdir itself is per-entry.
    let batchSize: Int

    init(batchSize: Int = 128) {
        self.batchSize = max(batchSize, 1)
    }

    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        // On fdopendir failure we do not consume the fd; the caller closes it per the protocol.
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

    /// `closedir` also closes the underlying fd, so `close()` must not close it again.
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
