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

        service.updateDevices([SidecarDevice(id: "vision-pro", name: "Apple Vision Pro")])

        await fulfillment(of: [refreshed], timeout: 1)
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
        XCTAssertEqual(control?.actionIconSystemName, "questionmark.circle")
        XCTAssertFalse(control?.isEnabled ?? true)
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

    func testDisconnectShortcutDoesNotGuessUnknownOrDisconnectedState() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let store = SidecarPreferencesStore(storage: InMemoryPluginStorage())
        store.reconcile(with: service.reachableDevices())
        store.updateShortcutAction(.disconnect, for: "ipad-1")
        store.updateShortcut(ShortcutBinding(keyCode: 0, modifiers: [.command]), for: "ipad-1")
        let shortcuts = FakeSidecarShortcutManager()
        let plugin = makePlugin(service: service, preferences: store, shortcutManager: shortcuts)

        shortcuts.trigger("device.ipad-1")

        XCTAssertFalse(service.didDisconnect)
        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "该 Sidecar 显示器当前未连接")
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
        initialDeviceRefreshDelayNanoseconds: UInt64 = 750_000_000,
        deviceRefreshIntervalNanoseconds: UInt64 = 5_000_000_000
    ) -> SidecarPlugin {
        SidecarPlugin(
            service: service,
            preferences: preferences ?? SidecarPreferencesStore(storage: InMemoryPluginStorage()),
            shortcutManager: shortcutManager ?? FakeSidecarShortcutManager(),
            initialDeviceRefreshDelayNanoseconds: initialDeviceRefreshDelayNanoseconds,
            deviceRefreshIntervalNanoseconds: deviceRefreshIntervalNanoseconds
        )
    }
}

@MainActor
private final class FakeSidecarService: SidecarServicing {
    var availability: SidecarServiceAvailability = .available
    var onDevicesChanged: (() -> Void)?
    private var pendingCompletion: ((Result<Void, SidecarServiceError>) -> Void)?
    private(set) var didConnect = false
    private(set) var didDisconnect = false
    private(set) var receivedWiredOnly = false
    private var devices: [SidecarDevice]

    init(devices: [SidecarDevice] = [], availability: SidecarServiceAvailability = .available) {
        self.devices = devices
        self.availability = availability
    }

    func reachableDevices() -> [SidecarDevice] { devices }
    func updateDevices(_ devices: [SidecarDevice]) { self.devices = devices }

    func connect(to device: SidecarDevice, wiredOnly: Bool, completion: @escaping (Result<Void, SidecarServiceError>) -> Void) {
        didConnect = true
        receivedWiredOnly = wiredOnly
        pendingCompletion = completion
    }

    func disconnect(from device: SidecarDevice, completion: @escaping (Result<Void, SidecarServiceError>) -> Void) {
        didDisconnect = true
        pendingCompletion = completion
    }

    func complete(_ result: Result<Void, SidecarServiceError>) {
        pendingCompletion?(result)
        pendingCompletion = nil
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
