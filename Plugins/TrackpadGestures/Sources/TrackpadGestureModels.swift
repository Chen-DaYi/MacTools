import Foundation
import MacToolsPluginKit

enum TipTapRegion: String, Codable, CaseIterable, Sendable {
    case left
    case middle
    case right
}

enum TrackpadGesture: String, Codable, CaseIterable, Identifiable, Sendable {
    case tipTapLeftOneFixed
    case tipTapRightOneFixed
    case tipTapLeftTwoFixed
    case tipTapMiddleTwoFixed
    case tipTapRightTwoFixed
    case threeFingerTap
    case fourFingerTap
    case fiveFingerTap
    case threeFingerLongTouch
    case fourFingerLongTouch
    case fiveFingerLongTouch
    case threeFingerDoubleTap
    case fourFingerDoubleTap
    case fiveFingerDoubleTap
    case twoFingerClick
    case threeFingerClick

    var id: String { rawValue }

    static let configurableCases: [TrackpadGesture] = [
        .tipTapLeftOneFixed,
        .tipTapRightOneFixed,
        .tipTapLeftTwoFixed,
        .tipTapMiddleTwoFixed,
        .tipTapRightTwoFixed,
        .threeFingerTap,
        .fourFingerTap,
        .fiveFingerTap,
        .threeFingerDoubleTap,
        .fourFingerDoubleTap,
        .fiveFingerDoubleTap,
        .twoFingerClick,
        .threeFingerClick,
        .threeFingerLongTouch,
        .fourFingerLongTouch,
        .fiveFingerLongTouch,
    ]

    var settingsOrder: Int {
        Self.configurableCases.firstIndex(of: self) ?? Self.configurableCases.count
    }

    var tipTapConfiguration: (fixedFingerCount: Int, region: TipTapRegion)? {
        switch self {
        case .tipTapLeftOneFixed:
            (1, .left)
        case .tipTapRightOneFixed:
            (1, .right)
        case .tipTapLeftTwoFixed:
            (2, .left)
        case .tipTapMiddleTwoFixed:
            (2, .middle)
        case .tipTapRightTwoFixed:
            (2, .right)
        default:
            nil
        }
    }

    var fingerTapCount: Int? {
        switch self {
        case .threeFingerTap: 3
        case .fourFingerTap: 4
        case .fiveFingerTap: 5
        default: nil
        }
    }

    var longTouchFingerCount: Int? {
        switch self {
        case .threeFingerLongTouch: 3
        case .fourFingerLongTouch: 4
        case .fiveFingerLongTouch: 5
        default: nil
        }
    }

    var doubleFingerTapCount: Int? {
        switch self {
        case .threeFingerDoubleTap: 3
        case .fourFingerDoubleTap: 4
        case .fiveFingerDoubleTap: 5
        default: nil
        }
    }

    var physicalClickFingerCount: Int? {
        switch self {
        case .twoFingerClick: 2
        case .threeFingerClick: 3
        default: nil
        }
    }

    static func fingerTap(count: Int) -> TrackpadGesture {
        switch count {
        case 4: .fourFingerTap
        case 5: .fiveFingerTap
        default: .threeFingerTap
        }
    }
}

enum TrackpadGestureMappingSort: String, CaseIterable, Sendable {
    case gesture
    case enabledFirst
    case actionName
    case addedOrder
}

enum TrackpadGestureMappingStatusFilter: String, CaseIterable, Sendable {
    case all
    case enabled
    case disabled
}

enum TrackpadGestureMappingActionFilter: String, CaseIterable, Sendable {
    case all
    case macToolsAction
    case keyboardShortcut
    case middleClick
}

enum TrackpadGestureAction: Codable, Equatable, Sendable {
    case action(ActionReference)
    case keyboardShortcut(ShortcutBinding)
    case middleClick

    private enum CodingKeys: String, CodingKey {
        case kind
        case reference
        case shortcut
    }

    private enum Kind: String, Codable {
        case action
        case keyboardShortcut
        case middleClick
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .action:
            self = .action(try container.decode(ActionReference.self, forKey: .reference))
        case .keyboardShortcut:
            self = .keyboardShortcut(try container.decode(ShortcutBinding.self, forKey: .shortcut))
        case .middleClick:
            self = .middleClick
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .action(reference):
            try container.encode(Kind.action, forKey: .kind)
            try container.encode(reference, forKey: .reference)
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
    private struct PortableBackup: Codable {
        let formatVersion: Int
        let mappings: [TrackpadGestureMapping]
        let ignoresGesturesWhileTyping: Bool
        let typingGracePeriod: TimeInterval
    }

    private static let portableBackupFormatVersion = 1
    private static let maximumPortableBackupByteCount = 256 * 1_024
    private struct LegacyMiddleClickMigrationRecord: Codable {
        let preferences: LegacyMiddleClickPreferences
        let mappingID: UUID?
    }

    private enum Key {
        static let mappings = "mappings"
        static let middleClickMigrationRecord = "migration.mouse-enhancer-middle-click.v2"
        static let ignoreWhileTyping = "ignore-while-typing"
        static let typingGracePeriod = "typing-grace-period"
        static let mappingSort = "settings.mapping-sort"
        static let mappingStatusFilter = "settings.mapping-status-filter"
        static let mappingActionFilter = "settings.mapping-action-filter"
    }

