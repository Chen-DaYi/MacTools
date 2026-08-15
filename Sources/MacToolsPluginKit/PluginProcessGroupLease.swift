import Darwin
import Foundation

/// Owns a dedicated process group from spawn until its leader is finally reaped.
///
/// Keeping the exited leader waitable with `WNOWAIT` prevents its PID (and therefore the
/// process-group ID) from being reused while cancellation or descendant cleanup can still signal
/// the group. `reapLeader()` is the single ownership-release point; signals after it are rejected.
public final class PluginProcessGroupLease: @unchecked Sendable {
    struct SystemOperations: @unchecked Sendable {
        var waitForExitWithoutReaping: @Sendable (pid_t) -> Bool
        var reap: @Sendable (pid_t) -> Int32?
        var signalGroup: @Sendable (pid_t, Int32) -> Bool
        var groupMembers: @Sendable (pid_t) -> [pid_t]?

        static let live = SystemOperations(
            waitForExitWithoutReaping: { processID in
                var information = siginfo_t()
                var result: Int32
                repeat {
                    result = waitid(P_PID, id_t(processID), &information, WEXITED | WNOWAIT)
                } while result != 0 && errno == EINTR
                return result == 0
            },
            reap: { processID in
                var status: Int32 = 0
                var result: pid_t
                repeat {
                    result = waitpid(processID, &status, 0)
                } while result < 0 && errno == EINTR
                return result == processID ? status : nil
            },
            signalGroup: { processID, signal in
                if Darwin.kill(-processID, signal) == 0 { return true }
                return errno == EPERM
            },
            groupMembers: { processGroupID in
                listGroupMembers(
                    processGroupID: processGroupID,
                    list: proc_listpgrppids
                )
            }
        )
    }

    typealias GroupMemberListOperation = @Sendable (
        _ processGroupID: pid_t,
        _ buffer: UnsafeMutableRawPointer?,
        _ bufferSize: Int32
    ) -> Int32

    /// `proc_listpgrppids` returns a PID count, while its buffer-size argument is
    /// measured in bytes. A full buffer is retried because the process group may
    /// have grown between the sizing and fill calls.
    static func listGroupMembers(
        processGroupID: pid_t,
        list: GroupMemberListOperation
    ) -> [pid_t]? {
        errno = 0
        let estimatedCount = list(processGroupID, nil, 0)
        guard estimatedCount >= 0 else { return nil }
        guard estimatedCount > 0 else {
            return errno == 0 ? [] : nil
        }

        var capacity = Int(estimatedCount) + 8
        for _ in 0..<4 {
            var processIDs = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let actualCount = processIDs.withUnsafeMutableBytes { buffer in
                list(processGroupID, buffer.baseAddress, Int32(buffer.count))
            }
            guard actualCount >= 0 else { return nil }
            guard actualCount > 0 || errno == 0 else { return nil }

            let count = Int(actualCount)
            guard count < capacity else {
                capacity = max(capacity * 2, count + 8)
                continue
            }
            return Array(processIDs.prefix(count))
        }
        return nil
    }

    private enum Phase {
        case running
        case exitedUnreaped
        case reapOnly
        case released
    }

    public let processID: pid_t

    private let lock = NSLock()
    private let operations: SystemOperations
    private var phase: Phase = .running

    public convenience init(processID: pid_t) {
        self.init(processID: processID, operations: .live)
    }

    init(processID: pid_t, operations: SystemOperations) {
        precondition(processID > 0)
        self.processID = processID
        self.operations = operations
    }

    /// Waits until the leader exits but deliberately leaves it unreaped.
    @discardableResult
    public func waitForLeaderExit() -> Bool {
        guard lock.withLock({ phase != .released }) else { return false }
        guard operations.waitForExitWithoutReaping(processID) else {
            return lock.withLock {
                guard phase != .released else { return false }
                phase = .reapOnly
                return false
            }
        }
        return lock.withLock {
            guard phase != .released else { return false }
            phase = .exitedUnreaped
            return true
        }
    }

    /// Signals the dedicated group only while this lease still owns its leader PID/PGID.
    @discardableResult
    public func signal(_ signal: Int32) -> Bool {
        lock.withLock {
            guard phase == .running || phase == .exitedUnreaped else { return false }
            return operations.signalGroup(processID, signal)
        }
    }

    /// Returns live descendants, excluding the intentionally retained leader zombie.
    public func remainingMemberPIDs() -> [pid_t]? {
        lock.withLock {
            guard phase == .running || phase == .exitedUnreaped else { return nil }
            return operations.groupMembers(processID)?.filter { $0 > 0 && $0 != processID }
        }
    }

    /// Reaps the leader and permanently releases signal ownership.
    public func reapLeader() -> Int32? {
        lock.withLock {
            guard phase != .released else { return nil }
            let status = operations.reap(processID)
            phase = .released
            return status
        }
    }
}
