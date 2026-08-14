import Foundation
import MacToolsPluginKit

@MainActor
final class TrackpadGestureOwnershipStore {
    enum OwnerKind: String {
        case provider
        case consumer
    }

    private enum StorageKey {
        static let owners = "trackpad.gesture.owners"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func owner(for gesture: TrackpadGesture) -> OwnerKind? {
        userDefaults.string(forKey: storageKey(for: gesture)).flatMap(OwnerKind.init(rawValue:))
    }

    func setOwner(_ owner: OwnerKind?, for gesture: TrackpadGesture) {
        userDefaults.set(owner?.rawValue, forKey: storageKey(for: gesture))
    }

    private func storageKey(for gesture: TrackpadGesture) -> String {
        "\(StorageKey.owners).\(gesture.rawValue)"
    }
}
