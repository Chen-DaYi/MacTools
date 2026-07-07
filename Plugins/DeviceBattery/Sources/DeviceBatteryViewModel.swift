import Combine
import Foundation
import MacToolsPluginKit

@MainActor
final class DeviceBatteryViewModel: ObservableObject {
    @Published private(set) var snapshot: DeviceBatterySnapshot = .idle {
        didSet {
            guard oldValue != snapshot else {
                return
            }
            onSnapshotChange?()
        }
    }

    private let sampler: any DeviceBatterySampling
    private let rapooMonitor: any RapooBatteryMonitoring
    private let localization: PluginLocalization
    private var samplingTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var systemItems: [DeviceBatteryItem] = []
    private var rapooSnapshot = RapooMouseBatterySnapshot.idle
    private var lastSystemUpdate: Date?
    private var isCollecting = false
    private var pendingCollectRequest = false
    private var isStarted = false
    private var includeInternalBattery = true
    private var includeBluetoothDevices = true
    private var includeRapooDevices = true

    var onSnapshotChange: (() -> Void)?

    convenience init() {
        let localization = PluginLocalization(bundle: .main)
        self.init(
            sampler: DeviceBatterySampler(localization: localization),
            rapooMonitor: RapooHIDBatteryMonitor(localization: localization),
            localization: localization
        )
    }

    init(
        sampler: any DeviceBatterySampling,
        rapooMonitor: any RapooBatteryMonitoring,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.sampler = sampler
        self.rapooMonitor = rapooMonitor
        self.localization = localization
        rapooSnapshot = rapooMonitor.snapshot
    }

    func start(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeRapooDevices: Bool
    ) {
        updateOptions(
            includeInternalBattery: includeInternalBattery,
            includeBluetoothDevices: includeBluetoothDevices,
            includeRapooDevices: includeRapooDevices
        )

        if isStarted {
            collectNow()
            return
        }

        isStarted = true
        rapooMonitor.onSnapshotChange = { [weak self] snapshot in
            self?.rapooSnapshot = snapshot
            self?.rebuildSnapshot()
        }

        if includeRapooDevices {
            rapooMonitor.start()
            rapooSnapshot = rapooMonitor.snapshot
        }

        samplingTask = Task { @MainActor [weak self] in
            await self?.runSamplingLoop()
        }
    }

    func stop() {
        samplingTask?.cancel()
        refreshTask?.cancel()
        samplingTask = nil
        refreshTask = nil
        rapooMonitor.stop()
        rapooMonitor.onSnapshotChange = nil
        isStarted = false
    }

    func refresh(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeRapooDevices: Bool
    ) {
        updateOptions(
            includeInternalBattery: includeInternalBattery,
            includeBluetoothDevices: includeBluetoothDevices,
            includeRapooDevices: includeRapooDevices
        )

        if includeRapooDevices {
            rapooMonitor.refresh()
            rapooSnapshot = rapooMonitor.snapshot
        } else {
            rapooMonitor.stop()
            rapooSnapshot = .idle
        }

        collectNow()
    }

    private func updateOptions(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeRapooDevices: Bool
    ) {
        self.includeInternalBattery = includeInternalBattery
        self.includeBluetoothDevices = includeBluetoothDevices
        self.includeRapooDevices = includeRapooDevices
    }

    private func collectNow() {
        if isCollecting {
            pendingCollectRequest = true
            return
        }

        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await self?.collectOnce()
        }
    }

    private func runSamplingLoop() async {
        while !Task.isCancelled {
            await collectOnce()

            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
        }
    }

    private func collectOnce() async {
        if isCollecting {
            pendingCollectRequest = true
            return
        }

        isCollecting = true
        defer {
            isCollecting = false
        }

        repeat {
            pendingCollectRequest = false
            rebuildSnapshot(accessOverride: .scanning)

            let referenceDate = Date()
            let collectedItems = await sampler.collectSystemDevices(referenceDate: referenceDate)
            guard !Task.isCancelled else {
                pendingCollectRequest = false
                return
            }

            systemItems = collectedItems
            lastSystemUpdate = referenceDate
            rebuildSnapshot()
        } while pendingCollectRequest && !Task.isCancelled
    }

    private func rebuildSnapshot(
        accessOverride: DeviceBatteryAccessState? = nil
    ) {
        var items = systemItems.filter { item in
            switch item.kind {
            case .internalBattery:
                return includeInternalBattery
            case .bluetooth, .magicAccessory, .airPodsPart, .other:
                return includeBluetoothDevices
            case .rapooMouse:
                return includeRapooDevices
            }
        }

        if includeRapooDevices, let rapooItem = rapooSnapshot.batteryItem(localization: localization) {
            items.append(rapooItem)
        }

        let accessState = accessOverride ?? resolvedAccessState(items: items)
        snapshot = DeviceBatterySnapshot(
            accessState: accessState,
            items: deduplicated(items),
            lastUpdated: lastSystemUpdate ?? rapooSnapshot.lastUpdated,
            rapooState: includeRapooDevices ? rapooSnapshot.accessState : .idle
        )
    }

    private func resolvedAccessState(items: [DeviceBatteryItem]) -> DeviceBatteryAccessState {
        if rapooSnapshot.accessState == .permissionDenied {
            return items.isEmpty ? .permissionDenied : .ready
        }

        if case let .failed(message) = rapooSnapshot.accessState, items.isEmpty {
            return .failed(message)
        }

        return items.isEmpty ? .noDevices : .ready
    }

    private func deduplicated(_ items: [DeviceBatteryItem]) -> [DeviceBatteryItem] {
        var bestByKey: [String: DeviceBatteryItem] = [:]
        var orderedKeys: [String] = []

        for item in DeviceBatteryItemNormalizer.removingRedundantComponentAggregates(items) {
            let key = "\(item.kind)-\(item.name.lowercased())-\(item.parentName ?? "")"
            if let existing = bestByKey[key] {
                bestByKey[key] = preferredItem(existing, item)
            } else {
                bestByKey[key] = item
                orderedKeys.append(key)
            }
        }

        return orderedKeys.compactMap { bestByKey[$0] }
    }

    private func preferredItem(
        _ left: DeviceBatteryItem,
        _ right: DeviceBatteryItem
    ) -> DeviceBatteryItem {
        if left.chargeState.isActiveChargingState != right.chargeState.isActiveChargingState {
            return left.chargeState.isActiveChargingState ? left : right
        }

        return left.lastUpdated ?? .distantPast >= right.lastUpdated ?? .distantPast ? left : right
    }
}
