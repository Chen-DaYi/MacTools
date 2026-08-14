import AppKit
import XCTest
import MacToolsPluginKit
@testable import TrackpadGesturesPlugin

@MainActor
private final class MutableBool {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval = 0

    var value: TimeInterval {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class LockedTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}

private final class TrackpadFrameDeliveryBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryStarted = DispatchSemaphore(value: 0)
    private let allowDeliveryToFinish = DispatchSemaphore(value: 0)
    private let invalidationStarted = DispatchSemaphore(value: 0)
    private var storedEvents: [String] = []

    var events: [String] { lock.withLock { storedEvents } }

    func pauseDelivery() {
        deliveryStarted.signal()
        allowDeliveryToFinish.wait()
        lock.withLock { storedEvents.append("delivery") }
    }

    func waitForDelivery() -> DispatchTimeoutResult {
        deliveryStarted.wait(timeout: .now() + 1)
    }

    func startInvalidation() {
        invalidationStarted.signal()
    }

    func waitForInvalidationAttempt() -> DispatchTimeoutResult {
        invalidationStarted.wait(timeout: .now() + 1)
    }

    func finishDelivery() {
        allowDeliveryToFinish.signal()
    }

    func recordReset() {
        lock.withLock { storedEvents.append("reset") }
    }
}

private final class TrackpadRecognitionFrameBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let framePaused = DispatchSemaphore(value: 0)
    private let continueFrame = DispatchSemaphore(value: 0)
    private var shouldPauseNextFrame = false

    func arm() {
        lock.withLock { shouldPauseNextFrame = true }
    }

    func pauseIfArmed() {
        let shouldPause = lock.withLock {
            guard shouldPauseNextFrame else { return false }
            shouldPauseNextFrame = false
            return true
        }
        guard shouldPause else { return }
        framePaused.signal()
        continueFrame.wait()
    }

    func waitUntilPaused() -> DispatchTimeoutResult {
        framePaused.wait(timeout: .now() + 1)
    }

    func resume() {
        continueFrame.signal()
    }
}

@MainActor
private final class TrackpadGestureMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else { return }
        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}

@MainActor
private final class MockMultitouchDeviceSession: MultitouchDeviceSessionManaging {
    var onRecognized: ((TrackpadGesture, UInt64) -> Void)?
    var onAvailabilityChange: ((Bool) -> Void)?
    private(set) var isActive = false
    var deviceCount = 1
    private(set) var activations: [Set<TrackpadGesture>] = []
    private(set) var updates: [Set<TrackpadGesture>] = []
    private(set) var deactivateCount = 0
    private(set) var middleClickGestureUpdates: [Set<TrackpadGesture>] = []
    private(set) var resolvedMiddleClicks: [(TrackpadGesture, UInt64)] = []
    private(set) var nativeClickResolutionUpdates: [[TrackpadGesture: TrackpadNativeClickResolution]] = []
    private(set) var typingProtectionUpdates: [(Bool, TimeInterval)] = []
    var activationSucceeds = true
    var resolvesMiddleClicks = false

    func activate(gestures: Set<TrackpadGesture>) -> Bool {
        activations.append(gestures)
        isActive = activationSucceeds
        return activationSucceeds
    }

    func update(gestures: Set<TrackpadGesture>) {
        updates.append(gestures)
    }

    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {
        middleClickGestureUpdates.append(gestures)
    }

    func resolveMiddleClick(for gesture: TrackpadGesture, deviceID: UInt64) -> Bool {
        resolvedMiddleClicks.append((gesture, deviceID))
        return resolvesMiddleClicks
    }

    func updateNativeClickResolutions(
        _ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]
    ) {
        nativeClickResolutionUpdates.append(resolutions)
        middleClickGestureUpdates.append(Set(resolutions.compactMap { gesture, resolution in
            resolution == .middleClick ? gesture : nil
        }))
    }

    func resolveNativeClick(
        for gesture: TrackpadGesture,
        deviceID: UInt64
    ) -> TrackpadNativeClickResolution? {
        resolvedMiddleClicks.append((gesture, deviceID))
        guard resolvesMiddleClicks else {
            return nativeClickResolutionUpdates.last?[gesture] == .consume ? .consume : nil
        }
        return nativeClickResolutionUpdates.last?[gesture]
    }

    func updateTypingProtection(isEnabled: Bool, gracePeriod: TimeInterval) {
        typingProtectionUpdates.append((isEnabled, gracePeriod))
    }

    func deactivate() {
        deactivateCount += 1
        isActive = false
    }

    func recognize(_ gesture: TrackpadGesture) {
        onRecognized?(gesture, 1)
    }

    func reportAvailability(_ available: Bool) {
        isActive = available
        onAvailabilityChange?(available)
    }
}

@MainActor
private final class MockTrackpadGestureActionExecutor: TrackpadGestureActionExecuting {
    private(set) var actions: [TrackpadGestureAction] = []
    func execute(_ action: TrackpadGestureAction) { actions.append(action) }
}

