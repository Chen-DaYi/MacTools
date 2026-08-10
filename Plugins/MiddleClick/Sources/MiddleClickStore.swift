import Foundation
import MacToolsPluginKit

@MainActor
final class MiddleClickStore {
    private enum StorageKey {
        static let isEnabled = "middle-click.enabled"
        static let requiredFingerCount = "middle-click.required-finger-count"
    }

    private(set) var isEnabled: Bool
    private(set) var requiredFingerCount: Int

    private let storage: any PluginStorage

    init(storage: any PluginStorage) {
        self.storage = storage

        storage.migrateValueIfNeeded(
            fromLegacyKey: StorageKey.isEnabled,
            to: StorageKey.isEnabled
        )
        storage.migrateValueIfNeeded(
            fromLegacyKey: StorageKey.requiredFingerCount,
            to: StorageKey.requiredFingerCount
        )

        isEnabled = storage.bool(forKey: StorageKey.isEnabled)
        if storage.object(forKey: StorageKey.requiredFingerCount) == nil {
            requiredFingerCount = 3
        } else {
            requiredFingerCount = Self.normalizedFingerCount(
                storage.integer(forKey: StorageKey.requiredFingerCount)
            )
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        guard self.isEnabled != isEnabled else { return }
        self.isEnabled = isEnabled
        storage.set(isEnabled, forKey: StorageKey.isEnabled)
    }

    func setRequiredFingerCount(_ count: Int) {
        let normalizedCount = Self.normalizedFingerCount(count)
        guard requiredFingerCount != normalizedCount else { return }
        requiredFingerCount = normalizedCount
        storage.set(normalizedCount, forKey: StorageKey.requiredFingerCount)
    }

    private static func normalizedFingerCount(_ count: Int) -> Int {
        [3, 4, 5].contains(count) ? count : 3
    }
}
