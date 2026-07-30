import AppKit
import XCTest
import IOKit.pwr_mgt
import MacToolsPluginKit
@testable import KeepAwakePlugin

@MainActor
final class KeepAwakePluginTests: XCTestCase {
    private var expectedClosedLidSystemImage: String {
        NSImage(
            systemSymbolName: "laptopcomputer.and.arrow.down",
            accessibilityDescription: nil
        ) == nil ? "laptopcomputer" : "laptopcomputer.and.arrow.down"
    }

    private func settleVirtualDisplayUpdate() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    private func display(
        id: CGDirectDisplayID,
        name: String,
        isBuiltin: Bool,
        vendorNumber: UInt32? = nil
    ) -> DisplayInfo {
        DisplayInfo(
            id: id,
            name: name,
            isBuiltin: isBuiltin,
            isMain: isBuiltin,
            vendorNumber: vendorNumber,
            modelNumber: nil,
            serialNumber: nil
        )
    }

    func testPermanentSessionPersistsAndRestoresAfterHostShutdown() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))

        XCTAssertTrue(firstPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(firstFactory.sessions.count, 1)
        XCTAssertEqual(firstFactory.sessions[0].startedConfigurations.count, 1)
        XCTAssertNil(firstFactory.sessions[0].startedConfigurations[0].endDate)
        XCTAssertFalse(firstFactory.sessions[0].startedConfigurations[0].preventDisplaySleep)
        XCTAssertFalse(firstFactory.sessions[0].startedConfigurations[0].preventLidCloseSleep)

        firstPlugin.deactivate(reason: .hostShutdown)

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(firstFactory.sessions[0].stopRequestCount, 1)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertTrue(secondPlugin.primaryPanelState.isOn)
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)
        XCTAssertEqual(secondFactory.sessions.count, 1)
        XCTAssertEqual(secondFactory.sessions[0].startedConfigurations.count, 1)
        XCTAssertNil(secondFactory.sessions[0].startedConfigurations[0].endDate)
        XCTAssertFalse(secondFactory.sessions[0].startedConfigurations[0].preventDisplaySleep)
        XCTAssertFalse(secondFactory.sessions[0].startedConfigurations[0].preventLidCloseSleep)
    }

    func testTemporarySessionDoesNotRestoreAfterHostShutdown() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))
        firstPlugin.handleAction(.setSelection(controlID: "duration", optionID: "oneHour"))

        XCTAssertTrue(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])
        XCTAssertEqual(firstFactory.sessions.count, 1)
        XCTAssertEqual(firstFactory.sessions[0].startedConfigurations.count, 2)
        XCTAssertNotNil(firstFactory.sessions[0].startedConfigurations[1].endDate)

        firstPlugin.deactivate(reason: .hostShutdown)

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertFalse(secondPlugin.primaryPanelState.isOn)
        XCTAssertTrue(secondFactory.sessions.isEmpty)
    }

    func testManualSwitchOffClearsPermanentRestoreState() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))
        XCTAssertEqual(storage.values["persistent-enabled"] as? Bool, true)

        firstPlugin.handleAction(.setSwitch(false))

        XCTAssertFalse(firstPlugin.primaryPanelState.isOn)
        XCTAssertNil(storage.values["persistent-enabled"])
        XCTAssertEqual(firstFactory.sessions[0].stopRequestCount, 1)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertFalse(secondPlugin.primaryPanelState.isOn)
        XCTAssertTrue(secondFactory.sessions.isEmpty)
    }

    func testKeepDisplayOnSettingDefaultsToOffAndUpdatesRunningSession() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(factory.sessions[0].startedConfigurations.last?.preventDisplaySleep, false)
        XCTAssertNil(storage.values["keep-display-on"])
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "不会自动停止")
        XCTAssertEqual(plugin.primaryPanelState.detail?.primaryControls.map(\.id), ["duration"])
        XCTAssertNotNil(plugin.configuration)
        XCTAssertNil(plugin.primaryPanelCompactIndicator)

        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(factory.sessions[0].startedConfigurations.count, 1)
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true])
        XCTAssertEqual(storage.values["keep-display-on"] as? Bool, true)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "不会自动停止")
        XCTAssertEqual(
            plugin.primaryPanelCompactIndicator,
            PluginPrimaryPanelCompactIndicator(
                icons: [
                    PluginPrimaryPanelIndicatorIcon(
                        systemImage: "display",
                        label: "屏幕",
                        accessibilityLabel: "保持屏幕常亮"
                    )
                ]
            )
        )

        plugin.setKeepDisplayOn(false)

        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false])
        XCTAssertNil(storage.values["keep-display-on"])
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "不会自动停止")
        XCTAssertNil(plugin.primaryPanelCompactIndicator)
    }

    func testKeepDisplayOnSettingAppliesToFutureSession() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(storage.values["keep-display-on"] as? Bool, true)
        XCTAssertTrue(factory.sessions.isEmpty)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertNil(plugin.primaryPanelCompactIndicator)

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(factory.sessions[0].startedConfigurations.last?.preventDisplaySleep, true)
        XCTAssertNotNil(plugin.primaryPanelCompactIndicator)
    }

    func testKeepDisplayOnUpdatePreservesTimedSessionEndDate() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        plugin.handleAction(.setSelection(controlID: "duration", optionID: "oneHour"))

        let session = factory.sessions[0]
        let scheduledEndDate = session.startedConfigurations.last?.endDate
        XCTAssertNotNil(scheduledEndDate)

        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(session.startedConfigurations.count, 2)
        XCTAssertEqual(session.startedConfigurations.last?.endDate, scheduledEndDate)
        XCTAssertEqual(session.displaySleepPreventionUpdates, [true])
    }

    func testFailedKeepDisplayOnUpdateKeepsAppliedPreferenceAndCanRetry() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        let session = factory.sessions[0]
        session.displayUpdateError = MockKeepAwakeSessionError.displayUpdateFailed

        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(session.displaySleepPreventionUpdates, [true])
        XCTAssertNil(storage.values["keep-display-on"])
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "不会自动停止")
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)

        session.displayUpdateError = nil
        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(session.displaySleepPreventionUpdates, [true, true])
        XCTAssertEqual(storage.values["keep-display-on"] as? Bool, true)
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "不会自动停止")
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testKeepDisplayOnPreferenceRestoresWithPermanentSession() {
        let storage = KeepAwakeMemoryStorage()
        let firstFactory = KeepAwakeSessionFactory()
        let firstPlugin = firstFactory.makePlugin(storage: storage)

        firstPlugin.handleAction(.setSwitch(true))
        firstPlugin.setKeepDisplayOn(true)
        firstPlugin.deactivate(reason: .hostShutdown)

        let secondFactory = KeepAwakeSessionFactory()
        let secondPlugin = secondFactory.makePlugin(storage: storage)
        secondPlugin.activate(context: Self.context(storage: storage))

        XCTAssertTrue(secondPlugin.primaryPanelState.isOn)
        XCTAssertEqual(secondFactory.sessions[0].startedConfigurations.last?.preventDisplaySleep, true)
        XCTAssertEqual(storage.values["keep-display-on"] as? Bool, true)
    }

    func testKeepDisplayOnPreferenceSurvivesSessionOff() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        plugin.setKeepDisplayOn(true)
        plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(storage.values["keep-display-on"] as? Bool, true)

        plugin.handleAction(.setSwitch(true))
        XCTAssertEqual(factory.sessions.last?.startedConfigurations.last?.preventDisplaySleep, true)
    }

    func testClosedLidSettingRequiresPortableMacButCanBeEnabledOnBattery() {
        let storage = KeepAwakeMemoryStorage()
        let desktopFactory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        )
        let desktopPlugin = desktopFactory.makePlugin(storage: storage)

        desktopPlugin.setKeepAwakeWithLidClosed(true)

        XCTAssertNil(storage.values["keep-awake-with-lid-closed"])
        XCTAssertNotNil(desktopPlugin.primaryPanelState.errorMessage)

        let batteryFactory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false
            )
        )
        let batteryPlugin = batteryFactory.makePlugin(storage: storage)

        batteryPlugin.setKeepAwakeWithLidClosed(true)

        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
        XCTAssertNil(batteryPlugin.primaryPanelState.errorMessage)

        batteryPlugin.handleAction(.setSwitch(true))

        XCTAssertEqual(
            batteryFactory.sessions[0].startedConfigurations.last?.preventLidCloseSleep,
            false
        )
        XCTAssertNil(batteryPlugin.primaryPanelCompactIndicator)
    }

    func testClosedLidSettingAppliesToRunningAndFutureSessions() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)

        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
        XCTAssertTrue(factory.sessions.isEmpty)

        plugin.handleAction(.setSwitch(true))

        XCTAssertEqual(factory.sessions[0].startedConfigurations.last?.preventLidCloseSleep, true)
        XCTAssertEqual(
            plugin.primaryPanelCompactIndicator,
            PluginPrimaryPanelCompactIndicator(
                icons: [
                    PluginPrimaryPanelIndicatorIcon(
                        systemImage: expectedClosedLidSystemImage,
                        label: "合盖",
                        accessibilityLabel: "合盖保持唤醒"
                    )
                ]
            )
        )

        plugin.setKeepDisplayOn(true)

        XCTAssertEqual(
            plugin.primaryPanelCompactIndicator,
            PluginPrimaryPanelCompactIndicator(
                icons: [
                    PluginPrimaryPanelIndicatorIcon(
                        systemImage: "display",
                        label: "屏幕",
                        accessibilityLabel: "保持屏幕常亮"
                    ),
                    PluginPrimaryPanelIndicatorIcon(
                        systemImage: expectedClosedLidSystemImage,
                        label: "合盖",
                        accessibilityLabel: "合盖保持唤醒"
                    )
                ]
            )
        )

        plugin.setKeepAwakeWithLidClosed(false)

        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates, [false])
        XCTAssertNil(storage.values["keep-awake-with-lid-closed"])
        XCTAssertEqual(
            plugin.primaryPanelCompactIndicator,
            PluginPrimaryPanelCompactIndicator(
                icons: [
                    PluginPrimaryPanelIndicatorIcon(
                        systemImage: "display",
                        label: "屏幕",
                        accessibilityLabel: "保持屏幕常亮"
                    )
                ]
            )
        )
    }

    func testSoftwareDisplayStartsForRunningClosedLidSessionAndStopsWhenDisabled() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)
        plugin.handleAction(.setSwitch(true))
        plugin.setKeepDesktopAvailableWithLidClosed(true)
        await settleVirtualDisplayUpdate()

        XCTAssertEqual(factory.virtualDisplayManager.startCount, 1)
        XCTAssertTrue(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true])
        XCTAssertEqual(
            storage.values["keep-desktop-available-with-lid-closed"] as? Bool,
            true
        )

        plugin.setKeepDesktopAvailableWithLidClosed(false)

        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false])
        XCTAssertEqual(factory.virtualDisplayManager.stopCount, 1)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertNil(storage.values["keep-desktop-available-with-lid-closed"])
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    func testSoftwareDisplayRunsOnlyWhileLidIsClosed() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: false
            )
        )
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)
        plugin.handleAction(.setSwitch(true))
        plugin.setKeepDesktopAvailableWithLidClosed(true)

        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.startCount, 0)
        XCTAssertTrue(
            storage.values["keep-desktop-available-with-lid-closed"] as? Bool == true
        )

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: true
            )
        )
        await settleVirtualDisplayUpdate()

        XCTAssertTrue(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.startCount, 1)
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true])
        XCTAssertTrue(factory.sessions[0].lidCloseSleepPreventionUpdates.isEmpty)

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: false
            )
        )
        await settleVirtualDisplayUpdate()

        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.stopCount, 1)
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false])
        XCTAssertTrue(
            storage.values["keep-desktop-available-with-lid-closed"] as? Bool == true
        )

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: true
            )
        )
        await settleVirtualDisplayUpdate()

        XCTAssertTrue(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.startCount, 2)
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false, true])
    }

    func testSoftwareDisplayPreferencePausesWithParentAndRestoresWhenReenabled() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)
        plugin.handleAction(.setSwitch(true))
        plugin.setKeepDesktopAvailableWithLidClosed(true)
        await settleVirtualDisplayUpdate()

        plugin.setKeepAwakeWithLidClosed(false)

        XCTAssertNil(storage.values["keep-awake-with-lid-closed"])
        XCTAssertEqual(
            storage.values["keep-desktop-available-with-lid-closed"] as? Bool,
            true
        )
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.stopCount, 1)
        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates, [false])
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false])

        plugin.setKeepAwakeWithLidClosed(true)
        await settleVirtualDisplayUpdate()

        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
        XCTAssertEqual(
            storage.values["keep-desktop-available-with-lid-closed"] as? Bool,
            true
        )
        XCTAssertTrue(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.startCount, 2)
        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates, [false, true])
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false, true])
    }

    func testSoftwareDisplayPreferenceSurvivesRelaunchWhileParentIsDisabled() async {
        let storage = KeepAwakeMemoryStorage()
        storage.set(true, forKey: "persistent-enabled")
        storage.set(true, forKey: "keep-desktop-available-with-lid-closed")
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.activate(context: Self.context(storage: storage))

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(
            storage.values["keep-desktop-available-with-lid-closed"] as? Bool,
            true
        )
        XCTAssertEqual(
            factory.sessions[0].startedConfigurations.last,
            MockKeepAwakeSession.Configuration(
                endDate: nil,
                preventDisplaySleep: false,
                preventLidCloseSleep: false
            )
        )

        plugin.setKeepAwakeWithLidClosed(true)
        await settleVirtualDisplayUpdate()

        XCTAssertTrue(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.startCount, 1)
        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates, [true])
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true])
    }

    func testSoftwareDisplayKeepsDisplayAssertionWhenDisplayPreferenceTurnsOff() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)
        plugin.setKeepDisplayOn(true)
        plugin.handleAction(.setSwitch(true))
        plugin.setKeepDesktopAvailableWithLidClosed(true)
        await settleVirtualDisplayUpdate()
        plugin.setKeepDisplayOn(false)

        XCTAssertTrue(factory.sessions[0].displaySleepPreventionUpdates.isEmpty)
        XCTAssertNil(storage.values["keep-display-on"])
        XCTAssertTrue(factory.virtualDisplayManager.isActive)
    }

    func testSoftwareDisplayPausesOnBatteryAndResumesOnExternalPower() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)
        plugin.handleAction(.setSwitch(true))
        plugin.setKeepDesktopAvailableWithLidClosed(true)
        await settleVirtualDisplayUpdate()

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false,
                isLidClosed: true
            )
        )
        await settleVirtualDisplayUpdate()

        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.stopCount, 1)
        XCTAssertEqual(
            storage.values["keep-desktop-available-with-lid-closed"] as? Bool,
            true
        )
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false])

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true,
                isLidClosed: true
            )
        )
        await settleVirtualDisplayUpdate()

        XCTAssertTrue(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.startCount, 2)
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false, true])
    }

    func testSoftwareDisplayFailureClearsOnlySoftwareDisplayPreference() async {
        let storage = KeepAwakeMemoryStorage()
        storage.set(true, forKey: "persistent-enabled")
        storage.set(true, forKey: "keep-awake-with-lid-closed")
        storage.set(true, forKey: "keep-desktop-available-with-lid-closed")
        let factory = KeepAwakeSessionFactory()
        factory.virtualDisplayManager.startError = MockVirtualDisplayError.creationFailed
        let plugin = factory.makePlugin(storage: storage)

        plugin.activate(context: Self.context(storage: storage))
        await settleVirtualDisplayUpdate()

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(
            factory.sessions[0].startedConfigurations.last?.preventLidCloseSleep,
            true
        )
        XCTAssertEqual(
            factory.sessions[0].startedConfigurations.last?.preventDisplaySleep,
            true
        )
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [false])
        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
        XCTAssertNil(storage.values["keep-desktop-available-with-lid-closed"])
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法创建软件显示器。")
    }

    func testUnexpectedSoftwareDisplayExitDisablesModeButKeepsSessionRunning() async {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)
        plugin.handleAction(.setSwitch(true))
        plugin.setKeepDesktopAvailableWithLidClosed(true)
        await settleVirtualDisplayUpdate()
        factory.virtualDisplayManager.simulateUnexpectedTermination()

        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(factory.sessions[0].stopRequestCount, 0)
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false])
        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
        XCTAssertNil(storage.values["keep-desktop-available-with-lid-closed"])
        XCTAssertEqual(
            plugin.primaryPanelState.errorMessage,
            "软件显示器已停止；合盖桌面模式已关闭。"
        )
    }

    func testSoftwareDisplayRunsOnlyWhenNoPhysicalExternalDisplayIsActive() async {
        let storage = KeepAwakeMemoryStorage()
        let builtInDisplay = display(
            id: 1,
            name: "Built-in Display",
            isBuiltin: true
        )
        let externalDisplay = display(
            id: 2,
            name: "Studio Display",
            isBuiltin: false,
            vendorNumber: 0x610
        )
        let factory = KeepAwakeSessionFactory(
            displays: [builtInDisplay, externalDisplay]
        )
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)
        plugin.handleAction(.setSwitch(true))
        plugin.setKeepDesktopAvailableWithLidClosed(true)
        await settleVirtualDisplayUpdate()

        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.startCount, 0)
        XCTAssertEqual(
            storage.values["keep-desktop-available-with-lid-closed"] as? Bool,
            true
        )

        factory.displayProvider.displays = [builtInDisplay]
        plugin.refreshDisplayTopology()
        await settleVirtualDisplayUpdate()

        XCTAssertTrue(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.startCount, 1)
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true])

        factory.displayProvider.displays = [
            builtInDisplay,
            display(
                id: 3,
                name: "MacTools Virtual Display",
                isBuiltin: false,
                vendorNumber: 505
            ),
        ]
        plugin.refreshDisplayTopology()
        await settleVirtualDisplayUpdate()

        XCTAssertTrue(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.stopCount, 0)

        factory.displayProvider.displays = [builtInDisplay, externalDisplay]
        plugin.refreshDisplayTopology()
        await settleVirtualDisplayUpdate()

        XCTAssertFalse(factory.virtualDisplayManager.isActive)
        XCTAssertEqual(factory.virtualDisplayManager.stopCount, 1)
        XCTAssertEqual(factory.sessions[0].displaySleepPreventionUpdates, [true, false])
        XCTAssertEqual(
            storage.values["keep-desktop-available-with-lid-closed"] as? Bool,
            true
        )
    }

    func testSettingsSearchIncludesScreenBasedToolsOptionOnPortableMac() {
        let portableFactory = KeepAwakeSessionFactory()
        let portablePlugin = portableFactory.makePlugin(
            storage: KeepAwakeMemoryStorage()
        )

        XCTAssertEqual(
            portablePlugin.settingsSearchEntries.map(\.id),
            [
                KeepAwakeSettingsSearchEntryID.keepDisplayOn,
                KeepAwakeSettingsSearchEntryID.keepAwakeWithLidClosed,
                KeepAwakeSettingsSearchEntryID.keepScreenBasedToolsWorking,
            ]
        )

        let childEntry = portablePlugin.settingsSearchEntries.last
        XCTAssertEqual(childEntry?.title, "让屏幕相关工具继续工作")
        XCTAssertEqual(
            childEntry?.description,
            "合盖后支持 Codex Computer Use、桌面自动化、屏幕共享和远程控制。"
        )

        let desktopFactory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: false,
                isOnExternalPower: true
            )
        )
        let desktopPlugin = desktopFactory.makePlugin(
            storage: KeepAwakeMemoryStorage()
        )

        XCTAssertEqual(
            desktopPlugin.settingsSearchEntries.map(\.id),
            [KeepAwakeSettingsSearchEntryID.keepDisplayOn]
        )
    }

    func testClosedLidSettingEnabledOnBatteryActivatesWhenPowerConnects() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false
            )
        )
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        plugin.setKeepAwakeWithLidClosed(true)

        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates, [false])
        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
        XCTAssertNil(plugin.primaryPanelCompactIndicator)

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true
            )
        )

        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates, [false, true])
        XCTAssertEqual(
            plugin.primaryPanelCompactIndicator,
            PluginPrimaryPanelCompactIndicator(
                icons: [
                    PluginPrimaryPanelIndicatorIcon(
                        systemImage: expectedClosedLidSystemImage,
                        label: "合盖",
                        accessibilityLabel: "合盖保持唤醒"
                    )
                ]
            )
        )
    }

    func testFailedClosedLidUpdateDoesNotStorePreferenceAndCanRetry() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        let session = factory.sessions[0]
        session.lidCloseUpdateError = MockKeepAwakeSessionError.lidCloseUpdateFailed

        plugin.setKeepAwakeWithLidClosed(true)

        XCTAssertEqual(session.lidCloseSleepPreventionUpdates, [true])
        XCTAssertNil(storage.values["keep-awake-with-lid-closed"])
        XCTAssertNil(plugin.primaryPanelCompactIndicator)
        XCTAssertNotNil(plugin.primaryPanelState.errorMessage)

        session.lidCloseUpdateError = nil
        plugin.setKeepAwakeWithLidClosed(true)

        XCTAssertEqual(session.lidCloseSleepPreventionUpdates, [true, true])
        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testDisconnectingPowerPausesClosedLidModeAndReconnectRestoresIt() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)
        plugin.setKeepDisplayOn(true)
        plugin.handleAction(.setSwitch(true))

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false
            )
        )

        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates, [false])
        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
        XCTAssertEqual(
            plugin.primaryPanelCompactIndicator,
            PluginPrimaryPanelCompactIndicator(
                icons: [
                    PluginPrimaryPanelIndicatorIcon(
                        systemImage: "display",
                        label: "屏幕",
                        accessibilityLabel: "保持屏幕常亮"
                    )
                ]
            )
        )
        XCTAssertTrue(plugin.primaryPanelState.isOn)

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true
            )
        )

        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates, [false, true])
        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
        XCTAssertEqual(
            plugin.primaryPanelCompactIndicator,
            PluginPrimaryPanelCompactIndicator(
                icons: [
                    PluginPrimaryPanelIndicatorIcon(
                        systemImage: "display",
                        label: "屏幕",
                        accessibilityLabel: "保持屏幕常亮"
                    ),
                    PluginPrimaryPanelIndicatorIcon(
                        systemImage: expectedClosedLidSystemImage,
                        label: "合盖",
                        accessibilityLabel: "合盖保持唤醒"
                    )
                ]
            )
        )
        XCTAssertTrue(plugin.primaryPanelState.isOn)
    }

    func testDisconnectingPowerPreservesClosedLidReleaseErrorAfterStoppingSession() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)
        plugin.handleAction(.setSwitch(true))
        factory.sessions[0].lidCloseUpdateError = MockKeepAwakeSessionError.lidCloseUpdateFailed

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false
            )
        )

        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates, [false])
        XCTAssertEqual(factory.sessions[0].stopRequestCount, 1)
        XCTAssertNil(storage.values["keep-awake-with-lid-closed"])
        XCTAssertNil(plugin.primaryPanelCompactIndicator)
        XCTAssertFalse(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法更新合盖状态。")
    }

    func testClosedLidPreferenceRestoresPausedWithoutExternalPower() {
        let storage = KeepAwakeMemoryStorage()
        storage.set(true, forKey: "keep-awake-with-lid-closed")
        storage.set(true, forKey: "persistent-enabled")
        let factory = KeepAwakeSessionFactory(
            powerSourceState: KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false
            )
        )
        let plugin = factory.makePlugin(storage: storage)

        plugin.activate(context: Self.context(storage: storage))

        XCTAssertEqual(factory.sessions[0].startedConfigurations.last?.preventLidCloseSleep, false)
        XCTAssertEqual(storage.values["keep-awake-with-lid-closed"] as? Bool, true)
        XCTAssertNil(plugin.primaryPanelCompactIndicator)
    }

    func testFailedClosedLidResumeClearsPreferenceAndKeepsNormalSessionRunning() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.setKeepAwakeWithLidClosed(true)
        plugin.handleAction(.setSwitch(true))
        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: false
            )
        )
        factory.sessions[0].lidCloseUpdateError = MockKeepAwakeSessionError.lidCloseUpdateFailed

        factory.powerSourceMonitor.send(
            KeepAwakePowerSourceState(
                isPortableMac: true,
                isOnExternalPower: true
            )
        )

        XCTAssertEqual(factory.sessions[0].lidCloseSleepPreventionUpdates, [false, true])
        XCTAssertEqual(factory.sessions[0].stopRequestCount, 0)
        XCTAssertNil(storage.values["keep-awake-with-lid-closed"])
        XCTAssertNil(plugin.primaryPanelCompactIndicator)
        XCTAssertTrue(plugin.primaryPanelState.isOn)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法更新合盖状态。")
    }

    func testTimedSessionSubtitleKeepsRemainingAndAbsoluteStopCompact() {
        let storage = KeepAwakeMemoryStorage()
        let factory = KeepAwakeSessionFactory()
        let plugin = factory.makePlugin(storage: storage)

        plugin.handleAction(.setSwitch(true))
        plugin.handleAction(.setSelection(controlID: "duration", optionID: "twoHours"))

        let subtitle = plugin.primaryPanelState.subtitle
        XCTAssertTrue(subtitle.contains(":"), subtitle)
        XCTAssertTrue(subtitle.contains("·"), subtitle)
        XCTAssertTrue(subtitle.contains("剩余"), subtitle)
        XCTAssertEqual(subtitle.filter { $0 == "·" }.count, 1, subtitle)
    }

    private static func context(storage: KeepAwakeMemoryStorage) -> PluginRuntimeContext {
        PluginRuntimeContext(pluginID: "keep-awake", storage: storage)
    }
}

