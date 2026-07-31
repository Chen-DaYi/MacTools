import Darwin
import Foundation

/// Root open result (design §3.2 typing).
enum DiskCleanRootOpenOutcome: Equatable {
    /// Directory: must be walked. **fd ownership transfers to the caller**; must close.
    case directory(fileDescriptor: Int32, identity: DiskCleanRootIdentity)
    /// Regular file / symlink / other non-directory: size and identity already known; no walk needed.
    case resolved(bytes: Int64, identity: DiskCleanRootIdentity)
    /// Could not open or not accepted.
    case failed(reason: DiskCleanScanCompleteness.PartialReason)
}

/// Unified entry for all sizing and execution.
///
/// **Callers must pass a physical path** (no symlink ancestors). `O_NOFOLLOW_ANY` rejects a symlink
/// at any path component, and on macOS `/var -> private/var` and `/tmp -> private/tmp` are themselves
/// symlinks: `/var/folders/...` fails with ELOOP and degrades to `partial([.walkError])`, so the
/// candidate is not cleanable. Rule globs that touch these locations must write `/private/var/...`.
/// Normalize with `realpath(3)`—`URL.resolvingSymlinksInPath()` **does not** expand `/var`.
///
/// Key constraints (design §3.2):
/// - `O_NOFOLLOW_ANY` rejects a symlink at **any path component**, not just the leaf—blocks
///   "middle directory replaced by a symlink into Documents".
/// - `O_NONBLOCK` is required, not optional: `O_RDONLY` on a FIFO with no writer blocks forever,
///   and FIFOs/sockets can appear in cache directories; a hang would burn the WorkerPool abandon budget.
/// - After open, `fstatfs` checks `MNT_LOCAL`; non-local volumes are rejected.
struct DiskCleanRootOpener: Sendable {
    init() {}

    func open(path: String) -> DiskCleanRootOpenOutcome {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard descriptor >= 0 else {
            let code = errno
            // ELOOP has two causes: leaf is a symlink (legitimate candidate; count the link itself),
            // or some intermediate component is a symlink (must reject). Must distinguish; see resolveLink.
            if code == ELOOP {
                return resolveLink(path: path)
            }
            return .failed(reason: code == EPERM || code == EACCES ? .permissionDenied : .walkError)
        }

        guard isLocalVolume(fileDescriptor: descriptor) else {
            close(descriptor)
            return .failed(reason: .unsupportedVolume)
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            close(descriptor)
            return .failed(reason: code == EPERM || code == EACCES ? .permissionDenied : .walkError)
        }

        let identity = DiskCleanRootIdentity(stat: status)
        guard identity.fileType == .directory else {
            close(descriptor)
            return .resolved(bytes: max(status.st_size, 0), identity: identity)
        }
        return .directory(fileDescriptor: descriptor, identity: identity)
    }

    /// Handle open returning ELOOP.
    ///
    /// Design §3.2 says "switch to the lstat path and take the link itself", but a naive `lstat`
    /// follows intermediate symlinks: with layout `dirlink -> realdir` + `realdir/link -> target`,
    /// `lstat("dirlink/link")` succeeds and reports symlink, so intermediate-replacement attacks
    /// slip through—exactly what `O_NOFOLLOW_ANY` is meant to stop. Therefore use **parent-directory
    /// fd anchoring**: open the parent with `O_NOFOLLOW_ANY` (any intermediate symlink fails there),
    /// then `fstatat(AT_SYMLINK_NOFOLLOW)` to confirm the leaf is the link itself. Semantics match
    /// the design while truly delivering "reject symlink at any component".
    private func resolveLink(path: String) -> DiskCleanRootOpenOutcome {
        guard let location = ParentAnchoredPath(path: path) else {
            return .failed(reason: .walkError)
        }

        let parentDescriptor = Darwin.open(
            location.parentPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK
        )
        guard parentDescriptor >= 0 else {
            let code = errno
            return .failed(reason: code == EPERM || code == EACCES ? .permissionDenied : .walkError)
        }
        defer { close(parentDescriptor) }

        guard isLocalVolume(fileDescriptor: parentDescriptor) else {
            return .failed(reason: .unsupportedVolume)
        }

        var status = stat()
        guard fstatat(parentDescriptor, location.name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            return .failed(reason: code == EPERM || code == EACCES ? .permissionDenied : .walkError)
        }

        let identity = DiskCleanRootIdentity(stat: status)
        // Leaf is not a symlink yet open failed → ELOOP can only come from an intermediate component; reject.
        guard identity.fileType == .symlink else {
            return .failed(reason: .walkError)
        }
        return .resolved(bytes: max(status.st_size, 0), identity: identity)
    }

    private func isLocalVolume(fileDescriptor: Int32) -> Bool {
        var fileSystem = statfs()
        guard fstatfs(fileDescriptor, &fileSystem) == 0 else { return false }
        return fileSystem.f_flags & UInt32(MNT_LOCAL) != 0
    }
}

/// Split an absolute path into "parent directory + leaf component" for fd-anchored addressing.
struct ParentAnchoredPath: Equatable {
    let parentPath: String
    let name: String

    init?(path: String) {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        // Root has no parent and can never be a candidate.
        guard trimmed != "/", !trimmed.isEmpty else { return nil }

        guard let separatorIndex = trimmed.lastIndex(of: "/") else { return nil }
        let name = String(trimmed[trimmed.index(after: separatorIndex)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let parent = String(trimmed[..<separatorIndex])
        self.parentPath = parent.isEmpty ? "/" : parent
        self.name = name
    }
}
