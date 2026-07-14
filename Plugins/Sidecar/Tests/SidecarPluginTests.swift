import XCTest
import MacToolsPluginKit
@testable import SidecarPlugin

@MainActor
final class SidecarPluginTests: XCTestCase {
    func testSidecarDeviceIdentifierAcceptsUUIDAndStringValues() {
        let uuid = UUID(uuidString: "9DFBEA6D-4DCF-431D-B7A0-A74F26231DAF")!

        XCTAssertEqual(
            SidecarCoreService.identifierString(from: uuid as NSUUID),
            "9DFBEA6D-4DCF-431D-B7A0-A74F26231DAF"
        )
        XCTAssertEqual(SidecarCoreService.identifierString(from: "sidecar-display" as NSString), "sidecar-display")
    }

    func testSidecarDeviceIdentifierRejectsUnstableObjectDescriptions() {
        XCTAssertNil(SidecarCoreService.identifierString(from: NSObject()))
    }

    func testMetadataUsesStableSidecarID() {
        XCTAssertEqual(makePlugin(service: FakeSidecarService()).metadata.id, "sidecar")
    }

    func testCollapsedRowSaysWhenNoSidecarDisplayIsAvailable() {
        let plugin = makePlugin(service: FakeSidecarService())

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "未发现可连接的 Sidecar 显示器")
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
    }

    func testBackgroundRefreshFindsDisplaysThatAppearAfterPluginStartup() async {
        let service = FakeSidecarService()
        let plugin = makePlugin(
            service: service,
            initialDeviceRefreshDelayNanoseconds: 10_000_000,
            deviceRefreshIntervalNanoseconds: 10_000_000
        )
        let refreshed = expectation(description: "displays refreshed")
        plugin.onStateChange = {
            if plugin.primaryPanelState.subtitle == "1 台可连接的 Sidecar 显示器" {
                refreshed.fulfill()
            }
        }
        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        plugin.panelSurfaceDidBecomeVisible(.primary)

        service.updateDevices([
            SidecarDevice(id: "vision-pro", name: "Apple Vision Pro", connectionState: .disconnected)
        ])

        await fulfillment(of: [refreshed], timeout: 1)
    }

    func testPollingRunsOnlyWhileThePrimaryPanelIsVisible() async {
        let service = FakeSidecarService()
        let plugin = makePlugin(
            service: service,
            initialDeviceRefreshDelayNanoseconds: 10_000_000,
            deviceRefreshIntervalNanoseconds: 10_000_000
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        let callsWhileHidden = service.reachableDevicesCallCount
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(service.reachableDevicesCallCount, callsWhileHidden)

        plugin.panelSurfaceDidBecomeVisible(.primary)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertGreaterThan(service.reachableDevicesCallCount, callsWhileHidden)

        plugin.panelSurfaceDidBecomeHidden(.primary)
        let callsAfterHiding = service.reachableDevicesCallCount
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(service.reachableDevicesCallCount, callsAfterHiding)
    }

    func testCompactPanelShowsOneDirectActionPerDevice() {
        let plugin = makePlugin(service: FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected),
            SidecarDevice(id: "ipad-2", name: "Other iPad", connectionState: .disconnected)
        ]))

        let controls = plugin.primaryPanelState.detail?.primaryControls ?? []
        XCTAssertEqual(controls.map(\.id), ["sidecar-connect.ipad-1", "sidecar-connect.ipad-2"])
        XCTAssertEqual(controls.first?.sectionTitle, "可用的 Sidecar 显示器")
        XCTAssertEqual(controls.first?.actionTitle, "My iPad · 连接")
        XCTAssertEqual(controls.first?.actionIconSystemName, "circle")
    }

    func testConnectedDevicesAppearFirstWithGreenConnectedIconAndDisconnectAction() {
        let plugin = makePlugin(service: FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-available", name: "Available iPad", connectionState: .disconnected),
            SidecarDevice(id: "ipad-connected", name: "Connected iPad", connectionState: .connected)
        ]))

        let controls = plugin.primaryPanelState.detail?.primaryControls ?? []
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台已连接 · 1 台可连接")
        XCTAssertEqual(controls.map(\.id), ["sidecar-disconnect.ipad-connected", "sidecar-connect.ipad-available"])
        XCTAssertEqual(controls[0].sectionTitle, "已连接")
        XCTAssertEqual(controls[0].actionTitle, "Connected iPad · 断开连接")
        XCTAssertEqual(controls[0].actionIconSystemName, "checkmark.circle.fill")
        XCTAssertEqual(controls[1].sectionTitle, "可用的 Sidecar 显示器")
        XCTAssertFalse(controls.contains(where: \.showsLeadingDivider))
    }

    func testConnectingAnotherDisplaySwitchesAfterTheCurrentDisplayDisconnects() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-current", name: "Current iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-target", name: "Target iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)

        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.last?.actionTitle,
            "Target iPad · 切换"
        )
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-target"))

        XCTAssertEqual(service.operations, ["disconnect:ipad-current"])
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "正在断开 Current iPad，然后连接 Target iPad…")

        service.complete(.success(()))

        XCTAssertEqual(service.operations, ["disconnect:ipad-current", "connect:ipad-target"])
        service.complete(.success(()))
        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.last?.actionTitle,
            "已断开 Current iPad，并已提交连接 Target iPad 的请求"
        )
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testSwitchDoesNotConnectTheTargetWhenDisconnectingTheCurrentDisplayFails() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-current", name: "Current iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-target", name: "Target iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-target"))
        service.complete(.failure(.system("Disconnect failed")))

        XCTAssertEqual(service.operations, ["disconnect:ipad-current"])
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "无法断开 Current iPad，因此无法切换到 Target iPad")
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台已连接 · 1 台可连接")
    }

    func testSwitchExplainsThatThePreviousDisplayWasDisconnectedWhenTargetConnectionFails() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-current", name: "Current iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-target", name: "Target iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-target"))
        service.complete(.success(()))
        service.complete(.failure(.system("Target unavailable")))

        XCTAssertEqual(
            plugin.primaryPanelState.errorMessage,
            "已断开 Current iPad，但无法连接 Target iPad：Target unavailable"
        )
    }

    func testWiredOnlyPreferenceChangesDirectConnectActionAndRequest() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateTransport(.wiredOnly, for: "ipad-1")
        let plugin = makePlugin(service: service, preferences: store)

        XCTAssertEqual(plugin.primaryPanelState.detail?.primaryControls.first?.actionTitle, "My iPad · 仅通过有线连接")
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))

        XCTAssertTrue(service.didConnect)
        XCTAssertTrue(service.receivedWiredOnly)
    }

    func testUnknownConnectionStateDoesNotClaimConnectOrDisconnect() {
        let plugin = makePlugin(service: FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .unknown)
        ]))

        let control = plugin.primaryPanelState.detail?.primaryControls.first
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台 Sidecar 显示器的连接状态不可用")
        XCTAssertEqual(control?.actionIconSystemName, "questionmark.circle")
        XCTAssertFalse(control?.isEnabled ?? true)
    }

    func testUntestedSystemShowsAWarningWithoutDisablingSidecar() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        service.isMinimumTestedSystem = false
        let plugin = makePlugin(service: service)

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台可连接的 Sidecar 显示器 · 未在 macOS 14.2 之前测试")
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
    }

    func testMinimumTestedVersionCheckDoesNotExcludeOlderSystems() {
        XCTAssertFalse(SidecarCoreService.isMinimumTested(OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)))
        XCTAssertTrue(SidecarCoreService.isMinimumTested(OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)))
        XCTAssertTrue(SidecarCoreService.isMinimumTested(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
    }

    func testPendingThenSuccessReturnsRowToLiveSummary() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "正在连接 My iPad…")
        service.complete(.success(()))

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台可连接的 Sidecar 显示器")
        XCTAssertEqual(plugin.primaryPanelState.detail?.primaryControls.first?.actionIconSystemName, "checkmark.circle")
    }

    func testConfirmedConnectionReplacesTransientFeedbackWithConnectedState() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = makePlugin(service: service)
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.success(()))
        service.updateDevices([SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected)])
        plugin.refresh()

        XCTAssertEqual(plugin.primaryPanelState.detail?.primaryControls.first?.actionTitle, "My iPad · 断开连接")
        XCTAssertEqual(plugin.primaryPanelState.detail?.primaryControls.first?.actionIconSystemName, "checkmark.circle.fill")
    }

    func testShortcutPreferencesPersistWhenDeviceIsUnavailable() {
        let storage = InMemoryPluginStorage()
        let store = SidecarPreferencesStore(storage: storage)
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        store.reconcile(with: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        store.updateTransport(.wiredOnly, for: "ipad-1")
        store.updateShortcutAction(.connect, for: "ipad-1")
        store.updateShortcut(binding, for: "ipad-1")

        let reloaded = SidecarPreferencesStore(storage: storage)
        XCTAssertEqual(reloaded.devices, [
            SidecarDevicePreference(
                id: "ipad-1",
                name: "My iPad",
                transport: .wiredOnly,
                shortcutAction: .connect,
                shortcut: binding
            )
        ])
        reloaded.reconcile(with: [])
        XCTAssertEqual(reloaded.devices.count, 1)
    }

    func testPortablePreferencesPreservePriorityAndGlobalShortcuts() {
        let source = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        source.reconcile(with: [
            SidecarDevice(id: "ipad-1", name: "First"),
            SidecarDevice(id: "ipad-2", name: "Second")
        ])
        source.move(deviceID: "ipad-2", before: "ipad-1")
        source.updateTransport(.wiredOnly, for: "ipad-2")
        source.updateConnectFirstAvailableShortcut(
            ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        )
        source.updateDisconnectAllShortcut(
            ShortcutBinding(keyCode: 1, modifiers: [.command, .shift])
        )

        let restored = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        restored.restorePortablePreferences(from: try! XCTUnwrap(source.portablePreferencesData()))

        XCTAssertEqual(restored.devices.map(\.id), ["ipad-2", "ipad-1"])
        XCTAssertEqual(restored.preference(for: "ipad-2")?.transport, .wiredOnly)
        XCTAssertEqual(
            restored.connectFirstAvailableShortcut,
            ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        )
        XCTAssertEqual(
            restored.disconnectAllShortcut,
            ShortcutBinding(keyCode: 1, modifiers: [.command, .shift])
        )
    }

    func testRestoringPreferencesRemovesDuplicateShortcutBindings() throws {
        struct PortablePreferences: Codable {
            let devices: [SidecarDevicePreference]
            let disconnectAllShortcut: ShortcutBinding?
            let connectFirstAvailableShortcut: ShortcutBinding?
        }

        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        let data = try JSONEncoder().encode(PortablePreferences(
            devices: [
                SidecarDevicePreference(id: "ipad-1", name: "First", shortcut: binding),
                SidecarDevicePreference(id: "ipad-2", name: "Second", shortcut: binding)
            ],
            disconnectAllShortcut: binding,
            connectFirstAvailableShortcut: binding
        ))
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())

        store.restorePortablePreferences(from: data)

        XCTAssertEqual(store.connectFirstAvailableShortcut, binding)
        XCTAssertNil(store.disconnectAllShortcut)
        XCTAssertNil(store.preference(for: "ipad-1")?.shortcut)
        XCTAssertNil(store.preference(for: "ipad-2")?.shortcut)
    }

    func testOnlyCustomizedOfflineDevicePreferencesNeedToRemainVisible() {
        let defaultPreference = SidecarDevicePreference(id: "ipad-1", name: "My iPad")
        let wiredPreference = SidecarDevicePreference(
            id: "ipad-2",
            name: "Desk iPad",
            transport: .wiredOnly
        )
        let shortcutPreference = SidecarDevicePreference(
            id: "ipad-3",
            name: "Travel iPad",
            shortcut: ShortcutBinding(keyCode: 0, modifiers: [.command])
        )

        XCTAssertFalse(defaultPreference.hasCustomConfiguration)
        XCTAssertTrue(wiredPreference.hasCustomConfiguration)
        XCTAssertTrue(shortcutPreference.hasCustomConfiguration)
    }

    func testSharedDeviceOrderingPrioritizesConnectedThenAvailableDisplays() {
        XCTAssertLessThan(
            SidecarDeviceOrdering.rank(for: .connected),
            SidecarDeviceOrdering.rank(for: .disconnected)
        )
        XCTAssertLessThan(
            SidecarDeviceOrdering.rank(for: .disconnected),
            SidecarDeviceOrdering.rank(for: .unknown)
        )
        XCTAssertLessThan(
            SidecarDeviceOrdering.rank(for: .unknown),
            SidecarDeviceOrdering.rank(for: nil)
        )
    }

    func testConfiguredPerDeviceShortcutUsesSavedActionAndTransport() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateTransport(.wiredOnly, for: "ipad-1")
        store.updateShortcutAction(.connect, for: "ipad-1")
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        store.updateShortcut(binding, for: "ipad-1")
        let shortcuts = FakeSidecarShortcutManager()
        let plugin = makePlugin(service: service, preferences: store, shortcutManager: shortcuts)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        XCTAssertEqual(shortcuts.bindings["device.ipad-1"], binding)

        shortcuts.trigger("device.ipad-1")
        XCTAssertTrue(service.didConnect)
        XCTAssertTrue(service.receivedWiredOnly)
    }

    func testConnectFirstAvailableShortcutUsesSavedPriorityAndConnectionMode() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "First", connectionState: .disconnected),
            SidecarDevice(id: "ipad-2", name: "Second", connectionState: .disconnected)
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.move(deviceID: "ipad-2", before: "ipad-1")
        store.updateTransport(.wiredOnly, for: "ipad-2")
        let binding = ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        store.updateConnectFirstAvailableShortcut(binding)
        let shortcuts = FakeSidecarShortcutManager()
        let plugin = makePlugin(service: service, preferences: store, shortcutManager: shortcuts)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        XCTAssertEqual(shortcuts.bindings["connect-first-available"], binding)

        shortcuts.trigger("connect-first-available")

        XCTAssertEqual(service.connectedDeviceID, "ipad-2")
        XCTAssertTrue(service.receivedWiredOnly)
    }

    func testConnectFirstAvailableDoesNotDisconnectAnExistingDisplay() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-current", name: "Current iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-target", name: "Target iPad", connectionState: .disconnected)
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateConnectFirstAvailableShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]))
        let shortcuts = FakeSidecarShortcutManager()
        let plugin = makePlugin(service: service, preferences: store, shortcutManager: shortcuts)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        shortcuts.trigger("connect-first-available")

        withExtendedLifetime(plugin) {}
        XCTAssertTrue(service.operations.isEmpty)
    }

    func testExplicitConnectShortcutSwitchesFromTheKnownConnectedDisplay() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-current", name: "Current iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-target", name: "Target iPad", connectionState: .disconnected)
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateShortcutAction(.connect, for: "ipad-target")
        store.updateShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]), for: "ipad-target")
        let shortcuts = FakeSidecarShortcutManager()
        let plugin = makePlugin(service: service, preferences: store, shortcutManager: shortcuts)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        shortcuts.trigger("device.ipad-target")

        withExtendedLifetime(plugin) {}
        XCTAssertEqual(service.operations, ["disconnect:ipad-current"])
    }

    func testDisconnectShortcutDoesNotGuessUnknownOrDisconnectedState() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateShortcutAction(.disconnect, for: "ipad-1")
        store.updateShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]), for: "ipad-1")
        let shortcuts = FakeSidecarShortcutManager()
        let plugin = makePlugin(service: service, preferences: store, shortcutManager: shortcuts)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))

        shortcuts.trigger("device.ipad-1")

        XCTAssertFalse(service.didDisconnect)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "该 Sidecar 显示器当前未连接")
    }

    func testDeactivationStopsPollingAndUnregistersShortcuts() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]), for: "ipad-1")
        let shortcuts = FakeSidecarShortcutManager()
        let plugin = makePlugin(service: service, preferences: store, shortcutManager: shortcuts)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        XCTAssertFalse(shortcuts.bindings.isEmpty)

        plugin.deactivate(reason: .disabled)
        plugin.refresh()
        plugin.panelSurfaceDidBecomeVisible(.primary)

        XCTAssertTrue(shortcuts.bindings.isEmpty)
    }

    func testFailedOperationFeedbackRemainsVisible() async {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service, operationFeedbackNanoseconds: 1)

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.failure(.system("Unavailable")))
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "Unavailable")
    }

    func testClosingThePanelClearsTerminalFeedbackThatWasAlreadyVisible() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let plugin = makePlugin(service: service)

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        plugin.panelSurfaceDidBecomeVisible(.primary)
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.failure(.system("Unavailable")))

        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "Unavailable")
        plugin.panelSurfaceDidBecomeHidden(.primary)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testExpiredShortcutFailureDoesNotAppearWhenThePanelOpens() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateShortcutAction(.disconnect, for: "ipad-1")
        store.updateShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]), for: "ipad-1")
        let shortcuts = FakeSidecarShortcutManager()
        let plugin = makePlugin(
            service: service,
            preferences: store,
            shortcutManager: shortcuts,
            terminalFeedbackExpiration: 0
        )

        plugin.activate(context: PluginRuntimeContext(pluginID: "sidecar", storage: InMemoryPluginStorage()))
        shortcuts.trigger("device.ipad-1")
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "该 Sidecar 显示器当前未连接")

        plugin.panelSurfaceDidBecomeVisible(.primary)
        XCTAssertNil(plugin.primaryPanelState.errorMessage)
    }

    func testServiceErrorsAndUnsupportedStateAreShown() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = makePlugin(service: service)
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.failure(.deviceUnavailable))
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "Sidecar 显示器已不在可用设备列表中")

        let unsupported = makePlugin(service: FakeSidecarService(availability: .unsupported(.frameworkLoadFailed)))
        XCTAssertEqual(unsupported.primaryPanelState.errorMessage, "此系统无法加载 SidecarCore")
    }

    private func makePlugin(
        service: FakeSidecarService,
        preferences: SidecarPreferencesStore? = nil,
        shortcutManager: (any SidecarShortcutManaging)? = nil,
        operationFeedbackNanoseconds: UInt64 = 4_000_000_000,
        terminalFeedbackExpiration: TimeInterval = 30,
        initialDeviceRefreshDelayNanoseconds: UInt64 = 750_000_000,
        deviceRefreshIntervalNanoseconds: UInt64 = 5_000_000_000
    ) -> SidecarPlugin {
        SidecarPlugin(
            service: service,
            preferences: preferences ?? SidecarPreferencesStore(storage: InMemoryPluginStorage()),
            shortcutManager: shortcutManager ?? FakeSidecarShortcutManager(),
            operationFeedbackNanoseconds: operationFeedbackNanoseconds,
            terminalFeedbackExpiration: terminalFeedbackExpiration,
            initialDeviceRefreshDelayNanoseconds: initialDeviceRefreshDelayNanoseconds,
            deviceRefreshIntervalNanoseconds: deviceRefreshIntervalNanoseconds
        )
    }
}