final class KeepAwakeStopScheduleFormattingTests: XCTestCase {
    private let localization = PluginLocalization(bundle: .main)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var locale: Locale { Locale(identifier: "en_US_POSIX") }

    func testSameDayStopUsesTimeOnly() {
        let reference = date(year: 2026, month: 7, day: 10, hour: 14, minute: 0)
        let end = date(year: 2026, month: 7, day: 10, hour: 16, minute: 30)

        let label = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
            until: end,
            referenceDate: reference,
            calendar: calendar,
            localization: localization,
            locale: locale
        )

        XCTAssertTrue(label.contains("4:30"), label)
        XCTAssertFalse(label.contains("16:30"), label)
    }

    func testSameDayStopUsesLocalePreferred24HourClock() {
        let reference = date(year: 2026, month: 7, day: 10, hour: 14, minute: 0)
        let end = date(year: 2026, month: 7, day: 10, hour: 16, minute: 30)

        let label = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
            until: end,
            referenceDate: reference,
            calendar: calendar,
            localization: localization,
            locale: Locale(identifier: "en_GB")
        )

        XCTAssertTrue(label.contains("16:30"), label)
    }

    func testNextDayStopUsesTomorrowPrefix() {
        let reference = date(year: 2026, month: 7, day: 10, hour: 22, minute: 0)
        let end = date(year: 2026, month: 7, day: 11, hour: 1, minute: 15)

        let label = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
            until: end,
            referenceDate: reference,
            calendar: calendar,
            localization: localization,
            locale: locale
        )

        // PluginLocalization falls back to default Chinese copy when the key is not in the test host bundle.
        XCTAssertTrue(label.contains("1:15"), label)
        XCTAssertTrue(
            label.contains("Tomorrow") || label.contains("明天"),
            label
        )
    }

    func testLaterDayStopIncludesDate() {
        let reference = date(year: 2026, month: 7, day: 10, hour: 12, minute: 0)
        let end = date(year: 2026, month: 7, day: 12, hour: 9, minute: 5)

        let label = KeepAwakeStopScheduleFormatting.absoluteStopLabel(
            until: end,
            referenceDate: reference,
            calendar: calendar,
            localization: localization,
            locale: locale
        )

        XCTAssertTrue(label.contains("9:05"), label)
        XCTAssertFalse(label.contains("Tomorrow") || label.contains("明天"), label)
        XCTAssertTrue(label.contains("Jul") || label.contains("7") || label.contains("12"), label)
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }
}

