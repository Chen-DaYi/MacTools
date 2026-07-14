import XCTest
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
        let plugin = SidecarPlugin(service: FakeSidecarService())

        XCTAssertEqual(plugin.metadata.id, "sidecar")
    }

    func testCollapsedRowSaysWhenNoSidecarDisplayIsAvailable() {
        let plugin = SidecarPlugin(service: FakeSidecarService())

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "未发现可连接的 Sidecar 显示器")
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
    }

    func testBackgroundRefreshFindsDisplaysThatAppearAfterPluginStartup() async {
        let service = FakeSidecarService()
        let plugin = SidecarPlugin(
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

        service.updateDevices([
            SidecarDevice(id: "vision-pro", name: "Apple Vision Pro")
        ])

        await fulfillment(of: [refreshed], timeout: 1)
    }

    func testExpandedDevicePanelShowsInlineActionsAndSeparatesWiredOnlyAction() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad"),
            SidecarDevice(id: "ipad-2", name: "Other iPad")
        ])
        let plugin = SidecarPlugin(service: service)

        plugin.handleAction(.setDisclosureExpanded(true))
        plugin.handleAction(.setNavigationSelection(controlID: "sidecar-device-navigation.ipad-1", optionID: "ipad-1"))

        let detail = plugin.primaryPanelState.detail
        let controls = detail?.primaryControls ?? []
        XCTAssertNil(detail?.secondaryPanel)
        XCTAssertEqual(
            controls.map(\.id),
            [
                "sidecar-device-navigation.ipad-1",
                "sidecar-connect.ipad-1",
                "sidecar-disconnect.ipad-1",
                "sidecar-wired-connect.ipad-1",
                "sidecar-device-navigation.ipad-2"
            ]
        )

        let connect = controls.first(where: { $0.id == "sidecar-connect.ipad-1" })
        XCTAssertEqual(connect?.actionTitle, "连接")
        XCTAssertEqual(connect?.showsLeadingDivider, true)

        let wired = controls.first(where: { $0.id == "sidecar-wired-connect.ipad-1" })
        XCTAssertEqual(wired?.actionTitle, "仅通过有线连接")
        XCTAssertEqual(wired?.sectionTitle, "仅有线：不会回退到 Wi-Fi")

        plugin.handleAction(.invokeAction(controlID: "sidecar-wired-connect.ipad-1"))
        XCTAssertTrue(service.receivedWiredOnly)
    }

    func testClearingSelectedDeviceHidesInlineActions() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = SidecarPlugin(service: service)

        plugin.handleAction(.setDisclosureExpanded(true))
        plugin.handleAction(.setNavigationSelection(controlID: "sidecar-device-navigation.ipad-1", optionID: "ipad-1"))
        plugin.handleAction(.clearNavigationSelection(controlID: "sidecar-device-navigation.ipad-1"))

        let controlIDs = plugin.primaryPanelState.detail?.primaryControls.map(\.id) ?? []
        XCTAssertEqual(controlIDs, ["sidecar-device-navigation.ipad-1"])
    }

    func testClickingSelectedDeviceAgainHidesInlineActions() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = SidecarPlugin(service: service)

        plugin.handleAction(.setDisclosureExpanded(true))
        plugin.handleAction(.setNavigationSelection(controlID: "sidecar-device-navigation.ipad-1", optionID: "ipad-1"))
        plugin.handleAction(.setNavigationSelection(controlID: "sidecar-device-navigation.ipad-1", optionID: "ipad-1"))

        let controlIDs = plugin.primaryPanelState.detail?.primaryControls.map(\.id) ?? []
        XCTAssertEqual(controlIDs, ["sidecar-device-navigation.ipad-1"])
    }

    func testConnectedDeviceShowsDisconnectOnly() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected)
        ])
        let plugin = SidecarPlugin(service: service)

        plugin.handleAction(.setDisclosureExpanded(true))
        plugin.handleAction(.setNavigationSelection(controlID: "sidecar-device-navigation.ipad-1", optionID: "ipad-1"))

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台显示器已通过 Sidecar 连接")
        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.first?.sectionTitle,
            "已连接"
        )
        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.first?.actionIconSystemName,
            "checkmark.circle.fill"
        )
        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.map(\.id),
            [
                "sidecar-device-navigation.ipad-1",
                "sidecar-disconnect.ipad-1"
            ]
        )
    }

    func testConnectedDevicesAppearBeforeAvailableDevicesWithSeparateSections() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-available", name: "Available iPad"),
            SidecarDevice(id: "ipad-connected", name: "Connected iPad", connectionState: .connected),
            SidecarDevice(id: "ipad-other", name: "Other iPad")
        ])
        let plugin = SidecarPlugin(service: service)

        plugin.handleAction(.setDisclosureExpanded(true))

        let controls = plugin.primaryPanelState.detail?.primaryControls ?? []
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台已连接 · 2 台可连接")
        XCTAssertEqual(
            controls.map(\.id),
            [
                "sidecar-device-navigation.ipad-connected",
                "sidecar-device-navigation.ipad-available",
                "sidecar-device-navigation.ipad-other"
            ]
        )
        XCTAssertEqual(controls[0].sectionTitle, "已连接")
        XCTAssertEqual(controls[1].sectionTitle, "可用的 Sidecar 显示器")
        XCTAssertNil(controls[2].sectionTitle)
        XCTAssertEqual(controls[0].actionIconSystemName, "checkmark.circle.fill")
        XCTAssertEqual(controls[1].actionIconSystemName, "circle")
    }

    func testDisconnectedDeviceShowsConnectActionsOnly() {
        let service = FakeSidecarService(devices: [
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .disconnected)
        ])
        let plugin = SidecarPlugin(service: service)

        plugin.handleAction(.setDisclosureExpanded(true))
        plugin.handleAction(.setNavigationSelection(controlID: "sidecar-device-navigation.ipad-1", optionID: "ipad-1"))

        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.map(\.id),
            [
                "sidecar-device-navigation.ipad-1",
                "sidecar-connect.ipad-1",
                "sidecar-wired-connect.ipad-1"
            ]
        )
    }

    func testPendingThenSuccessReturnsCollapsedRowToLiveStateSummary() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = SidecarPlugin(service: service)
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "正在连接 My iPad…")

        service.complete(.success(()))

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台可连接的 Sidecar 显示器")
        XCTAssertFalse(plugin.primaryPanelState.subtitle.contains("已连接"))
    }

    func testCompletedOperationFeedbackAppearsOnItsDeviceRow() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = SidecarPlugin(service: service)
        plugin.handleAction(.setDisclosureExpanded(true))

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.success(()))

        let deviceControl = plugin.primaryPanelState.detail?.primaryControls.first
        XCTAssertEqual(deviceControl?.options.first?.subtitle, "已提交连接 My iPad 的请求")
        XCTAssertEqual(deviceControl?.actionIconSystemName, "checkmark.circle")
    }

    func testConfirmedConnectionReplacesTransientFeedbackWithConnectedState() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = SidecarPlugin(service: service)
        plugin.handleAction(.setDisclosureExpanded(true))

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.success(()))
        service.updateDevices([
            SidecarDevice(id: "ipad-1", name: "My iPad", connectionState: .connected)
        ])
        plugin.refresh()

        let deviceControl = plugin.primaryPanelState.detail?.primaryControls.first
        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台显示器已通过 Sidecar 连接")
        XCTAssertEqual(deviceControl?.options.first?.subtitle, "已通过 Sidecar 连接")
        XCTAssertEqual(deviceControl?.actionIconSystemName, "checkmark.circle.fill")
    }

    func testFailureAndTimeoutAreShown() async {
        let failureService = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let failurePlugin = SidecarPlugin(service: failureService)
        failurePlugin.handleAction(.invokeAction(controlID: "sidecar-disconnect.ipad-1"))
        failureService.complete(.failure(.system("Sidecar error")))

        XCTAssertEqual(failurePlugin.primaryPanelState.errorMessage, "Sidecar error")

        let timeoutService = FakeSidecarService(devices: [SidecarDevice(id: "ipad-2", name: "Test iPad")])
        let timeoutPlugin = SidecarPlugin(
            service: timeoutService,
            operationTimeoutNanoseconds: 0
        )
        let timedOut = expectation(description: "operation timed out")
        timeoutPlugin.onStateChange = {
            if timeoutPlugin.primaryPanelState.errorMessage == "操作超时，请检查目标设备、线缆和网络后重试" {
                timedOut.fulfill()
            }
        }
        timeoutPlugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-2"))

        await fulfillment(of: [timedOut], timeout: 1)

        XCTAssertEqual(timeoutPlugin.primaryPanelState.errorMessage, "操作超时，请检查目标设备、线缆和网络后重试")
    }

    func testServiceErrorsAreLocalizedInPanel() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = SidecarPlugin(service: service)

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.failure(.deviceUnavailable))

        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "Sidecar 显示器已不在可用设备列表中")
    }

    func testUnsupportedReasonIsLocalizedInPanel() {
        let service = FakeSidecarService(availability: .unsupported(.frameworkLoadFailed))
        let plugin = SidecarPlugin(service: service)

        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "此系统无法加载 SidecarCore")
    }
}

@MainActor
private final class FakeSidecarService: SidecarServicing {
    var availability: SidecarServiceAvailability = .available
    var onDevicesChanged: (() -> Void)?
    private var pendingCompletion: ((Result<Void, SidecarServiceError>) -> Void)?
    private(set) var receivedWiredOnly = false
    private var devices: [SidecarDevice]

    init(
        devices: [SidecarDevice] = [],
        availability: SidecarServiceAvailability = .available
    ) {
        self.devices = devices
        self.availability = availability
    }

    func reachableDevices() -> [SidecarDevice] {
        devices
    }

    func updateDevices(_ devices: [SidecarDevice]) {
        self.devices = devices
    }

    func connect(
        to device: SidecarDevice,
        wiredOnly: Bool,
        completion: @escaping (Result<Void, SidecarServiceError>) -> Void
    ) {
        receivedWiredOnly = wiredOnly
        pendingCompletion = completion
    }

    func disconnect(
        from device: SidecarDevice,
        completion: @escaping (Result<Void, SidecarServiceError>) -> Void
    ) {
        pendingCompletion = completion
    }

    func complete(_ result: Result<Void, SidecarServiceError>) {
        pendingCompletion?(result)
        pendingCompletion = nil
    }
}
