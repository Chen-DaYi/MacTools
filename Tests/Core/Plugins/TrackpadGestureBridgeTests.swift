import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class TrackpadGestureBridgeTests: XCTestCase {
    func testBridgeRoutesClaimsAndRemovesConflictingLocalMappings() {
        let bridge = TrackpadGestureBridge()
        let provider = ProviderSpy()
        let consumer = ConsumerSpy(claims: [.threeFingerTap])
        var claimChanges = 0

        bridge.connect(
            providers: [provider],
            consumers: [consumer],
            onClaimsChanged: { claimChanges += 1 }
        )

        XCTAssertEqual(provider.externalClaims, [.threeFingerTap])
        provider.deliver(.threeFingerTap, deviceID: 42)
        XCTAssertEqual(consumer.receivedGestures, [.threeFingerTap])
        XCTAssertEqual(consumer.receivedDeviceIDs, [42])

        consumer.requestTrackpadGestureOwnership?(.fourFingerTap)
        XCTAssertEqual(provider.removedLocalMappings, [.fourFingerTap])

        provider.addLocalMapping(.threeFingerTap)
        XCTAssertEqual(provider.localMappings, [])
        XCTAssertEqual(provider.removedLocalMappings, [.fourFingerTap, .threeFingerTap])

        consumer.onTrackpadGestureClaimsChange?()
        XCTAssertEqual(claimChanges, 2)
    }
}

@MainActor
private final class ProviderSpy: TrackpadGestureEventProviding {
    private(set) var externalClaims: Set<TrackpadGesture> = []
    private(set) var removedLocalMappings: [TrackpadGesture] = []
    private(set) var localMappings: Set<TrackpadGesture> = []
    var onTrackpadGestureMappingsChange: (() -> Void)?
    private var handler: ((TrackpadGesture, UInt64) -> Void)?

    func setExternalGestureClaims(
        _ gestures: Set<TrackpadGesture>,
        handler: @escaping (TrackpadGesture, UInt64) -> Void
    ) {
        externalClaims = gestures
        let conflicts = localMappings.intersection(gestures)
        conflicts.forEach { removeLocalMapping(for: $0) }
        self.handler = handler
    }

    func removeLocalMapping(for gesture: TrackpadGesture) {
        removedLocalMappings.append(gesture)
        localMappings.remove(gesture)
    }

    func deliver(_ gesture: TrackpadGesture, deviceID: UInt64) {
        handler?(gesture, deviceID)
    }

    func addLocalMapping(_ gesture: TrackpadGesture) {
        localMappings.insert(gesture)
        onTrackpadGestureMappingsChange?()
    }
}

@MainActor
private final class ConsumerSpy: TrackpadGestureEventConsuming {
    let claimedTrackpadGestures: Set<TrackpadGesture>
    var onTrackpadGestureClaimsChange: (() -> Void)?
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?
    private(set) var receivedGestures: [TrackpadGesture] = []
    private(set) var receivedDeviceIDs: [UInt64] = []

    init(claims: Set<TrackpadGesture>) {
        claimedTrackpadGestures = claims
    }

    func receiveTrackpadGesture(_ gesture: TrackpadGesture, deviceID: UInt64) {
        receivedGestures.append(gesture)
        receivedDeviceIDs.append(deviceID)
    }
}
