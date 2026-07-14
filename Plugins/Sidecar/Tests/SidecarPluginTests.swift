import XCTest
@testable import SidecarPlugin

@MainActor
final class SidecarPluginTests: XCTestCase {
    func testMetadataUsesStableSidecarID() {
        let plugin = SidecarPlugin(service: FakeSidecarService())

        XCTAssertEqual(plugin.metadata.id, "sidecar")
    }

    func testCollapsedRowSaysWhenNoIPadIsAvailable() {
        let plugin = SidecarPlugin(service: FakeSidecarService())

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "未发现可连接的 iPad")
        XCTAssertTrue(plugin.primaryPanelState.isEnabled)
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

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "1 台 iPad 已通过 Sidecar 连接")
        XCTAssertEqual(
            plugin.primaryPanelState.detail?.primaryControls.map(\.id),
            [
                "sidecar-device-navigation.ipad-1",
                "sidecar-disconnect.ipad-1"
            ]
        )
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

    func testPendingThenSuccessDoesNotClaimCurrentConnectionState() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = SidecarPlugin(service: service)
        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "正在连接 My iPad…")

        service.complete(.success(()))

        XCTAssertEqual(plugin.primaryPanelState.subtitle, "已提交连接 My iPad 的请求")
        XCTAssertFalse(plugin.primaryPanelState.subtitle.contains("已连接"))
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
        timeoutPlugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-2"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(timeoutPlugin.primaryPanelState.errorMessage, "操作超时，请检查 iPad、线缆和网络后重试")
    }

    func testServiceErrorsAreLocalizedInPanel() {
        let service = FakeSidecarService(devices: [SidecarDevice(id: "ipad-1", name: "My iPad")])
        let plugin = SidecarPlugin(service: service)

        plugin.handleAction(.invokeAction(controlID: "sidecar-connect.ipad-1"))
        service.complete(.failure(.deviceUnavailable))

        XCTAssertEqual(plugin.primaryPanelState.errorMessage, "iPad 已不在可用设备列表中")
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
    private let devices: [SidecarDevice]

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
