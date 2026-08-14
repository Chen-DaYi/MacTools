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
    private enum Owner: Equatable {
        case provider(ObjectIdentifier)
        case consumer(ObjectIdentifier)
    }

    private var providerReferences: [WeakTrackpadGestureProvider] = []
    private var consumerReferences: [WeakTrackpadGestureConsumer] = []
    private var owners: [TrackpadGesture: Owner] = [:]

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

        let providerReferences = providers.map(WeakTrackpadGestureProvider.init)
        let consumerReferences = consumers.map(WeakTrackpadGestureConsumer.init)
        self.providerReferences = providerReferences
        self.consumerReferences = consumerReferences

        for consumer in consumers {
            consumer.onTrackpadGestureClaimsChange = onClaimsChanged
            consumer.requestTrackpadGestureOwnership = { [weak self, weak consumer] gesture in
                guard let self, let consumer else { return }
                let providers = self.providerReferences.compactMap(\.value)
                let consumers = self.consumerReferences.compactMap(\.value)
                self.owners[gesture] = .consumer(ObjectIdentifier(consumer))
                self.applyOwnership(providers: providers, consumers: consumers)
            }
        }
        for provider in providers {
            provider.onTrackpadGestureRequestsChange = onClaimsChanged
            provider.requestTrackpadGestureOwnership = { [weak self, weak provider] gesture in
                guard let self, let provider else { return }
                let providers = self.providerReferences.compactMap(\.value)
                let consumers = self.consumerReferences.compactMap(\.value)
                self.owners[gesture] = .provider(ObjectIdentifier(provider))
                self.applyOwnership(providers: providers, consumers: consumers)
            }
        }
        applyOwnership(providers: providers, consumers: consumers)
    }

    private func applyOwnership(
        providers: [any TrackpadGestureEventProviding],
        consumers: [any TrackpadGestureEventConsuming]
    ) {
        let requestedGestures = providers.reduce(into: Set<TrackpadGesture>()) { $0.formUnion($1.requestedTrackpadGestures) }
            .union(consumers.reduce(into: Set<TrackpadGesture>()) { $0.formUnion($1.claimedTrackpadGestures) })
        owners = owners.filter { gesture, owner in
            requestedGestures.contains(gesture)
                && participant(owner, requests: gesture, providers: providers, consumers: consumers)
        }

        for gesture in requestedGestures where owners[gesture] == nil {
            if let provider = providers.first(where: { $0.requestedTrackpadGestures.contains(gesture) }) {
                owners[gesture] = .provider(ObjectIdentifier(provider))
            } else if let consumer = consumers.first(where: { $0.claimedTrackpadGestures.contains(gesture) }) {
                owners[gesture] = .consumer(ObjectIdentifier(consumer))
            }
        }

        for provider in providers {
            let providerID = ObjectIdentifier(provider)
            let localGestures = Set(owners.compactMap { gesture, owner in
                owner == .provider(providerID) ? gesture : nil
            })
            let externalGestures = Set(owners.compactMap { gesture, owner in
                if case .consumer = owner { return gesture }
                return nil
            })
            provider.setTrackpadGestureOwnership(
                localGestures: localGestures,
                externalGestures: externalGestures
            ) { [weak self] gesture, deviceID in
                guard let self,
                      case let .consumer(ownerID)? = self.owners[gesture]
                else { return }
                self.consumerReferences.compactMap(\.value).first(where: { ObjectIdentifier($0) == ownerID })?
                    .receiveTrackpadGesture(gesture, deviceID: deviceID)
            }
        }
        for consumer in consumers {
            let consumerID = ObjectIdentifier(consumer)
            consumer.setOwnedTrackpadGestures(Set(owners.compactMap { gesture, owner in
                owner == .consumer(consumerID) ? gesture : nil
            }))
        }
    }

    private func participant(
        _ owner: Owner,
        requests gesture: TrackpadGesture,
        providers: [any TrackpadGestureEventProviding],
        consumers: [any TrackpadGestureEventConsuming]
    ) -> Bool {
        switch owner {
        case let .provider(id): providers.contains { ObjectIdentifier($0) == id && $0.requestedTrackpadGestures.contains(gesture) }
        case let .consumer(id): consumers.contains { ObjectIdentifier($0) == id && $0.claimedTrackpadGestures.contains(gesture) }
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
            provider.onTrackpadGestureRequestsChange = nil
            provider.setTrackpadGestureOwnership(localGestures: [], externalGestures: []) { _, _ in }
        }

        let activeConsumerIDs = Set(consumers.map { ObjectIdentifier($0) })
        for consumer in consumerReferences.compactMap(\.value)
        where !activeConsumerIDs.contains(ObjectIdentifier(consumer)) {
            consumer.onTrackpadGestureClaimsChange = nil
            consumer.requestTrackpadGestureOwnership = nil
            consumer.setOwnedTrackpadGestures([])
        }
    }
}
