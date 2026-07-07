import XCTest
import MacToolsPluginKit
@testable import DeviceBatteryPlugin

@MainActor
final class DeviceBatteryPluginTests: XCTestCase {
    func testPluginDescriptorUsesExpandedFullWidthSpan() {
        let plugin = DeviceBatteryPlugin(
            context: makeContext(),
            viewModel: DeviceBatteryViewModel(
                sampler: StubDeviceBatterySampler(items: []),
                rapooMonitor: StubRapooBatteryMonitor()
            ),
            inputMonitoringAuthorizationStatus: { .unknown }
        )

        XCTAssertEqual(plugin.metadata.id, "device-battery")
        XCTAssertEqual(plugin.metadata.title, "设备电量")
        XCTAssertEqual(plugin.descriptor.span, PluginComponentSpan(width: 4, height: 15)!)
    }

    func testLayoutSpanAccountsForVisibleDeviceCount() {
        XCTAssertEqual(DeviceBatteryComponentLayout.spanHeight(mode: .list, visibleItemCount: 1), 14)
        XCTAssertEqual(DeviceBatteryComponentLayout.spanHeight(mode: .list, visibleItemCount: 9), 31)
    }

    func testStorePersistsLayoutAndSources() {
        let storage = DeviceBatteryMemoryStorage()
        let store = DeviceBatteryStore(storage: storage)

        store.setLayoutMode(.list)
        store.setShowBluetoothDevices(false)
        store.setShowRapooDevices(false)

        let reloaded = DeviceBatteryStore(storage: storage)
        XCTAssertEqual(reloaded.layoutMode, .list)
        XCTAssertTrue(reloaded.showInternalBattery)
        XCTAssertFalse(reloaded.showBluetoothDevices)
        XCTAssertFalse(reloaded.showRapooDevices)
    }

    func testStorePersistsLowBatteryNotificationSettings() {
        let storage = DeviceBatteryMemoryStorage()
        let store = DeviceBatteryStore(storage: storage)

        XCTAssertFalse(store.lowBatteryNotificationEnabled)
        XCTAssertEqual(store.lowBatteryNotificationThreshold, 20)

        store.setLowBatteryNotificationEnabled(true)
        store.setLowBatteryNotificationThreshold(15)

        let reloaded = DeviceBatteryStore(storage: storage)
        XCTAssertTrue(reloaded.lowBatteryNotificationEnabled)
        XCTAssertEqual(reloaded.lowBatteryNotificationThreshold, 15)
    }

    func testStoreClampsLowBatteryNotificationThreshold() {
        let store = DeviceBatteryStore(storage: DeviceBatteryMemoryStorage())

        store.setLowBatteryNotificationThreshold(0)
        XCTAssertEqual(store.lowBatteryNotificationThreshold, 1)

        store.setLowBatteryNotificationThreshold(120)
        XCTAssertEqual(store.lowBatteryNotificationThreshold, 99)
    }

    func testBluetoothPowerLogParserReadsConnectedMouseBattery() {
        let line = """
        2026-06-02 14:05:52.648 Df bluetoothd[616:f85de1] [com.apple.bluetooth:CBPowerSource] Power source updated CBPowerSource Nm 'MX Anywhere 3S', SID 49354549, AcCa Mouse, AcID 0532E370-EA18-11C7-44F9-6D7E86E35891, PID 0xB037 (?), VID 0x046D (?), VIDSrc USB, Type 'Accessory Source', TPT Bluetooth LE, CF 0x1 < Attributes >, IF 0x2 < IOKit >, Present yes, MaxC 100%, Battery -80%
        """

        let reading = DeviceBatteryBluetoothPowerLogParser.reading(from: line)

        XCTAssertEqual(reading?.name, "MX Anywhere 3S")
        XCTAssertEqual(reading?.vendorID, "0x046D")
        XCTAssertEqual(reading?.productID, "0xB037")
        XCTAssertEqual(reading?.deviceType, "Mouse")
        XCTAssertEqual(reading?.level, 80)
        XCTAssertEqual(reading?.chargeState, .normal)
    }

    func testBluetoothPowerLogParserReadsAirPodsComponents() {
        let line = """
        2026-06-02 16:43:44.978 Df bluetoothd[616:ff000b] [com.apple.bluetooth:CBPowerSource] Power source updated CBPowerSource Nm 'ggbond AirPods 4', SID 70391692, AcCa Headphone, PID 0x201B (Device1,8219), VID 0x004C (Apple), Battery 68% (Unknown), Components (Y): Left +100%, CF 0x1 < Attributes >, Right +100%, CF 0x1 < Attributes >, Case +83%, CF 0x1 < Attributes >
        """

        let readings = DeviceBatteryBluetoothPowerLogParser.readings(fromLine: line)

        XCTAssertEqual(readings.first { $0.component == nil }?.level, 68)
        XCTAssertEqual(readings.first { $0.component == .left }?.chargeState, .charging)
        XCTAssertEqual(readings.first { $0.component == .chargingCase }?.level, 83)
    }

