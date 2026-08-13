import Foundation
import MacToolsPluginKit

enum TrackpadGestureAction: Codable, Equatable, Sendable {
    case keyboardShortcut(ShortcutBinding)
    case middleClick

    private enum CodingKeys: String, CodingKey {
        case kind
        case shortcut
    }

    private enum Kind: String, Codable {
        case keyboardShortcut
        case middleClick
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .keyboardShortcut:
            self = .keyboardShortcut(try container.decode(ShortcutBinding.self, forKey: .shortcut))
        case .middleClick:
            self = .middleClick
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .keyboardShortcut(shortcut):
            try container.encode(Kind.keyboardShortcut, forKey: .kind)
            try container.encode(shortcut, forKey: .shortcut)
        case .middleClick:
            try container.encode(Kind.middleClick, forKey: .kind)
        }
    }
}

struct TrackpadGestureMapping: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var gesture: TrackpadGesture
    var action: TrackpadGestureAction
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        gesture: TrackpadGesture,
        action: TrackpadGestureAction,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.gesture = gesture
        self.action = action
        self.isEnabled = isEnabled
    }
}

struct LegacyMiddleClickPreferences: Codable, Equatable, Sendable {
    let isEnabled: Bool
    let fingerCount: Int

    private enum Key {
        static let enabled = "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled"
        static let fingerCount = "plugin.mouse-enhancer.mouse-enhancer.middle-click.finger-count"
    }

    static func load(from defaults: UserDefaults = .standard) -> LegacyMiddleClickPreferences? {
        guard defaults.object(forKey: Key.enabled) != nil else {
            return nil
        }

        let storedCount = defaults.object(forKey: Key.fingerCount) == nil
            ? 3
            : defaults.integer(forKey: Key.fingerCount)
        return LegacyMiddleClickPreferences(
            isEnabled: defaults.bool(forKey: Key.enabled),
            fingerCount: [3, 4, 5].contains(storedCount) ? storedCount : 3
        )
    }
}

@MainActor
final class TrackpadGestureStore: ObservableObject {
    private struct LegacyMiddleClickMigrationRecord: Codable {
        let preferences: LegacyMiddleClickPreferences
        let mappingID: UUID?
    }

    private enum Key {
        static let mappings = "mappings"
        static let middleClickMigrationRecord = "migration.mouse-enhancer-middle-click.v2"
        static let ignoreWhileTyping = "ignore-while-typing"
        static let typingGracePeriod = "typing-grace-period"
    }

    @Published private(set) var mappings: [TrackpadGestureMapping]
    @Published private(set) var isTesting = false
    @Published private(set) var lastTestGesture: TrackpadGesture?
    @Published private(set) var ignoresGesturesWhileTyping: Bool
    @Published private(set) var typingGracePeriod: TimeInterval

    private let storage: any PluginStorage
    private let encoder = JSONEncoder()

    init(
        storage: any PluginStorage,
        legacyMiddleClick: LegacyMiddleClickPreferences? = LegacyMiddleClickPreferences.load()
    ) {
        self.storage = storage
        let decoded = storage.data(forKey: Key.mappings)
            .flatMap { try? JSONDecoder().decode([TrackpadGestureMapping].self, from: $0) }
            ?? []
        self.mappings = Self.normalized(decoded)
        self.ignoresGesturesWhileTyping = storage.object(forKey: Key.ignoreWhileTyping)
            .map { ($0 as? NSNumber)?.boolValue ?? true }
            ?? true
        let storedGracePeriod = (storage.object(forKey: Key.typingGracePeriod) as? NSNumber)?.doubleValue
            ?? TrackpadTypingSuppressionGate.defaultGracePeriod
        self.typingGracePeriod = TrackpadTypingSuppressionGate.clamped(storedGracePeriod)
        migrateLegacyMiddleClickIfNeeded(legacyMiddleClick)
    }

    var enabledGestures: Set<TrackpadGesture> {
        Set(mappings.lazy.filter(\.isEnabled).map(\.gesture))
    }

    func mapping(for gesture: TrackpadGesture) -> TrackpadGestureMapping? {
        mappings.first { $0.gesture == gesture }
    }

    func conflictingMapping(
        for gesture: TrackpadGesture,
        excludingID: UUID? = nil
    ) -> TrackpadGestureMapping? {
        mappings.first { $0.id != excludingID && $0.gesture == gesture }
    }

    func availableGestures(excludingID: UUID? = nil) -> [TrackpadGesture] {
        TrackpadGesture.configurableCases.filter {
            conflictingMapping(for: $0, excludingID: excludingID) == nil
        }
    }

    func mappings(
        using shortcut: ShortcutBinding,
        excludingID: UUID? = nil
    ) -> [TrackpadGestureMapping] {
        mappings.filter { mapping in
            guard mapping.id != excludingID,
                  case let .keyboardShortcut(existingShortcut) = mapping.action
            else {
                return false
            }
            return existingShortcut == shortcut
        }
    }

