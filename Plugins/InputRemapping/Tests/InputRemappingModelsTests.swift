import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit
import XCTest
@testable import InputRemappingPlugin

@MainActor
private final class InputRemappingMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}

private final class InputRemappingTapSpy: InputRemappingEventTapping {
    private(set) var rules: [InputRemappingRule] = []
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var cancelCaptureCallCount = 0
    var startResult = true
    var captureHandler: (@Sendable (InputRemappingCapturedInput) -> Void)?
    var shortcutCaptureHandler: (@Sendable (ShortcutBinding) -> Void)?
    private(set) var executedActions: [InputRemappingRule.Action] = []

    func update(rules: [InputRemappingRule]) {
        self.rules = rules
    }

    func start() -> Bool {
        startCallCount += 1
        return startResult
    }

    func stop() {
        stopCallCount += 1
    }

    func beginInputCapture(_ handler: @escaping @Sendable (InputRemappingCapturedInput) -> Void) -> Bool {
        captureHandler = handler
        return startResult
    }

    func beginShortcutCapture(_ handler: @escaping @Sendable (ShortcutBinding) -> Void) -> Bool {
        shortcutCaptureHandler = handler
        return startResult
    }

    func cancelButtonCapture() {
        cancelCaptureCallCount += 1
        captureHandler = nil
        shortcutCaptureHandler = nil
    }

    func execute(_ action: InputRemappingRule.Action) -> Bool {
        executedActions.append(action)
        return true
    }

    func capture(_ input: InputRemappingCapturedInput) {
        captureHandler?(input)
    }

    func capture(shortcut: ShortcutBinding) {
        shortcutCaptureHandler?(shortcut)
    }
}

@MainActor
private final class InputRemappingPermissionState {
    var accessibilityGranted = false
    var inputMonitoringStatus: InputRemappingInputMonitoringStatus = .denied
}

final class InputRemappingModelsTests: XCTestCase {

    func testShortcutActionKindStaysSelectedAfterRecording() {
        let recorded = InputRemappingRule.Action.shortcut(ShortcutBinding(keyCode: 21, modifiers: [.command, .shift]))

        XCTAssertEqual(recorded.kind, .shortcut)
        XCTAssertEqual(recorded.replacingKind(.shortcut), recorded)
    }
    func testMatcherRequiresEligibleButtonAndExactModifiers() {
        let rule = InputRemappingRule(
            buttonNumber: 4,
            modifiers: [.command],
            action: .mouseBack
        )

        XCTAssertEqual(
            InputRemappingRuleMatcher.rule(for: 4, flags: [.maskCommand], in: [rule])?.id,
            rule.id
        )
        XCTAssertNil(InputRemappingRuleMatcher.rule(for: 2, flags: [.maskCommand], in: [rule]))
        XCTAssertNil(InputRemappingRuleMatcher.rule(for: 33, flags: [.maskCommand], in: [rule]))
        XCTAssertNil(InputRemappingRuleMatcher.rule(for: 4, flags: [], in: [rule]))
    }

    func testRuleNormalizesButtonNumberUsingSharedPolicy() {
        XCTAssertEqual(
            InputRemappingRule(buttonNumber: -1).buttonNumber,
            InputRemappingRulePolicy.minimumButtonNumber
        )
        XCTAssertEqual(
            InputRemappingRule(buttonNumber: 100).buttonNumber,
            InputRemappingRulePolicy.maximumButtonNumber
        )
    }

