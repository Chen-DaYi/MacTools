import Darwin
import Foundation

// MARK: - 种类

/// 残留安装包种类（设计 §10.2）。原始值即小写扩展名，判定只看扩展名。
enum DiskCleanInstallerKind: String, CaseIterable, Equatable, Sendable {
    case diskImage = "dmg"
    case installerPackage = "pkg"
    case discImage = "iso"
    case signedArchive = "xip"
    /// `.zip` 里可能是安装包，也可能是用户自己打的资料包。默认永不勾选。
    case zipArchive = "zip"

    var fileExtension: String { rawValue }

    /// 是否是"几乎只可能是安装包"的格式。`.zip` 是唯一的例外。
    var isLikelyInstaller: Bool { self != .zipArchive }

    var displayName: String {
        switch self {
        case .diskImage:
            return "磁盘映像"
        case .installerPackage:
            return "安装包"
        case .discImage:
            return "光盘映像"
        case .signedArchive:
            return "签名归档"
        case .zipArchive:
            return "压缩包"
        }
    }

    /// 合成 target 的稳定 ID（`DiskCleanRuleCatalogV2` 据此建 target）。
    /// 会原样写进审计日志，改动等于改动历史记录的语义。
    var targetID: String {
        "installer." + rawValue
    }

    static let byExtension: [String: DiskCleanInstallerKind] = Dictionary(
        uniqueKeysWithValues: DiskCleanInstallerKind.allCases.map { ($0.rawValue, $0) }
    )
}

// MARK: - 候选

struct DiskCleanInstallerCandidate: Identifiable, Equatable, Sendable {
    /// 不默认勾选的原因。勾选了的候选没有 note。
    enum Note: Equatable, Sendable {
        /// 修改时间在 7 天内，可能还在用（刚下载、待安装）。
        case recentlyModified
        /// `.zip` 不一定是安装包。
        case mayNotBeInstaller
    }

    /// 物理路径（Downloads 目录经 `realpath` 规范化后拼接文件名，末级不解析）。
    let path: String
    let kind: DiskCleanInstallerKind
    /// 预览用逻辑大小。**权威大小仍由统一管线的 sizing 给出**（设计 §3.2 分型路径），
    /// 这里只是发现阶段顺手取到的 `st_size`，用于列表即时展示。
    let byteSize: Int64
    let modifiedAt: Date
    let isSelectedByDefault: Bool
    let note: Note?

    var id: String { path }

    var displayName: String { (path as NSString).lastPathComponent }
}

// MARK: - 扫描结果

/// `~/Downloads` 的扫描结果。
///
/// `denied` 与 `scanned(candidates: [])` **必须分开**：TCC 拒绝时目录里可能有几十 GB 安装包，
/// 显示"没有可清理项"是在骗用户。前者要引导授权，后者才是真的没有。
enum DiskCleanInstallerScanOutcome: Equatable, Sendable {
    case scanned(candidates: [DiskCleanInstallerCandidate])
    /// 权限被拒（TCC 未授权或目录权限）。
    case denied(path: String)
    /// 其它不可用：目录不存在、不是目录、非本地卷。
    case unavailable(path: String, reason: DiskCleanScanCompleteness.PartialReason)

    var candidates: [DiskCleanInstallerCandidate] {
        if case let .scanned(candidates) = self { return candidates }
        return []
    }
}

// MARK: - 扫描器

/// 残留安装包扫描（设计 §10.2）。
///
/// `~/Downloads` **顶层不递归**：下载目录里的子目录通常是用户自己整理的资料，递归进去找 `.dmg`
/// 只会把归档好的东西也报出来。
///
/// 阻塞式，但只做一次顶层 `readdir` + 每条一次 `fstatat`，耗时与目录条目数成正比且没有下潜，
/// 因此不需要 WorkerPool 的放弃预算——那套机制是为可能永久挂住的递归 sizing 准备的。
struct DiskCleanInstallerScanner: Sendable {
    /// 超过这个年龄的安装包才默认勾选。刚下载的可能还没装。
    static let defaultStaleAge: TimeInterval = 7 * 24 * 60 * 60

    /// 扫描范围。带 `~` 前缀，供规则目录写进 `reservedRootPaths`
    /// （`expandedReservedRootPaths()` 负责展开）。
    static let defaultDownloadsPath = "~/Downloads"

    private let downloadsPath: String
    private let staleAge: TimeInterval
    private let opener: DiskCleanRootOpener
    private let sourceFactory: any DiskCleanDirectoryEntrySourceFactory
    private let now: @Sendable () -> Date

