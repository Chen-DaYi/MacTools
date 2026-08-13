import MacToolsPluginKit

/// Coordinates the single precise-trackpad event provider with plugins that claim gestures.
@MainActor
final class TrackpadGestureBridge {
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
        let claims = consumers.reduce(into: Set<TrackpadGesture>()) { $0.formUnion($1.claimedTrackpadGestures) }

        for consumer in consumers {
            consumer.onTrackpadGestureClaimsChange = onClaimsChanged
            consumer.requestTrackpadGestureOwnership = { gesture in
                providers.forEach { $0.removeLocalMapping(for: gesture) }
            }
        }
        for provider in providers {
            provider.requestTrackpadGestureOwnership = { gesture in
                consumers.forEach { $0.removeTrackpadGestureClaim(for: gesture) }
            }
            provider.setExternalGestureClaims(claims) { gesture, deviceID in
                consumers.first(where: { $0.claimedTrackpadGestures.contains(gesture) })?
                    .receiveTrackpadGesture(gesture, deviceID: deviceID)
            }
        }
    }
}