@MainActor
private final class MockMultitouchFrameListener: MultitouchFrameListening {
    var deviceCount = 1
    var startSucceeds = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@Sendable (TrackpadContactFrame) -> Void)?
    private var retainedHandlers: [@Sendable (TrackpadContactFrame) -> Void] = []

    func start(handler: @escaping @Sendable (TrackpadContactFrame) -> Void) -> Bool {
        startCount += 1
        self.handler = startSucceeds ? handler : nil
        if startSucceeds {
            retainedHandlers.append(handler)
        }
        return startSucceeds
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func send(_ frame: TrackpadContactFrame, usingStart index: Int? = nil) {
        if let index {
            retainedHandlers[index](frame)
        } else {
            handler?(frame)
        }
    }
}

@MainActor
final class TrackpadGestureStoreTests: XCTestCase {
    func testTypingProtectionDefaultsPersistAndClampGracePeriod() {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)

        XCTAssertTrue(store.ignoresGesturesWhileTyping)
        XCTAssertEqual(store.typingGracePeriod, 0.4)

        store.setIgnoresGesturesWhileTyping(false)
        store.setTypingGracePeriod(2.0)
        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertFalse(reloaded.ignoresGesturesWhileTyping)
        XCTAssertEqual(reloaded.typingGracePeriod, 1.0)

