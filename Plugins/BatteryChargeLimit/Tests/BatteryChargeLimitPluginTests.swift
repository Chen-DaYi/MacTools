import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import BatteryChargeLimitPlugin

// MARK: - Mocks

@MainActor
private final class MockBatteryReader: BatteryChargeLimitReading {
    var snapshot: BatterySnapshot
    private(set) var readCount = 0

    init(snapshot: BatterySnapshot = .empty) {
        self.snapshot = snapshot
    }

    func readSnapshot() -> BatterySnapshot {
        readCount += 1
        return snapshot
    }
}

@MainActor
private final class MockBatteryWriter: BatteryChargeLimitWriting {
    var isHelperAvailable: Bool
    var isInstalledHelperAvailable: Bool
    var capabilities: BatterySMCCapabilities
    var inhibitCalls: [Int] = []
    var resumeCalls: Int = 0
    var dischargeCalls: [Bool] = []
    var nextError: BatteryChargeWriteError?

    init(
        isHelperAvailable: Bool = true,
        isInstalledHelperAvailable: Bool = true,
        capabilities: BatterySMCCapabilities = BatterySMCCapabilities(
            hasCHTE: false, hasCH0BC: true, hasBCLM: false, hasCH0I: true
        )
    ) {
        self.isHelperAvailable = isHelperAvailable
        self.isInstalledHelperAvailable = isInstalledHelperAvailable
        self.capabilities = capabilities
    }

    func probeCapabilities() -> BatterySMCCapabilities { capabilities }

    @discardableResult
    func inhibitCharging(limitPercent: Int) -> BatteryChargeWriteError? {
        inhibitCalls.append(limitPercent)
        return nextError
    }

    @discardableResult
    func resumeCharging() -> BatteryChargeWriteError? {
        resumeCalls += 1
        return nextError
    }

    @discardableResult
    func setForceDischarge(_ on: Bool) -> BatteryChargeWriteError? {
        dischargeCalls.append(on)
        return nextError
    }
}

// MARK: - Tests

@MainActor
final class BatteryChargeLimitPluginTests: XCTestCase {

