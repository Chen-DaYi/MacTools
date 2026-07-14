import Foundation

struct SidecarDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let connectionState: SidecarConnectionState

    init(
        id: String,
        name: String,
        connectionState: SidecarConnectionState = .unknown
    ) {
        self.id = id
        self.name = name
        self.connectionState = connectionState
    }
}

enum SidecarConnectionState: Equatable {
    case unknown
    case disconnected
    case connected
}

enum SidecarServiceAvailability: Equatable {
    case available
    case unsupported(SidecarUnavailableReason)
}

enum SidecarUnavailableReason: Equatable {
    case minimumTestedVersion
    case frameworkLoadFailed
    case missingManager
    case missingTypes
    case managerInitializationFailed
    case missingInterfaces
}

enum SidecarServiceError: Error, Equatable, LocalizedError {
    case unsupported(SidecarUnavailableReason)
    case deviceUnavailable
    case operationUnavailable
    case system(String)

    var errorDescription: String? {
        switch self {
        case let .system(message):
            message
        case let .unsupported(reason):
            reason.errorDescription
        case .deviceUnavailable:
            "Device unavailable"
        case .operationUnavailable:
            "Sidecar operation unavailable"
        }
    }
}

extension SidecarUnavailableReason {
    var errorDescription: String {
        switch self {
        case .minimumTestedVersion:
            "Sidecar is tested on macOS 14.2 or later"
        case .frameworkLoadFailed:
            "SidecarCore cannot be loaded on this system"
        case .missingManager:
            "This system does not provide SidecarDisplayManager"
        case .missingTypes:
            "SidecarCore is missing required types on this system"
        case .managerInitializationFailed:
            "SidecarDisplayManager cannot be started on this system"
        case .missingInterfaces:
            "SidecarCore is missing required interfaces on this system"
        }
    }
}

enum SidecarOperationKind {
    case connect
    case disconnect
    case wiredConnect
}

enum SidecarOperationState {
    case pending(SidecarOperationKind, deviceName: String)
    case succeeded(SidecarOperationKind, deviceName: String)
    case failed(SidecarOperationKind, deviceName: String, message: String)
    case timedOut(SidecarOperationKind, deviceName: String)
}

extension SidecarOperationState {
    var isPending: Bool {
        if case .pending = self {
            return true
        }
        return false
    }
}
