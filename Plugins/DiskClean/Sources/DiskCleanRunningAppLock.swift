import AppKit
import Foundation

/// 运行中应用/进程快照（设计 §4.2 第 4 条）。
///
/// v1 对**每条规则**各 spawn 一次 `pgrep`（43 条规则 = 43 个子进程）。这里改成一次快照：
/// 一次 `NSWorkspace.runningApplications` + 一次批量 `pgrep`，之后全部 target 的锁定判定
/// 都在内存里完成。
///
/// 快照是值类型且不自动刷新——这正是设计想要的语义：扫描期间用同一时点的判定，
/// 执行前（§7.1 preflight、§7.2 逐项复核）再取新快照，形成"双时点锁"。
struct DiskCleanRunningAppSnapshot: Equatable, Sendable {
    /// 运行中应用的 bundle ID（小写归一，bundle ID 大小写不敏感）。
    let runningBundleIDs: Set<String>
    /// 运行中的进程名（`pgrep -x` 精确匹配结果，大小写敏感）。
    let runningProcessNames: Set<String>
    let observedAt: Date

    init(
        runningBundleIDs: Set<String> = [],
        runningProcessNames: Set<String> = [],
        observedAt: Date = Date()
    ) {
        self.runningBundleIDs = Set(runningBundleIDs.map { $0.lowercased() })
        self.runningProcessNames = runningProcessNames
        self.observedAt = observedAt
    }

    /// 锁定该 target 的进程名，未锁定时为 nil。
    ///
    /// bundle ID 命中时返回 bundle ID 本身作为展示名——用户看到的是"正在使用(com.google.Chrome)"，
    /// 比返回一个猜测的中文应用名更诚实，且不需要额外查询。
    func lockingProcessName(for target: DiskCleanRuleTarget) -> String? {
        lockingProcessName(
            bundleIDs: target.lockedByBundleIDs,
            processNames: target.skipWhenProcessIsRunning
        )
    }

    /// 执行侧入口：计划项自带锁定声明（铸造时从目录复制），无需再查规则目录。
    func lockingProcessName(bundleIDs: [String], processNames: [String]) -> String? {
        for bundleID in bundleIDs where runningBundleIDs.contains(bundleID.lowercased()) {
            return bundleID
        }
        for name in processNames where runningProcessNames.contains(name) {
            return name
        }
        return nil
    }

    /// 换一批 bundle ID，其余不变。执行侧逐项刷新锁定判定时用。
    func replacingBundleIDs(_ bundleIDs: Set<String>, observedAt: Date) -> DiskCleanRunningAppSnapshot {
        DiskCleanRunningAppSnapshot(
            runningBundleIDs: bundleIDs,
            runningProcessNames: runningProcessNames,
            observedAt: observedAt
        )
    }

    /// 全体 target 声明的进程名去重集合。批量 pgrep 的查询集就是它。
    static func processNames(in targets: [DiskCleanRuleTarget]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for target in targets {
            for name in target.skipWhenProcessIsRunning where seen.insert(name).inserted {
                ordered.append(name)
            }
        }
        return ordered
    }
}

/// 快照来源 seam。扫描侧与执行侧共用同一接口，判定矩阵只需测一次。
protocol DiskCleanRunningAppSnapshotting: Sendable {
    func makeSnapshot(processNames: [String]) async -> DiskCleanRunningAppSnapshot

    /// 只刷新 bundle ID 部分，进程名沿用传入快照。
    ///
    /// 执行器逐项复核锁定（§7.2）时用它：`NSWorkspace.runningApplications` 是便宜的内存读取，
    /// 每项刷新没有负担；`pgrep` 要 spawn 子进程，逐项跑会把一次清理拖成几十次 fork，
    /// 故进程名沿用 preflight 那一次的结果。取舍是"进程名维度的锁定判定最多滞后一次清理的时长"，
    /// 而真正的防线是删除原语的身份验证与冻结（§7.3、§7.4），不是这里。
    func refreshingBundleIDs(in snapshot: DiskCleanRunningAppSnapshot) async -> DiskCleanRunningAppSnapshot
}

