import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import FanControlPlugin

// MARK: - Mock SMC Reader

@MainActor
private final class MockSMCReader: FanControlSMCReading {
    var snapshot: FanSnapshot
    var snapshots: [FanSnapshot]
    private(set) var readCount = 0

    init(snapshot: FanSnapshot = .empty, snapshots: [FanSnapshot] = []) {
        self.snapshot = snapshot
        self.snapshots = snapshots
    }

    func readSnapshot() -> FanSnapshot {
        readCount += 1
        guard !snapshots.isEmpty else {
            return snapshot
        }
        return snapshots.removeFirst()
    }
}

// MARK: - Mock SMC Writer

@MainActor
private final class MockSMCWriter: FanControlSMCWriting {
    var isHelperAvailable: Bool
    var appliedStrategy: FanControlStrategy?
    var writeError: FanWriteError?

    init(isHelperAvailable: Bool = true) {
        self.isHelperAvailable = isHelperAvailable
    }

    @discardableResult
    func apply(strategy: FanControlStrategy, snapshot: FanSnapshot) -> FanWriteError? {
        appliedStrategy = strategy
        return writeError
    }
}

// MARK: - FanControlPluginTests

@MainActor
final class FanControlPluginTests: XCTestCase {

    // MARK: - Metadata

    func testMetadataIdentifiesFanControlPlugin() {
        let plugin = makeFanControlPlugin()

        XCTAssertEqual(plugin.metadata.id, "fan-control")
        XCTAssertEqual(plugin.metadata.title, "风扇控制")
    }

    func testMetadataDefaultDescription() {
        let plugin = makeFanControlPlugin()

        XCTAssertEqual(plugin.metadata.defaultDescription, "管理风扇转速预设")
    }

    func testControlStyleIsDisclosure() {
        let plugin = makeFanControlPlugin()

        XCTAssertEqual(plugin.primaryPanelDescriptor.controlStyle, .disclosure)
    }

    // MARK: - Panel State

    func testInitialPanelStateIsNotExpanded() {
        let plugin = makeFanControlPlugin()

        XCTAssertFalse(plugin.primaryPanelState.isExpanded)
    }

    func testInitialPanelStateIsEnabled() {
        let plugin = makeFanControlPlugin()

        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
    }

    func testInitialPanelStateHasNoError() {
        let plugin = makeFanControlPlugin()

        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSubtitleContainsActivePresetNameWhenNoSnapshot() {
        let plugin = makeFanControlPlugin()

        XCTAssertTrue(plugin.primaryPanelState.subtitle.contains("自动"))
    }

    func testSubtitleContainsRPMWhenSnapshotHasFanSpeed() {
        let snapshot = FanSnapshot(
            fanCount: 1,
            fanSpeeds: [3600],
            fanMinSpeeds: [1200],
            fanMaxSpeeds: [5200],
            cpuTemperature: 45.0
        )
        let reader = MockSMCReader(snapshot: snapshot)
        let plugin = makeFanControlPlugin(reader: reader)

        plugin.refresh()

        XCTAssertTrue(plugin.primaryPanelState.subtitle.contains("3600 RPM"))
    }

    // MARK: - Disclosure Expansion

    func testHandleDisclosureExpandedTogglesState() {
        let plugin = makeFanControlPlugin()

        plugin.handleAction(.setDisclosureExpanded(true))
        XCTAssertTrue(plugin.primaryPanelState.isExpanded)

        plugin.handleAction(.setDisclosureExpanded(false))
        XCTAssertFalse(plugin.primaryPanelState.isExpanded)
    }

    func testCollapsingDisclosureClearsError() {
        let writer = MockSMCWriter()
        writer.writeError = .writeFailed("test error")
        let plugin = makeFanControlPlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)

        plugin.handleAction(.setDisclosureExpanded(false))
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    // MARK: - Preset Selection

    func testSelectingBuiltInAutoPresetAppliesAutoStrategy() {
        let writer = MockSMCWriter()
        let plugin = makeFanControlPlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.auto))