@MainActor
final class KeepAwakeSessionTests: XCTestCase {
    func testDisplayAssertionFailureDoesNotPreventSessionStart() throws {
        var createdKinds: [KeepAwakeSession.AssertionKind] = []
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                createdKinds.append(kind)
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .display:
                    return (kIOReturnError, 0)
                case .lidClose:
                    return (kIOReturnSuccess, 2)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: true,
            preventLidCloseSleep: false
        )
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(createdKinds, [.system, .display])
        XCTAssertEqual(releasedAssertionIDs, [1])
    }

    func testDisplayAssertionCanBeUpdatedWithoutRestartingSystemAssertion() throws {
        var createdKinds: [KeepAwakeSession.AssertionKind] = []
        var releasedAssertionIDs: [IOPMAssertionID] = []
        var nextAssertionID = IOPMAssertionID(1)
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                createdKinds.append(kind)
                defer { nextAssertionID += 1 }
                return (kIOReturnSuccess, nextAssertionID)
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: false,
            preventLidCloseSleep: false
        )
        try session.setPreventDisplaySleep(true)
        try session.setPreventDisplaySleep(false)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(createdKinds, [.system, .display])
        XCTAssertEqual(releasedAssertionIDs, [2, 1])
    }

    func testFailedDisplayAssertionCreationCanBeRetried() throws {
        var displayCreationAttempts = 0
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .display:
                    displayCreationAttempts += 1
                    return displayCreationAttempts == 1
                        ? (kIOReturnError, 0)
                        : (kIOReturnSuccess, 2)
                case .lidClose:
                    return (kIOReturnSuccess, 3)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: false,
            preventLidCloseSleep: false
        )
        XCTAssertThrowsError(try session.setPreventDisplaySleep(true))
        try session.setPreventDisplaySleep(true)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(displayCreationAttempts, 2)
        XCTAssertEqual(releasedAssertionIDs, [2, 1])
    }

    func testFailedDisplayAssertionReleaseRetainsAssertionForRetry() throws {
        var shouldFailDisplayRelease = true
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .display:
                    return (kIOReturnSuccess, 2)
                case .lidClose:
                    return (kIOReturnSuccess, 3)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                if assertionID == 2, shouldFailDisplayRelease {
                    return kIOReturnError
                }
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: true,
            preventLidCloseSleep: false
        )
        XCTAssertThrowsError(try session.setPreventDisplaySleep(false))
        shouldFailDisplayRelease = false
        try session.setPreventDisplaySleep(false)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(releasedAssertionIDs, [2, 2, 1])
    }

    func testClosedLidAssertionCanBeEnabledAndReleasedDuringSession() throws {
        var createdKinds: [KeepAwakeSession.AssertionKind] = []
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                createdKinds.append(kind)
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .lidClose:
                    return (kIOReturnSuccess, 2)
                case .display:
                    return (kIOReturnSuccess, 3)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: false,
            preventLidCloseSleep: false
        )
        try session.setPreventLidCloseSleep(true)
        try session.setPreventLidCloseSleep(false)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(createdKinds, [.system, .lidClose])
        XCTAssertEqual(releasedAssertionIDs, [2, 1])
    }

    func testFailedClosedLidAssertionReleaseCanBeRetried() throws {
        var shouldFailLidCloseRelease = true
        var releasedAssertionIDs: [IOPMAssertionID] = []
        let session = KeepAwakeSession(
            onEnd: { _ in },
            assertionCreator: { kind in
                switch kind {
                case .system:
                    return (kIOReturnSuccess, 1)
                case .lidClose:
                    return (kIOReturnSuccess, 2)
                case .display:
                    return (kIOReturnSuccess, 3)
                }
            },
            assertionReleaser: { assertionID in
                releasedAssertionIDs.append(assertionID)
                if assertionID == 2, shouldFailLidCloseRelease {
                    return kIOReturnError
                }
                return kIOReturnSuccess
            }
        )

        try session.start(
            until: nil,
            preventDisplaySleep: false,
            preventLidCloseSleep: true
        )
        XCTAssertThrowsError(try session.setPreventLidCloseSleep(false))
        shouldFailLidCloseRelease = false
        try session.setPreventLidCloseSleep(false)
        session.requestStop(reason: .userRequested)

        XCTAssertEqual(releasedAssertionIDs, [2, 2, 1])
    }
}