    func testSuccessfulDownConsumesMatchingUpWithoutExecutingTwice() {
        let rule = InputRemappingRule(buttonNumber: 4, action: .mouseBack)
        var processor = InputRemappingEventProcessor()
        var executions: [InputRemappingRule.Action] = []

        XCTAssertTrue(processor.shouldConsume(
            phase: .down,
            buttonNumber: 4,
            flags: [],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: {
                executions.append($0)
                return true
            }
        ))
        XCTAssertTrue(processor.shouldConsume(
            phase: .up,
            buttonNumber: 4,
            flags: [],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in XCTFail("Mouse-up must not execute an action"); return true }
        ))
        XCTAssertEqual(executions, [.mouseBack])
    }

    func testSuccessfulKeyboardDownConsumesMatchingUpWithoutExecutingTwice() {
        let rule = InputRemappingRule(
            trigger: .keyboard(keyCode: 12, modifiers: [.command]),
            action: .mouseBack
        )
        var processor = InputRemappingEventProcessor()
        var executions = 0

        XCTAssertTrue(processor.shouldConsumeKeyboard(
            isKeyDown: true,
            keyCode: 12,
            flags: [.maskCommand],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in executions += 1; return true }
        ))
        XCTAssertTrue(processor.shouldConsumeKeyboard(
            isKeyDown: false,
            keyCode: 12,
            flags: [.maskCommand],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in XCTFail("Key-up must not execute an action"); return true }
        ))
        XCTAssertEqual(executions, 1)
    }

    func testUnmodifiedKeyboardTriggerStartsDisabledUntilConfirmed() {
        let rule = InputRemappingRule(
            isEnabled: true,
            trigger: .keyboard(keyCode: 12, modifiers: []),
            action: .mouseBack
        )
        XCTAssertFalse(rule.isEnabled)

        var editedRule = InputRemappingRule(buttonNumber: 4)
        editedRule.replaceTrigger(.keyboard(keyCode: 12, modifiers: []))
        XCTAssertFalse(editedRule.isEnabled)
    }

    func testDoubleClickExecutesWithoutConsumingTheNativeClickPair() {
        let rule = InputRemappingRule(
            trigger: .mouseButton(number: 4, modifiers: [], interaction: .doubleClick),
            action: .mouseBack
        )
        var processor = InputRemappingEventProcessor()
        var executions = 0

        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [], isMarkedSynthetic: false, rules: [rule], timestamp: 1, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .up, buttonNumber: 4, flags: [], isMarkedSynthetic: false, rules: [rule], timestamp: 1.01, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .down, buttonNumber: 4, flags: [], isMarkedSynthetic: false, rules: [rule], timestamp: 1.1, execute: { _ in executions += 1; return true }))
        XCTAssertFalse(processor.shouldConsume(phase: .up, buttonNumber: 4, flags: [], isMarkedSynthetic: false, rules: [rule], timestamp: 1.11, execute: { _ in executions += 1; return true }))
        XCTAssertEqual(executions, 1)
    }

    func testScrollRuleMatchesOnlyItsDirectionAndModifiers() {
        let rule = InputRemappingRule(
            trigger: .scroll(direction: .up, modifiers: [.command]),
            action: .mouseBack
        )
        XCTAssertEqual(InputRemappingRuleMatcher.scrollRule(for: .up, flags: [.maskCommand], in: [rule])?.id, rule.id)
        XCTAssertNil(InputRemappingRuleMatcher.scrollRule(for: .down, flags: [.maskCommand], in: [rule]))
        XCTAssertNil(InputRemappingRuleMatcher.scrollRule(for: .up, flags: [], in: [rule]))
    }

    @MainActor
    func testTrackpadGestureClaimExecutesOnlyItsMappedAction() throws {
        let tap = InputRemappingTapSpy()
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(pluginID: "input-remapping", storage: InputRemappingMemoryStorage()),
            tap: tap,
            accessibilityTrusted: { true },
            inputMonitoringStatus: { .granted }
        )
        plugin.store.addRule()
        var rule = try XCTUnwrap(plugin.store.rules.first)
        rule.replaceTrigger(.trackpadGesture(.threeFingerTap))
        rule.action = .mouseBack
        plugin.store.replace(rule)

        XCTAssertEqual(plugin.claimedTrackpadGestures, [.threeFingerTap])
        plugin.receiveTrackpadGesture(.threeFingerTap, deviceID: 1)
        XCTAssertEqual(tap.executedActions, [.mouseBack])
    }

    func testFailedOrInapplicableDownAndUnpairedUpFailOpen() {
        let rule = InputRemappingRule(buttonNumber: 4, action: .mouseBack)
        var processor = InputRemappingEventProcessor()

        XCTAssertFalse(processor.shouldConsume(
            phase: .down,
            buttonNumber: 4,
            flags: [],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in false }
        ))
        XCTAssertFalse(processor.shouldConsume(
            phase: .up,
            buttonNumber: 4,
            flags: [],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in true }
        ))
        XCTAssertFalse(processor.shouldConsume(
            phase: .down,
            buttonNumber: 5,
            flags: [],
            isMarkedSynthetic: false,
            rules: [rule],
            execute: { _ in XCTFail("An inapplicable rule must not execute"); return true }
        ))
    }

    func testEventsMarkedByInputRemappingAlwaysPassThrough() {
        let rule = InputRemappingRule(buttonNumber: 4, action: .mouseBack)
        var processor = InputRemappingEventProcessor()

        XCTAssertFalse(processor.shouldConsume(
            phase: .down,
            buttonNumber: 4,
            flags: [],
            isMarkedSynthetic: true,
            rules: [rule],
            execute: { _ in XCTFail("Marked event must not execute"); return true }
        ))
    }

    func testSystemDefinedMediaEventEncodesDownAndUpStateOnce() {
        let keyType: Int32 = 16

        XCTAssertEqual(
            InputRemappingSystemDefinedEvent.data1(
                keyType: keyType,
                state: InputRemappingSystemDefinedEvent.keyDownState
            ),
            Int((keyType << 16) | 0xA00)
        )
        XCTAssertEqual(
            InputRemappingSystemDefinedEvent.data1(
                keyType: keyType,
                state: InputRemappingSystemDefinedEvent.keyUpState
            ),
            Int((keyType << 16) | 0xB00)
        )
    }

    @MainActor
    func testStorePersistsAndReloadsRules() throws {
        let storage = InputRemappingMemoryStorage()
        let firstStore = InputRemappingStore(storage: storage)
        firstStore.addRule()
        let savedRule = try XCTUnwrap(firstStore.rules.first)
        var editedRule = savedRule
        editedRule.buttonNumber = 7
        editedRule.action = .volumeUp
        firstStore.replace(editedRule)

        let secondStore = InputRemappingStore(storage: storage)

        XCTAssertEqual(secondStore.rules, [editedRule])
    }

    @MainActor
    func testStoreNormalizesCopiedAndPersistedButtonNumbers() throws {
        let storage = InputRemappingMemoryStorage()
        let store = InputRemappingStore(storage: storage)
        store.addRule()
        var copiedRule = try XCTUnwrap(store.rules.first)
        copiedRule.buttonNumber = 99
        store.replace(copiedRule)
        XCTAssertEqual(store.rules.first?.buttonNumber, InputRemappingRulePolicy.maximumButtonNumber)

        let data = try XCTUnwrap(storage.data(forKey: "input-remapping.rules.v1"))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var trigger = try XCTUnwrap(payload[0]["trigger"] as? [String: Any])
        trigger["number"] = -1
        payload[0]["trigger"] = trigger
        storage.set(try JSONSerialization.data(withJSONObject: payload), forKey: "input-remapping.rules.v1")

        let reloadedStore = InputRemappingStore(storage: storage)
        XCTAssertEqual(
            reloadedStore.rules.first?.buttonNumber,
            InputRemappingRulePolicy.minimumButtonNumber
        )
    }

    @MainActor
    func testPermissionStatesReflectProvidersAndActionsAreReal() {
        let tap = InputRemappingTapSpy()
        var requestedAccessibility = false
        var openedURL: URL?
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(
                pluginID: "input-remapping",
                storage: InputRemappingMemoryStorage()
            ),
            tap: tap,
            accessibilityTrusted: { requestedAccessibility },
            requestAccessibilityTrust: { prompt in
                requestedAccessibility = prompt
                return requestedAccessibility
            },
            inputMonitoringStatus: { .denied },
            openURL: { openedURL = $0 }
        )

        XCTAssertFalse(plugin.permissionState(for: "accessibility").isGranted)
        XCTAssertFalse(plugin.permissionState(for: "input-monitoring").isGranted)
        XCTAssertFalse(plugin.permissionState(for: "unknown").isGranted)

        plugin.handlePermissionAction(id: "accessibility")
        XCTAssertTrue(plugin.permissionState(for: "accessibility").isGranted)

        plugin.handlePermissionAction(id: "input-monitoring")
        XCTAssertTrue(openedURL?.absoluteString.contains("Privacy_ListenEvent") == true)
    }

    @MainActor
    func testRulesStartOnlyWithBothPermissionsAndEveryDeactivationStopsTap() {
        let storage = InputRemappingMemoryStorage()
        let store = InputRemappingStore(storage: storage)
        store.addRule()
        let tap = InputRemappingTapSpy()
        let permissionState = InputRemappingPermissionState()
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(pluginID: "input-remapping", storage: storage),
            tap: tap,
            accessibilityTrusted: { true },
            inputMonitoringStatus: { permissionState.inputMonitoringStatus }
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "input-remapping"))
        XCTAssertEqual(tap.startCallCount, 0)
        XCTAssertGreaterThan(tap.stopCallCount, 0)

        permissionState.inputMonitoringStatus = .granted
        plugin.refresh()
        XCTAssertEqual(tap.startCallCount, 1)

        plugin.deactivate(reason: .updating)
        XCTAssertGreaterThanOrEqual(tap.stopCallCount, 2)
    }

    @MainActor
    func testAppReactivationResamplesPermissionsAndDeactivationRemovesObserver() async {
        let storage = InputRemappingMemoryStorage()
        InputRemappingStore(storage: storage).addRule()
        let tap = InputRemappingTapSpy()
        let notificationCenter = NotificationCenter()
        let permissionState = InputRemappingPermissionState()
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(pluginID: "input-remapping", storage: storage),
            tap: tap,
            accessibilityTrusted: { permissionState.accessibilityGranted },
            inputMonitoringStatus: { permissionState.inputMonitoringStatus },
            notificationCenter: notificationCenter
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "input-remapping"))
        XCTAssertEqual(tap.startCallCount, 0)

        permissionState.accessibilityGranted = true
        permissionState.inputMonitoringStatus = .granted
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(tap.startCallCount, 1)

        permissionState.accessibilityGranted = false
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertGreaterThan(tap.stopCallCount, 0)

        plugin.deactivate(reason: .disabled)
        let startCountAfterDeactivation = tap.startCallCount
        permissionState.accessibilityGranted = true
        notificationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Task.yield()
        XCTAssertEqual(tap.startCallCount, startCountAfterDeactivation)
    }

    @MainActor
    func testSettingsPageUsesValidFormContract() throws {
        let plugin = InputRemappingPlugin(
            context: PluginRuntimeContext(
                pluginID: "input-remapping",
                storage: InputRemappingMemoryStorage()
            ),
            tap: InputRemappingTapSpy(),
            accessibilityTrusted: { false },
            inputMonitoringStatus: { .denied }
        )
        let page = try XCTUnwrap(plugin.settingsPage)

        XCTAssertEqual(page.body.layout, .form)
        guard case let .form(sections) = page.body else {
            return XCTFail("Expected form settings")
        }
        XCTAssertNotNil(sections.first?.headerAccessory)
        XCTAssertNoThrow(try PluginSettingsValidator.validate(page))
    }

    @MainActor
    func testButtonCaptureRecordsAnEligibleButtonAndCanBeCancelled() async {
        let tap = InputRemappingTapSpy()
        let coordinator = InputRemappingButtonCaptureCoordinator(
            tap: tap,
            scheduleArming: { $0() }
        )
        var capturedInput: InputRemappingCapturedInput?

        XCTAssertTrue(coordinator.start(ruleID: UUID()) {
            capturedInput = $0
        })
        tap.capture(.mouseButton(number: 4, modifiers: []))
        await Task.yield()

        XCTAssertEqual(capturedInput, .mouseButton(number: 4, modifiers: []))
        XCTAssertNil(coordinator.recordingRuleID)

        XCTAssertTrue(coordinator.start(ruleID: UUID()) { _ in })
        coordinator.cancel()
        XCTAssertNil(coordinator.recordingRuleID)
        XCTAssertEqual(tap.cancelCaptureCallCount, 1)
    }

    @MainActor
    func testShortcutCaptureRecordsAKeyboardBinding() async {
        let tap = InputRemappingTapSpy()
        let coordinator = InputRemappingButtonCaptureCoordinator(
            tap: tap,
            scheduleArming: { $0() }
        )
        var captured: ShortcutBinding?

        XCTAssertTrue(coordinator.startShortcut(ruleID: UUID()) { captured = $0 })
        tap.capture(shortcut: ShortcutBinding(keyCode: 12, modifiers: [.command]))
        await Task.yield()

        XCTAssertEqual(captured, ShortcutBinding(keyCode: 12, modifiers: [.command]))
        XCTAssertNil(coordinator.recordingShortcutRuleID)
    }

    @MainActor
    func testInputCaptureIgnoresTheClickThatOpenedRecording() async throws {
        let tap = InputRemappingTapSpy()
        var pendingArming: (@MainActor () -> Void)?
        let coordinator = InputRemappingButtonCaptureCoordinator(
            tap: tap,
            scheduleArming: { pendingArming = $0 }
        )
        var captured: InputRemappingCapturedInput?

        XCTAssertTrue(coordinator.start(ruleID: UUID()) { captured = $0 })
        XCTAssertNotNil(coordinator.preparingRuleID)
        tap.capture(.mouseButton(number: 0, modifiers: []))
        await Task.yield()
        XCTAssertNil(captured)

        let arm = try XCTUnwrap(pendingArming)
        arm()
        tap.capture(.mouseButton(number: 4, modifiers: []))
        await Task.yield()
        XCTAssertEqual(captured, .mouseButton(number: 4, modifiers: []))
    }
}
