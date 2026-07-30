import Darwin
import Foundation

// MARK: - 目标种类

/// 开发产物种类（设计 §10.1）。
///
/// 每种都绑定一组**工程标记**：只有目录的同级出现标记文件才算命中。这是防误报的唯一手段——
/// `~/Documents/build` 很可能是照片目录，`~/Pictures/dist` 也一样，误删代价远大于漏删。
/// `__pycache__` 是唯一无条件命中的种类：这个名字由 CPython 独占产生，不存在歧义。
enum DiskCleanPurgeKind: String, CaseIterable, Equatable, Sendable {
    case nodeModules
    case rustTarget
    case buildOutput
    case distOutput
    case pythonCache

    /// 目录名。判定只看这个名字，不看路径其余部分。
    var directoryName: String {
        switch self {
        case .nodeModules:
            return "node_modules"
        case .rustTarget:
            return "target"
        case .buildOutput:
            return "build"
        case .distOutput:
            return "dist"
        case .pythonCache:
            return "__pycache__"
        }
    }

    /// 同级工程标记候选：命中任一即可。空数组表示无条件命中。
    var projectMarkers: [String] {
        switch self {
        case .nodeModules:
            return ["package.json"]
        case .rustTarget:
            return ["Cargo.toml"]
        case .buildOutput, .distOutput:
            return ["package.json", "setup.py", "pyproject.toml"]
        case .pythonCache:
            return []
        }
    }

    var displayName: String {
        switch self {
        case .nodeModules:
            return "Node 依赖"
        case .rustTarget:
            return "Rust 编译产物"
        case .buildOutput:
            return "构建输出"
        case .distOutput:
            return "打包输出"
        case .pythonCache:
            return "Python 字节码缓存"
        }
    }

    /// 合成 target 的稳定 ID（`DiskCleanRuleCatalogV2` 据此建 target）。
    /// 会原样写进审计日志，改动等于改动历史记录的语义。
    var targetID: String {
        "purge." + directoryName
    }

    /// 目录名 → 种类。名字唯一，故用字典而不是逐个比较。
    static let byDirectoryName: [String: DiskCleanPurgeKind] = Dictionary(
        uniqueKeysWithValues: DiskCleanPurgeKind.allCases.map { ($0.directoryName, $0) }
    )
}

// MARK: - git 状态

/// 候选所在仓库的 git 状态（设计 §10.1 git 警示）。
///
/// **fail-safe 方向固定**：查不出来就当有改动。误判为"脏"只是少默认勾选一项，用户可手动勾选；
/// 误判为"干净"则可能让用户在不知情下删掉尚未提交的构建产物依赖的工作区状态。
enum DiskCleanPurgeGitState: Equatable, Sendable {
    /// 根目录边界内没有找到 `.git`。不显示徽标，按普通候选处理。
    case notInRepository
    case clean(repositoryPath: String)
    case dirty(repositoryPath: String, reason: DirtyReason)

    enum DirtyReason: Equatable, Sendable {
        /// `git status --porcelain -unormal` 有输出。
        case uncommittedChanges
        /// `git log --branches --not --remotes` 有输出。
        case unpushedCommits
        /// git 缺失、超时（2s）或非零退出——按有改动处理。
        case inspectionFailed(String)
    }

    var isDirty: Bool {
        if case .dirty = self { return true }
        return false
    }

    var repositoryPath: String? {
        switch self {
        case .notInRepository:
            return nil
        case let .clean(repositoryPath):
            return repositoryPath
        case let .dirty(repositoryPath, _):
            return repositoryPath
        }
    }
}

// MARK: - 发现结果

/// 遍历阶段产出的一条命中。尚未做 git 检查，也未求大小——两者都在后续阶段补齐。
struct DiskCleanPurgeDiscoveredItem: Equatable, Sendable {
    /// **物理路径**：根经 `realpath` 规范化，途中每一级都以 no-follow 打开，因此拼接结果不含
    /// 任何符号链接祖先，可直接交给 sizing 与执行原语（设计 §13-6）。
    let path: String
    let kind: DiskCleanPurgeKind
    /// 实际命中的工程标记文件名。`__pycache__` 无条件命中，故为 nil。
    let projectMarker: String?
    /// 标记所在目录，即工程根。
    let projectPath: String
    /// 最近的 `.git` 祖先（含扫描根自身，不越过根边界）。nil = 不在仓库中。
    let repositoryPath: String?
}

