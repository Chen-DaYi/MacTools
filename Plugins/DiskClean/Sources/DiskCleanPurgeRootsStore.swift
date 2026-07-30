import Foundation

// MARK: - 规范化结果

/// 一个扫描根被拒收的原因。UI 据此给出具体提示，而不是静默丢弃用户刚选的文件夹。
enum DiskCleanPurgeRootRejection: Equatable, Sendable {
    /// 不是绝对路径，或 `realpath(3)` 解析失败（不存在、无权限、路径过长）。
    case unresolvable(path: String)
    /// 规范化后与已有根重复（例如经由不同 symlink 指向同一目录）。
    case duplicate(path: String)
    /// 被列表中另一个根覆盖：扫描祖先必然覆盖后代，留着后代只会让同一候选出现两次。
    case coveredByAncestor(path: String, ancestor: String)
}

struct DiskCleanPurgeRootsUpdate: Equatable, Sendable {
    /// 规范化后的物理路径列表，保持用户添加顺序。
    let roots: [String]
    let rejections: [DiskCleanPurgeRootRejection]
}

/// 扫描根规范化（设计 §10.1 + §13-6）。
///
/// 三件事，纯函数、无副作用（`realpath` 经 `resolvePhysicalPath` 注入）：
/// 1. **物理路径化**：喂给 sizing / 执行原语的路径不得含符号链接祖先，否则 `O_NOFOLLOW_ANY`
///    会以 ELOOP 拒绝整棵树（`/var`、`/tmp` 本身就是 symlink）。规范化只能用 `realpath(3)`。
/// 2. **去重**：两个不同写法可能指向同一目录，规范化后才看得出来。
/// 3. **祖先裁决——保留祖先、弃后代**：两者都扫等于把后代里的候选报两遍；反过来"保留后代弃
///    祖先"会缩小用户明确要求的扫描范围，是静默失效。裁决只看规范化后的完整集合，与添加顺序
///    无关：先加 `~/Code/app` 再加 `~/Code`，结果同样是只保留 `~/Code`。
enum DiskCleanPurgeRootNormalizer {
    static func normalize(
        _ paths: [String],
        resolvePhysicalPath: (String) -> String?
    ) -> DiskCleanPurgeRootsUpdate {
        var resolved: [(original: String, physical: String)] = []
        var rejections: [DiskCleanPurgeRootRejection] = []
        var seen: Set<String> = []

        for path in paths {
            let expanded = expandTilde(in: path)
            guard expanded.hasPrefix("/"), let physical = resolvePhysicalPath(expanded) else {
                rejections.append(.unresolvable(path: path))
                continue
            }
            let trimmed = trimTrailingSlashes(physical)
            guard seen.insert(trimmed).inserted else {
                rejections.append(.duplicate(path: path))
                continue
            }
            resolved.append((original: path, physical: trimmed))
        }

        var roots: [String] = []
        for entry in resolved {
            if let ancestor = resolved.first(where: { isStrictAncestor($0.physical, of: entry.physical) }) {
                rejections.append(.coveredByAncestor(path: entry.original, ancestor: ancestor.physical))
                continue
            }
            roots.append(entry.physical)
        }

        return DiskCleanPurgeRootsUpdate(roots: roots, rejections: rejections)
    }

    /// 严格祖先：`/a` 是 `/a/b` 的祖先，但不是 `/a` 自身、也不是 `/ab` 的祖先。
    /// 两侧都已去掉尾部斜杠，`/` 单独处理（拼接会得到 `//`）。
    static func isStrictAncestor(_ ancestor: String, of path: String) -> Bool {
        guard ancestor != path else { return false }
        if ancestor == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }

    private static func expandTilde(in path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + path.dropFirst(1)
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }
}

// MARK: - 持久化 seam

/// 扫描根的原始持久化。与 `DiskCleanRemovalModeStoring` 同一形态：只管存取，不含语义。
protocol DiskCleanPurgeRootsPersisting: Sendable {
    func loadRoots() -> [String]
    func saveRoots(_ roots: [String])
}

/// `UserDefaults` 本身线程安全但未标注 Sendable，与既有
/// `UserDefaultsDiskCleanRemovalModeStore` 同一处理方式。
struct UserDefaultsDiskCleanPurgeRootsPersistence: DiskCleanPurgeRootsPersisting, @unchecked Sendable {
    static let defaultsKey = "DiskClean.purgeRoots"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRoots() -> [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func saveRoots(_ roots: [String]) {
        defaults.set(roots, forKey: Self.defaultsKey)
    }
}

// MARK: - 存储

/// 用户配置的开发产物扫描根（设计 §10.1）。默认空——不全盘扫描，只扫用户明确指定的目录。
///
/// 写入前一律经 `DiskCleanPurgeRootNormalizer` 规范化，因此**存储里的路径必然是物理路径**。
/// 读取不再规范化：目录可能已被删除或替换，此时 `realpath` 失败会让根凭空消失，用户看不到
/// 自己加过什么。让扫描器用 `O_NOFOLLOW_ANY` 打开时失败并如实上报，是更诚实的降级。
struct DiskCleanPurgeRootsStore: Sendable {
    private let persistence: any DiskCleanPurgeRootsPersisting
    private let resolvePhysicalPath: @Sendable (String) -> String?

    init(
        persistence: any DiskCleanPurgeRootsPersisting = UserDefaultsDiskCleanPurgeRootsPersistence(),
        resolvePhysicalPath: @escaping @Sendable (String) -> String? = { DiskCleanPhysicalPath.realpath(of: $0) }
    ) {
        self.persistence = persistence
        self.resolvePhysicalPath = resolvePhysicalPath
    }

    func roots() -> [String] {
        persistence.loadRoots()
    }

    /// 追加一个根并落盘。返回值含被拒收项，供 UI 说明原因。
    @discardableResult
    func add(_ path: String) -> DiskCleanPurgeRootsUpdate {
        replaceAll(with: persistence.loadRoots() + [path])
    }

    /// 移除一个根。同时匹配原始写法与规范化写法：目录已不存在时 `realpath` 会失败，
    /// 只按规范化匹配会让用户永远删不掉这一条。
    @discardableResult
    func remove(_ path: String) -> [String] {
        let physical = resolvePhysicalPath(path)
        let remaining = persistence.loadRoots().filter { $0 != path && $0 != physical }
        persistence.saveRoots(remaining)
        return remaining
    }

    /// 整表重写（设置页批量编辑、迁移旧存储）。
    @discardableResult
    func replaceAll(with paths: [String]) -> DiskCleanPurgeRootsUpdate {
        let update = DiskCleanPurgeRootNormalizer.normalize(paths, resolvePhysicalPath: resolvePhysicalPath)
        persistence.saveRoots(update.roots)
        return update
    }
}