    func testBatteryCenterLogParserReadsChargingState() {
        let line = """
        2026-06-12 21:43:32.313 Df NotificationCenter[1199:36289f6] [com.apple.BatteryCenter:PowerSourceController] Found device: <BCBatteryDevice: 0x804941b80; vendor = Apple; productIdentifier = 8212; parts = (null); identifier = 49443244; matchIdentifier = (null); name = ggbond AirPods; groupName =ggbond AirPods; percentCharge = 24; lowBattery = NO; lowPowerModeActive = NO; connected = YES; charging = YES; paused = NO; internal = NO; powerSource = NO; poweredSoureState = AC Power; transportType = Bluetooth; accessoryIdentifier = 2C7600E3-8F61-4CAA-A1F0-BADBEEF12345; accessoryCategory = Headphones; modelNumber = AirPods Pro 2; >
        """

        let reading = DeviceBatteryBatteryCenterLogParser.reading(fromLine: line)

        XCTAssertEqual(reading?.name, "ggbond AirPods")
        XCTAssertEqual(reading?.model, "AirPods Pro 2")
        XCTAssertEqual(reading?.level, 24)
        XCTAssertEqual(reading?.chargeState, .charging)
        XCTAssertEqual(reading?.isConnected, true)
    }

    func testAppleHeadphoneAdvertisementParserReadsChargingParts() {
        var data = [UInt8](repeating: 0, count: 25)
        data[0] = 0x4C
        data[1] = 0x00
        data[2] = 0x12
        data[12] = 0x80 | 24
        data[13] = 0x80 | 100
        data[14] = 100

        let readings = DeviceBatteryAppleHeadphoneAdvertisementParser.readings(from: Data(data))

        XCTAssertEqual(readings.first { $0.component == .chargingCase }?.chargeState, .charging)
        XCTAssertEqual(readings.first { $0.component == .left }?.level, 100)
        XCTAssertEqual(readings.first { $0.component == .right }?.chargeState, .normal)
    }

    func testRapooParserReadsProtocolOneBatteryReport() {
        let report = [UInt8](repeating: 0, count: 16).setting(1, at: 6).setting(83, at: 7)

        XCTAssertEqual(
            RapooBatteryParser.parseInputReport(reportID: 7, bytes: report),
            RapooBatteryReading(level: 83, chargeState: .normal, statusCode: 1)
        )
    }

    func testItemNormalizerDropsAirPodsAggregateWhenComponentsExist() {
        let aggregate = makeAirPodsItem(id: "main", role: .aggregate)
        let caseItem = makeAirPodsItem(id: "case", role: .chargingCase)

        XCTAssertEqual(
            DeviceBatteryItemNormalizer.removingRedundantComponentAggregates([aggregate, caseItem]).map(\.id),
            ["case"]
        )
    }