/// 单个扫描根的遍历状态。
enum DiskCleanPurgeRootStatus: Equatable, Sendable {
    /// 根本没打开——目录已删除、TCC 拒绝、或非本地卷。UI 必须与"扫过但没有候选"区分开。
    case unreadable(reason: DiskCleanScanCompleteness.PartialReason)
    /// 已遍历。`completeness` 记录途中被跳过的子树（权限、挂载点、深度截断不算）。
    case traversed(completeness: DiskCleanScanCompleteness)
}

struct DiskCleanPurgeDiscoveryReport: Equatable, Sendable {
    let root: String
    let status: DiskCleanPurgeRootStatus
    let items: [DiskCleanPurgeDiscoveredItem]
}

/// 带 git 状态的完整候选描述。第二阶段据此铸造统一管线的 `DiskCleanCandidate`。
struct DiskCleanPurgeCandidate: Identifiable, Equatable, Sendable {
    let item: DiskCleanPurgeDiscoveredItem
    let gitState: DiskCleanPurgeGitState

    var id: String { item.path }
    var path: String { item.path }
    var kind: DiskCleanPurgeKind { item.kind }
    var projectMarker: String? { item.projectMarker }
    var projectPath: String { item.projectPath }

    /// 默认勾选策略：仓库脏（含检查失败）时不默认勾选，其余默认勾选。
    var isSelectedByDefault: Bool { !gitState.isDirty }
}

struct DiskCleanPurgeRootReport: Equatable, Sendable {
    let root: String
    let status: DiskCleanPurgeRootStatus
    let candidates: [DiskCleanPurgeCandidate]
}

struct DiskCleanPurgeScanResult: Equatable, Sendable {
    let reports: [DiskCleanPurgeRootReport]

    var candidates: [DiskCleanPurgeCandidate] {
        reports.flatMap(\.candidates)
    }

    /// 完全没能打开的根。UI 据此提示"文件夹已移除或无访问权限"，而不是显示空列表。
    var unreadableRoots: [String] {
        reports.compactMap { report in
            if case .unreadable = report.status { return report.root }
            return nil
        }
    }
}

// MARK: - 遍历

/// 开发产物发现遍历（设计 §10.1）。**阻塞式**，由 `DiskCleanPurgeScanner` 在后台队列调用。
///
/// 用 fd-relative `readdir`（复用 SlowWalker 的条目来源）而不是 `FileManager.enumerator`：
/// 后者没有 no-follow 与设备约束，会跟随符号链接走出扫描根、并静默穿越挂载点。这里虽然只是
/// 发现、不删任何东西，但产出的路径要直接交给删除原语，路径本身必须是可信的物理路径。
///
/// 深度上限 6 层，命中即剪枝：`node_modules` 内部还有成千上万个嵌套 `node_modules`，报第二层
/// 起的任何一个都毫无意义——删外层已经连它们一起删了。
struct DiskCleanPurgeDiscovery: Sendable {
    static let defaultMaximumDepth = 6

    /// 可命中候选的最大深度（根为 0）。深度等于上限的目录仍参与判定，但不再向下枚举。
    let maximumDepth: Int
    private let opener: DiskCleanRootOpener
    private let sourceFactory: any DiskCleanDirectoryEntrySourceFactory

    init(
        maximumDepth: Int = defaultMaximumDepth,
        opener: DiskCleanRootOpener = DiskCleanRootOpener(),
        sourceFactory: any DiskCleanDirectoryEntrySourceFactory = DiskCleanDirectoryStreamEntrySourceFactory()
    ) {
        self.maximumDepth = max(maximumDepth, 1)
        self.opener = opener
        self.sourceFactory = sourceFactory
    }

