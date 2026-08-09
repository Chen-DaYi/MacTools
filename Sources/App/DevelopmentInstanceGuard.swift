import AppKit
import Darwin
import Foundation
import OSLog

enum DevelopmentInstanceLockResult: Equatable {
    case acquired
    case ownedByOtherProcess
    case unavailable
}

protocol DevelopmentInstanceLocking: AnyObject {
    func tryAcquire(identifier: String) -> DevelopmentInstanceLockResult
    func release()
}

final class DevelopmentInstanceFileLock: DevelopmentInstanceLocking {
    private var fileDescriptor: Int32 = -1

    func tryAcquire(identifier: String) -> DevelopmentInstanceLockResult {
        if fileDescriptor >= 0 {
            return .acquired
        }

        let safeIdentifier = identifier.map { character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character
                : "-"
        }
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(safeIdentifier) + ".instance.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            AppLog.developmentInstance.error(
                "Failed to open development instance lock at \(lockURL.path, privacy: .public)"
            )
            return .unavailable
        }

        _ = Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var lock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            Darwin.close(descriptor)
            return .ownedByOtherProcess
        }

        fileDescriptor = descriptor
        return .acquired
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        var lock = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_UNLCK),
            l_whence: Int16(SEEK_SET)
        )
        _ = Darwin.fcntl(fileDescriptor, F_SETLK, &lock)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    deinit {
        release()
    }
}

@MainActor
final class DevelopmentInstanceGuard {
    static let allowMultipleInstancesEnvironmentKey =
        "MACTOOLS_ALLOW_MULTIPLE_DEBUG_INSTANCES"

    private let lock: any DevelopmentInstanceLocking
    private let environment: [String: String]
    private let processIdentifier: pid_t
    private let activateExistingInstance: @MainActor (String, pid_t) -> Void
    private var holdsLock = false
    private(set) var ownsInstance = false

    init(
        lock: any DevelopmentInstanceLocking = DevelopmentInstanceFileLock(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        activateExistingInstance: @escaping @MainActor (String, pid_t) -> Void =
            DevelopmentInstanceGuard.activateExistingApplication
    ) {
        self.lock = lock
        self.environment = environment
        self.processIdentifier = processIdentifier
        self.activateExistingInstance = activateExistingInstance
    }

    func claim(bundleIdentifier: String?) -> Bool {
        guard shouldEnforceSingleton else {
            ownsInstance = true
            return true
        }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            AppLog.developmentInstance.error(
                "Development singleton disabled because the app has no bundle identifier"
            )
            ownsInstance = true
            return true
        }
        switch lock.tryAcquire(identifier: bundleIdentifier) {
        case .acquired:
            holdsLock = true
            ownsInstance = true
            return true
        case .ownedByOtherProcess:
            AppLog.developmentInstance.notice(
                "Another development app instance owns \(bundleIdentifier, privacy: .public)"
            )
            activateExistingInstance(bundleIdentifier, processIdentifier)
            return false
        case .unavailable:
            AppLog.developmentInstance.error(
                "Development singleton lock is unavailable; continuing without the lock"
            )
            ownsInstance = true
            return true
        }
    }

    func release() {
        guard ownsInstance else { return }
        if holdsLock {
            lock.release()
            holdsLock = false
        }
        ownsInstance = false
    }

    private var shouldEnforceSingleton: Bool {
        environment[Self.allowMultipleInstancesEnvironmentKey] != "1"
            && environment["XCTestConfigurationFilePath"] == nil
            && environment["XCTestSessionIdentifier"] == nil
            && environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
    }

    private static func activateExistingApplication(
        bundleIdentifier: String,
        currentProcessIdentifier: pid_t
    ) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentProcessIdentifier }?
            .activate(options: [.activateAllWindows])
    }
}
