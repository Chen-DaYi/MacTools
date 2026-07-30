import Darwin
import Foundation

/// 求大小结果的完整性。
///
/// 核心不变量（设计 §3.1）：`completeness != .complete`，或原因集合含 `crossedMountPoint`
/// 的候选**不可清理**。选择模型、Planner、执行器三处各自复核，本类型只负责如实记录降级原因。
enum DiskCleanScanCompleteness: Equatable, Sendable {
    case complete
    case partial(reasons: Set<PartialReason>)

    enum PartialReason: Equatable, Sendable, Hashable {
        /// 协作式 deadline 到期，或调用方取消。
        case timedOut
        /// EPERM/EACCES 子树被跳过。
        case permissionDenied
        /// 非本地卷、黑名单卷，或熔断后未执行 sizing。
        case unsupportedVolume
        /// 子树内发现挂载点，未下潜。
        case crossedMountPoint
        /// 属性异常且逐条 fstatat 回退失败。
        case walkError
    }

    var isComplete: Bool {
        self == .complete
    }

    var partialReasons: Set<PartialReason> {
        guard case let .partial(reasons) = self else { return [] }
        return reasons
    }
}

/// 根对象身份。用于大小缓存命中判定与执行前的 fd 锚定复核。
struct DiskCleanRootIdentity: Equatable, Sendable {
    /// 文件类型。设计 §3.1 列举 directory/regularFile/symlink；`other` 覆盖真实缓存目录中
    /// 确实存在的 socket、FIFO、设备节点——它们必须能被如实归类，而不是被迫伪装成普通文件。
    enum FileType: Equatable, Sendable {
        case directory
        case regularFile
        case symlink
        case other
    }

    /// `st_dev`。挂载防护与设备黑名单统一使用此值。
    let devid: UInt64
    /// `st_ino`。
    let fileID: UInt64
    let mtime: Date
    let fileType: FileType

    /// 从 `stat` 构造身份。
    init(stat value: stat) {
        self.devid = UInt64(UInt32(bitPattern: value.st_dev))
        self.fileID = value.st_ino
        self.mtime = Self.date(from: value.st_mtimespec)
        self.fileType = FileType(mode: value.st_mode)
    }

    init(devid: UInt64, fileID: UInt64, mtime: Date, fileType: FileType) {
        self.devid = devid
        self.fileID = fileID
        self.mtime = mtime
        self.fileType = fileType
    }

    /// 时间换算集中在一处：缓存命中依赖 mtime 全等，两侧必须用同一套换算。
    static func date(from time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}

extension DiskCleanRootIdentity.FileType {
    init(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFDIR: self = .directory
        case S_IFREG: self = .regularFile
        case S_IFLNK: self = .symlink
        default: self = .other
        }
    }
}

struct DiskCleanSizeResult: Equatable, Sendable {
    /// 估算逻辑大小（`st_size` 求和，硬链接按 `(devid, fileID)` 去重）。
    ///
    /// ≠ 实际可释放空间：APFS clone、稀疏文件、目录外硬链接都会让两者不等。
    /// UI 一律表述为"约 X GB"，完成文案不得写"已释放"。
    let estimatedBytes: Int64
    let fileCount: Int
    let completeness: DiskCleanScanCompleteness
    /// 根 fd 的 `fstat` 结果。仅当根本无法打开根对象（或被熔断/黑名单拦截）时为 nil，
    /// 此时 `completeness` 必然不是 `.complete`，候选因此不可清理。
    let rootIdentity: DiskCleanRootIdentity?
    /// 真实观测时刻。缓存命中时传导缓存条目的观测时刻，不得刷新为读取时刻。
    let observedAt: Date

    init(
        estimatedBytes: Int64,
        fileCount: Int,
        completeness: DiskCleanScanCompleteness,
        rootIdentity: DiskCleanRootIdentity?,
        observedAt: Date
    ) {
        self.estimatedBytes = estimatedBytes
        self.fileCount = fileCount
        self.completeness = completeness
        self.rootIdentity = rootIdentity
        self.observedAt = observedAt
    }

    /// 未能取得任何大小信息时的结果。
    static func unavailable(
        reasons: Set<DiskCleanScanCompleteness.PartialReason>,
        rootIdentity: DiskCleanRootIdentity? = nil,
        observedAt: Date
    ) -> DiskCleanSizeResult {
        DiskCleanSizeResult(
            estimatedBytes: 0,
            fileCount: 0,
            completeness: .partial(reasons: reasons),
            rootIdentity: rootIdentity,
            observedAt: observedAt
        )
    }
}

/// 沿途收集降级原因，避免每个分支都重复拼装 Set。
struct DiskCleanCompletenessAccumulator {
    private var reasons: Set<DiskCleanScanCompleteness.PartialReason> = []

    mutating func add(_ reason: DiskCleanScanCompleteness.PartialReason) {
        reasons.insert(reason)
    }

    /// 把 errno 映射为降级原因：权限类单列，其余归 walkError。
    mutating func add(errno code: Int32) {
        add(code == EPERM || code == EACCES ? .permissionDenied : .walkError)
    }

    var completeness: DiskCleanScanCompleteness {
        reasons.isEmpty ? .complete : .partial(reasons: reasons)
    }
}

/// 阻塞式 sizer 的运行上下文。
///
/// 取消与超时对 walker 是同一出口：两者都让遍历尽快返回，结果标记 `.timedOut`
/// （取消场景下调用方会丢弃该结果）。
struct DiskCleanSizingContext: Sendable {
    let deadline: Date
    let isCancelled: @Sendable () -> Bool
    /// sizer 打开根 fd 后**立即**调用，上报根对象所在设备号。
    ///
    /// 返回 false 表示该设备已被熔断黑名单拦截，sizer 必须立刻放弃并返回
    /// `partial([.unsupportedVolume])`。上报动作本身让 WorkerPool 在超时放弃线程时
    /// 知道该把哪个设备拉黑。
    let admitDevice: @Sendable (UInt64) -> Bool
    /// 可注入时钟，便于测试 deadline 判定。
    let now: @Sendable () -> Date

    init(
        deadline: Date,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        admitDevice: @escaping @Sendable (UInt64) -> Bool = { _ in true },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.deadline = deadline
        self.isCancelled = isCancelled
        self.admitDevice = admitDevice
        self.now = now
    }

    /// 是否应当停止遍历（取消或到期）。
    var shouldStop: Bool {
        isCancelled() || now() >= deadline
    }
}

/// 求大小能力。**阻塞式**：实现会滞留在 syscall 中，必须经 `DiskCleanWorkerPool`
/// 在常驻线程上调用，不得直接在 Swift 并发线程池上跑。
protocol DiskCleanDirectorySizing: Sendable {
    func size(ofItemAt path: String, context: DiskCleanSizingContext) -> DiskCleanSizeResult
}