    func discover(root: String, isCancelled: () -> Bool = { false }) -> DiskCleanPurgeDiscoveryReport {
        switch opener.open(path: root) {
        case let .failed(reason):
            return DiskCleanPurgeDiscoveryReport(root: root, status: .unreadable(reason: reason), items: [])

        case .resolved:
            // 根不是目录（文件 / symlink / socket）。没有可遍历的内容，如实报不可读。
            return DiskCleanPurgeDiscoveryReport(root: root, status: .unreadable(reason: .walkError), items: [])

        case let .directory(fileDescriptor, identity):
            var state = TraversalState(rootDevice: identity.devid)
            let rootRepository = Self.containsGitEntry(directoryFileDescriptor: fileDescriptor) ? root : nil
            visit(
                fileDescriptor: fileDescriptor,
                path: root,
                depth: 0,
                repositoryPath: rootRepository,
                isCancelled: isCancelled,
                state: &state
            )
            // readdir 顺序由文件系统决定，排序让列表与测试都稳定。
            return DiskCleanPurgeDiscoveryReport(
                root: root,
                status: .traversed(completeness: state.accumulator.completeness),
                items: state.items.sorted { $0.path < $1.path }
            )
        }
    }

    // MARK: 内部

    private struct TraversalState {
        let rootDevice: UInt64
        var items: [DiskCleanPurgeDiscoveredItem] = []
        var accumulator = DiskCleanCompletenessAccumulator()
    }

    /// 递归而非显式栈：深度上限 6，栈与 fd 占用都是常数级，换来的可读性值这个代价
    /// （执行器的删除 prewalk 深度上限是 128，那里必须用显式栈）。
    ///
    /// `fileDescriptor` 所有权移交本方法。
    private func visit(
        fileDescriptor: Int32,
        path: String,
        depth: Int,
        repositoryPath: String?,
        isCancelled: () -> Bool,
        state: inout TraversalState
    ) {
        let source: any DiskCleanDirectoryEntrySource
        do {
            source = try sourceFactory.makeSource(fileDescriptor: fileDescriptor)
        } catch {
            // 协议约定：makeSource 抛错时 fd 所有权仍归调用方。
            close(fileDescriptor)
            state.accumulator.add(errno: (error as? DiskCleanPOSIXError)?.code ?? EIO)
            return
        }
        defer { source.close() }

        while true {
            guard !isCancelled() else {
                // 取消与 sizing 侧同一出口：结果标记为不完整，调用方据此知道这不是"扫完了没有"。
                state.accumulator.add(.timedOut)
                return
            }

            let batch: [DiskCleanWalkEntry]?
            do {
                batch = try source.nextBatch()
            } catch {
                state.accumulator.add(errno: (error as? DiskCleanPOSIXError)?.code ?? EIO)
                return
            }
            guard let batch else { return }

            for entry in batch {
                guard case let .resolved(resolved) = entry else {
                    state.accumulator.add(.walkError)
                    continue
                }
                // symlink 一律不跟随、不上报：跟随会走出扫描根，上报又会让用户以为删的是目标。
                guard resolved.fileType == .directory else { continue }
                guard let name = Self.name(of: resolved) else {
                    // 文件名不是合法 UTF-8，无法安全地表达成候选路径。少扫一棵树，方向 fail-safe。
                    state.accumulator.add(.walkError)
                    continue
                }

                let childPath = path + "/" + name
                let childDepth = depth + 1

                if let kind = DiskCleanPurgeKind.byDirectoryName[name],
                   let match = Self.projectMarker(for: kind, directoryFileDescriptor: source.directoryFileDescriptor) {
                    state.items.append(
                        DiskCleanPurgeDiscoveredItem(
                            path: childPath,
                            kind: kind,
                            projectMarker: match.markerName,
                            projectPath: path,
                            repositoryPath: repositoryPath
                        )
                    )
                    continue  // 命中即剪枝
                }

                guard childDepth < maximumDepth else { continue }
                guard resolved.devid == state.rootDevice else {
                    // 挂载点不下潜：另一个卷有自己的可用空间与权限模型，扫描根的授权不覆盖它。
                    state.accumulator.add(.crossedMountPoint)
                    continue
                }

                descend(
                    name: resolved.nameBytes,
                    parentFileDescriptor: source.directoryFileDescriptor,
                    childPath: childPath,
                    depth: childDepth,
                    inheritedRepositoryPath: repositoryPath,
                    isCancelled: isCancelled,
                    state: &state
                )
            }
        }
    }

