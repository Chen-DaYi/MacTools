import MacToolsPluginKit

@MainActor
private final class WeakTrackpadGestureProvider {
    weak var value: (any TrackpadGestureEventProviding)?

    init(_ value: any TrackpadGestureEventProviding) {
        self.value = value
    }
}

@MainActor
private final class WeakTrackpadGestureConsumer {
    weak var value: (any TrackpadGestureEventConsuming)?

    init(_ value: any TrackpadGestureEventConsuming) {
        self.value = value
    }
}

/// Coordinates the single precise-trackpad event provider with plugins that claim gestures.
@MainActor
final class TrackpadGestureBridge {
    private var providerReferences: [WeakTrackpadGestureProvider] = []
    private var consumerReferences: [WeakTrackpadGestureConsumer] = []

    func connect(
        plugins: [any MacToolsPlugin],
        onClaimsChanged: @escaping () -> Void
    ) {
        let providers = plugins.compactMap { $0 as? any TrackpadGestureEventProviding }
        let consumers = plugins.compactMap { $0 as? any TrackpadGestureEventConsuming }

        connect(
            providers: providers,
            consumers: consumers,
            onClaimsChanged: onClaimsChanged
        )
    }

    func connect(
        providers: [any TrackpadGestureEventProviding],
        consumers: [any TrackpadGestureEventConsuming],
        onClaimsChanged: @escaping () -> Void
    ) {
        disconnectRemovedParticipants(providers: providers, consumers: consumers)

        let claims = consumers.reduce(into: Set<TrackpadGesture>()) { $0.formUnion($1.claimedTrackpadGestures) }
        let providerReferences = providers.map(WeakTrackpadGestureProvider.init)
        let consumerReferences = consumers.map(WeakTrackpadGestureConsumer.init)
        self.providerReferences = providerReferences
        self.consumerReferences = consumerReferences

        for consumer in consumers {
            consumer.onTrackpadGestureClaimsChange = onClaimsChanged
            consumer.requestTrackpadGestureOwnership = { gesture in
                providerReferences.compactMap(\.value).forEach { $0.removeLocalMapping(for: gesture) }
            }
        }
        for provider in providers {
            provider.requestTrackpadGestureOwnership = { gesture in
                consumerReferences.compactMap(\.value).forEach { $0.removeTrackpadGestureClaim(for: gesture) }
            }
            provider.setExternalGestureClaims(claims) { gesture, deviceID in
                consumerReferences.compactMap(\.value).first(where: { $0.claimedTrackpadGestures.contains(gesture) })?
                    .receiveTrackpadGesture(gesture, deviceID: deviceID)
            }
        }
    }

    private func disconnectRemovedParticipants(
        providers: [any TrackpadGestureEventProviding],
        consumers: [any TrackpadGestureEventConsuming]
    ) {
        let activeProviderIDs = Set(providers.map { ObjectIdentifier($0) })
        for provider in providerReferences.compactMap(\.value)
        where !activeProviderIDs.contains(ObjectIdentifier(provider)) {
            provider.requestTrackpadGestureOwnership = nil
            provider.setExternalGestureClaims([]) { _, _ in }
        }

        let activeConsumerIDs = Set(consumers.map { ObjectIdentifier($0) })
        for consumer in consumerReferences.compactMap(\.value)
        where !activeConsumerIDs.contains(ObjectIdentifier(consumer)) {
            consumer.onTrackpadGestureClaimsChange = nil
            consumer.requestTrackpadGestureOwnership = nil
        }
    }
}
