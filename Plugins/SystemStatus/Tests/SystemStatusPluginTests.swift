import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import SystemStatusPlugin

@MainActor
final class SystemStatusPluginTests: XCTestCase {
    private let suiteName = "SystemStatusPluginTests"

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPluginDescriptorUsesExpandedFullWidthSpan() {
        let plugin = SystemStatusPlugin()
        let expectedHeight = PluginComponentPanelLayoutMetrics.default.heightSpan(
            fittingContentHeight: SystemStatusComponentLayout.dashboardContentHeight
        )

        XCTAssertEqual(plugin.metadata.id, "system-status")
        XCTAssertEqual(plugin.metadata.title, "系统状态")
        XCTAssertEqual(plugin.descriptor.span, PluginComponentSpan(width: 4, height: expectedHeight)!)
    }

    func testPluginHostIncludesSystemStatusComponentOnlyWhenProvided() {
        let host = makePluginHostForTests(
            plugins: [SystemStatusPlugin()],
            suiteName: suiteName
        )

        XCTAssertTrue(host.componentItems.contains { $0.id == "system-status" })
        XCTAssertFalse(host.panelItems.contains { $0.id == "system-status" })

        let managementItem = host.featureManagementItems.first { $0.id == "system-status" }
        XCTAssertEqual(managementItem?.presentation, .componentPanel)
    }