    private func descend(
        name: [CChar],
        parentFileDescriptor: Int32,
        childPath: String,
        depth: Int,
        inheritedRepositoryPath: String?,
        isCancelled: () -> Bool,
        state: inout TraversalState
    ) {
        // 单组件 `openat` + `O_NOFOLLOW`：条目在 readdir 与 open 之间被换成 symlink 时以 ELOOP 失败。
        let childDescriptor = name.withUnsafeBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return openat(parentFileDescriptor, base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard childDescriptor >= 0 else {
            state.accumulator.add(errno: errno)
            return
        }

        // 最近的 `.git` 覆盖继承值：嵌套仓库（子模块、monorepo 内独立仓库）以最近的为准。
        let repositoryPath = Self.containsGitEntry(directoryFileDescriptor: childDescriptor)
            ? childPath
            : inheritedRepositoryPath

        visit(
            fileDescriptor: childDescriptor,
            path: childPath,
            depth: depth,
            repositoryPath: repositoryPath,
            isCancelled: isCancelled,
            state: &state
        )
    }

    /// 工程标记判定结果。`unconditional` 与"匹配到某个标记"必须能区分：前者的候选描述里
    /// 没有标记依据可展示，而不是"标记为空字符串"。
    private enum MarkerMatch {
        case unconditional
        case matched(String)

        var markerName: String? {
            if case let .matched(name) = self { return name }
            return nil
        }
    }

    /// 返回 nil = 未命中，不是候选。
    private static func projectMarker(
        for kind: DiskCleanPurgeKind,
        directoryFileDescriptor: Int32
    ) -> MarkerMatch? {
        guard !kind.projectMarkers.isEmpty else { return .unconditional }
        for marker in kind.projectMarkers
        where existsAsFile(name: marker, directoryFileDescriptor: directoryFileDescriptor) {
            return .matched(marker)
        }
        return nil
    }

    /// 标记必须是文件或符号链接，不能是目录：monorepo 里 `package.json` 可能是符号链接，
    /// 但名为 `package.json` 的**目录**只说明这是个巧合，不是工程根。
    private static func existsAsFile(name: String, directoryFileDescriptor: Int32) -> Bool {
        var status = stat()
        guard fstatat(directoryFileDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return DiskCleanRootIdentity.FileType(mode: status.st_mode) != .directory
    }

    /// `.git` 可能是目录（普通仓库），也可能是文件（worktree / submodule 的 gitdir 指针），两者都算。
    private static func containsGitEntry(directoryFileDescriptor: Int32) -> Bool {
        var status = stat()
        return fstatat(directoryFileDescriptor, ".git", &status, AT_SYMLINK_NOFOLLOW) == 0
    }

    private static func name(of entry: DiskCleanResolvedEntry) -> String? {
        let bytes = entry.nameBytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        // 用 String(bytes:encoding:) 而不是 String(decoding:)：后者会把非法字节替换成 U+FFFD，
        // 拼出来的路径指向一个不存在的文件，交给删除原语毫无意义。
        return String(bytes: bytes, encoding: .utf8)
    }
}

// MARK: - git 检查

/// 仓库脏状态检查。两条命令都走 `DiskCleanSubprocessRunning` seam，超时 2 秒（设计 §10.1）。
struct DiskCleanGitStatusInspector: Sendable {
    static let executablePath = "/usr/bin/git"
    static let timeout = Duration.seconds(2)

    private let runner: any DiskCleanSubprocessRunning

    init(runner: any DiskCleanSubprocessRunning = LocalDiskCleanSubprocessRunner()) {
        self.runner = runner
    }

    func inspect(repositoryPath: String) async -> DiskCleanPurgeGitState {
        do {
            let status = try await run(
                arguments: ["-C", repositoryPath, "status", "--porcelain", "-unormal"]
            )
            guard status.exitCode == 0 else {
                return .dirty(repositoryPath: repositoryPath, reason: .inspectionFailed("status 退出码 \(status.exitCode)"))
            }
            if !Self.isBlank(status.standardOutput) {
                return .dirty(repositoryPath: repositoryPath, reason: .uncommittedChanges)
            }

            // 未推送提交：本地分支上、任何远程分支都没有的提交。有一条就够，故 -n 1。
            let unpushed = try await run(
                arguments: ["-C", repositoryPath, "log", "--branches", "--not", "--remotes", "-n", "1"]
            )
            guard unpushed.exitCode == 0 else {
                return .dirty(repositoryPath: repositoryPath, reason: .inspectionFailed("log 退出码 \(unpushed.exitCode)"))
            }
            if !Self.isBlank(unpushed.standardOutput) {
                return .dirty(repositoryPath: repositoryPath, reason: .unpushedCommits)
            }
            return .clean(repositoryPath: repositoryPath)
        } catch {
            return .dirty(repositoryPath: repositoryPath, reason: .inspectionFailed(Self.describe(error)))
        }
    }

    private func run(arguments: [String]) async throws -> DiskCleanSubprocessResult {
        try await runner.run(
            executablePath: Self.executablePath,
            arguments: arguments,
            timeout: Self.timeout
        )
    }

    /// 只有空白输出才算干净：git 在无改动时输出空串，被 shell 包装过的路径可能带一个换行。
    private static func isBlank(_ output: Data) -> Bool {
        String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DiskCleanSubprocessError.timedOut:
            return "git 检查超时"
        case DiskCleanSubprocessError.executableUnavailable:
            return "未找到 git"
        case let DiskCleanSubprocessError.launchFailed(_, message):
            return "git 启动失败：\(message)"
        default:
            return "git 检查失败"
        }
    }
}

// MARK: - 扫描器

/// 开发产物清扫扫描器（设计 §10.1）。
///
/// 编排两件事：后台线程上的阻塞遍历，以及每个仓库一次的 git 检查（同一仓库下常有几十个
/// `node_modules`，逐个 spawn 会把 2 秒超时乘上几十倍）。
struct DiskCleanPurgeScanner: Sendable {
    private let discovery: DiskCleanPurgeDiscovery
    private let inspector: DiskCleanGitStatusInspector