    // MARK: Metadata
    func testPanelHiddenWhenNoBattery() {
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: .empty))

        XCTAssertFalse(plugin.primaryPanelState.isVisible)
    }

    func testPanelVisibleWhenBatteryPresent() {
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 65)))
        plugin.refresh()

        XCTAssertTrue(plugin.primaryPanelState.isVisible)
    }

    // MARK: Enable / Disable

    func testEnableTogglePersistsAndInhibitsCharging() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()

        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        XCTAssertTrue(plugin.store.isEnabled)
        XCTAssertEqual(writer.inhibitCalls, [BatteryChargeLimits.defaultPercent])
    }

    func testDisableTogglePersistsAndResumesCharging() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()

        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertGreaterThanOrEqual(writer.resumeCalls, 1)
    }

    func testEnableWithUnsupportedHardwareSurfacesError() {
        let writer = MockBatteryWriter(capabilities: .none)
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()

        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testActivateWhenDisabledReadsOnceWithoutStartingMonitoring() async {
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 60))
        let plugin = makePlugin(reader: reader)

        plugin.activate(context: PluginRuntimeContext(pluginID: "battery-charge-limit"))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(reader.readCount, 1)
    }

    func testActivateWhenEnabledStartsMonitoring() async {
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 60))
        let plugin = makePlugin(reader: reader)
        plugin.store.setEnabled(true)

        plugin.activate(context: PluginRuntimeContext(pluginID: "battery-charge-limit"))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertGreaterThanOrEqual(reader.readCount, 2)
        plugin.deactivate(reason: .updating)
    }

    func testDeactivateWithoutEnablingDoesNotWriteSMC() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)

        plugin.deactivate(reason: .hostShutdown)

        XCTAssertEqual(writer.resumeCalls, 0)
        XCTAssertTrue(writer.dischargeCalls.isEmpty)
    }

    func testDeactivateWhenEnabledRestoresUnrestrictedCharging() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        writer.resumeCalls = 0
        writer.dischargeCalls = []

        plugin.deactivate(reason: .hostShutdown)

        XCTAssertEqual(writer.resumeCalls, 1)
        XCTAssertEqual(writer.dischargeCalls, [false])
    }

    func testDeactivateWhenEnabledButHelperNotInstalledSkipsCleanup() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        writer.resumeCalls = 0
        writer.dischargeCalls = []
        writer.isInstalledHelperAvailable = false

        plugin.deactivate(reason: .hostShutdown)

        XCTAssertEqual(writer.resumeCalls, 0)
        XCTAssertTrue(writer.dischargeCalls.isEmpty)
    }

    func testDeactivateWhileChargingDoesNotRepeatCleanup() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        plugin.handleAction(.invokeAction(controlID: "battery-charge-action"))
        writer.resumeCalls = 0
        writer.dischargeCalls = []

        plugin.deactivate(reason: .hostShutdown)

        XCTAssertEqual(writer.resumeCalls, 0)
        XCTAssertTrue(writer.dischargeCalls.isEmpty)
    }

    func testDeactivateAfterFailedEnableDoesNotRetryCleanup() {
        let writer = MockBatteryWriter(capabilities: .none)
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()

        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        plugin.deactivate(reason: .hostShutdown)

        XCTAssertEqual(writer.resumeCalls, 0)
        XCTAssertTrue(writer.dischargeCalls.isEmpty)
    }

    // MARK: Limit Changes

    func testLimitSliderUpdatesPersistedLimitOnEnd() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        plugin.handleAction(.setSlider(controlID: "battery-limit-slider", value: 70, phase: .ended))

        XCTAssertEqual(plugin.store.limitPercent, 70)
        // Limit change re-applies holdAtLimit using the new value.
        XCTAssertTrue(writer.inhibitCalls.contains(70))
    }

    func testLimitSliderChangedPhaseDoesNotPersist() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()

        plugin.handleAction(.setSlider(controlID: "battery-limit-slider", value: 70, phase: .changed))

        XCTAssertEqual(plugin.store.limitPercent, BatteryChargeLimits.defaultPercent)
    }

    // MARK: Mode Transitions

    func testStartChargingResumesAndTransitionsToCharging() {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        writer.resumeCalls = 0

        plugin.handleAction(.invokeAction(controlID: "battery-charge-action"))

        XCTAssertEqual(plugin.store.mode, .charging)
        XCTAssertGreaterThanOrEqual(writer.resumeCalls, 1)
    }

    func testReachingLimitWhileChargingTransitionsBackToHold() {
        let writer = MockBatteryWriter()
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 60))
        let plugin = makePlugin(reader: reader, writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        plugin.handleAction(.invokeAction(controlID: "battery-charge-action"))
        XCTAssertEqual(plugin.store.mode, .charging)

        // Simulate the battery reaching the configured limit.
        reader.snapshot = makeSnapshot(level: BatteryChargeLimits.defaultPercent)
        plugin.refresh()

        XCTAssertEqual(plugin.store.mode, .holdAtLimit)
    }

    func testHoldAtLimitDoesNotAutoResumeBelowLimit() {
        let writer = MockBatteryWriter()
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 60))
        let plugin = makePlugin(reader: reader, writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        writer.resumeCalls = 0

        // Battery drops further while in holdAtLimit — mode must NOT transition
        // back to .charging on its own. This is the core behavior contract.
        reader.snapshot = makeSnapshot(level: 50)
        plugin.refresh()
        reader.snapshot = makeSnapshot(level: 40)
        plugin.refresh()

        XCTAssertEqual(plugin.store.mode, .holdAtLimit)
        XCTAssertEqual(writer.resumeCalls, 0, "Plugin must not call resumeCharging() while in holdAtLimit")
    }

    func testForceDischargeStartsWhenSupportedAndAboveLimit() {
        let writer = MockBatteryWriter()
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 90))
        let plugin = makePlugin(reader: reader, writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))

        plugin.handleAction(.invokeAction(controlID: "battery-discharge-action"))

        XCTAssertEqual(plugin.store.mode, .discharging)
        XCTAssertTrue(writer.dischargeCalls.contains(true))
    }

    func testCanonicalActionsPublishLimitsAndExplicitModes() {
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 90)))
        plugin.refresh()

        XCTAssertEqual(plugin.actionDefinitions.map(\.key.actionID), [
            "set-enabled", "set-limit", "hold", "resume", "discharge",
        ])
        XCTAssertTrue(plugin.actionCatalogEntries.contains(where: { $0.title.contains("80%") }))
        XCTAssertEqual(
            plugin.actionDefinitions.first(where: { $0.key.actionID == "discharge" })?.risk,
            .confirmationRequired
        )
    }

    func testCanonicalEnableAndLimitActionsUseExistingMutationPaths() async throws {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)), writer: writer)
        plugin.refresh()
        let enable = try XCTUnwrap(
            plugin.actionCatalogEntries.first(where: { $0.reference.key.actionID == "set-enabled" })?.reference
        )
        let limit = try XCTUnwrap(
            plugin.actionCatalogEntries.first(where: { $0.title.contains("70%") })?.reference
        )

        let enableResult = try await plugin.beginAction(
            ActionInvocation(reference: enable, source: .test, mode: .background)
        ).result()
        let limitResult = try await plugin.beginAction(
            ActionInvocation(reference: limit, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(enableResult, .succeeded())
        XCTAssertEqual(limitResult, .succeeded())
        XCTAssertTrue(plugin.store.isEnabled)
        XCTAssertEqual(plugin.store.limitPercent, 70)
        XCTAssertTrue(writer.inhibitCalls.contains(70))
    }

    func testCanonicalActionDefersMutationUntilHandleStarts() async throws {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(
            reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)),
            writer: writer
        )
        plugin.refresh()
        let enable = try XCTUnwrap(
            plugin.actionCatalogEntries.first(where: {
                $0.reference.key.actionID == "set-enabled"
            })?.reference
        )

        let handle = try plugin.beginAction(ActionInvocation(
            reference: enable,
            source: .test,
            mode: .foreground
        ))

        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertTrue(writer.inhibitCalls.isEmpty)
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertTrue(plugin.store.isEnabled)
        XCTAssertFalse(writer.inhibitCalls.isEmpty)
    }

    func testCanonicalActionsRequireForegroundWhenHelperIsNotInstalled() async throws {
        let writer = MockBatteryWriter(isInstalledHelperAvailable: false)
        let plugin = makePlugin(
            reader: MockBatteryReader(snapshot: makeSnapshot(level: 60)),
            writer: writer
        )
        plugin.refresh()
        let enable = try XCTUnwrap(
            plugin.actionCatalogEntries.first(where: {
                $0.reference.key.actionID == "set-enabled"
            })?.reference
        )

        XCTAssertTrue(plugin.actionDefinitions.allSatisfy {
            !$0.capabilities.contains(.background)
                && $0.capabilities.contains(.foregroundInteractive)
        })
        let result = try await plugin.beginAction(ActionInvocation(
            reference: enable,
            source: .workflow,
            mode: .background
        )).result()

        XCTAssertEqual(result, .failed(message: PluginKitLocalization.actionUnavailable))
        XCTAssertFalse(plugin.store.isEnabled)
        XCTAssertTrue(writer.inhibitCalls.isEmpty)
    }

    func testCanonicalDischargeRequiresEnabledSupportedState() async throws {
        let writer = MockBatteryWriter()
        let plugin = makePlugin(reader: MockBatteryReader(snapshot: makeSnapshot(level: 90)), writer: writer)
        plugin.refresh()
        let discharge = try XCTUnwrap(
            plugin.actionCatalogEntries.first(where: { $0.reference.key.actionID == "discharge" })?.reference
        )

        XCTAssertFalse(plugin.actionAvailability(for: discharge).isAvailable)

        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        XCTAssertTrue(plugin.actionAvailability(for: discharge).isAvailable)
        let result = try await plugin.beginAction(
            ActionInvocation(reference: discharge, source: .test, mode: .background)
        ).result()

        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(plugin.store.mode, .discharging)
        XCTAssertTrue(writer.dischargeCalls.contains(true))
    }

    func testForceDischargeStopsWhenReachingLimit() {
        let writer = MockBatteryWriter()
        let reader = MockBatteryReader(snapshot: makeSnapshot(level: 90))
        let plugin = makePlugin(reader: reader, writer: writer)
        plugin.refresh()
        plugin.handleAction(.invokeAction(controlID: "battery-enable-action"))
        plugin.handleAction(.invokeAction(controlID: "battery-discharge-action"))

        reader.snapshot = makeSnapshot(level: BatteryChargeLimits.defaultPercent)
        plugin.refresh()

        XCTAssertEqual(plugin.store.mode, .holdAtLimit)
    }

    // MARK: Permissions
    private func makePlugin(
        reader: MockBatteryReader? = nil,
        writer: MockBatteryWriter? = nil
    ) -> BatteryChargeLimitPlugin {
        let suiteName = "BatteryChargeLimitPluginTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storage = UserDefaultsPluginStorage(pluginID: "battery-charge-limit", userDefaults: defaults)
        let context = PluginRuntimeContext(pluginID: "battery-charge-limit", storage: storage)
        return BatteryChargeLimitPlugin(
            context: context,
            reader: reader ?? MockBatteryReader(),
            writer: writer ?? MockBatteryWriter()
        )
    }

    private func makeSnapshot(level: Int, state: BatteryPowerState = .acPower, isOnAdapter: Bool = true) -> BatterySnapshot {
        BatterySnapshot(
            isAvailable: true,
            levelPercent: level,
            state: state,
            isOnAdapter: isOnAdapter
        )
    }
}
