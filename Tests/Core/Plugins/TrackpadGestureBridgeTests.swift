import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class TrackpadGestureBridgeTests: XCTestCase {
    func testBridgeRoutesClaimsAndLetsTheLastEditedPluginTakeOwnership() {
        let bridge = TrackpadGestureBridge()
        let provider = ProviderSpy()
        let consumer = ConsumerSpy(claims: [.threeFingerTap])
        var claimChanges = 0
        var reconnect: (() -> Void)!

        reconnect = {
            bridge.connect(
                providers: [provider],
                consumers: [consumer],
                onClaimsChanged: {
                    claimChanges += 1
                    reconnect()
                }
            )
        }
        reconnect()

        XCTAssertEqual(provider.externalClaims, [.threeFingerTap])
        provider.deliver(.threeFingerTap, deviceID: 42)
        XCTAssertEqual(consumer.receivedGestures, [.threeFingerTap])
        XCTAssertEqual(consumer.receivedDeviceIDs, [42])

        consumer.requestTrackpadGestureOwnership?(.fourFingerTap)
        XCTAssertEqual(provider.removedLocalMappings, [.fourFingerTap])

        provider.addLocalMapping(.threeFingerTap)
        XCTAssertEqual(provider.localMappings, [.threeFingerTap])
        XCTAssertEqual(consumer.claimedTrackpadGestures, [])
        XCTAssertEqual(consumer.removedClaims, [.threeFingerTap])
        XCTAssertEqual(provider.externalClaims, [])
        XCTAssertEqual(claimChanges, 1)
    }
}

@MainActor
private final class ProviderSpy: TrackpadGestureEventProviding {
    private(set) var externalClaims: Set<TrackpadGesture> = []
    private(set) var removedLocalMappings: [TrackpadGesture] = []
    private(set) var localMappings: Set<TrackpadGesture> = []
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?
    private var handler: ((TrackpadGesture, UInt64) -> Void)?

    func setExternalGestureClaims(
        _ gestures: Set<TrackpadGesture>,
        handler: @escaping (TrackpadGesture, UInt64) -> Void
    ) {
        externalClaims = gestures
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
        requestTrackpadGestureOwnership?(gesture)
    }
}

@MainActor
private final class ConsumerSpy: TrackpadGestureEventConsuming {
    private(set) var claimedTrackpadGestures: Set<TrackpadGesture>
    var onTrackpadGestureClaimsChange: (() -> Void)?
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?
    private(set) var removedClaims: [TrackpadGesture] = []
    private(set) var receivedGestures: [TrackpadGesture] = []
    private(set) var receivedDeviceIDs: [UInt64] = []

    init(claims: Set<TrackpadGesture>) {
        claimedTrackpadGestures = claims
    }

    func receiveTrackpadGesture(_ gesture: TrackpadGesture, deviceID: UInt64) {
        receivedGestures.append(gesture)
        receivedDeviceIDs.append(deviceID)
    }

    func removeTrackpadGestureClaim(for gesture: TrackpadGesture) {
        guard claimedTrackpadGestures.remove(gesture) != nil else { return }
        removedClaims.append(gesture)
        onTrackpadGestureClaimsChange?()
    }
}