extension DiskCleanRunningAppSnapshotting {
    func refreshingBundleIDs(in snapshot: DiskCleanRunningAppSnapshot) async -> DiskCleanRunningAppSnapshot {
        snapshot
    }
}

/// 真实实现：`NSWorkspace` + 一次批量 `pgrep`。
///
/// 两个来源都只做"加法"：任一来源失败只会让锁定判定漏报（候选仍会被删），因此
/// **执行侧必须重取快照并逐项复核**（§7.2），不能把这里当唯一防线。
struct DiskCleanRunningAppLock: DiskCleanRunningAppSnapshotting {
    static let defaultExecutablePath = "/usr/bin/pgrep"

    let executablePath: String
    let timeout: Duration
    let subprocessRunner: any DiskCleanSubprocessRunning
    let now: @Sendable () -> Date

    init(
        executablePath: String = DiskCleanRunningAppLock.defaultExecutablePath,
        timeout: Duration = DiskCleanDynamicRuleProviders.subprocessTimeout,
        subprocessRunner: any DiskCleanSubprocessRunning = LocalDiskCleanSubprocessRunner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.executablePath = executablePath
        self.timeout = timeout
        self.subprocessRunner = subprocessRunner
        self.now = now
    }

    func makeSnapshot(processNames: [String]) async -> DiskCleanRunningAppSnapshot {
        DiskCleanRunningAppSnapshot(
            runningBundleIDs: await Self.runningBundleIDs(),
            runningProcessNames: await runningProcessNames(among: processNames),
            observedAt: now()
        )
    }

    func refreshingBundleIDs(in snapshot: DiskCleanRunningAppSnapshot) async -> DiskCleanRunningAppSnapshot {
        snapshot.replacingBundleIDs(await Self.runningBundleIDs(), observedAt: now())
    }

    /// `NSWorkspace` 只保证主线程安全，故显式跳到主 actor 读取。
    private static func runningBundleIDs() async -> Set<String> {
        await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
    }

    private func runningProcessNames(among names: [String]) async -> Set<String> {
        guard !names.isEmpty else { return [] }

        let result: DiskCleanSubprocessResult
        do {
            result = try await subprocessRunner.run(
                executablePath: executablePath,
                arguments: ["-x", "-l", Self.pattern(for: names)],
                timeout: timeout
            )
        } catch {
            // pgrep 缺失或超时 → 判定漏报，执行侧复核兜底。
            return []
        }
        // pgrep 无匹配时退出码为 1，输出为空——不是失败。
        guard result.exitCode == 0 || result.exitCode == 1 else { return [] }

        // 只采信本次查询集合内的名字：pattern 是正则，输出理论上可能包含意外匹配。
        let requested = Set(names)
        return Set(Self.processNames(fromPgrepOutput: result.standardOutput).filter(requested.contains))
    }

    /// 一次查全部名字：`pgrep -x` 的 pattern 是扩展正则，`-x` 要求整名匹配，
    /// 因此 `(a|b|c)` 的语义正好是"名字精确等于其中之一"。
    static func pattern(for names: [String]) -> String {
        "(" + names.map(escapeForExtendedRegex).joined(separator: "|") + ")"
    }

    /// 进程名里出现 `.`、`+`、`(` 等正则元字符是常态（`com.docker.backend`），必须逐字转义。
    static func escapeForExtendedRegex(_ name: String) -> String {
        let metacharacters: Set<Character> = ["\\", ".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|"]
        var escaped = ""
        escaped.reserveCapacity(name.count)
        for character in name {
            if metacharacters.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }

    /// `pgrep -l` 每行是 `<pid> <进程名>`；进程名可含空格，故只切掉第一个空格前的 pid。
    static func processNames(fromPgrepOutput output: Data) -> [String] {
        String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let separatorIndex = line.firstIndex(of: " ") else { return nil }
                let name = String(line[line.index(after: separatorIndex)...])
                return name.isEmpty ? nil : name
            }
    }
}