@MainActor
private final class KeepAwakeSessionFactory {
    private(set) var sessions: [MockKeepAwakeSession] = []
    let powerSourceMonitor: MockKeepAwakePowerSourceMonitor
    let virtualDisplayManager = MockKeepAwakeVirtualDisplayManager()
    let displayProvider: MockKeepAwakeDisplayProvider

    init(
        powerSourceState: KeepAwakePowerSourceState = KeepAwakePowerSourceState(
            isPortableMac: true,
            isOnExternalPower: true,
            isLidClosed: true
        ),
        displays: [DisplayInfo] = []
    ) {
        powerSourceMonitor = MockKeepAwakePowerSourceMonitor(currentState: powerSourceState)
        displayProvider = MockKeepAwakeDisplayProvider(displays: displays)
    }

    func makePlugin(storage: KeepAwakeMemoryStorage) -> KeepAwakePlugin {
        KeepAwakePlugin(
            context: PluginRuntimeContext(pluginID: "keep-awake", storage: storage),
            powerSourceMonitor: powerSourceMonitor,
            virtualDisplayManager: virtualDisplayManager,
            displayProvider: displayProvider,
            sessionFactory: { [weak self] _, onEnd in
                let session = MockKeepAwakeSession(onEnd: onEnd)
                self?.sessions.append(session)
                return session
            }
        )
    }
}

