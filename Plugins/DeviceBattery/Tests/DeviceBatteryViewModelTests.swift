import XCTest
import MacToolsPluginKit
@testable import DeviceBatteryPlugin

@MainActor
final class DeviceBatteryViewModelTests: XCTestCase {
    func testNoSamplingRunsWithoutVisibleComponentOrLowBatteryMonitoring() async {
        let sampler = RecordingDeviceBatterySampler()
        let powerObserver = RecordingPowerSourceObserver()
        let bluetoothObserver = RecordingBluetoothConnectionObserver()
        let viewModel = makeViewModel(
            sampler: sampler,
            powerObserver: powerObserver,
            bluetoothObserver: bluetoothObserver
        )

        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: true
        )
        try? await Task.sleep(for: .milliseconds(50))

        let counts = await sampler.counts()
        XCTAssertEqual(counts, .zero)
        XCTAssertFalse(powerObserver.isStarted)
        XCTAssertFalse(bluetoothObserver.isStarted)
        viewModel.stop()
    }

    func testVisibleComponentStartsEachSourceAndHidingStopsPeriodicWork() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )

        viewModel.setComponentPanelVisible(true)
        await waitForCounts(.oneEach, sampler: sampler)
        viewModel.setComponentPanelVisible(false)
        try? await Task.sleep(for: .milliseconds(50))

        let counts = await sampler.counts()
        XCTAssertEqual(counts, .oneEach)
        viewModel.stop()
    }

    func testLowBatteryMonitoringActsAsBackgroundConsumer() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )

        await waitForCounts(.oneEach, sampler: sampler)
        XCTAssertEqual(viewModel.bluetoothRefreshInterval, 30)
        viewModel.stop()
    }

    func testSystemEventsRefreshOnlyTheirSourceAndDebounceBluetooth() async {
        let sampler = RecordingDeviceBatterySampler()
        let powerObserver = RecordingPowerSourceObserver()
        let bluetoothObserver = RecordingBluetoothConnectionObserver()
        let viewModel = makeViewModel(
            sampler: sampler,
            powerObserver: powerObserver,
            bluetoothObserver: bluetoothObserver
        )
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        await waitForCounts(.oneEach, sampler: sampler)

        powerObserver.sendChange()
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 2, bluetooth: 1, appleMobile: 1),
            sampler: sampler
        )

        bluetoothObserver.sendConnectionChange()
        bluetoothObserver.sendConnectionChange()
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 2, bluetooth: 2, appleMobile: 1),
            sampler: sampler
        )
        viewModel.stop()
    }

    func testActivityPauseDefersEventsAndCoalescesResume() async {
        let sampler = RecordingDeviceBatterySampler()
        let bluetoothObserver = RecordingBluetoothConnectionObserver()
        let viewModel = makeViewModel(
            sampler: sampler,
            bluetoothObserver: bluetoothObserver
        )
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        await waitForCounts(.oneEach, sampler: sampler)

        viewModel.setApplicationActivityState(.systemSleeping)
        bluetoothObserver.sendConnectionChange()
        try? await Task.sleep(for: .milliseconds(50))
        let counts = await sampler.counts()
        XCTAssertEqual(counts, .oneEach)

        viewModel.setApplicationActivityState(.interactive)
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 2, bluetooth: 2, appleMobile: 2),
            sampler: sampler
        )
        let options = await sampler.bluetoothOptions()
        XCTAssertEqual(options.last?.forceProfileRefresh, true)
        viewModel.stop()
    }

    func testReopeningComponentForcesBluetoothProfileRefresh() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.start(
            includeInternalBattery: false,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: false,
            includeRapooDevices: false
        )

        viewModel.setComponentPanelVisible(true)
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 0, bluetooth: 1, appleMobile: 0),
            sampler: sampler
        )
        viewModel.setComponentPanelVisible(false)
        viewModel.setComponentPanelVisible(true)
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 0, bluetooth: 2, appleMobile: 0),
            sampler: sampler
        )

        let options = await sampler.bluetoothOptions()
        XCTAssertEqual(options.map(\.forceProfileRefresh), [true, true])
        viewModel.stop()
    }

    func testWakeWindowConnectionEventIsMergedIntoResumeSampling() async {
        let sampler = RecordingDeviceBatterySampler()
        let bluetoothObserver = RecordingBluetoothConnectionObserver()
        let viewModel = makeViewModel(
            sampler: sampler,
            bluetoothObserver: bluetoothObserver,
            schedule: DeviceBatterySamplingSchedule(
                internalBatteryFallback: 30,
                bluetoothBackground: 30,
                bluetoothComponentVisible: 30,
                appleMobileBackground: 30,
                appleMobileComponentVisible: 30,
                bluetoothConnectionDebounce: 0.01,
                activityResumeDelay: 0.05
            )
        )
        viewModel.setLowBatteryMonitoringEnabled(true)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: true,
            includeAppleMobileDevices: true,
            includeRapooDevices: false
        )
        await waitForCounts(.oneEach, sampler: sampler)

        viewModel.setApplicationActivityState(.displayAsleep)
        viewModel.setApplicationActivityState(.interactive)
        bluetoothObserver.sendConnectionChange()
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 2, bluetooth: 2, appleMobile: 2),
            sampler: sampler
        )
        try? await Task.sleep(for: .milliseconds(100))

        let finalCounts = await sampler.counts()
        let finalBluetoothOptions = await sampler.bluetoothOptions()
        XCTAssertEqual(finalCounts, DeviceBatterySamplingCounts(
            internalBattery: 2,
            bluetooth: 2,
            appleMobile: 2
        ))
        XCTAssertEqual(finalBluetoothOptions.last?.forceProfileRefresh, true)
        viewModel.stop()
    }

    func testRemovingLastConsumerClearsCollectedSnapshot() async {
        let sampler = RecordingDeviceBatterySampler()
        let viewModel = makeViewModel(sampler: sampler)
        viewModel.start(
            includeInternalBattery: true,
            includeBluetoothDevices: false,
            includeAppleMobileDevices: false,
            includeRapooDevices: false
        )
        viewModel.setComponentPanelVisible(true)
        await waitForCounts(
            DeviceBatterySamplingCounts(internalBattery: 1, bluetooth: 0, appleMobile: 0),
            sampler: sampler
        )
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(viewModel.snapshot.lastUpdated)

        viewModel.setComponentPanelVisible(false)

        XCTAssertNil(viewModel.snapshot.lastUpdated)
        XCTAssertTrue(viewModel.snapshot.items.isEmpty)
        viewModel.stop()
    }

    private func makeViewModel(
        sampler: RecordingDeviceBatterySampler,
        powerObserver: RecordingPowerSourceObserver? = nil,
        bluetoothObserver: RecordingBluetoothConnectionObserver? = nil,
        schedule: DeviceBatterySamplingSchedule? = nil
    ) -> DeviceBatteryViewModel {
        DeviceBatteryViewModel(
            sampler: sampler,
            rapooMonitor: RecordingRapooBatteryMonitor(),
            powerSourceObserver: powerObserver ?? RecordingPowerSourceObserver(),
            bluetoothConnectionObserver: bluetoothObserver ?? RecordingBluetoothConnectionObserver(),
            schedule: schedule ?? DeviceBatterySamplingSchedule(
                internalBatteryFallback: 30,
                bluetoothBackground: 30,
                bluetoothComponentVisible: 30,
                appleMobileBackground: 30,
                appleMobileComponentVisible: 30,
                bluetoothConnectionDebounce: 0.01,
                activityResumeDelay: 0.01
            )
        )
    }

    private func waitForCounts(
        _ expected: DeviceBatterySamplingCounts,
        sampler: RecordingDeviceBatterySampler
    ) async {
        for _ in 0..<100 {
            if await sampler.counts() == expected {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let actual = await sampler.counts()
        XCTFail("Timed out waiting for sampling counts \(expected); got \(actual)")
    }
}

private struct DeviceBatterySamplingCounts: Equatable, Sendable {
    let internalBattery: Int
    let bluetooth: Int
    let appleMobile: Int

    static let zero = DeviceBatterySamplingCounts(
        internalBattery: 0,
        bluetooth: 0,
        appleMobile: 0
    )
    static let oneEach = DeviceBatterySamplingCounts(
        internalBattery: 1,
        bluetooth: 1,
        appleMobile: 1
    )
}

private actor RecordingDeviceBatterySampler: DeviceBatterySampling {
    private var samplingCounts = DeviceBatterySamplingCounts.zero
    private var recordedBluetoothOptions: [DeviceBatteryBluetoothSamplingOptions] = []

    func collectInternalBattery(referenceDate: Date) async -> [DeviceBatteryItem] {
        samplingCounts = DeviceBatterySamplingCounts(
            internalBattery: samplingCounts.internalBattery + 1,
            bluetooth: samplingCounts.bluetooth,
            appleMobile: samplingCounts.appleMobile
        )
        return []
    }

    func collectBluetoothDevices(
        referenceDate: Date,
        options: DeviceBatteryBluetoothSamplingOptions
    ) async -> [DeviceBatteryItem] {
        samplingCounts = DeviceBatterySamplingCounts(
            internalBattery: samplingCounts.internalBattery,
            bluetooth: samplingCounts.bluetooth + 1,
            appleMobile: samplingCounts.appleMobile
        )
        recordedBluetoothOptions.append(options)
        return []
    }

    func collectAppleMobileDevices(
        referenceDate: Date,
        minimumRefreshInterval: TimeInterval
    ) async -> [DeviceBatteryItem] {
        samplingCounts = DeviceBatterySamplingCounts(
            internalBattery: samplingCounts.internalBattery,
            bluetooth: samplingCounts.bluetooth,
            appleMobile: samplingCounts.appleMobile + 1
        )
        return []
    }

    func counts() -> DeviceBatterySamplingCounts {
        samplingCounts
    }

    func bluetoothOptions() -> [DeviceBatteryBluetoothSamplingOptions] {
        recordedBluetoothOptions
    }
}

@MainActor
private final class RecordingPowerSourceObserver: DeviceBatteryPowerSourceObserving {
    var onChange: (() -> Void)?
    private(set) var isStarted = false
    func start() { isStarted = true }
    func stop() { isStarted = false }
    func sendChange() { onChange?() }
}

@MainActor
private final class RecordingBluetoothConnectionObserver:
    DeviceBatteryBluetoothConnectionObserving {
    var onConnectionChange: (() -> Void)?
    private(set) var isStarted = false
    func start() { isStarted = true }
    func stop() { isStarted = false }
    func sendConnectionChange() { onConnectionChange?() }
}

@MainActor
private final class RecordingRapooBatteryMonitor: RapooBatteryMonitoring {
    var snapshot = RapooMouseBatterySnapshot.idle
    var onSnapshotChange: ((RapooMouseBatterySnapshot) -> Void)?
    func start() {}
    func stop() {}
    func refresh() {}
}
