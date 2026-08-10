import CoreAudio
import Foundation

struct AudioApplication: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let processObjectIDs: [AudioObjectID]
}

struct AudioApplicationSnapshot: Equatable, Sendable {
    let applications: [AudioApplication]
    let outputDeviceUID: String?

    static let empty = AudioApplicationSnapshot(applications: [], outputDeviceUID: nil)
}

struct ApplicationVolumeTarget: Equatable, Sendable {
    let id: String
    let processObjectIDs: [AudioObjectID]
    let gain: Double
}

enum ApplicationVolumeRouteResult: Equatable, Sendable {
    case succeeded
    case failed
}

@MainActor
protocol AudioApplicationMonitoring: AnyObject {
    var onUpdate: ((AudioApplicationSnapshot) -> Void)? { get set }

    func start()
    func refresh()
    func stop()
}

@MainActor
protocol ApplicationVolumeRouting: AnyObject {
    var isSupported: Bool { get }

    func update(targets: [ApplicationVolumeTarget], outputDeviceUID: String?)
    func applyAndWait(
        targets: [ApplicationVolumeTarget],
        outputDeviceUID: String?
    ) async -> ApplicationVolumeRouteResult
    func requestSystemAudioAccess() async -> Bool
    func stop()
}

extension ApplicationVolumeRouting {
    func applyAndWait(
        targets: [ApplicationVolumeTarget],
        outputDeviceUID: String?
    ) async -> ApplicationVolumeRouteResult {
        update(targets: targets, outputDeviceUID: outputDeviceUID)
        await Task.yield()
        return .succeeded
    }
}

enum AppVolumeAccessState: Equatable {
    case unknown
    case requesting
    case granted
    case denied
}
