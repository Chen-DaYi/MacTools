import CoreFoundation
import Foundation

enum AppInstanceLaunchDisposition: Equatable {
    case primary
    case secondary(AppInstanceForwardingResult)
}

enum AppInstanceForwardingResult: Equatable {
    case acknowledged
    case timedOut
    case rejected
}

enum AppInstanceResponse: String, Codable, Equatable {
    case accepted
    case notReady
    case unsupported
    case invalid
}

struct AppInstanceCommand: Codable, Equatable {
    let version: Int
    let command: String
    let requestID: UUID

    static let currentVersion = 1
    static let showSettings = "show-settings"
    static let maximumPayloadSize = 1_024

    static func showSettingsRequest() -> Self {
        Self(
            version: currentVersion,
            command: showSettings,
            requestID: UUID()
        )
    }

    var isSupported: Bool {
        version == Self.currentVersion && command == Self.showSettings
    }
}

final class AppInstanceCoordinator {
    private static let messageID: Int32 = 1
    private static let sendTimeout: CFTimeInterval = 0.5
    private static let receiveTimeout: CFTimeInterval = 0.5
    private static let forwardingTimeout: TimeInterval = 2
    private static let retryDelay: TimeInterval = 0.1

    private let portName: String
    private let callbackBox: CallbackBox
    private var localPort: CFMessagePort?

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        let identifier = bundleIdentifier ?? "com.example.mactools"
        portName = "\(identifier).instance-coordination.v1"
        callbackBox = CallbackBox()
    }

    deinit {
        invalidate()
    }

    func setCommandHandler(_ handler: @escaping () -> AppInstanceResponse) {
        callbackBox.setHandler(handler)
    }

    func acquireOrForwardSettingsRequest() -> AppInstanceLaunchDisposition {
        if registerLocalPortIfPossible() {
            AppLog.instanceCoordination.debug("Elected primary instance")
            return .primary
        }

        let deadline = Date().addingTimeInterval(Self.forwardingTimeout)
        var lastResult: AppInstanceForwardingResult = .timedOut

        while Date() < deadline {
            switch forwardSettingsRequest() {
            case .accepted:
                AppLog.instanceCoordination.debug("Forwarded settings recovery request")
                return .secondary(.acknowledged)
            case .notReady:
                lastResult = .timedOut
            case .invalidPort:
                if registerLocalPortIfPossible() {
                    AppLog.instanceCoordination.notice("Recovered primary ownership after an invalid port")
                    return .primary
                }
                lastResult = .timedOut
            case .rejected:
                AppLog.instanceCoordination.error("Settings recovery request was rejected")
                return .secondary(.rejected)
            }

            RunLoop.current.run(until: Date().addingTimeInterval(Self.retryDelay))
        }

        AppLog.instanceCoordination.error("Timed out forwarding settings recovery request")
        return .secondary(lastResult)
    }

    func invalidate() {
        guard let localPort else { return }
        CFMessagePortInvalidate(localPort)
        self.localPort = nil
        AppLog.instanceCoordination.debug("Invalidated primary instance port")
    }

    private func registerLocalPortIfPossible() -> Bool {
        guard localPort == nil else { return true }

        var shouldFreeInfo = DarwinBoolean(false)
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        guard let port = CFMessagePortCreateLocal(
            kCFAllocatorDefault,
            portName as CFString,
            Self.receiveMessage,
            &context,
            &shouldFreeInfo
        ) else {
            AppLog.instanceCoordination.error("Unable to create instance coordination port")
            return false
        }

        guard !shouldFreeInfo.boolValue else {
            return false
        }

        CFMessagePortSetDispatchQueue(port, DispatchQueue.main)
        localPort = port
        return true
    }

    private func forwardSettingsRequest() -> ForwardingAttempt {
        guard let remotePort = CFMessagePortCreateRemote(kCFAllocatorDefault, portName as CFString) else {
            return .invalidPort
        }

        let command = AppInstanceCommand.showSettingsRequest()
        guard let data = try? JSONEncoder().encode(command) else {
            return .rejected
        }

        var returnedData: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(
            remotePort,
            Self.messageID,
            data as CFData,
            Self.sendTimeout,
            Self.receiveTimeout,
            CFRunLoopMode.defaultMode.rawValue,
            &returnedData
        )

        guard result == kCFMessagePortSuccess else {
            return .invalidPort
        }
        guard let returnedData else {
            return .rejected
        }

        let responseData = returnedData.takeRetainedValue() as Data
        guard let response = try? JSONDecoder().decode(AppInstanceResponse.self, from: responseData) else {
            return .rejected
        }

        switch response {
        case .accepted:
            return .accepted
        case .notReady:
            return .notReady
        case .unsupported, .invalid:
            return .rejected
        }
    }

    private static let receiveMessage: CFMessagePortCallBack = { _, messageID, data, info in
        guard messageID == AppInstanceCoordinator.messageID, let data, let info else {
            return AppInstanceCoordinator.encodedResponse(.invalid)
        }

        let callbackBox = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        return AppInstanceCoordinator.encodedResponse(callbackBox.response(for: data as Data))
    }

    private static func encodedResponse(_ response: AppInstanceResponse) -> Unmanaged<CFData>? {
        guard let data = try? JSONEncoder().encode(response) else { return nil }
        return Unmanaged.passRetained(data as CFData)
    }
}

private enum ForwardingAttempt {
    case accepted
    case notReady
    case invalidPort
    case rejected
}

private final class CallbackBox {
    private let lock = NSLock()
    private var handler: (() -> AppInstanceResponse)?
    private var acceptedRequestIdentifiers = Set<UUID>()

    func setHandler(_ handler: @escaping () -> AppInstanceResponse) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func response(for data: Data) -> AppInstanceResponse {
        guard
            data.count <= AppInstanceCommand.maximumPayloadSize,
            let command = try? JSONDecoder().decode(AppInstanceCommand.self, from: data),
            command.isSupported
        else {
            return .invalid
        }

        lock.lock()
        defer { lock.unlock() }

        if acceptedRequestIdentifiers.contains(command.requestID) {
            return .accepted
        }

        let response = handler?() ?? .notReady
        if response == .accepted {
            acceptedRequestIdentifiers.insert(command.requestID)
        }
        return response
    }
}
