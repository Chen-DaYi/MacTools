import Darwin
import Foundation

/// 根对象打开结果（设计 §3.2 分型）。
enum DiskCleanRootOpenOutcome: Equatable {
    /// 目录：需交给 walker 遍历。**fd 所有权移交调用方**，必须 close。
    case directory(fileDescriptor: Int32, identity: DiskCleanRootIdentity)
    /// 普通文件 / symlink / 其它非目录：大小与身份已确定，无需遍历。
    case resolved(bytes: Int64, identity: DiskCleanRootIdentity)
    /// 无法打开或不予受理。
    case failed(reason: DiskCleanScanCompleteness.PartialReason)
}

/// 所有 sizing 与执行的统一入口。
///
/// **调用方必须传物理路径**（不含任何符号链接祖先）。因为 `O_NOFOLLOW_ANY` 拒绝路径中
/// 任意一级的 symlink，而 macOS 上 `/var -> private/var`、`/tmp -> private/tmp` 本身就是
/// 符号链接：`/var/folders/...` 会直接以 ELOOP 失败并降级为 `partial([.walkError])`，
/// 候选因而不可清理。规则 glob 涉及这类位置时必须写 `/private/var/...`。
/// 需要规范化时用 `realpath(3)`——`URL.resolvingSymlinksInPath()` **不会**展开 `/var`。
///
/// 关键约束（设计 §3.2）：
/// - `O_NOFOLLOW_ANY` 拒绝**路径任意一级**的符号链接，而不只是末级——防"中间目录被换成
///   指向 Documents 的 symlink"。
/// - `O_NONBLOCK` 是必需的而非可选：`O_RDONLY` 打开一个没有写端的 FIFO 会永久阻塞，
///   而缓存目录里出现 FIFO/socket 完全可能，一旦挂住就会烧掉 WorkerPool 的放弃预算。
/// - 打开后 `fstatfs` 校验 `MNT_LOCAL`；非本地卷不予受理。
struct DiskCleanRootOpener: Sendable {
    init() {}

    func open(path: String) -> DiskCleanRootOpenOutcome {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard descriptor >= 0 else {
            let code = errno
            // ELOOP 有两种成因：末级是 symlink（合法候选，按链接本身计），
            // 或路径中间某级是 symlink（必须拒绝）。二者必须区分，见 resolveLink。
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

    /// 处理 open 返回 ELOOP 的情况。
    ///
    /// 设计 §3.2 写的是"改 lstat 路径取链接本身"，但朴素 `lstat` 会跟随中间级 symlink：
    /// 布局 `dirlink -> realdir` + `realdir/link -> target` 时，`lstat("dirlink/link")`
    /// 成功且报告 symlink，于是中间级替换攻击被放过——正是 `O_NOFOLLOW_ANY` 要防的事。
    /// 因此这里改为**父目录 fd 锚定**：先用 `O_NOFOLLOW_ANY` 打开父目录（中间级有 symlink
    /// 就会在这一步失败），再 `fstatat(AT_SYMLINK_NOFOLLOW)` 确认末级确实是链接本身。
    /// 语义与设计一致，但真正兑现了"拒绝任意一级 symlink"的承诺。
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
        // 末级不是 symlink，却打不开 → ELOOP 只能来自路径中间级，拒绝。
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

/// 把绝对路径拆成"父目录 + 末级组件"，用于 fd 锚定寻址。
struct ParentAnchoredPath: Equatable {
    let parentPath: String
    let name: String

    init?(path: String) {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        // 根目录没有父目录，也不可能是候选。
        guard trimmed != "/", !trimmed.isEmpty else { return nil }

        guard let separatorIndex = trimmed.lastIndex(of: "/") else { return nil }
        let name = String(trimmed[trimmed.index(after: separatorIndex)...])
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let parent = String(trimmed[..<separatorIndex])
        self.parentPath = parent.isEmpty ? "/" : parent
        self.name = name
    }
}
