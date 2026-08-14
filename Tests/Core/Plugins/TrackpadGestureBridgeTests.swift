import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class TrackpadGestureBridgeTests: XCTestCase {
    func testBridgeRoutesClaimsAndLetsTheLastEditedPluginTakeOwnershipWithoutDeletingMappings() {
        let bridge = TrackpadGestureBridge(ownershipStore: makeOwnershipStore())
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

        provider.addLocalMapping(.threeFingerTap)
        XCTAssertEqual(provider.localMappings, [.threeFingerTap])
        XCTAssertEqual(consumer.claimedTrackpadGestures, [.threeFingerTap])
        XCTAssertEqual(provider.externalClaims, [])
        XCTAssertEqual(consumer.ownedGestures, [])
        XCTAssertEqual(claimChanges, 1)
    }

    func testBridgeDoesNotRetainProviderAndConsumerThroughCallbacks() {
        weak var weakProvider: ProviderSpy?
        weak var weakConsumer: ConsumerSpy?

        do {
            let bridge = TrackpadGestureBridge(ownershipStore: makeOwnershipStore())
            let provider = ProviderSpy()
            let consumer = ConsumerSpy(claims: [.threeFingerTap])
            weakProvider = provider
            weakConsumer = consumer
            bridge.connect(providers: [provider], consumers: [consumer], onClaimsChanged: {})
        }

        XCTAssertNil(weakProvider)
        XCTAssertNil(weakConsumer)
    }

    func testBridgeRestoresTheMostRecentOwnerAfterRestart() {
        let suiteName = "TrackpadGestureBridgeTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = TrackpadGestureOwnershipStore(userDefaults: userDefaults)
        let bridge = TrackpadGestureBridge(ownershipStore: store)
        let provider = ProviderSpy()
        let consumer = ConsumerSpy(claims: [.threeFingerTap])
        bridge.connect(providers: [provider], consumers: [consumer], onClaimsChanged: {})
        consumer.claim(.threeFingerTap)

        let restoredBridge = TrackpadGestureBridge(ownershipStore: store)
        let restoredProvider = ProviderSpy()
        let restoredConsumer = ConsumerSpy(claims: [.threeFingerTap])
        restoredBridge.connect(
            providers: [restoredProvider],
            consumers: [restoredConsumer],
            onClaimsChanged: {}
        )

        XCTAssertEqual(restoredProvider.externalClaims, [.threeFingerTap])
        XCTAssertEqual(restoredConsumer.ownedGestures, [.threeFingerTap])
    }

    func testBridgeDisconnectsParticipantsRemovedByAPluginReload() {
        let bridge = TrackpadGestureBridge(ownershipStore: makeOwnershipStore())
        let provider = ProviderSpy()
        let consumer = ConsumerSpy(claims: [.threeFingerTap])
        bridge.connect(providers: [provider], consumers: [consumer], onClaimsChanged: {})

        bridge.connect(providers: [], consumers: [], onClaimsChanged: {})

        XCTAssertNil(provider.requestTrackpadGestureOwnership)
        XCTAssertNil(provider.onTrackpadGestureRequestsChange)
        XCTAssertEqual(provider.externalClaims, [])
        XCTAssertNil(consumer.onTrackpadGestureClaimsChange)
        XCTAssertNil(consumer.requestTrackpadGestureOwnership)
    }

    private func makeOwnershipStore() -> TrackpadGestureOwnershipStore {
        TrackpadGestureOwnershipStore(
            userDefaults: UserDefaults(suiteName: "TrackpadGestureBridgeTests-\(UUID().uuidString)")!
        )
    }
}

@MainActor
private final class ProviderSpy: TrackpadGestureEventProviding {
    private(set) var externalClaims: Set<TrackpadGesture> = []
    private(set) var localMappings: Set<TrackpadGesture> = []
    private(set) var ownedLocalGestures: Set<TrackpadGesture> = []
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?
    var onTrackpadGestureRequestsChange: (() -> Void)?
    private var handler: ((TrackpadGesture, UInt64) -> Void)?

    var requestedTrackpadGestures: Set<TrackpadGesture> { localMappings }

    func setTrackpadGestureOwnership(
        localGestures: Set<TrackpadGesture>,
        externalGestures: Set<TrackpadGesture>,
        handler: @escaping (TrackpadGesture, UInt64) -> Void
    ) {
        ownedLocalGestures = localGestures
        externalClaims = externalGestures
        self.handler = handler
    }

    func deliver(_ gesture: TrackpadGesture, deviceID: UInt64) {
        handler?(gesture, deviceID)
    }

    func addLocalMapping(_ gesture: TrackpadGesture) {
        localMappings.insert(gesture)
        requestTrackpadGestureOwnership?(gesture)
        onTrackpadGestureRequestsChange?()
    }
}

@MainActor
private final class ConsumerSpy: TrackpadGestureEventConsuming {
    private(set) var claimedTrackpadGestures: Set<TrackpadGesture>
    var onTrackpadGestureClaimsChange: (() -> Void)?
    var requestTrackpadGestureOwnership: ((TrackpadGesture) -> Void)?
    private(set) var ownedGestures: Set<TrackpadGesture> = []
    private(set) var receivedGestures: [TrackpadGesture] = []
    private(set) var receivedDeviceIDs: [UInt64] = []

    init(claims: Set<TrackpadGesture>) {
        claimedTrackpadGestures = claims
    }

    func receiveTrackpadGesture(_ gesture: TrackpadGesture, deviceID: UInt64) {
        receivedGestures.append(gesture)
        receivedDeviceIDs.append(deviceID)
    }

    func setOwnedTrackpadGestures(_ gestures: Set<TrackpadGesture>) {
        ownedGestures = gestures
    }

    func claim(_ gesture: TrackpadGesture) {
        requestTrackpadGestureOwnership?(gesture)
    }
}