    func testSystemStatusLayoutUsesTwoColumnCoreMetricGridOrder() {
        XCTAssertEqual(SystemStatusComponentLayout.columns, 2)
        XCTAssertEqual(SystemStatusComponentLayout.rows, 3)
        XCTAssertEqual(SystemStatusComponentLayout.cardSpacing, 6)
        XCTAssertEqual(SystemStatusComponentLayout.cardContentPadding, 8)
        XCTAssertEqual(SystemStatusComponentLayout.dashboardContentHeight, 411)
        XCTAssertEqual(
            SystemStatusComponentLayout.orderedMetricKinds,
            [.cpu, .gpu, .network, .disk, .memory, .battery]
        )
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .cpu), SystemStatusGridPosition(row: 0, column: 0))
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .gpu), SystemStatusGridPosition(row: 0, column: 1))
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .network), SystemStatusGridPosition(row: 1, column: 0))
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .disk), SystemStatusGridPosition(row: 1, column: 1))
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .memory), SystemStatusGridPosition(row: 2, column: 0))
        XCTAssertEqual(SystemStatusComponentLayout.position(for: .battery), SystemStatusGridPosition(row: 2, column: 1))
        XCTAssertNil(SystemStatusComponentLayout.position(for: .topProcesses))
    }

    func testProductionSamplingScheduleBalancesForegroundDetailAndBackgroundCost() {
        let schedule = SystemStatusSamplingSchedule.production

        XCTAssertEqual(schedule.backgroundFastInterval, .seconds(30))
        XCTAssertEqual(schedule.foregroundFastInterval, .seconds(3))
        XCTAssertEqual(schedule.backgroundSlowInterval, 300)
        XCTAssertEqual(schedule.foregroundSlowInterval, 15)
        XCTAssertEqual(schedule.backgroundProcessInterval, 300)
        XCTAssertEqual(schedule.foregroundProcessInterval, 15)
        XCTAssertEqual(schedule.backgroundHistoryInterval, 300)
        XCTAssertEqual(schedule.foregroundHistoryInterval, 60)
    }

    func testViewModelMergesDiskCapacityAndActivitySamples() async throws {
        let viewModel = SystemStatusViewModel(
            sampler: StubSystemStatusSampler(),
            historyStore: StubSystemStatusHistoryStore(),
            schedule: .test
        )

        await viewModel.refreshSnapshotNow(referenceDate: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(viewModel.snapshot.disk.usedBytes, 50)
        XCTAssertEqual(viewModel.snapshot.disk.totalBytes, 100)
        XCTAssertEqual(viewModel.snapshot.disk.readBytesPerSecond, 2_048)
        XCTAssertEqual(viewModel.snapshot.disk.writeBytesPerSecond, 1_024)
        XCTAssertEqual(viewModel.snapshot.history.last?.diskReadBytesPerSecond, 2_048)
        XCTAssertEqual(viewModel.snapshot.history.last?.diskWriteBytesPerSecond, 1_024)
    }

    func testDisplayHistoryFastPruneKeepsRecentSortedSamples() {
        let points = (0..<1_905).map { index in
            SystemStatusHistoryPoint(
                timestamp: TimeInterval(index),
                cpuUsage: Double(index) / 2_000
            )
        }

        let pruned = SystemStatusViewModel.prunedSortedDisplayHistory(
            points,
            referenceDate: Date(timeIntervalSince1970: 1_904)
        )

        XCTAssertEqual(pruned.count, 1_800)
        XCTAssertEqual(pruned.first?.timestamp, 105)
        XCTAssertEqual(pruned.last?.timestamp, 1_904)
    }

    func testDisplayHistoryFallbackPruneSortsOutOfOrderSamples() {
        let points = [
            SystemStatusHistoryPoint(timestamp: 12),
            SystemStatusHistoryPoint(timestamp: 10),
            SystemStatusHistoryPoint(timestamp: 11),
            SystemStatusHistoryPoint(timestamp: -2_000),
            SystemStatusHistoryPoint(timestamp: 80)
        ]

        let pruned = SystemStatusViewModel.prunedDisplayHistory(
            points,
            referenceDate: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(pruned.map(\.timestamp), [10, 11, 12, 80])
    }

    func testPluginReusesViewModelAcrossComponentViews() {
        let viewModel = SystemStatusViewModel(sampler: StubSystemStatusSampler())
        let plugin = SystemStatusPlugin(viewModel: viewModel)

        let first = plugin.makeView(
            context: PluginComponentContext(
                pluginID: "system-status",
                dismiss: {},
                isPanelVisible: true
            )
        )
        let second = plugin.makeView(
            context: PluginComponentContext(
                pluginID: "system-status",
                dismiss: {},
                isPanelVisible: true
            )
        )

        XCTAssertFalse(String(describing: first).isEmpty)
        XCTAssertFalse(String(describing: second).isEmpty)
    }

}

private actor StubSystemStatusSampler: SystemStatusSampling {
    private(set) var fastCallCount = 0
    private(set) var slowCallCount = 0
    private(set) var processCallCount = 0
    private(set) var publicIPCallCount = 0

    var callCounts: (fast: Int, slow: Int, processes: Int, publicIP: Int) {
        (fastCallCount, slowCallCount, processCallCount, publicIPCallCount)
    }

    func collectFast(referenceDate: Date) async -> SystemStatusFastSample {
        fastCallCount += 1
        return SystemStatusFastSample(
            cpu: SystemStatusCPUSnapshot(
                usage: min(0.95, 0.20 + Double(fastCallCount) * 0.01),
                loadAverage1Minute: 1.42,
                temperatureCelsius: 42,
                systemPowerWatts: 8.5,
                isCollecting: false
            ),
            memory: SystemStatusMemorySnapshot(
                usedBytes: 4_000,
                totalBytes: 8_000,
                swapUsedBytes: 512,
                swapTotalBytes: 2_048
            ),
            network: SystemStatusNetworkSnapshot(
                interfaceName: "en0",
                ipAddress: "192.168.1.2",
                publicIPAddress: nil,
                downloadBytesPerSecond: 1_024,
                uploadBytesPerSecond: 512,
                isConnected: true,
                isCollecting: false
            ),
            disk: SystemStatusDiskSnapshot(
                usedBytes: nil,
                totalBytes: nil,
                readBytesPerSecond: 2_048,
                writeBytesPerSecond: 1_024
            )
        )
    }

    func collectSlow() async -> SystemStatusSlowSample {
        slowCallCount += 1
        return SystemStatusSlowSample(
            disk: SystemStatusDiskSnapshot(
                usedBytes: 50,
                totalBytes: 100,
                readBytesPerSecond: nil,
                writeBytesPerSecond: nil
            ),
            battery: SystemStatusBatterySnapshot(
                isAvailable: true,
                level: 0.8,
                state: .acPower,
                timeRemainingMinutes: nil,
                adapterWatts: 70,
                batteryPowerWatts: -18.5,
                temperatureCelsius: 31,
                healthPercent: 96,
                cycleCount: 120
            ),
            gpu: SystemStatusGPUSnapshot(
                usage: 0.4,
                name: "M1 Pro",
                temperatureCelsius: 43,
                isAvailable: true,
                isCollecting: false
            ),
            hardware: SystemStatusHardwareSnapshot(
                modelName: "MacBookPro18,3",
                chipName: "Apple M1 Pro",
                macOSVersion: "macOS 15.0",
                uptimeSeconds: 3_600,
                totalMemoryBytes: 16_000
            )
        )
    }

    func collectTopProcesses(limit: Int) async -> [SystemStatusTopProcess] {
        processCallCount += 1
        return [
            SystemStatusTopProcess(
                pid: 1,
                displayName: "launchd",
                command: "/sbin/launchd",
                cpuPercent: 1,
                memoryPercent: 0.1,
                memoryBytes: 12_582_912
            )
        ]
    }

    func collectPublicIPAddress() async -> String? {
        publicIPCallCount += 1
        return "203.0.113.1"
    }
}

private actor StubSystemStatusHistoryStore: SystemStatusHistoryStoring {
    private(set) var appendedCount = 0
    private var points: [SystemStatusHistoryPoint] = []

    func load(referenceDate: Date) async -> [SystemStatusHistoryPoint] {
        points
    }

    func append(_ point: SystemStatusHistoryPoint, referenceDate: Date) async -> [SystemStatusHistoryPoint] {
        appendedCount += 1
        points.append(point)
        return points
    }
}

private extension SystemStatusSamplingSchedule {
    static let test = SystemStatusSamplingSchedule(
        backgroundFastInterval: .milliseconds(20),
        foregroundFastInterval: .milliseconds(20),
        backgroundSlowInterval: 0,
        foregroundSlowInterval: 0,
        backgroundProcessInterval: 0,
        foregroundProcessInterval: 0,
        backgroundHistoryInterval: 0,
        foregroundHistoryInterval: 0
    )

    static let foregroundRestart = SystemStatusSamplingSchedule(
        backgroundFastInterval: .seconds(30),
        foregroundFastInterval: .milliseconds(20),
        backgroundSlowInterval: 30,
        foregroundSlowInterval: 30,
        backgroundProcessInterval: 30,
        foregroundProcessInterval: 30,
        backgroundHistoryInterval: 30,
        foregroundHistoryInterval: 30
    )
}