@MainActor
private final class FakeSidecarService: SidecarServicing {
    var availability: SidecarServiceAvailability = .available
    var isMinimumTestedSystem = true
    var onDevicesChanged: (() -> Void)?
    private var pendingCompletion: ((Result<Void, SidecarServiceError>) -> Void)?
    private(set) var didConnect = false
    private(set) var didDisconnect = false
    private(set) var receivedWiredOnly = false
    private(set) var connectedDeviceID: String?
    private(set) var operations: [String] = []
    private(set) var reachableDevicesCallCount = 0
    private var devices: [SidecarDevice]

    init(devices: [SidecarDevice] = [], availability: SidecarServiceAvailability = .available) {
        self.devices = devices
        self.availability = availability
    }

    func reachableDevices() -> [SidecarDevice] {
        reachableDevicesCallCount += 1
        return devices
    }
    func updateDevices(_ devices: [SidecarDevice]) { self.devices = devices }

    func connect(to device: SidecarDevice, wiredOnly: Bool, completion: @escaping (Result<Void, SidecarServiceError>) -> Void) {
        didConnect = true
        receivedWiredOnly = wiredOnly
        connectedDeviceID = device.id
        operations.append("connect:\(device.id)")
        pendingCompletion = completion
    }

    func disconnect(from device: SidecarDevice, completion: @escaping (Result<Void, SidecarServiceError>) -> Void) {
        didDisconnect = true
        operations.append("disconnect:\(device.id)")
        pendingCompletion = completion
    }

    func complete(_ result: Result<Void, SidecarServiceError>) {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?(result)
    }
}

@MainActor
private final class FakeSidecarShortcutManager: SidecarShortcutManaging {
    var onTrigger: ((String) -> Void)?
    private(set) var bindings: [String: ShortcutBinding] = [:]

    func sync(bindings: [String: ShortcutBinding]) { self.bindings = bindings }
    func temporarilyDisable(id: String) { bindings.removeValue(forKey: id) }
    func unregisterAll() { bindings = [:] }
    func trigger(_ id: String) { onTrigger?(id) }
}

@MainActor
private final class InMemoryPluginStorage: PluginStorage {
    private var store: [String: Any] = [:]

    func object(forKey key: String) -> Any? { store[key] }
    func data(forKey key: String) -> Data? { store[key] as? Data }
    func string(forKey key: String) -> String? { store[key] as? String }
    func stringArray(forKey key: String) -> [String]? { store[key] as? [String] }
    func integer(forKey key: String) -> Int { store[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { store[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { store[key] = value }
    func removeObject(forKey key: String) { store.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {
        guard store[key] == nil, let value = store[legacyKey] else { return }
        store[key] = value
        store.removeValue(forKey: legacyKey)
    }
}