    func testLowBatteryNotificationMergesMultipleDevices() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)
        let snapshot = makeSnapshot(items: [
            makeBatteryItem(id: "mouse", name: "Mouse", level: 12),
            makeBatteryItem(id: "keyboard", name: "Keyboard", level: 18),
            makeBatteryItem(id: "trackpad", name: "Trackpad", level: 38)
        ])

        controller.evaluate(
            snapshot: snapshot,
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 1)
        XCTAssertEqual(notifier.notifications[0].deviceIDs, ["mouse", "keyboard"])
        XCTAssertEqual(notifier.notifications[0].title, "2 台设备电量偏低")
        XCTAssertTrue(notifier.notifications[0].body.contains("Mouse 12%"))
        XCTAssertTrue(notifier.notifications[0].body.contains("Keyboard 18%"))
        XCTAssertFalse(notifier.notifications[0].body.contains("Trackpad"))
    }

    func testLowBatteryNotificationDoesNotRepeatUntilDeviceRecovers() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)
        let lowSnapshot = makeSnapshot(items: [
            makeBatteryItem(id: "mouse", name: "Mouse", level: 12)
        ])

        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )
        XCTAssertEqual(notifier.notifications.count, 1)

        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(id: "mouse", name: "Mouse", level: 35)
            ]),
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 2)
    }

    func testLowBatteryNotificationDoesNotRepeatWhenSourceIDChanges() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)

        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "bluetooth-powerlog-airpods-left",
                    name: "AirPods 左耳",
                    level: 7,
                    kind: .airPodsPart,
                    parentName: "AirPods 充电盒",
                    componentIdentity: DeviceBatteryComponentIdentity(groupID: "airpods-address", role: .left)
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "apple-headphone-advertisement-airpods-left",
                    name: "AirPods 左耳",
                    level: 6,
                    kind: .airPodsPart,
                    parentName: "AirPods 充电盒",
                    componentIdentity: DeviceBatteryComponentIdentity(groupID: "airpods-advertisement", role: .left)
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 1)
    }

    func testLowBatteryNotificationDoesNotRepeatWhenDeviceKindChanges() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)

        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "bluetooth-mx-anywhere",
                    name: "MX Anywhere 3S",
                    level: 9,
                    kind: .bluetooth
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "batterycenter-mx-anywhere",
                    name: "MX Anywhere 3S",
                    level: 8,
                    kind: .magicAccessory
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 1)
    }

    func testLowBatteryNotificationDoesNotRepeatWhenAggregateRoleChanges() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)

        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "corebluetooth-airpods",
                    name: "AirPods",
                    level: 9,
                    kind: .airPodsPart,
                    componentIdentity: DeviceBatteryComponentIdentity(groupID: "airpods", role: .aggregate)
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(
                    id: "batterycenter-airpods",
                    name: "AirPods",
                    level: 8,
                    kind: .airPodsPart
                )
            ]),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 1)
    }

    func testLowBatteryNotificationDoesNotResetWhenDeviceTemporarilyMissing() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)
        let lowSnapshot = makeSnapshot(items: [
            makeBatteryItem(id: "mouse", name: "Mouse", level: 8)
        ])

        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: makeSnapshot(items: []),
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 10,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 1)
    }

    func testLowBatteryNotificationResetsAfterDeviceIsCharged() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)
        let lowSnapshot = makeSnapshot(items: [
            makeBatteryItem(id: "mouse", name: "Mouse", level: 12)
        ])

        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(id: "mouse", name: "Mouse", level: 100, chargeState: .charged)
            ]),
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )
        controller.evaluate(
            snapshot: lowSnapshot,
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertEqual(notifier.notifications.count, 2)
    }

    func testLowBatteryNotificationIgnoresChargingDevicesAndBoundaryValue() {
        let notifier = RecordingLowBatteryNotifier()
        let controller = DeviceBatteryLowBatteryNotificationController(notifier: notifier)

        controller.evaluate(
            snapshot: makeSnapshot(items: [
                makeBatteryItem(id: "mouse", name: "Mouse", level: 20),
                makeBatteryItem(id: "keyboard", name: "Keyboard", level: 12, chargeState: .charging),
                makeBatteryItem(id: "trackpad", name: "Trackpad", level: 12, isConnected: false)
            ]),
            isEnabled: true,
            threshold: 20,
            localization: PluginLocalization(bundle: .main)
        )

        XCTAssertTrue(notifier.notifications.isEmpty)
    }

    private func makeContext() -> PluginRuntimeContext {
        PluginRuntimeContext(pluginID: "device-battery", storage: DeviceBatteryMemoryStorage())
    }

    private func makeSnapshot(items: [DeviceBatteryItem]) -> DeviceBatterySnapshot {
        DeviceBatterySnapshot(
            accessState: .ready,
            items: items,
            lastUpdated: Date(),
            rapooState: .idle
        )
    }

    private func makeAirPodsItem(id: String, role: DeviceBatteryComponentRole) -> DeviceBatteryItem {
        DeviceBatteryItem(
            id: id,
            name: id,
            model: "AirPods 4",
            kind: .airPodsPart,
            level: 80,
            chargeState: .normal,
            parentName: nil,
            source: "test",
            lastUpdated: Date(),
            isConnected: true,
            detail: "Headphones",
            componentIdentity: DeviceBatteryComponentIdentity(groupID: "airpods", role: role)
        )
    }

    private func makeBatteryItem(
        id: String,
        name: String,
        level: Int,
        kind: DeviceBatteryKind = .bluetooth,
        chargeState: DeviceBatteryChargeState = .normal,
        isConnected: Bool = true,
        parentName: String? = nil,
        componentIdentity: DeviceBatteryComponentIdentity? = nil
    ) -> DeviceBatteryItem {
        DeviceBatteryItem(
            id: id,
            name: name,
            model: nil,
            kind: kind,
            level: level,
            chargeState: chargeState,
            parentName: parentName,
            source: "test",
            lastUpdated: Date(),
            isConnected: isConnected,
            detail: nil,
            componentIdentity: componentIdentity
        )
    }
}

@MainActor
private final class DeviceBatteryMemoryStorage: PluginStorage {
    private var values: [String: Any] = [:]

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

private struct StubDeviceBatterySampler: DeviceBatterySampling {
    let items: [DeviceBatteryItem]

    func collectSystemDevices(referenceDate: Date) async -> [DeviceBatteryItem] {
        items
    }
}

@MainActor
private final class RecordingLowBatteryNotifier: DeviceBatteryLowBatteryNotifying {
    private(set) var notifications: [DeviceBatteryLowBatteryNotification] = []

    func notifyLowBatteryDevices(
        _ items: [DeviceBatteryItem],
        threshold: Int,
        localization: PluginLocalization
    ) {
        notifications.append(
            DeviceBatteryLowBatteryNotificationContent.make(
                items: items,
                threshold: threshold,
                localization: localization
            )
        )
    }
}

@MainActor
private final class StubRapooBatteryMonitor: RapooBatteryMonitoring {
    var snapshot = RapooMouseBatterySnapshot.idle
    var onSnapshotChange: ((RapooMouseBatterySnapshot) -> Void)?

    func start() {}
    func stop() {}
    func refresh() {}
}

private extension Array where Element == UInt8 {
    func setting(_ value: UInt8, at index: Int) -> [UInt8] {
        var copy = self
        copy[index] = value
        return copy
    }
}
