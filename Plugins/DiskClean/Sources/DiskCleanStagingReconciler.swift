import Darwin
import Foundation

/// Plugin on-disk state directory (journal + audit log).
///
/// Provided by the host via `PluginRuntimeContext.supportDirectory`; may be nil under
/// static loading and similar cases, in which we fall back to the same host-agreed location.
/// That path hits the `DiskCleanSafetyPolicy` "cleanup tool state" protection branch, so
/// the cleaner never deletes its own state as cache.
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

/// Outcome of reconciling one unfinished journal entry.
enum DiskCleanReconcileOutcome: Equatable, Sendable {
    /// Staged object was renamed back to the original path.
    case rolledBack(originalPath: String)
    /// Staged object is already gone (previous disposal actually succeeded; only the completion record was not fsynced). Entry is closed out.
    case absent(stagedName: String)
    /// Original path was recreated; never overwrite. Keep the staged object and leave the entry **unfinished** so the next launch can still surface it.
    case blocked(stagedName: String, originalPath: String)
    /// Cannot decide (parent directory unreadable, etc.). Leave unfinished for the next launch retry.
    case failed(stagedName: String, reason: String)
}

protocol DiskCleanStagingReconciling: Sendable {
    func reconcile(storageDirectory: URL) async
}

/// Startup reconciliation (design §7.6).
///
/// The crash matrix has only two outcomes: journal written but rename never happened
/// (no staged object — close the entry), or rename happened but the completion record
/// never landed (orphan staged object — rename back). The write-order invariant
/// (begin + fsync → rename) rules out a third case of "staged object with no record".
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
            // Parent directory is gone entirely → staged object is gone too; nothing to recover.
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

        // Same invariant as execution-time rollback: RENAME_EXCL; never overwrite a recreated original path.
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
