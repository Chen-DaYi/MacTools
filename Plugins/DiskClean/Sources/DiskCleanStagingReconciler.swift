import Darwin
import Foundation

/// 插件的磁盘状态目录（journal + 审计日志）。
///
/// 宿主经 `PluginRuntimeContext.supportDirectory` 提供；静态加载等场景下可能为 nil，
/// 此时回退到与宿主同一约定的位置。该位置命中 `DiskCleanSafetyPolicy` 的
/// "cleanup tool state" 保护分支，因此清理工具永远不会把自己的状态当缓存删掉。
enum DiskCleanStorageLocation {
    static func resolve(supportDirectory: URL?) -> URL {
        supportDirectory ?? fallbackDirectory
    }

    static var fallbackDirectory: URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport.appendingPathComponent("MacTools/DiskClean", isDirectory: true)
    }
}

/// 单条未完成条目的处理结果。
enum DiskCleanReconcileOutcome: Equatable, Sendable {
    /// 暂存对象已改回原路径。
    case rolledBack(originalPath: String)
    /// 暂存对象已不存在（上次处置其实成功了，只是完成记录没落盘）。条目销账。
    case absent(stagedName: String)
    /// 原路径已被重建，绝不覆盖。暂存对象保留，条目**保持未完成**以便下次继续提示。
    case blocked(stagedName: String, originalPath: String)
    /// 无法判定（父目录打不开等）。条目保持未完成，留待下次启动重试。
    case failed(stagedName: String, reason: String)
}

protocol DiskCleanStagingReconciling: Sendable {
    func reconcile(storageDirectory: URL) async
}

/// 启动 reconciliation（设计 §7.6）。
///
/// 崩溃点矩阵只有两种可能：journal 写完但 rename 未发生（没有暂存对象，条目直接销账），
/// 或 rename 已发生但完成记录未落盘（暂存对象是孤儿，改回原名）。写入顺序铁律
/// （begin + fsync → rename）保证不存在第三种"有暂存对象却没有记录"的情况。
struct DiskCleanStagingReconciler: DiskCleanStagingReconciling {
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func reconcile(storageDirectory: URL) async {
        _ = reconcile(
            journal: DiskCleanStagingJournal(directory: storageDirectory),
            auditLog: DiskCleanAuditLog(directory: storageDirectory)
        )
    }

    @discardableResult
    func reconcile(
        journal: DiskCleanStagingJournal,
        auditLog: DiskCleanAuditLog
    ) -> [DiskCleanReconcileOutcome] {
        let entries = journal.incompleteEntries()
        guard !entries.isEmpty else { return [] }

        var outcomes: [DiskCleanReconcileOutcome] = []
        for entry in entries {
            let outcome = reconcile(entry, journal: journal)
            outcomes.append(outcome)
            auditLog.append(record(for: outcome, entry: entry))
        }
        journal.compact()
        return outcomes
    }

    private func reconcile(
        _ entry: DiskCleanStagingJournal.Entry,
        journal: DiskCleanStagingJournal
    ) -> DiskCleanReconcileOutcome {
        let originalPath = DiskCleanRemovalPrimitive.join(entry.parentPath, entry.originalName)

        let parentDescriptor = Darwin.open(
            entry.parentPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK
        )
        guard parentDescriptor >= 0 else {
            let code = errno
            guard code == ENOENT else {
                return .failed(stagedName: entry.stagedName, reason: message(code))
            }
            // 父目录整个不在了 → 暂存对象也不在，没有可恢复的东西。
            journal.complete(entryID: entry.id, status: "reconciledParentMissing", at: now())
            return .absent(stagedName: entry.stagedName)
        }
        defer { close(parentDescriptor) }

        var status = stat()
        guard fstatat(parentDescriptor, entry.stagedName, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            guard code == ENOENT else {
                return .failed(stagedName: entry.stagedName, reason: message(code))
            }
            journal.complete(entryID: entry.id, status: "reconciledAbsent", at: now())
            return .absent(stagedName: entry.stagedName)
        }

        // 与执行期回滚同一条铁律：RENAME_EXCL，绝不覆盖已被重建的原路径。
        guard renameatx_np(
            parentDescriptor,
            entry.stagedName,
            parentDescriptor,
            entry.originalName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            let code = errno
            guard code == EEXIST else {
                return .failed(stagedName: entry.stagedName, reason: message(code))
            }
            return .blocked(stagedName: entry.stagedName, originalPath: originalPath)
        }

        journal.complete(entryID: entry.id, status: "reconciledRolledBack", at: now())
        return .rolledBack(originalPath: originalPath)
    }

    private func record(
        for outcome: DiskCleanReconcileOutcome,
        entry: DiskCleanStagingJournal.Entry
    ) -> DiskCleanAuditLog.Record {
        let originalPath = DiskCleanRemovalPrimitive.join(entry.parentPath, entry.originalName)
        switch outcome {
        case .rolledBack:
            return DiskCleanAuditLog.Record(
                timestamp: now(),
                action: .scanEvent,
                path: originalPath,
                stagedName: entry.stagedName,
                status: "reconciledRolledBack"
            )
        case .absent:
            return DiskCleanAuditLog.Record(
                timestamp: now(),
                action: .scanEvent,
                path: originalPath,
                stagedName: entry.stagedName,
                status: "reconciledAbsent"
            )
        case .blocked:
            return DiskCleanAuditLog.Record(
                timestamp: now(),
                action: .scanEvent,
                path: originalPath,
                stagedName: entry.stagedName,
                status: "rollbackBlocked",
                error: "原路径已被重建，暂存对象保留"
            )
        case let .failed(_, reason):
            return DiskCleanAuditLog.Record(
                timestamp: now(),
                action: .scanEvent,
                path: originalPath,
                stagedName: entry.stagedName,
                status: "reconcileFailed",
                error: reason
            )
        }
    }

    private func message(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