        XCTAssertEqual(writer.appliedStrategy, .auto)
    }

    func testSelectingFullSpeedPresetAppliesFullSpeedStrategy() {
        let writer = MockSMCWriter()
        let plugin = makeFanControlPlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))

        XCTAssertEqual(writer.appliedStrategy, .fullSpeed)
    }

    func testSelectingUnknownPresetIDDoesNotApply() {
        let writer = MockSMCWriter()
        let plugin = makeFanControlPlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: "nonexistent-id"))

        XCTAssertNil(writer.appliedStrategy)
    }

    func testSelectingPresetClearsError() {
        let writer = MockSMCWriter()
        writer.writeError = .writeFailed("prev error")
        let plugin = makeFanControlPlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))
        writer.writeError = nil
        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.auto))

        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    // MARK: - Write Error Propagation

    func testWriteErrorAppearsInPanelState() {
        let writer = MockSMCWriter()
        writer.writeError = .writeFailed("硬件写入失败")
        let plugin = makeFanControlPlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))

        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    func testHelperNotFoundErrorAppearsInPanelState() {
        let writer = MockSMCWriter(isHelperAvailable: false)
        writer.writeError = .helperNotFound
        let plugin = makeFanControlPlugin(writer: writer)

        plugin.handleAction(.setSelection(controlID: "fan-preset-list", optionID: FanPresetBuiltInID.fullSpeed))

        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)
    }

    // MARK: - Slider Action

    func testSliderEndedUpdatesCustomPresetRPM() {
        let writer = MockSMCWriter()
        let plugin = makeFanControlPlugin(writer: writer)

        let preset = plugin.presetStore.addCustomPreset()
        plugin.presetStore.setActivePreset(id: preset.id)

        plugin.handleAction(.setSlider(controlID: "fan-custom-rpm", value: 4000, phase: .ended))

        if case let .fixed(rpm) = writer.appliedStrategy {
            XCTAssertEqual(rpm, 4000)
        } else {
            XCTFail("Expected .fixed strategy, got \(String(describing: writer.appliedStrategy))")
        }
    }

    func testSliderChangedPhaseDoesNotApplyPreset() {
        let writer = MockSMCWriter()
        let plugin = makeFanControlPlugin(writer: writer)

        let preset = plugin.presetStore.addCustomPreset()
        plugin.presetStore.setActivePreset(id: preset.id)

        plugin.handleAction(.setSlider(controlID: "fan-custom-rpm", value: 4000, phase: .changed))

        XCTAssertNil(writer.appliedStrategy)
    }

    func testSliderWithWrongControlIDDoesNothing() {
        let writer = MockSMCWriter()
        let plugin = makeFanControlPlugin(writer: writer)

        plugin.handleAction(.setSlider(controlID: "wrong-id", value: 4000, phase: .ended))

        XCTAssertNil(writer.appliedStrategy)
    }

    // MARK: - Delete Preset Action

    func testDeleteBuiltInPresetDoesNothing() {
        let writer = MockSMCWriter()
        let plugin = makeFanControlPlugin(writer: writer)

        // Active preset is built-in by default
        plugin.handleAction(.invokeAction(controlID: "fan-delete-preset"))

        XCTAssertNil(writer.appliedStrategy)
    }

    func testDeleteCustomPresetResetsToAuto() {
        let writer = MockSMCWriter()
        let plugin = makeFanControlPlugin(writer: writer)

        let preset = plugin.presetStore.addCustomPreset()
        plugin.presetStore.setActivePreset(id: preset.id)

        plugin.handleAction(.invokeAction(controlID: "fan-delete-preset"))

        XCTAssertEqual(writer.appliedStrategy, .auto)
    }

    // MARK: - Permissions & Settings

    func testPermissionRequirementsIsEmpty() {
        let plugin = makeFanControlPlugin()

        XCTAssertTrue(plugin.permissionRequirements.isEmpty)
    }

    func testSettingsSectionsIsEmpty() {
        let plugin = makeFanControlPlugin()

        XCTAssertTrue(plugin.settingsSections.isEmpty)
    }

    func testShortcutDefinitionsIsEmpty() {
        let plugin = makeFanControlPlugin()

        XCTAssertTrue(plugin.shortcutDefinitions.isEmpty)
    }

    // MARK: - Plugin Host Integration

    func testPluginHostIncludesFanControlPlugin() {
        let host = makePluginHostForTests(plugins: [makeFanControlPlugin()])

        XCTAssertTrue(host.featureManagementItems.contains { $0.id == "fan-control" })
    }

    // MARK: - Monitoring

    func testMonitoringOnlyNotifiesWhenSnapshotMeaningfullyChanges() async throws {
        let firstSnapshot = FanSnapshot(
            fanCount: 1,
            fanSpeeds: [3600],
            fanMinSpeeds: [1200],
            fanMaxSpeeds: [5200],
            cpuTemperature: 45.0
        )
        let equivalentSnapshot = FanSnapshot(
            fanCount: 1,
            fanSpeeds: [3605],
            fanMinSpeeds: [1200],
            fanMaxSpeeds: [5200],
            cpuTemperature: 45.0
        )
        let changedSnapshot = FanSnapshot(
            fanCount: 1,
            fanSpeeds: [3720],
            fanMinSpeeds: [1200],
            fanMaxSpeeds: [5200],
            cpuTemperature: 45.0
        )
        let reader = MockSMCReader(
            snapshots: [firstSnapshot, equivalentSnapshot, changedSnapshot]
        )
        let plugin = makeFanControlPlugin(
            reader: reader,
            monitoringActiveInterval: .milliseconds(10),
            monitoringIdleInterval: .milliseconds(10)
        )
        var stateChangeCount = 0
        plugin.onStateChange = {
            stateChangeCount += 1
        }

        plugin.activate(context: PluginRuntimeContext(pluginID: "fan-control"))
        try await Task.sleep(for: .milliseconds(45))
        plugin.deactivate(reason: .disabled)

        XCTAssertGreaterThanOrEqual(reader.readCount, 3)
        XCTAssertEqual(stateChangeCount, 2)
    }

    func testFeaturePanelVisibilityAndDisclosureControlActiveMonitoring() async throws {
        let snapshot = FanSnapshot(
            fanCount: 1,
            fanSpeeds: [3600],
            fanMinSpeeds: [1200],
            fanMaxSpeeds: [5200],
            cpuTemperature: 45.0
        )
        let reader = MockSMCReader(snapshot: snapshot)
        let plugin = makeFanControlPlugin(
            reader: reader,
            monitoringActiveInterval: .milliseconds(10),
            monitoringIdleInterval: .milliseconds(200)
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "fan-control"))
        try await Task.sleep(for: .milliseconds(40))
        let idleReadCount = reader.readCount

        plugin.setFeaturePanelVisible(true)
        plugin.handleAction(.setDisclosureExpanded(true))
        try await Task.sleep(for: .milliseconds(45))
        let activeReadCount = reader.readCount

        plugin.setFeaturePanelVisible(false)
        try await Task.sleep(for: .milliseconds(45))
        let closedReadCount = reader.readCount

        plugin.deactivate(reason: .disabled)

        XCTAssertEqual(idleReadCount, 1)
        XCTAssertGreaterThan(activeReadCount, idleReadCount + 1)
        XCTAssertLessThanOrEqual(closedReadCount - activeReadCount, 1)
    }

    // MARK: - Helpers

    private func makeFanControlPlugin(
        reader: MockSMCReader? = nil,
        writer: MockSMCWriter? = nil,
        monitoringActiveInterval: Duration = .seconds(2),
        monitoringIdleInterval: Duration = .seconds(10)
    ) -> FanControlPlugin {
        let suiteName = "FanControlPluginTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let storage = UserDefaultsPluginStorage(pluginID: "fan-control", userDefaults: defaults)
        let context = PluginRuntimeContext(pluginID: "fan-control", storage: storage)
        return FanControlPlugin(
            context: context,
            smcReader: reader ?? MockSMCReader(),
            smcWriter: writer ?? MockSMCWriter(),
            monitoringActiveInterval: monitoringActiveInterval,
            monitoringIdleInterval: monitoringIdleInterval
        )
    }
}