    init(
        discovery: DiskCleanPurgeDiscovery = DiskCleanPurgeDiscovery(),
        inspector: DiskCleanGitStatusInspector = DiskCleanGitStatusInspector()
    ) {
        self.discovery = discovery
        self.inspector = inspector
    }

    func scan(roots: [String]) async -> DiskCleanPurgeScanResult {
        var reports: [DiskCleanPurgeRootReport] = []
        var inspectedRepositories: [String: DiskCleanPurgeGitState] = [:]

        for root in roots {
            let discovered = await discoverInBackground(root: root)
            var candidates: [DiskCleanPurgeCandidate] = []
            candidates.reserveCapacity(discovered.items.count)

            for item in discovered.items {
                guard let repository = item.repositoryPath else {
                    candidates.append(DiskCleanPurgeCandidate(item: item, gitState: .notInRepository))
                    continue
                }
                let state: DiskCleanPurgeGitState
                if let cached = inspectedRepositories[repository] {
                    state = cached
                } else {
                    state = await inspector.inspect(repositoryPath: repository)
                    inspectedRepositories[repository] = state
                }
                candidates.append(DiskCleanPurgeCandidate(item: item, gitState: state))
            }

            reports.append(
                DiskCleanPurgeRootReport(root: root, status: discovered.status, candidates: candidates)
            )
        }

        return DiskCleanPurgeScanResult(reports: reports)
    }

    /// 遍历滞留在 `readdir`/`openat` 里，不能占用 Swift 并发的协作线程池。深度上限 6 让耗时有界，
    /// 因此无需 WorkerPool 的放弃预算——那套机制是为可能永久挂住的 sizing 准备的。
    ///
    /// 阻塞遍历不响应 `Task.isCancelled`，取消经 `DiskCleanCancellationFlag`（与 WorkerPool 同一个）
    /// 置位后由遍历逐批轮询。
    private func discoverInBackground(root: String) async -> DiskCleanPurgeDiscoveryReport {
        let flag = DiskCleanCancellationFlag()
        let discovery = self.discovery
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        returning: discovery.discover(root: root, isCancelled: { flag.isSet })
                    )
                }
            }
        } onCancel: {
            flag.set()
        }
    }
}
