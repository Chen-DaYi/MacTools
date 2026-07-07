import Darwin
import Foundation
import MacToolsPluginKit

protocol ActivityBarSocketServing: AnyObject {
    var isRunning: Bool { get }

    func start() throws
    func stop()
}

enum ActivityBarSocketError: LocalizedError, Equatable {
    case pathTooLong(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    var errorDescription: String? {
        localizedDescription(localization: PluginLocalization(bundle: .main))
    }

    func localizedDescription(localization: PluginLocalization) -> String {
        switch self {
        case let .pathTooLong(path):
            return localization.format("error.socket.pathTooLong", defaultValue: "Socket 路径过长：%@", path)
        case let .socketFailed(code):
            return localization.format("error.socket.createFailed", defaultValue: "创建 Socket 失败：%d", code)
        case let .bindFailed(code):
            return localization.format("error.socket.bindFailed", defaultValue: "绑定 Socket 失败：%d", code)
        case let .listenFailed(code):
            return localization.format("error.socket.listenFailed", defaultValue: "监听 Socket 失败：%d", code)
        }
    }
}

final class ActivityBarHookSocketServer: ActivityBarSocketServing, @unchecked Sendable {
    private let socketPath: String
    private let onEvent: @MainActor (ActivityBarHookEvent) -> Void
    private let stateLock = NSLock()
    private var serverFD: Int32 = -1
    private var running = false

    var isRunning: Bool {
        stateLock.withLock { running }
    }

    init(
        socketPath: String = ActivityBarConstants.defaultSocketPath,
        onEvent: @escaping @MainActor (ActivityBarHookEvent) -> Void
    ) {
        self.socketPath = socketPath
        self.onEvent = onEvent
    }

    func start() throws {
        guard !isRunning else {
            return
        }

        removeSocketFile()

        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw ActivityBarSocketError.socketFailed(errno)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < maxPathLength else {
            close(fileDescriptor)
            throw ActivityBarSocketError.pathTooLong(socketPath)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for index in 0..<pathBytes.count {
                buffer[index] = UInt8(bitPattern: pathBytes[index])
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            let code = errno
            close(fileDescriptor)
            throw ActivityBarSocketError.bindFailed(code)
        }

        guard listen(fileDescriptor, 5) == 0 else {
            let code = errno
            close(fileDescriptor)
            throw ActivityBarSocketError.listenFailed(code)
        }

        let flags = fcntl(fileDescriptor, F_GETFL)
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)

        stateLock.withLock {
            serverFD = fileDescriptor
            running = true
        }

        ActivityBarLog.socket.info("Activity bar socket listening at \(self.socketPath, privacy: .public)")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        let fileDescriptor = stateLock.withLock { () -> Int32 in
            running = false
            let fd = serverFD
            serverFD = -1
            return fd
        }

        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }

        removeSocketFile()
    }

    private func acceptLoop() {
        while stateLock.withLock({ running }) {
            var clientAddress = sockaddr_un()
            var clientLength = socklen_t(MemoryLayout<sockaddr_un>.size)
            let fd = stateLock.withLock { serverFD }

            guard fd >= 0 else {
                return
            }

            let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    accept(fd, socketAddress, &clientLength)
                }
            }

            if clientFD >= 0 {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.handleClient(clientFD)
                }
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                Thread.sleep(forTimeInterval: 0.05)
            } else if stateLock.withLock({ running }) {
                ActivityBarLog.socket.error("Activity bar socket accept failed: \(errno)")
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private func handleClient(_ fileDescriptor: Int32) {
        defer {
            close(fileDescriptor)
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var data = Data()
        let bufferSize = 8_192
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
        }

        while true {
            let bytesRead = read(fileDescriptor, buffer, bufferSize)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            } else {
                break
            }
        }

        guard !data.isEmpty else {
            return
        }

        do {
            let event = try JSONDecoder().decode(ActivityBarHookEvent.self, from: data)
            let callback = onEvent
            Task { @MainActor in
                callback(event)
            }
        } catch {
            ActivityBarLog.socket.error("Activity bar hook decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeSocketFile() {
        unlink(socketPath)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer {
            unlock()
        }

        return try body()
    }
}