    @Published private(set) var mappings: [TrackpadGestureMapping]
    @Published private(set) var isTesting = false
    @Published private(set) var lastTestGesture: TrackpadGesture?
    @Published private(set) var ignoresGesturesWhileTyping: Bool
    @Published private(set) var typingGracePeriod: TimeInterval
    @Published private(set) var mappingSort: TrackpadGestureMappingSort
    @Published private(set) var mappingStatusFilter: TrackpadGestureMappingStatusFilter
    @Published private(set) var mappingActionFilter: TrackpadGestureMappingActionFilter

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
        self.mappingSort = storage.string(forKey: Key.mappingSort)
            .flatMap(TrackpadGestureMappingSort.init(rawValue:))
            ?? .gesture
        self.mappingStatusFilter = storage.string(forKey: Key.mappingStatusFilter)
            .flatMap(TrackpadGestureMappingStatusFilter.init(rawValue:))
            ?? .all
        self.mappingActionFilter = storage.string(forKey: Key.mappingActionFilter)
            .flatMap(TrackpadGestureMappingActionFilter.init(rawValue:))
            ?? .all
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

    func setMappingSort(_ sort: TrackpadGestureMappingSort) {
        guard mappingSort != sort else { return }
        mappingSort = sort
        storage.set(sort.rawValue, forKey: Key.mappingSort)
    }

    func setMappingStatusFilter(_ filter: TrackpadGestureMappingStatusFilter) {
        guard mappingStatusFilter != filter else { return }
        mappingStatusFilter = filter
        storage.set(filter.rawValue, forKey: Key.mappingStatusFilter)
    }

    func setMappingActionFilter(_ filter: TrackpadGestureMappingActionFilter) {
        guard mappingActionFilter != filter else { return }
        mappingActionFilter = filter
        storage.set(filter.rawValue, forKey: Key.mappingActionFilter)
    }

    func resetMappingViewPreferences() {
        setMappingSort(.gesture)
        setMappingStatusFilter(.all)
        setMappingActionFilter(.all)
    }

    @discardableResult
    func migrateActions(using context: TrackpadActionHostContext) -> Bool {
        var updated = mappings
        var changed = false
        for index in updated.indices {
            guard case let .action(reference) = updated[index].action,
                  let migrated = context.migrate(reference),
                  migrated != reference else {
                continue
            }
            updated[index].action = .action(migrated)
            changed = true
        }
        guard changed else { return false }
        mappings = Self.normalized(updated)
        persist()
        return true
    }

    func portableBackup(using context: TrackpadActionHostContext? = nil) -> Data? {
        let backup = PortableBackup(
            formatVersion: Self.portableBackupFormatVersion,
            mappings: mappings.filter { mapping in
                guard case let .action(reference) = mapping.action else { return true }
                return context?.canExport(reference) ?? true
            },
            ignoresGesturesWhileTyping: ignoresGesturesWhileTyping,
            typingGracePeriod: typingGracePeriod
        )
        guard let data = try? encoder.encode(backup),
              data.count <= Self.maximumPortableBackupByteCount else {
            return nil
        }
        return data
    }

    func actionReferences(inPortableBackup data: Data) -> [ActionReference]? {
        guard data.count <= Self.maximumPortableBackupByteCount,
              let backup = try? JSONDecoder().decode(PortableBackup.self, from: data),
              backup.formatVersion == Self.portableBackupFormatVersion,
              backup.mappings == Self.normalized(backup.mappings) else {
            return nil
        }
        return backup.mappings.compactMap { mapping in
            guard case let .action(reference) = mapping.action else { return nil }
            return reference
        }
    }

    @discardableResult
    func restorePortableBackup(
        _ data: Data,
        using context: TrackpadActionHostContext? = nil
    ) -> Bool {
        guard data.count <= Self.maximumPortableBackupByteCount,
              let backup = try? JSONDecoder().decode(PortableBackup.self, from: data),
              backup.formatVersion == Self.portableBackupFormatVersion,
              backup.mappings == Self.normalized(backup.mappings),
              backup.mappings.allSatisfy({ mapping in
                  guard case let .action(reference) = mapping.action else { return true }
                  return context?.canRestore(reference) ?? true
              }) else {
            return false
        }
        guard let mappingData = try? encoder.encode(backup.mappings) else { return false }
        let gracePeriod = TrackpadTypingSuppressionGate.clamped(backup.typingGracePeriod)
        storage.set(mappingData, forKey: Key.mappings)
        storage.set(backup.ignoresGesturesWhileTyping, forKey: Key.ignoreWhileTyping)
        storage.set(gracePeriod, forKey: Key.typingGracePeriod)
        guard storage.data(forKey: Key.mappings) == mappingData,
              storage.bool(forKey: Key.ignoreWhileTyping) == backup.ignoresGesturesWhileTyping,
              (storage.object(forKey: Key.typingGracePeriod) as? NSNumber)?.doubleValue
                == gracePeriod else {
            return false
        }
        mappings = backup.mappings
        ignoresGesturesWhileTyping = backup.ignoresGesturesWhileTyping
        typingGracePeriod = gracePeriod
        return true
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
        case .action:
            true
        case let .keyboardShortcut(binding):
            binding.isValid
        case .middleClick:
            true
        }
    }
}
