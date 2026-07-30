import Foundation

/// 开发产物扫描根的界面状态（设计 §10.1 设置区）。
///
/// 把"存储 + 拒收反馈 + 通知扫描范围变化"三件事收在一处：视图只发命令读状态，
/// 而拒收原因（不可解析 / 重复 / 被祖先覆盖）必须有个地方留到下一次渲染——
/// `DiskCleanPurgeRootsStore.add` 返回后就没人记得它了，用户会以为自己刚选的文件夹凭空消失。
@MainActor
final class DiskCleanPurgeRootsModel: ObservableObject {
    /// 规范化后的物理路径，保持添加顺序。
    @Published private(set) var roots: [String]
    /// 最近一次增删被拒收的条目。任何一次成功操作都会清空它。
    @Published private(set) var rejections: [DiskCleanPurgeRootRejection]

    /// 根集合变化时的回调。用于把新范围推给开发产物分段的 Controller——
    /// 范围一变结果就该标记为陈旧，这条线不能断。
    var onRootsChange: (([String]) -> Void)?

    private let store: DiskCleanPurgeRootsStore

    init(store: DiskCleanPurgeRootsStore = DiskCleanPurgeRootsStore()) {
        self.store = store
        self.roots = store.roots()
        self.rejections = []
    }

    var scope: DiskCleanScanScope {
        .developerArtifacts(roots: roots)
    }

    var isEmpty: Bool { roots.isEmpty }

    func add(_ path: String) {
        apply(store.add(path))
    }

    func remove(_ path: String) {
        // 移除不会产生拒收：路径不在表里时结果就是原样，没有需要解释的东西。
        update(roots: store.remove(path), rejections: [])
    }

    /// 用户看过原因后手动收起。不自动超时消失——拒收说明用户的意图没被满足，
    /// 得由用户确认自己读到了。
    func dismissRejections() {
        guard !rejections.isEmpty else { return }
        rejections = []
    }

    private func apply(_ update: DiskCleanPurgeRootsUpdate) {
        self.update(roots: update.roots, rejections: update.rejections)
    }

    private func update(roots: [String], rejections: [DiskCleanPurgeRootRejection]) {
        self.rejections = rejections
        guard roots != self.roots else { return }
        self.roots = roots
        onRootsChange?(roots)
    }
}
