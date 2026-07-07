import Foundation
import MacToolsPluginKit

enum MouseEnhancerDevice: Equatable, Sendable {
    case mouse
    case trackpad
}

struct MouseEnhancerConfiguration: Equatable, Sendable {
    var reverseMouseHorizontal: Bool
    var reverseMouseVertical: Bool
    var reverseTrackpadHorizontal: Bool
    var reverseTrackpadVertical: Bool
    var middleClickEnabled: Bool
    var middleClickFingerCount: Int

    init(
        reverseMouseHorizontal: Bool,
        reverseMouseVertical: Bool,
        reverseTrackpadHorizontal: Bool,
        reverseTrackpadVertical: Bool,
        middleClickEnabled: Bool = false,
        middleClickFingerCount: Int = 3
    ) {
        self.reverseMouseHorizontal = reverseMouseHorizontal
        self.reverseMouseVertical = reverseMouseVertical
        self.reverseTrackpadHorizontal = reverseTrackpadHorizontal
        self.reverseTrackpadVertical = reverseTrackpadVertical
        self.middleClickEnabled = middleClickEnabled
        self.middleClickFingerCount = middleClickFingerCount
    }

    static let `default` = MouseEnhancerConfiguration(
        reverseMouseHorizontal: false,
        reverseMouseVertical: false,
        reverseTrackpadHorizontal: false,
        reverseTrackpadVertical: false,
        middleClickEnabled: false,
        middleClickFingerCount: 3
    )

    var hasMouseReversing: Bool {
        reverseMouseHorizontal || reverseMouseVertical
    }

    var hasTrackpadReversing: Bool {
        reverseTrackpadHorizontal || reverseTrackpadVertical
    }

    var shouldInstallEventTap: Bool {
        hasMouseReversing || hasTrackpadReversing
    }

    func shouldReverse(device: MouseEnhancerDevice) -> Bool {
        switch device {
        case .mouse:
            return hasMouseReversing
        case .trackpad:
            return hasTrackpadReversing
        }
    }

    func shouldReverseVertical(device: MouseEnhancerDevice) -> Bool {
        switch device {
        case .mouse:
            return reverseMouseVertical
        case .trackpad:
            return reverseTrackpadVertical
        }
    }

    func shouldReverseHorizontal(device: MouseEnhancerDevice) -> Bool {
        switch device {
        case .mouse:
            return reverseMouseHorizontal
        case .trackpad:
            return reverseTrackpadHorizontal
        }
    }
}

@MainActor
final class MouseEnhancerStore: ObservableObject {
    private enum StorageKey {
        static let reverseMouseHorizontal = "mouse-enhancer.scroll-reversing.mouse.horizontal"
        static let reverseMouseVertical = "mouse-enhancer.scroll-reversing.mouse.vertical"
        static let reverseTrackpadHorizontal = "mouse-enhancer.scroll-reversing.trackpad.horizontal"
        static let reverseTrackpadVertical = "mouse-enhancer.scroll-reversing.trackpad.vertical"
        static let middleClickEnabled = "mouse-enhancer.middle-click.enabled"
        static let middleClickFingerCount = "mouse-enhancer.middle-click.finger-count"
    }

    @Published private(set) var configuration: MouseEnhancerConfiguration

    private let storage: any PluginStorage

    init(storage: any PluginStorage) {
        self.storage = storage
        self.configuration = MouseEnhancerConfiguration(
            reverseMouseHorizontal: Self.bool(
                forKey: StorageKey.reverseMouseHorizontal,
                defaultValue: MouseEnhancerConfiguration.default.reverseMouseHorizontal,
                storage: storage
            ),
            reverseMouseVertical: Self.bool(
                forKey: StorageKey.reverseMouseVertical,
                defaultValue: MouseEnhancerConfiguration.default.reverseMouseVertical,
                storage: storage
            ),
            reverseTrackpadHorizontal: Self.bool(
                forKey: StorageKey.reverseTrackpadHorizontal,
                defaultValue: MouseEnhancerConfiguration.default.reverseTrackpadHorizontal,
                storage: storage
            ),
            reverseTrackpadVertical: Self.bool(
                forKey: StorageKey.reverseTrackpadVertical,
                defaultValue: MouseEnhancerConfiguration.default.reverseTrackpadVertical,
                storage: storage
            ),
            middleClickEnabled: Self.bool(
                forKey: StorageKey.middleClickEnabled,
                defaultValue: MouseEnhancerConfiguration.default.middleClickEnabled,
                storage: storage
            ),
            middleClickFingerCount: Self.fingerCount(
                forKey: StorageKey.middleClickFingerCount,
                defaultValue: MouseEnhancerConfiguration.default.middleClickFingerCount,
                storage: storage
            )
        )
    }

    func setReverseMouseHorizontal(_ isEnabled: Bool) {
        update(StorageKey.reverseMouseHorizontal, value: isEnabled) {
            $0.reverseMouseHorizontal = isEnabled
        }
    }

    func setReverseMouseVertical(_ isEnabled: Bool) {
        update(StorageKey.reverseMouseVertical, value: isEnabled) {
            $0.reverseMouseVertical = isEnabled
        }
    }

    func setReverseTrackpadHorizontal(_ isEnabled: Bool) {
        update(StorageKey.reverseTrackpadHorizontal, value: isEnabled) {
            $0.reverseTrackpadHorizontal = isEnabled
        }
    }

    func setReverseTrackpadVertical(_ isEnabled: Bool) {
        update(StorageKey.reverseTrackpadVertical, value: isEnabled) {
            $0.reverseTrackpadVertical = isEnabled
        }
    }

    func setMiddleClickEnabled(_ isEnabled: Bool) {
        update(StorageKey.middleClickEnabled, value: isEnabled) {
            $0.middleClickEnabled = isEnabled
        }
    }

    func setMiddleClickFingerCount(_ count: Int) {
        let normalizedCount = Self.normalizedFingerCount(count)
        update(StorageKey.middleClickFingerCount, value: normalizedCount) {
            $0.middleClickFingerCount = normalizedCount
        }
    }

    private func update(
        _ key: String,
        value: Any,
        mutate: (inout MouseEnhancerConfiguration) -> Void
    ) {
        var next = configuration
        mutate(&next)
        guard next != configuration else {
            return
        }

        storage.set(value, forKey: key)
        configuration = next
    }

    private static func bool(
        forKey key: String,
        defaultValue: Bool,
        storage: any PluginStorage
    ) -> Bool {
        guard storage.object(forKey: key) != nil else {
            return defaultValue
        }

        return storage.bool(forKey: key)
    }

    private static func fingerCount(
        forKey key: String,
        defaultValue: Int,
        storage: any PluginStorage
    ) -> Int {
        guard storage.object(forKey: key) != nil else {
            return defaultValue
        }

        return normalizedFingerCount(storage.integer(forKey: key))
    }

    private static func normalizedFingerCount(_ count: Int) -> Int {
        [3, 4, 5].contains(count) ? count : MouseEnhancerConfiguration.default.middleClickFingerCount
    }
}
