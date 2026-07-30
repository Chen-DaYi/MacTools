import AppKit
import Foundation
import os

// MARK: - 探测 seam

/// 完全磁盘访问探测（设计 §9）。
///
/// 插件本地实现，不经宿主权限卡：PluginKit v3 的 `PluginPermissionKind` 没有 fullDiskAccess，
/// 加一个新 case 会改变共享 ABI，而 loader 对 `pluginKitVersion` 是严格相等校验。
protocol DiskCleanFullDiskAccessProbing: Sendable {
    var hasFullDiskAccess: Bool { get }
}

/// 恒为"已授权"。扫描引擎的测试默认值：不跳过任何 target，扫描覆盖面与 v1 逐条一致。
struct DiskCleanAssumedFullDiskAccess: DiskCleanFullDiskAccessProbing {
    var hasFullDiskAccess: Bool { true }
}

/// 单个文件能否以只读打开。真实探针与测试替身的分界线。
protocol DiskCleanFileReadabilityProbing: Sendable {
    func canOpenForReading(atPath path: String) -> Bool
}

/// `FileHandle(forReadingAtPath:)`：**开即关，不读任何字节**。
///
/// 用 `FileHandle` 而不是 `open(2)`：探测目标是 TCC 保护文件，这里要的正是 Foundation
/// 那套"打不开就返回 nil"的静默失败——不抛错、不写日志、不产生任何用户可见痕迹。
struct DiskCleanFileHandleReadabilityProbe: DiskCleanFileReadabilityProbing {
    func canOpenForReading(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        try? handle.close()
        return true
    }
}

// MARK: - 能力探针

/// 完全磁盘访问能力探针（设计 §9）。
///
/// **没有查询 FDA 的 API**，只能拿一个已知受保护的文件试开：能开 = 有 FDA。探测本身绝不
/// 触发弹窗——FDA 类保护是静默 EPERM，只有 Documents/Downloads/Desktop 与沙盒容器
/// （`kTCCServiceSystemPolicyAppData`）那几类才会弹窗，这里刻意避开它们。
///
/// **进程内缓存**：FDA 绑定进程启动，运行期间不会变化——这正是状态卡要提示"退出并重新打开"
/// 的原因。缓存顺带保证同一次扫描里每个 target 看到的是同一个答案。
final class DiskCleanFullDiskAccessProbe: DiskCleanFullDiskAccessProbing, @unchecked Sendable {
    /// 进程级共享实例。扫描引擎与详情页读同一份结果，不会出现"引擎说没有、界面说有"。
    static let shared = DiskCleanFullDiskAccessProbe()

    /// 探测目标，按顺序试，先开成功者为准。
    ///
    /// - TCC.db：任何做过一次隐私授权决定的账户都有，覆盖面最广，且是纯 FDA 类保护。
    /// - Safari 书签：TCC.db 万一缺失时的兜底（例如全新账户）。同属静默 EPERM 类。
    ///
    /// 两个都打不开时返回"未授权"。文件不存在与被拒绝在这里同样处理：都无法证明有 FDA，
    /// 而误报"有"会让引擎照常展开受保护 target，换来一堆 permissionDenied 的空候选。
    static func defaultProbePaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
        [
            homeDirectory + "/Library/Application Support/com.apple.TCC/TCC.db",
            homeDirectory + "/Library/Safari/Bookmarks.plist"
        ]
    }

    private let probePaths: [String]
    private let readability: any DiskCleanFileReadabilityProbing
    private let cachedResult = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    init(
        probePaths: [String] = DiskCleanFullDiskAccessProbe.defaultProbePaths(),
        readability: any DiskCleanFileReadabilityProbing = DiskCleanFileHandleReadabilityProbe()
    ) {
        self.probePaths = probePaths
        self.readability = readability
    }

    var hasFullDiskAccess: Bool {
        if let cached = cachedResult.withLock({ $0 }) {
            return cached
        }
        // 锁外求值：探测是文件系统调用，持锁跑它会让并发的 sizing 线程排队等一次 open。
        // 并发首访至多多探一次，结果相同，无副作用。
        let result = probePaths.contains { readability.canOpenForReading(atPath: $0) }
        cachedResult.withLock { $0 = result }
        return result
    }
}

// MARK: - 授权引导

/// "前往授权"的落点（设计 §9）。
enum DiskCleanFullDiskAccessGuide {
    /// 系统设置 → 隐私与安全性 → 完全磁盘访问。
    static let settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    static var settingsURL: URL? {
        URL(string: settingsURLString)
    }

    /// 打开系统设置。URL 构造失败时静默返回——按钮点了没反应好过崩溃。
    @MainActor
    static func openSettings() {
        guard let settingsURL else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}
