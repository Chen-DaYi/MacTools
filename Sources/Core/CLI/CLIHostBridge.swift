import Combine
import Foundation
import MacToolsCLIProtocol

@MainActor
final class CLIHostBridge: NSObject, CLIHostXPCProtocol {
    private let serviceController: CLIBrokerServiceController
    private let identityValidator = CLIPeerIdentityValidator()
    nonisolated private let callerIsBroker: @Sendable () -> Bool
    nonisolated private let requestState = CLIHostRequestState()
    private var connection: NSXPCConnection?
    private var reconnectTask: Task<Void, Never>?
    private var serviceStatusObservation: AnyCancellable?
    private var isStarted = false
    private lazy var callbackRelay = CLIHostBridgeCallbackRelay { @MainActor [weak self] in
        self?.scheduleReconnect()
    }

    init(
        serviceController: CLIBrokerServiceController = .shared,
        callerIsBroker: @escaping @Sendable () -> Bool = {
            guard let connection = NSXPCConnection.current() else { return false }
            return CLIPeerIdentityValidator().accepts(connection, as: .broker)
        }
    ) {
        self.serviceController = serviceController
        self.callerIsBroker = callerIsBroker
        super.init()
        serviceStatusObservation = serviceController.$status
            .removeDuplicates()
            .sink { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.serviceStatusDidChange(status)
                }
            }
    }

    func start() {
        isStarted = true
        serviceController.reconcileRegisteredService()
        serviceStatusDidChange(serviceController.status)
    }

    func stop() {
        isStarted = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.invalidate()
        connection = nil
    }

    nonisolated func handle(_ requestData: Data, withReply reply: @escaping (Data) -> Void) {
        let reply = CLIHostReply(reply)
        guard callerIsBroker() else {
            reply.call(Data())
            return
        }
        let request: CLIRequestEnvelope
        do {
            request = try CLIProtocolCodec.decodeRequest(
                CLIRequestEnvelope.self,
                from: requestData,
                allowedKeys: ["protocolVersion", "requestID", "operation", "sentAt", "payload"]
            )
        } catch {
            reply.call(Data())
            return
        }
        guard requestState.begin(request.requestID) else {
            reply.call(Self.encodedFailure(
                request: request,
                outcome: .cancelled,
                category: "cancelled",
                message: "The request was cancelled.",
                startedAt: .now
            ))
            return
        }
        Task { @MainActor in
            defer { requestState.finish(request.requestID) }
            let response: Data
            if requestState.isCancelled(request.requestID) {
                response = Self.encodedFailure(
                    request: request,
                    outcome: .cancelled,
                    category: "cancelled",
                    message: "The request was cancelled.",
                    startedAt: .now
                )
            } else {
                response = Self.response(to: request)
            }
            reply.call(response)
        }
    }

    nonisolated func cancel(_ requestID: UUID, withReply reply: @escaping (Bool) -> Void) {
        guard callerIsBroker() else {
            reply(false)
            return
        }
        reply(requestState.cancel(requestID))
    }

    private static func response(to request: CLIRequestEnvelope) -> Data {
        let startedAt = Date()
        guard request.operation == .doctor,
              request.payload == nil,
              (CLIProtocolVersion.minimum...CLIProtocolVersion.current)
                .contains(request.protocolVersion) else {
            return encodedFailure(
                request: request,
                outcome: .protocolIncompatible,
                category: "protocolIncompatible",
                message: "The CLI protocol version or operation is not supported.",
                startedAt: startedAt
            )
        }
        let record = CLIDoctorRecord(
            hostVersion: AppMetadata.shortVersion ?? "unknown",
            hostBuild: AppMetadata.buildNumber ?? "unknown",
            protocolVersion: request.protocolVersion,
            brokerServiceStatus: CLIBrokerServiceController.shared.status.rawValue
        )
        do {
            let payload = try CLIProtocolCodec.encodeResponse(record)
            return try CLIProtocolCodec.encodeResponse(CLIResponseEnvelope(
                protocolVersion: request.protocolVersion,
                requestID: request.requestID,
                operation: request.operation,
                startedAt: startedAt,
                finishedAt: .now,
                outcome: .completed,
                message: nil,
                rejection: nil,
                payload: payload
            ))
        } catch {
            return encodedFailure(
                request: request,
                outcome: .hostUnavailable,
                category: "responseEncodingFailed",
                message: "MacTools could not encode the doctor response.",
                startedAt: startedAt
            )
        }
    }

    private nonisolated static func encodedFailure(
        request: CLIRequestEnvelope,
        outcome: CLIOutcome,
        category: String,
        message: String,
        startedAt: Date
    ) -> Data {
        (try? CLIProtocolCodec.encodeResponse(CLIResponseEnvelope.failure(
            request: request,
            outcome: outcome,
            category: category,
            message: message,
            startedAt: startedAt
        ))) ?? Data()
    }

    private func connect() {
        guard isStarted, serviceController.status == .enabled else { return }
        connection?.invalidate()
        let connection = NSXPCConnection(
            machServiceName: CLIServiceConfiguration.serviceName(
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
        )
        connection.remoteObjectInterface = NSXPCInterface(with: CLIBrokerXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: CLIHostXPCProtocol.self)
        connection.exportedObject = self
        guard identityValidator.configure(connection, toRequire: .broker) else { return }
        connection.invalidationHandler = callbackRelay.makeReconnectHandler()
        connection.interruptionHandler = callbackRelay.makeReconnectHandler()
        connection.activate()
        self.connection = connection

        guard let broker = connection.remoteObjectProxyWithErrorHandler(
            callbackRelay.makeReconnectErrorHandler()
        ) as? CLIBrokerXPCProtocol else {
            scheduleReconnect()
            return
        }
        let registration = CLIHostRegistration(
            minimumProtocolVersion: CLIProtocolVersion.minimum,
            maximumProtocolVersion: CLIProtocolVersion.current,
            hostVersion: AppMetadata.shortVersion ?? "unknown",
            hostBuild: AppMetadata.buildNumber ?? "unknown"
        )
        guard let data = try? CLIProtocolCodec.encodeRequest(registration) else { return }
        broker.registerHost(
            data,
            withReply: callbackRelay.makeRegistrationReplyHandler(for: connection)
        )
    }

    private func scheduleReconnect() {
        guard isStarted, reconnectTask == nil else { return }
        connection?.invalidate()
        connection = nil
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            self?.connect()
        }
    }

    private func serviceStatusDidChange(
        _ status: CLIBrokerServiceController.ServiceStatus
    ) {
        guard isStarted else { return }
        switch status {
        case .enabled:
            if connection == nil { connect() }
        case .requiresApproval, .notRegistered, .notFound, .registrationFailed:
            reconnectTask?.cancel()
            reconnectTask = nil
            connection?.invalidate()
            connection = nil
        }
    }
}