        reloaded.setTypingGracePeriod(0)
        XCTAssertEqual(reloaded.typingGracePeriod, 0.2)
    }

    func testAddEditToggleDeleteAndPersistence() throws {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        let shortcut = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        var mapping = TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .keyboardShortcut(shortcut)
        )

        XCTAssertTrue(store.save(mapping))
        mapping.isEnabled = false
        XCTAssertTrue(store.save(mapping))
        XCTAssertFalse(store.mappings[0].isEnabled)

        store.setEnabled(true, id: mapping.id)
        let reloaded = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertEqual(reloaded.mappings, [TrackpadGestureMapping(
            id: mapping.id,
            gesture: mapping.gesture,
            action: mapping.action,
            isEnabled: true
        )])

        reloaded.delete(id: mapping.id)
        XCTAssertTrue(TrackpadGestureStore(storage: storage, legacyMiddleClick: nil).mappings.isEmpty)
    }

    func testDuplicateGestureIsRejectedEvenWhenExistingMappingIsDisabled() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        let first = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick,
            isEnabled: false
        )
        let duplicate = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 1, modifiers: .command))
        )

        XCTAssertTrue(store.save(first))
        XCTAssertFalse(store.save(duplicate))
        XCTAssertEqual(store.conflictingMapping(for: .fourFingerTap)?.id, first.id)
    }

    func testAvailableGesturesExcludeConfiguredRowsButKeepEditedRowsCurrentGesture() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        let first = TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .middleClick,
            isEnabled: false
        )
        let second = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(second))

        XCTAssertFalse(store.availableGestures().contains(.tipTapLeftOneFixed))
        XCTAssertFalse(store.availableGestures().contains(.fourFingerTap))

        let editingFirst = store.availableGestures(excludingID: first.id)
        XCTAssertTrue(editingFirst.contains(.tipTapLeftOneFixed))
        XCTAssertFalse(editingFirst.contains(.fourFingerTap))
        XCTAssertTrue(editingFirst.contains(.fiveFingerLongTouch))
        XCTAssertTrue(editingFirst.contains(.threeFingerDoubleTap))
        XCTAssertTrue(editingFirst.contains(.fourFingerDoubleTap))
        XCTAssertTrue(editingFirst.contains(.fiveFingerDoubleTap))
    }

    func testDoubleTapGesturesCanBePersistedAsMappings() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )

        for gesture in [
            TrackpadGesture.threeFingerDoubleTap,
            .fourFingerDoubleTap,
            .fiveFingerDoubleTap,
        ] {
            XCTAssertTrue(store.save(TrackpadGestureMapping(
                gesture: gesture,
                action: .middleClick
            )))
        }
        XCTAssertEqual(store.mappings.count, 3)
    }

    func testShortcutReuseLookupAllowsButReportsOtherMappings() {
        let store = TrackpadGestureStore(
            storage: TrackpadGestureMemoryStorage(),
            legacyMiddleClick: nil
        )
        let shortcut = ShortcutBinding(keyCode: 1, modifiers: [.command, .shift])
        let first = TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .keyboardShortcut(shortcut),
            isEnabled: false
        )
        let second = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(shortcut)
        )
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(second))

        XCTAssertEqual(store.mappings(using: shortcut).map(\.id), [first.id, second.id])
        XCTAssertEqual(
            store.mappings(using: shortcut, excludingID: second.id).map(\.id),
            [first.id]
        )
    }

    func testLegacyMiddleClickMigratesOnceForUnchangedObservedPreferences() {
        let storage = TrackpadGestureMemoryStorage()
        let legacy = LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 5)

        let store = TrackpadGestureStore(storage: storage, legacyMiddleClick: legacy)
        XCTAssertEqual(store.mappings.count, 1)
        XCTAssertEqual(store.mappings[0].gesture, .fiveFingerTap)
        XCTAssertEqual(store.mappings[0].action, .middleClick)
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))

        let reloaded = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: legacy
        )
        XCTAssertEqual(reloaded.mappings, store.mappings)
    }

    func testDisabledLegacyMiddleClickMigratesAsDisabledAndPreservesFingerCount() {
        let storage = TrackpadGestureMemoryStorage()
        let store = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: false, fingerCount: 4)
        )

        XCTAssertEqual(store.mappings.count, 1)
        XCTAssertEqual(store.mappings[0].gesture, .fourFingerTap)
        XCTAssertEqual(store.mappings[0].action, .middleClick)
        XCTAssertFalse(store.mappings[0].isEnabled)
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))
    }

    func testLegacyMiddleClickMergesIntoNonConflictingExistingMappings() throws {
        let storage = TrackpadGestureMemoryStorage()
        let existing = TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 0, modifiers: .command))
        )
        storage.set(try JSONEncoder().encode([existing]), forKey: "mappings")

        let store = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 4)
        )

        XCTAssertEqual(store.mappings.map(\.gesture), [.tipTapLeftOneFixed, .fourFingerTap])
        XCTAssertEqual(store.mapping(for: .fourFingerTap)?.action, .middleClick)
    }

    func testExistingSameGestureMappingWinsLegacyMigrationCollision() throws {
        let storage = TrackpadGestureMemoryStorage()
        let shortcut = ShortcutBinding(keyCode: 1, modifiers: [.command, .shift])
        let existing = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .keyboardShortcut(shortcut)
        )
        storage.set(try JSONEncoder().encode([existing]), forKey: "mappings")

        let store = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 3)
        )

        XCTAssertEqual(store.mappings, [existing])
        XCTAssertEqual(store.mapping(for: .threeFingerTap)?.action, .keyboardShortcut(shortcut))
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))
    }

    func testReupgradeMigratesLegacyPreferenceCreatedDuringDowngrade() {
        let storage = TrackpadGestureMemoryStorage()

        let firstUpgrade = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertTrue(firstUpgrade.mappings.isEmpty)
        XCTAssertNil(storage.object(forKey: "migration.mouse-enhancer-middle-click.v2"))

        // Simulate the marker written by Trackpad Gestures 1.0.0 before the user downgraded.
        storage.set(true, forKey: "migration.mouse-enhancer-middle-click.v1")
        let reupgrade = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 5)
        )

        XCTAssertEqual(reupgrade.mappings.count, 1)
        XCTAssertEqual(reupgrade.mapping(for: .fiveFingerTap)?.action, .middleClick)
        XCTAssertEqual(reupgrade.mapping(for: .fiveFingerTap)?.isEnabled, true)
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))
    }

    func testReupgradeUpdatesOnlyMigrationOwnedMappingAfterDowngradeEdit() throws {
        let storage = TrackpadGestureMemoryStorage()
        let initial = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 3)
        )
        let importedID = try XCTUnwrap(initial.mapping(for: .threeFingerTap)?.id)
        let deliberate = TrackpadGestureMapping(
            gesture: .tipTapRightOneFixed,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 17, modifiers: .command))
        )
        XCTAssertTrue(initial.save(deliberate))

        let reupgrade = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: false, fingerCount: 4)
        )

        XCTAssertNil(reupgrade.mapping(for: .threeFingerTap))
        XCTAssertEqual(reupgrade.mapping(for: .fourFingerTap)?.id, importedID)
        XCTAssertEqual(reupgrade.mapping(for: .fourFingerTap)?.action, .middleClick)
        XCTAssertEqual(reupgrade.mapping(for: .fourFingerTap)?.isEnabled, false)
        XCTAssertEqual(reupgrade.mapping(for: .tipTapRightOneFixed), deliberate)
    }

    func testReupgradePreservesUserMappingThatConflictsWithDowngradedLegacyChoice() {
        let storage = TrackpadGestureMemoryStorage()
        let deliberate = TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 1, modifiers: [.command, .shift]))
        )
        let initial = TrackpadGestureStore(storage: storage, legacyMiddleClick: nil)
        XCTAssertTrue(initial.save(deliberate))

        let reupgrade = TrackpadGestureStore(
            storage: storage,
            legacyMiddleClick: LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 4)
        )

        XCTAssertEqual(reupgrade.mappings, [deliberate])
        XCTAssertNotNil(storage.data(forKey: "migration.mouse-enhancer-middle-click.v2"))
    }

    func testLegacyPreferenceReaderDoesNotRemoveDowngradeKeys() throws {
        let suiteName = "TrackpadGestureStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let enabledKey = "plugin.mouse-enhancer.mouse-enhancer.middle-click.enabled"
        let countKey = "plugin.mouse-enhancer.mouse-enhancer.middle-click.finger-count"
        defaults.set(true, forKey: enabledKey)
        defaults.set(4, forKey: countKey)

        XCTAssertEqual(
            LegacyMiddleClickPreferences.load(from: defaults),
            LegacyMiddleClickPreferences(isEnabled: true, fingerCount: 4)
        )
        XCTAssertEqual(defaults.object(forKey: enabledKey) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: countKey) as? Int, 4)
    }
}

@MainActor
final class TrackpadGesturesPluginTests: XCTestCase {
    func testMultitouchRuntimeResolvesRequiredSymbolsDynamically() {
        XCTAssertNotNil(MultitouchSupportRuntime.load())
    }

    func testMultitouchDriverFailsClosedWithoutRuntime() {
        let driver = MultitouchDeviceDriver(runtime: nil)

        XCTAssertFalse(driver.start { _ in })
        XCTAssertEqual(driver.deviceCount, 0)
    }