    /// `downloadsPath` 是注入点：测试传临时目录，绝不碰真实 `~/Downloads`。
    init(
        downloadsPath: String = DiskCleanRuleTarget.expandHome(
            in: DiskCleanInstallerScanner.defaultDownloadsPath,
            homeDirectory: NSHomeDirectory()
        ),
        staleAge: TimeInterval = defaultStaleAge,
        opener: DiskCleanRootOpener = DiskCleanRootOpener(),
        sourceFactory: any DiskCleanDirectoryEntrySourceFactory = DiskCleanDirectoryStreamEntrySourceFactory(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.downloadsPath = downloadsPath
        self.staleAge = staleAge
        self.opener = opener
        self.sourceFactory = sourceFactory
        self.now = now
    }

    func scan() -> DiskCleanInstallerScanOutcome {
        // 目录本身用 realpath 全解析（用户的 Downloads 可能是指向外置卷的符号链接）；解析失败时
        // 原样交给 opener，让它给出确切的失败原因，而不是在这里猜。
        let path = DiskCleanPhysicalPath.realpath(of: downloadsPath) ?? downloadsPath

        switch opener.open(path: path) {
        case let .failed(reason):
            return reason == .permissionDenied ? .denied(path: path) : .unavailable(path: path, reason: reason)

        case .resolved:
            // 不是目录：Downloads 被换成了文件或符号链接。
            return .unavailable(path: path, reason: .walkError)

        case let .directory(fileDescriptor, _):
            return collect(fileDescriptor: fileDescriptor, directoryPath: path)
        }
    }

    // MARK: 内部

    /// `fileDescriptor` 所有权移交本方法。
    private func collect(fileDescriptor: Int32, directoryPath: String) -> DiskCleanInstallerScanOutcome {
        let source: any DiskCleanDirectoryEntrySource
        do {
            source = try sourceFactory.makeSource(fileDescriptor: fileDescriptor)
        } catch {
            // 协议约定：makeSource 抛错时 fd 所有权仍归调用方。
            close(fileDescriptor)
            let code = (error as? DiskCleanPOSIXError)?.code ?? EIO
            return code == EPERM || code == EACCES
                ? .denied(path: directoryPath)
                : .unavailable(path: directoryPath, reason: .walkError)
        }
        defer { source.close() }

        let observedAt = now()
        var candidates: [DiskCleanInstallerCandidate] = []

        while let batch = try? source.nextBatch() {
            for entry in batch {
                guard case let .resolved(resolved) = entry else { continue }
                // 只收普通文件：符号链接不跟随（删的是链接不是安装包），目录不递归。
                guard resolved.fileType == .regularFile else { continue }
                guard
                    let name = Self.name(of: resolved),
                    let kind = DiskCleanInstallerKind.byExtension[(name as NSString).pathExtension.lowercased()],
                    let status = Self.status(name: name, directoryFileDescriptor: source.directoryFileDescriptor)
                else { continue }

                let modifiedAt = DiskCleanRootIdentity.date(from: status.st_mtimespec)
                candidates.append(
                    makeCandidate(
                        path: directoryPath + "/" + name,
                        kind: kind,
                        byteSize: max(status.st_size, 0),
                        modifiedAt: modifiedAt,
                        observedAt: observedAt
                    )
                )
            }
        }

        // readdir 顺序由文件系统决定，排序让列表与测试都稳定。
        return .scanned(candidates: candidates.sorted { $0.path < $1.path })
    }

    private func makeCandidate(
        path: String,
        kind: DiskCleanInstallerKind,
        byteSize: Int64,
        modifiedAt: Date,
        observedAt: Date
    ) -> DiskCleanInstallerCandidate {
        let isStale = observedAt.timeIntervalSince(modifiedAt) > staleAge
        let note: DiskCleanInstallerCandidate.Note?
        if !kind.isLikelyInstaller {
            note = .mayNotBeInstaller
        } else if !isStale {
            note = .recentlyModified
        } else {
            note = nil
        }

        return DiskCleanInstallerCandidate(
            path: path,
            kind: kind,
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            isSelectedByDefault: kind.isLikelyInstaller && isStale,
            note: note
        )
    }

    /// 单独 `fstatat` 取 mtime——目录条目只带类型与大小，没有时间。顺带用同一次调用的 `st_size`，
    /// 保证大小与时间来自同一时刻的观测。
    private static func status(name: String, directoryFileDescriptor: Int32) -> stat? {
        var status = stat()
        guard fstatat(directoryFileDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        return status
    }

    private static func name(of entry: DiskCleanResolvedEntry) -> String? {
        let bytes = entry.nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        // 非法 UTF-8 文件名无法安全地表达成候选路径，宁可漏报。
        return String(bytes: bytes, encoding: .utf8)
    }
}