    @discardableResult
    func save(_ mapping: TrackpadGestureMapping) -> Bool {
        guard conflictingMapping(for: mapping.gesture, excludingID: mapping.id) == nil else {
            return false
        }
        guard Self.isValid(mapping) else {
            return false
        }

        if let index = mappings.firstIndex(where: { $0.id == mapping.id }) {
            mappings[index] = mapping
        } else {
            mappings.append(mapping)
        }
        persist()
        return true
    }

    func setEnabled(_ isEnabled: Bool, id: UUID) {
        guard let index = mappings.firstIndex(where: { $0.id == id }),
              mappings[index].isEnabled != isEnabled
        else {
            return
        }
        mappings[index].isEnabled = isEnabled
        persist()
    }

    func delete(id: UUID) {
        let originalCount = mappings.count
        mappings.removeAll { $0.id == id }
        if mappings.count != originalCount {
            persist()
        }
    }

    func setTesting(_ isTesting: Bool) {
        self.isTesting = isTesting
        if !isTesting {
            lastTestGesture = nil
        }
    }

    func recordTestGesture(_ gesture: TrackpadGesture) {
        lastTestGesture = gesture
    }

    func setIgnoresGesturesWhileTyping(_ isEnabled: Bool) {
        guard ignoresGesturesWhileTyping != isEnabled else { return }
        ignoresGesturesWhileTyping = isEnabled
        storage.set(isEnabled, forKey: Key.ignoreWhileTyping)
    }

    func setTypingGracePeriod(_ gracePeriod: TimeInterval) {
        let clamped = TrackpadTypingSuppressionGate.clamped(gracePeriod)
        guard typingGracePeriod != clamped else { return }
        typingGracePeriod = clamped
        storage.set(clamped, forKey: Key.typingGracePeriod)
    }

    private func migrateLegacyMiddleClickIfNeeded(_ legacy: LegacyMiddleClickPreferences?) {
        guard let legacy else {
            return
        }

        let previousRecord = storage.data(forKey: Key.middleClickMigrationRecord)
            .flatMap { try? JSONDecoder().decode(LegacyMiddleClickMigrationRecord.self, from: $0) }
        guard previousRecord?.preferences != legacy else {
            return
        }

        let mappingID = reconcileLegacyMiddleClick(legacy, previousRecord: previousRecord)
        let record = LegacyMiddleClickMigrationRecord(
            preferences: legacy,
            mappingID: mappingID
        )
        if let data = try? encoder.encode(record) {
            // Mouse Enhancer keys remain untouched so a temporary host downgrade can restore the
            // legacy owner. This record lets the next upgrade detect values changed while old.
            storage.set(data, forKey: Key.middleClickMigrationRecord)
        }
    }

    private func reconcileLegacyMiddleClick(
        _ legacy: LegacyMiddleClickPreferences,
        previousRecord: LegacyMiddleClickMigrationRecord?
    ) -> UUID? {
        let desiredGesture = TrackpadGesture.fingerTap(count: legacy.fingerCount)

        if let previousRecord,
           let mappingID = previousRecord.mappingID,
           let index = mappings.firstIndex(where: { $0.id == mappingID }),
           mappings[index] == TrackpadGestureMapping(
               id: mappingID,
               gesture: .fingerTap(count: previousRecord.preferences.fingerCount),
               action: .middleClick,
               isEnabled: previousRecord.preferences.isEnabled
           ) {
            if conflictingMapping(for: desiredGesture, excludingID: mappingID) == nil {
                mappings[index].gesture = desiredGesture
                mappings[index].isEnabled = legacy.isEnabled
                persist()
                return mappingID
            }

            // A newer explicit mapping wins the desired gesture. Remove only the unchanged
            // migration-owned mapping so the superseded legacy gesture does not remain active.
            mappings.remove(at: index)
            persist()
            return nil
        }

        // Existing mappings may predate the versioned migration record or may have been edited by
        // the user. Never claim or overwrite them without positive ownership evidence.
        guard conflictingMapping(for: desiredGesture) == nil else {
            return nil
        }

        let mapping = TrackpadGestureMapping(
            gesture: desiredGesture,
            action: .middleClick,
            isEnabled: legacy.isEnabled
        )
        mappings.append(mapping)
        persist()
        return mapping.id
    }

    private func persist() {
        guard let data = try? encoder.encode(mappings) else {
            return
        }
        storage.set(data, forKey: Key.mappings)
    }

    private static func normalized(_ candidates: [TrackpadGestureMapping]) -> [TrackpadGestureMapping] {
        var seenGestures = Set<TrackpadGesture>()
        var seenIDs = Set<UUID>()
        return candidates.filter { mapping in
            guard isValid(mapping),
                  seenIDs.insert(mapping.id).inserted,
                  seenGestures.insert(mapping.gesture).inserted
            else {
                return false
            }
            return true
        }
    }

    private static func isValid(_ mapping: TrackpadGestureMapping) -> Bool {
        return switch mapping.action {
        case let .keyboardShortcut(binding):
            binding.isValid
        case .middleClick:
            true
        }
    }
}