    func testMetadataAndEmptyState() {
        let plugin = makePlugin().plugin
        XCTAssertEqual(plugin.metadata.id, "trackpad-gestures")
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "尚未配置手势")
        XCTAssertEqual(plugin.permissionRequirements.map(\.id), ["accessibility", "input-monitoring"])
    }

    func testEnabledMappingExecutesEveryRepeatedRecognizedAction() {
        let fixture = makePlugin()
        let shortcut = ShortcutBinding(keyCode: 0, modifiers: [.command, .shift])
        let mapping = TrackpadGestureMapping(
            gesture: .tipTapRightOneFixed,
            action: .keyboardShortcut(shortcut)
        )
        XCTAssertTrue(fixture.plugin.store.save(mapping))

        fixture.plugin.configurationDidChange()
        XCTAssertEqual(fixture.session.activations, [[.tipTapRightOneFixed]])
        fixture.session.recognize(.tipTapRightOneFixed)
        fixture.session.recognize(.tipTapRightOneFixed)
        XCTAssertEqual(fixture.executor.actions, [
            .keyboardShortcut(shortcut),
            .keyboardShortcut(shortcut),
        ])
        XCTAssertEqual(
            fixture.session.nativeClickResolutionUpdates.last?[.tipTapRightOneFixed],
            .consume
        )
        XCTAssertEqual(fixture.session.typingProtectionUpdates.last?.0, true)
        XCTAssertEqual(fixture.session.typingProtectionUpdates.last?.1, 0.4)
    }

    func testConfiguredDoubleTapExecutesItsAction() {
        let fixture = makePlugin()
        let shortcut = ShortcutBinding(keyCode: 2, modifiers: [.command, .option])
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fiveFingerDoubleTap,
            action: .keyboardShortcut(shortcut)
        )))

        fixture.plugin.configurationDidChange()
        XCTAssertEqual(fixture.session.activations.last, [.fiveFingerDoubleTap])
        fixture.session.recognize(.fiveFingerDoubleTap)
        XCTAssertEqual(fixture.executor.actions, [.keyboardShortcut(shortcut)])
    }

    func testOrdinaryMultiFingerShortcutDoesNotConsumeNativeClick() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 0, modifiers: .command))
        )))

        fixture.plugin.configurationDidChange()

        XCTAssertNil(fixture.session.nativeClickResolutionUpdates.last?[.fourFingerTap])
    }

    func testTypingProtectionConfigurationIsForwardedToSession() {
        let fixture = makePlugin()
        fixture.plugin.store.setIgnoresGesturesWhileTyping(false)
        fixture.plugin.store.setTypingGracePeriod(0.8)
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .tipTapLeftOneFixed,
            action: .keyboardShortcut(ShortcutBinding(keyCode: 0, modifiers: .command))
        )))

        fixture.plugin.configurationDidChange()

        XCTAssertEqual(fixture.session.typingProtectionUpdates.last?.0, false)
        XCTAssertEqual(fixture.session.typingProtectionUpdates.last?.1, 0.8)
    }

    func testRepeatedMiddleClickMappingIsResolvedBySessionWithoutSyntheticExecutorDuplicate() {
        let fixture = makePlugin()
        fixture.session.resolvesMiddleClicks = true
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))

        fixture.plugin.configurationDidChange()
        fixture.session.recognize(.threeFingerTap)
        fixture.session.recognize(.threeFingerTap)

        XCTAssertEqual(fixture.session.middleClickGestureUpdates.last, [.threeFingerTap])
        XCTAssertEqual(fixture.session.resolvedMiddleClicks.count, 2)
        XCTAssertEqual(fixture.session.resolvedMiddleClicks.first?.0, .threeFingerTap)
        XCTAssertEqual(fixture.session.resolvedMiddleClicks.first?.1, 1)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
    }

    func testRecognitionAfterDeactivationDoesNotExecuteAction() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()

        fixture.plugin.deactivate(reason: .disabled)
        fixture.session.recognize(.threeFingerTap)

        XCTAssertTrue(fixture.executor.actions.isEmpty)
    }

    func testPermissionLossAtDeliveryStopsSessionAndDoesNotExecuteAction() {
        let accessibilityGranted = MutableBool(true)
        let fixture = makePlugin(accessibilityTrusted: { accessibilityGranted.value })
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()

        accessibilityGranted.value = false
        fixture.session.recognize(.threeFingerTap)

        XCTAssertFalse(fixture.session.isActive)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
        XCTAssertNotNil(fixture.plugin.primaryPanelState.errorMessage)
    }

    func testAutomaticListenerRecoveryClearsUnavailableError() {
        let fixture = makePlugin()
        fixture.session.activationSucceeds = false
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()
        XCTAssertNotNil(fixture.plugin.primaryPanelState.errorMessage)

        fixture.session.reportAvailability(true)

        XCTAssertNil(fixture.plugin.primaryPanelState.errorMessage)
    }

    func testFeatureExtractionReadinessRejectsListenerActivationFailure() {
        let fixture = makePlugin()
        fixture.session.activationSucceeds = false
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))

        fixture.plugin.configurationDidChange()

        XCTAssertThrowsError(try fixture.plugin.validateFeatureExtractionReadiness()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                fixture.plugin.primaryPanelState.errorMessage
            )
        }
    }

    func testFeatureExtractionReadinessRejectsAsynchronousListenerLoss() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()

        fixture.session.reportAvailability(false)

        XCTAssertThrowsError(try fixture.plugin.validateFeatureExtractionReadiness())
    }

    func testTestModeRecognizesWithoutExecutingActions() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.store.setTesting(true)
        fixture.plugin.configurationDidChange()

        XCTAssertEqual(fixture.session.activations.last, Set(TrackpadGesture.allCases))
        fixture.session.recognize(.threeFingerTap)
        XCTAssertEqual(fixture.plugin.store.lastTestGesture, .threeFingerTap)
        XCTAssertTrue(fixture.executor.actions.isEmpty)

        fixture.session.recognize(.fiveFingerDoubleTap)
        XCTAssertEqual(fixture.plugin.store.lastTestGesture, .fiveFingerDoubleTap)
        XCTAssertTrue(fixture.executor.actions.isEmpty)
    }

    func testPermissionRevocationStopsActiveListener() {
        let accessibilityGranted = MutableBool(true)
        let fixture = makePlugin(accessibilityTrusted: { accessibilityGranted.value })
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()
        XCTAssertTrue(fixture.session.isActive)

        accessibilityGranted.value = false
        fixture.plugin.refreshAccessibilityPermission()
        XCTAssertFalse(fixture.session.isActive)
        XCTAssertNotNil(fixture.plugin.primaryPanelState.errorMessage)
    }

    func testInputMonitoringDenialPreventsActivationAndRequestsGuidance() {
        let fixture = makePlugin(inputMonitoringStatus: { .denied })
        var requestedPermission: String?
        fixture.plugin.requestPermissionGuidance = { requestedPermission = $0 }
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )))

        fixture.plugin.configurationDidChange()

        XCTAssertTrue(fixture.session.activations.isEmpty)
        XCTAssertEqual(requestedPermission, "input-monitoring")
    }

    func testAppReactivationResamplesInputMonitoringGrantAndRevocation() async {
        let inputMonitoringGranted = MutableBool(false)
        let fixture = makePlugin(inputMonitoringStatus: {
            inputMonitoringGranted.value ? .granted : .denied
        })
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .fourFingerTap,
            action: .middleClick
        )))
        fixture.plugin.activate(context: PluginRuntimeContext(pluginID: "trackpad-gestures"))
        XCTAssertFalse(fixture.session.isActive)

        inputMonitoringGranted.value = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertTrue(fixture.session.isActive)

        inputMonitoringGranted.value = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertFalse(fixture.session.isActive)
        fixture.plugin.deactivate(reason: .disabled)
    }

    func testDeactivationStopsListenerAndClearsTestMode() {
        let fixture = makePlugin()
        fixture.plugin.store.setTesting(true)
        fixture.plugin.configurationDidChange()
        fixture.plugin.deactivate(reason: .disabled)

        XCTAssertFalse(fixture.plugin.store.isTesting)
        XCTAssertFalse(fixture.session.isActive)
    }

    func testUpdateDeactivationAlwaysStopsCallbackBearingSession() {
        let fixture = makePlugin()
        XCTAssertTrue(fixture.plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))
        fixture.plugin.configurationDidChange()
        XCTAssertTrue(fixture.session.isActive)
        fixture.plugin.store.setTesting(true)

        fixture.plugin.deactivate(reason: .updating)

        XCTAssertFalse(fixture.plugin.store.isTesting)
        XCTAssertFalse(fixture.session.isActive)
        XCTAssertEqual(fixture.session.deactivateCount, 1)
    }

    func testSessionRestartsDriverForWakeAndDeviceRecovery() {
        let driver = MockMultitouchFrameListener()
        var tapStarts = 0
        var tapStops = 0
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { tapStarts += 1; return true },
            testEventTapStop: { tapStops += 1 }
        )

        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.simulateWakeRecoveryForTests()
        session.simulateDeviceRecoveryForTests()

        XCTAssertEqual(driver.startCount, 3)
        XCTAssertGreaterThanOrEqual(driver.stopCount, 2)
        XCTAssertEqual(tapStarts, 3)
        XCTAssertEqual(tapStops, 2)
        session.deactivate()
    }

    func testSessionCanRecoverAfterEventTapRestartFailure() {
        let driver = MockMultitouchFrameListener()
        var eventTapResults = [true, false, true]
        var availability: [Bool] = []
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { eventTapResults.removeFirst() },
            testEventTapStop: {}
        )
        session.onAvailabilityChange = { availability.append($0) }

        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.restartImmediatelyForTests()
        XCTAssertFalse(session.isActive)

        session.restartImmediatelyForTests()
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(driver.startCount, 2)
        XCTAssertEqual(availability, [true, false, true])
        session.deactivate()
    }

    func testRealSessionPropagatesFrameListenerStartupFailureToExtractionReadiness() {
        let driver = MockMultitouchFrameListener()
        driver.startSucceeds = false
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {}
        )
        let plugin = TrackpadGesturesPlugin(
            context: PluginRuntimeContext(
                pluginID: "trackpad-gestures",
                storage: TrackpadGestureMemoryStorage()
            ),
            legacyMiddleClick: nil,
            session: session,
            accessibilityTrusted: { true },
            requestAccessibilityTrust: { _ in true },
            inputMonitoringStatus: { .granted },
            openURL: { _ in }
        )
        XCTAssertTrue(plugin.store.save(TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick
        )))

        plugin.configurationDidChange()

        XCTAssertFalse(session.isActive)
        XCTAssertThrowsError(try plugin.validateFeatureExtractionReadiness())
        XCTAssertEqual(driver.startCount, 1)

        driver.startSucceeds = true
        session.restartImmediatelyForTests()
        XCTAssertTrue(session.isActive)
        XCTAssertNoThrow(try plugin.validateFeatureExtractionReadiness())
        XCTAssertEqual(driver.startCount, 2)
        plugin.deactivate(reason: .disabled)
    }

    func testEnablingLocalGestureRequestsOwnershipForTrackpadGestures() {
        let (plugin, _, _) = makePlugin()
        let mapping = TrackpadGestureMapping(
            gesture: .threeFingerTap,
            action: .middleClick,
            isEnabled: false
        )
        var ownershipRequests: [TrackpadGesture] = []
        plugin.requestTrackpadGestureOwnership = { ownershipRequests.append($0) }
        XCTAssertTrue(plugin.store.save(mapping))

        plugin.configurationDidChange()
        XCTAssertEqual(ownershipRequests, [])

        plugin.store.setEnabled(true, id: mapping.id)
        plugin.configurationDidChange()

        XCTAssertEqual(ownershipRequests, [.threeFingerTap])
    }

    func testExternalTipTapClaimConsumesTheNativeClick() {
        let (plugin, session, _) = makePlugin()
        let gesture = TrackpadGesture.tipTapLeftOneFixed

        plugin.setTrackpadGestureOwnership(localGestures: [], externalGestures: [gesture]) { _, _ in }
        plugin.activate(context: PluginRuntimeContext(pluginID: "trackpad-gestures"))

        XCTAssertEqual(session.nativeClickResolutionUpdates.last?[gesture], .consume)
    }

    func testSessionRestartsDriverWhenDeviceRemovalNotificationArrives() async throws {
        let driver = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            deviceChangeRestartDelay: 0
        )

        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.simulateDeviceRemovalNotificationForTests()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(driver.startCount, 2)
        XCTAssertGreaterThanOrEqual(driver.stopCount, 1)
        session.deactivate()
    }

    func testFrameCallbackGateRejectsWrongDeviceOldTimestampAndInvalidatedRegistration() {
        let gate = MultitouchFrameCallbackGate()
        let deliveryCount = LockedTestCounter()
        gate.activate(deviceIDs: [7], startedAt: 10) { _ in deliveryCount.increment() }

        XCTAssertFalse(gate.deliver(TrackpadContactFrame(
            deviceID: 8, timestamp: 11, contacts: []
        )))
        XCTAssertFalse(gate.deliver(TrackpadContactFrame(
            deviceID: 7, timestamp: 9.99, contacts: []
        )))
        XCTAssertTrue(gate.deliver(TrackpadContactFrame(
            deviceID: 7, timestamp: 10, contacts: []
        )))
        XCTAssertEqual(deliveryCount.value, 1)

        gate.invalidate()
        XCTAssertFalse(gate.deliver(TrackpadContactFrame(
            deviceID: 7, timestamp: 11, contacts: []
        )))
        XCTAssertEqual(deliveryCount.value, 1)
    }

    func testFrameCallbackGateInvalidationWaitsForAdmittedHandler() {
        let gate = MultitouchFrameCallbackGate()
        let barrier = TrackpadFrameDeliveryBarrier()
        let deliveryFinished = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)
        gate.activate(deviceIDs: [7], startedAt: 10) { _ in barrier.pauseDelivery() }

        DispatchQueue.global().async {
            gate.deliver(TrackpadContactFrame(deviceID: 7, timestamp: 10, contacts: []))
            deliveryFinished.signal()
        }
        XCTAssertEqual(barrier.waitForDelivery(), .success)
        DispatchQueue.global().async {
            barrier.startInvalidation()
            gate.invalidate()
            barrier.recordReset()
            invalidationFinished.signal()
        }
        XCTAssertEqual(barrier.waitForInvalidationAttempt(), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 0.05), .timedOut)

        barrier.finishDelivery()

        XCTAssertEqual(deliveryFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(barrier.events, ["delivery", "reset"])
    }

    func testFrameDeliveryGateInvalidationWaitsBeforeResettingAdmittedDelivery() {
        let gate = MultitouchFrameDeliveryGate()
        let generation = gate.beginGeneration()
        let barrier = TrackpadFrameDeliveryBarrier()
        let deliveryFinished = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            gate.deliver(generation: generation) {
                barrier.pauseDelivery()
            }
            deliveryFinished.signal()
        }
        XCTAssertEqual(barrier.waitForDelivery(), .success)
        DispatchQueue.global().async {
            barrier.startInvalidation()
            gate.invalidate {
                barrier.recordReset()
            }
            invalidationFinished.signal()
        }
        XCTAssertEqual(barrier.waitForInvalidationAttempt(), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 0.05), .timedOut)

        barrier.finishDelivery()

        XCTAssertEqual(deliveryFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(barrier.events, ["delivery", "reset"])
        let rejectedDeliveryCount = LockedTestCounter()
        XCTAssertFalse(gate.deliver(generation: generation) {
            rejectedDeliveryCount.increment()
        })
        XCTAssertEqual(rejectedDeliveryCount.value, 0)
    }

    func testSessionRecordsCandidateSynchronouslyBeforeNativeEventsAndRecognition() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        var postedTypes: [CGEventType] = []
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { postedTypes.append($0.type) },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.updateMiddleClickGestures([.threeFingerTap])
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))

        driver.send(makeThreeContactFrame())
        clock.value = 0.01
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        clock.value = 0.02
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseUp,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseUp))
        ))
        clock.value = 0.03
        XCTAssertTrue(session.resolveMiddleClick(for: .threeFingerTap, deviceID: 1))

        XCTAssertEqual(postedTypes, [.otherMouseDown, .otherMouseUp])
        session.deactivate()
    }

    func testTypingSuppressionRemembersContactFrameQueuedBeforeKeyDown() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let recognitionBarrier = TrackpadRecognitionFrameBarrier()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            recognitionBeforeFrameProcessing: { recognitionBarrier.pauseIfArmed() },
            middleClickClock: { clock.value }
        )
        var recognized: [TrackpadGesture] = []
        session.onRecognized = { gesture, _ in recognized.append(gesture) }
        session.updateTypingProtection(isEnabled: true, gracePeriod: 0.4)
        XCTAssertTrue(session.activate(gestures: [.tipTapLeftOneFixed]))
        defer {
            recognitionBarrier.resume()
            session.deactivate()
        }

        listener.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        session.waitForRecognitionForTests()

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let tapping = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        recognitionBarrier.arm()
        clock.value = 0.10
        listener.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        XCTAssertEqual(recognitionBarrier.waitUntilPaused(), .success)

        let keyDown = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))
        let keyUp = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: false
        ))
        clock.value = 0.11
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyDown, event: keyDown))
        clock.value = 0.12
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyUp, event: keyUp))
        recognitionBarrier.resume()
        session.waitForRecognitionForTests()

        clock.value = 0.60
        listener.send(.init(deviceID: 1, timestamp: 0.60, contacts: fixed))
        clock.value = 0.61
        listener.send(.init(deviceID: 1, timestamp: 0.61, contacts: fixed + [tapping]))
        clock.value = 0.66
        listener.send(.init(deviceID: 1, timestamp: 0.66, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()
        XCTAssertTrue(recognized.isEmpty)

        clock.value = 0.70
        listener.send(.init(deviceID: 1, timestamp: 0.70, contacts: []))
        clock.value = 0.80
        listener.send(.init(deviceID: 1, timestamp: 0.80, contacts: fixed))
        clock.value = 0.89
        listener.send(.init(deviceID: 1, timestamp: 0.89, contacts: fixed))
        clock.value = 0.90
        listener.send(.init(deviceID: 1, timestamp: 0.90, contacts: fixed + [tapping]))
        clock.value = 0.95
        listener.send(.init(deviceID: 1, timestamp: 0.95, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()

        XCTAssertEqual(recognized, [.tipTapLeftOneFixed])
    }

    func testSessionIgnoresMacToolsGeneratedShortcutKeysForTypingProtection() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            middleClickClock: { clock.value }
        )
        var recognized: [TrackpadGesture] = []
        session.onRecognized = { gesture, _ in recognized.append(gesture) }
        session.updateTypingProtection(isEnabled: true, gracePeriod: 1.0)
        XCTAssertTrue(session.activate(gestures: [.tipTapLeftOneFixed]))
        defer { session.deactivate() }

        let generatedKey = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))
        generatedKey.setIntegerValueField(
            .eventSourceUserData,
            value: TrackpadGestureActionExecutor.keyboardEventMarker
        )
        clock.value = 0.10
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyDown, event: generatedKey))

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let tapping = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        listener.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        listener.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.11, contacts: fixed + [tapping]))
        listener.send(.init(deviceID: 1, timestamp: 0.16, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()

        XCTAssertEqual(recognized, [.tipTapLeftOneFixed])
    }

    func testKeyDownInvalidatesRecognitionQueuedForMainActorDelivery() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            middleClickClock: { clock.value }
        )
        var recognized: [TrackpadGesture] = []
        session.onRecognized = { gesture, _ in recognized.append(gesture) }
        session.updateTypingProtection(isEnabled: true, gracePeriod: 0.4)
        XCTAssertTrue(session.activate(gestures: [.tipTapLeftOneFixed]))
        defer { session.deactivate() }

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let tapping = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        listener.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        listener.send(.init(deviceID: 1, timestamp: 0.01, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.10, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.11, contacts: fixed + [tapping]))
        listener.send(.init(deviceID: 1, timestamp: 0.16, contacts: fixed))
        session.waitForRecognitionForTests()

        let keyDown = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))
        clock.value = 0.17
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyDown, event: keyDown))
        await Task.yield()

        XCTAssertTrue(recognized.isEmpty)
    }

    func testDisabledTypingProtectionDoesNotSuppressGestureAfterKeyDown() async throws {
        let clock = LockedTestClock()
        let listener = MockMultitouchFrameListener()
        let session = MultitouchDeviceSession(
            driver: listener,
            testEventTapStart: { true },
            middleClickClock: { clock.value }
        )
        var recognized: [TrackpadGesture] = []
        session.onRecognized = { gesture, _ in recognized.append(gesture) }
        session.updateTypingProtection(isEnabled: false, gracePeriod: 1.0)
        XCTAssertTrue(session.activate(gestures: [.tipTapLeftOneFixed]))
        defer { session.deactivate() }

        listener.send(.init(deviceID: 1, timestamp: 0, contacts: []))
        session.waitForRecognitionForTests()

        let keyDown = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0,
            keyDown: true
        ))
        clock.value = 0.10
        XCTAssertFalse(session.handleNativeEventForTests(type: .keyDown, event: keyDown))

        let fixed = [TrackpadContactSnapshot(identifier: 1, x: 0.5, y: 0.5)]
        let tapping = TrackpadContactSnapshot(identifier: 2, x: 0.1, y: 0.5)
        listener.send(.init(deviceID: 1, timestamp: 0.20, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.29, contacts: fixed))
        listener.send(.init(deviceID: 1, timestamp: 0.30, contacts: fixed + [tapping]))
        listener.send(.init(deviceID: 1, timestamp: 0.35, contacts: fixed))
        session.waitForRecognitionForTests()
        await Task.yield()

        XCTAssertEqual(recognized, [.tipTapLeftOneFixed])
    }

    func testSessionRejectsRetainedListenerCallbackAfterRestart() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        let session = MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: { clock.value },
            synthesizeMiddleClick: {},
            releaseMiddleButton: {},
            postMiddleClickEvent: { _ in },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
        session.updateMiddleClickGestures([.threeFingerTap])
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        session.restartImmediatelyForTests()

        driver.send(makeThreeContactFrame(), usingStart: 0)
        clock.value = 0.01
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))

        // Move beyond the fail-safe window created by the passed-through stale-click probe,
        // then prove the current generation still accepts fresh frames.
        clock.value = 0.40
        driver.send(makeThreeContactFrame(), usingStart: 1)
        clock.value = 0.41
        XCTAssertTrue(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))
        session.deactivate()
    }

    func testSessionDeactivationBalancesRewrittenMiddleButtonDown() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        var releaseCount = 0
        let session = makeMiddleClickSession(
            driver: driver,
            now: { clock.value },
            releaseMiddleButton: { releaseCount += 1 }
        )
        session.updateMiddleClickGestures([.threeFingerTap])
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        driver.send(makeThreeContactFrame())
        clock.value = 0.01
        XCTAssertTrue(session.resolveMiddleClick(for: .threeFingerTap, deviceID: 1))
        clock.value = 0.02
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))

        session.deactivate()

        XCTAssertEqual(releaseCount, 1)
    }

    func testEventTapDisableBalancesRewrittenMiddleButtonDown() throws {
        let driver = MockMultitouchFrameListener()
        let clock = LockedTestClock()
        var releaseCount = 0
        let session = makeMiddleClickSession(
            driver: driver,
            now: { clock.value },
            releaseMiddleButton: { releaseCount += 1 }
        )
        session.updateMiddleClickGestures([.threeFingerTap])
        XCTAssertTrue(session.activate(gestures: [.threeFingerTap]))
        driver.send(makeThreeContactFrame())
        clock.value = 0.01
        XCTAssertTrue(session.resolveMiddleClick(for: .threeFingerTap, deviceID: 1))
        clock.value = 0.02
        XCTAssertFalse(session.handleNativeEventForTests(
            type: .leftMouseDown,
            event: try XCTUnwrap(makeMouseEvent(type: .leftMouseDown))
        ))

        session.simulateEventTapDisableForTests()

        XCTAssertEqual(releaseCount, 1)
        session.deactivate()
    }

    private func makeMiddleClickSession(
        driver: MockMultitouchFrameListener,
        now: @escaping @Sendable () -> TimeInterval,
        releaseMiddleButton: @escaping @Sendable @MainActor () -> Void
    ) -> MultitouchDeviceSession {
        MultitouchDeviceSession(
            driver: driver,
            testEventTapStart: { true },
            testEventTapStop: {},
            middleClickClock: now,
            synthesizeMiddleClick: {},
            releaseMiddleButton: releaseMiddleButton,
            postMiddleClickEvent: { _ in },
            middleClickEventOrigin: { _ in .trackpad(deviceID: 1) }
        )
    }

    private func makeThreeContactFrame() -> TrackpadContactFrame {
        TrackpadContactFrame(
            deviceID: 1,
            timestamp: 0,
            contacts: [
                .init(identifier: 1, x: 0.2, y: 0.5),
                .init(identifier: 2, x: 0.5, y: 0.5),
                .init(identifier: 3, x: 0.8, y: 0.5),
            ]
        )
    }

    private func makeMouseEvent(type: CGEventType) -> CGEvent? {
        CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .left
        )
    }

    private func makePlugin(
        accessibilityTrusted: @escaping @Sendable @MainActor () -> Bool = { true },
        inputMonitoringStatus: @escaping @Sendable @MainActor () -> TrackpadInputMonitoringStatus = {
            .granted
        }
    ) -> (
        plugin: TrackpadGesturesPlugin,
        session: MockMultitouchDeviceSession,
        executor: MockTrackpadGestureActionExecutor
    ) {
        let session = MockMultitouchDeviceSession()
        let executor = MockTrackpadGestureActionExecutor()
        let plugin = TrackpadGesturesPlugin(
            context: PluginRuntimeContext(
                pluginID: "trackpad-gestures",
                storage: TrackpadGestureMemoryStorage()
            ),
            legacyMiddleClick: nil,
            session: session,
            actionExecutor: executor,
            accessibilityTrusted: accessibilityTrusted,
            requestAccessibilityTrust: { _ in accessibilityTrusted() },
            inputMonitoringStatus: inputMonitoringStatus,
            openURL: { _ in }
        )
        return (plugin, session, executor)
    }
}