private final class CLIHostReply<Value>: @unchecked Sendable {
    private let closure: (Value) -> Void

    init(_ closure: @escaping (Value) -> Void) {
        self.closure = closure
    }

    func call(_ value: Value) {
        closure(value)
    }
}

final class CLIHostRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = Set<UUID>()
    private var cancelled = Set<UUID>()

    func begin(_ requestID: UUID) -> Bool {
        lock.withLock {
            guard active.count < CLIProtocolVersion.maximumInFlightRequestsGlobally,
                  !active.contains(requestID) else { return false }
            active.insert(requestID)
            return true
        }
    }

    func cancel(_ requestID: UUID) -> Bool {
        lock.withLock {
            guard active.contains(requestID) else { return false }
            cancelled.insert(requestID)
            return true
        }
    }

    func isCancelled(_ requestID: UUID) -> Bool {
        lock.withLock { cancelled.contains(requestID) }
    }

    func finish(_ requestID: UUID) {
        lock.withLock {
            active.remove(requestID)
            cancelled.remove(requestID)
        }
    }
}

final class CLIHostBridgeCallbackRelay: @unchecked Sendable {
    private let reconnect: @MainActor @Sendable () -> Void
    private let connectionIsBroker: @Sendable (NSXPCConnection) -> Bool

    init(
        reconnect: @escaping @MainActor @Sendable () -> Void,
        connectionIsBroker: @escaping @Sendable (NSXPCConnection) -> Bool = {
            CLIPeerIdentityValidator().accepts($0, as: .broker)
        }
    ) {
        self.reconnect = reconnect
        self.connectionIsBroker = connectionIsBroker
    }

    nonisolated func makeReconnectHandler() -> @Sendable () -> Void {
        { [weak self] in self?.requestReconnect() }
    }

    nonisolated func makeReconnectErrorHandler() -> @Sendable (Error) -> Void {
        { [weak self] _ in self?.requestReconnect() }
    }

    nonisolated func makeRegistrationReplyHandler(
        for connection: NSXPCConnection
    ) -> @Sendable (Data) -> Void {
        let reference = CLIHostXPCConnectionReference(connection)
        return { [weak self, reference, connectionIsBroker] response in
            guard let connection = reference.connection,
                  connectionIsBroker(connection),
                  let handshake = try? CLIProtocolCodec.decodeResponse(
                    CLIHandshakeResponse.self,
                    from: response,
                    allowedKeys: [
                        "selectedProtocolVersion", "brokerVersion", "brokerBuild",
                        "hostVersion", "hostBuild", "hostReady", "message",
                    ]
                  ),
                  (try? CLIProtocolSemanticValidator.validate(handshake: handshake)) != nil
            else {
                self?.requestReconnect()
                return
            }
            if handshake.hostReady {
                guard handshake.selectedProtocolVersion != nil else {
                    self?.requestReconnect()
                    return
                }
            } else if handshake.hostVersion == nil {
                self?.requestReconnect()
            }
        }
    }

    nonisolated func requestReconnect() {
        let reconnect = reconnect
        Task { @MainActor in reconnect() }
    }
}

private final class CLIHostXPCConnectionReference: @unchecked Sendable {
    weak var connection: NSXPCConnection?

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