@MainActor
private final class MockKeepAwakeVirtualDisplayManager: KeepAwakeVirtualDisplayManaging {
    var isAvailable = true
    private(set) var isActive = false
    var onUnexpectedTermination: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?

    func start() async throws {
        startCount += 1
        if let startError {
            throw startError
        }
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        stopCount += 1
        isActive = false
    }

    func simulateUnexpectedTermination() {
        isActive = false
        onUnexpectedTermination?()
    }
}

private final class MockKeepAwakeDisplayProvider: DisplayProviding {
    var displays: [DisplayInfo]

    init(displays: [DisplayInfo]) {
        self.displays = displays
    }

    func listConnectedDisplays() -> [DisplayInfo] {
        displays
    }

    func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        nil
    }
}

@MainActor
private final class MockKeepAwakeSession: KeepAwakeSessionManaging {
    struct Configuration: Equatable {
        let endDate: Date?
        let preventDisplaySleep: Bool
        let preventLidCloseSleep: Bool
    }

    private let onEnd: (KeepAwakeSession.EndReason) -> Void
    private(set) var startedConfigurations: [Configuration] = []
    private(set) var displaySleepPreventionUpdates: [Bool] = []
    private(set) var lidCloseSleepPreventionUpdates: [Bool] = []
    private(set) var stopRequestCount = 0
    var displayUpdateError: Error?
    var lidCloseUpdateError: Error?

    init(onEnd: @escaping (KeepAwakeSession.EndReason) -> Void) {
        self.onEnd = onEnd
    }

    func start(
        until endDate: Date?,
        preventDisplaySleep: Bool,
        preventLidCloseSleep: Bool
    ) throws {
        startedConfigurations.append(
            Configuration(
                endDate: endDate,
                preventDisplaySleep: preventDisplaySleep,
                preventLidCloseSleep: preventLidCloseSleep
            )
        )
    }

    func setPreventDisplaySleep(_ preventDisplaySleep: Bool) throws {
        displaySleepPreventionUpdates.append(preventDisplaySleep)
        if let displayUpdateError {
            throw displayUpdateError
        }
    }

    func setPreventLidCloseSleep(_ preventLidCloseSleep: Bool) throws {
        lidCloseSleepPreventionUpdates.append(preventLidCloseSleep)
        if let lidCloseUpdateError {
            throw lidCloseUpdateError
        }
    }

    func requestStop(reason: KeepAwakeSession.EndReason) {
        stopRequestCount += 1
        onEnd(reason)
    }
}

@MainActor
private final class MockKeepAwakePowerSourceMonitor: KeepAwakePowerSourceMonitoring {
    private(set) var currentState: KeepAwakePowerSourceState
    var onChange: ((KeepAwakePowerSourceState) -> Void)?

    init(currentState: KeepAwakePowerSourceState) {
        self.currentState = currentState
    }

    func start() {}
    func stop() {}

    func send(_ state: KeepAwakePowerSourceState) {
        currentState = state
        onChange?(state)
    }
}

private enum MockKeepAwakeSessionError: LocalizedError {
    case displayUpdateFailed
    case lidCloseUpdateFailed

    var errorDescription: String? {
        switch self {
        case .displayUpdateFailed:
            return "无法更新屏幕状态。"
        case .lidCloseUpdateFailed:
            return "无法更新合盖状态。"
        }
    }
}

private enum MockVirtualDisplayError: LocalizedError {
    case creationFailed

    var errorDescription: String? {
        "无法创建软件显示器。"
    }
}

@MainActor
private final class KeepAwakeMemoryStorage: PluginStorage {
    var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }

    func set(_ value: Any?, forKey key: String) {
        guard let value else {
            values.removeValue(forKey: key)
            return
        }

        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }

    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard values[key] == nil, let value = values[legacyKey] else {
            return
        }

        values[key] = value
        values.removeValue(forKey: legacyKey)
    }
}
