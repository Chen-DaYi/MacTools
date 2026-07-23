import Combine
import Foundation
import MacToolsPluginKit

struct DeviceBatterySamplingSchedule: Equatable, Sendable {
    let internalBatteryFallback: TimeInterval
    let bluetoothBackground: TimeInterval
    let bluetoothComponentVisible: TimeInterval
    let appleMobileBackground: TimeInterval
    let appleMobileComponentVisible: TimeInterval
    let bluetoothConnectionDebounce: TimeInterval
    let activityResumeDelay: TimeInterval

    static let standard = DeviceBatterySamplingSchedule(
        internalBatteryFallback: 5 * 60,
        bluetoothBackground: 5 * 60,
        bluetoothComponentVisible: 60,
        appleMobileBackground: 5 * 60,
        appleMobileComponentVisible: 90,
        bluetoothConnectionDebounce: 2.5,
        activityResumeDelay: 2
    )
}

@MainActor
final class DeviceBatteryViewModel: ObservableObject {
    @Published private(set) var snapshot: DeviceBatterySnapshot = .idle {
        didSet {
            guard oldValue != snapshot else { return }
            onSnapshotChange?()
        }
    }

    private let sampler: any DeviceBatterySampling
    private let rapooMonitor: any RapooBatteryMonitoring
    private let powerSourceObserver: any DeviceBatteryPowerSourceObserving
    private let bluetoothConnectionObserver: any DeviceBatteryBluetoothConnectionObserving
    private let localization: PluginLocalization
    private let schedule: DeviceBatterySamplingSchedule

    private var internalBatteryTask: Task<Void, Never>?
    private var bluetoothTask: Task<Void, Never>?
    private var appleMobileTask: Task<Void, Never>?
    private var bluetoothEventTask: Task<Void, Never>?
    private var activityResumeTask: Task<Void, Never>?
    private var activeCollectionIDs: Set<UUID> = []

    private var internalBatteryItems: [DeviceBatteryItem] = []
    private var bluetoothItems: [DeviceBatteryItem] = []
    private var appleMobileItems: [DeviceBatteryItem] = []
    private var rapooSnapshot = RapooMouseBatterySnapshot.idle
    private var sourceUpdateDates: [DeviceBatterySource: Date] = [:]
    private var activityState: PluginApplicationActivityState = .interactive
    private var needsBluetoothRefreshOnResume = false
    private var isStarted = false
    private var includeInternalBattery = true
    private var includeBluetoothDevices = true
    private var includeAppleMobileDevices = true
    private var includeRapooDevices = true
    private var isComponentPanelVisible = false
    private var isLowBatteryMonitoringEnabled = false

    var onSnapshotChange: (() -> Void)?

    convenience init() {
        let localization = PluginLocalization(bundle: .main)
        self.init(
            sampler: DeviceBatterySampler(localization: localization),
            rapooMonitor: RapooHIDBatteryMonitor(localization: localization),
            powerSourceObserver: SystemDeviceBatteryPowerSourceObserver(),
            bluetoothConnectionObserver: SystemDeviceBatteryBluetoothConnectionObserver(),
            localization: localization
        )
    }

    init(
        sampler: any DeviceBatterySampling,
        rapooMonitor: any RapooBatteryMonitoring,
        powerSourceObserver: any DeviceBatteryPowerSourceObserving = NullDeviceBatteryPowerSourceObserver(),
        bluetoothConnectionObserver: any DeviceBatteryBluetoothConnectionObserving = NullDeviceBatteryBluetoothConnectionObserver(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        schedule: DeviceBatterySamplingSchedule = .standard
    ) {
        self.sampler = sampler
        self.rapooMonitor = rapooMonitor
        self.powerSourceObserver = powerSourceObserver
        self.bluetoothConnectionObserver = bluetoothConnectionObserver
        self.localization = localization
        self.schedule = schedule
        rapooSnapshot = rapooMonitor.snapshot
    }

    func start(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeAppleMobileDevices: Bool,
        includeRapooDevices: Bool
    ) {
        updateOptions(
            includeInternalBattery: includeInternalBattery,
            includeBluetoothDevices: includeBluetoothDevices,
            includeAppleMobileDevices: includeAppleMobileDevices,
            includeRapooDevices: includeRapooDevices
        )

        guard !isStarted else {
            reconcileSamplingDemand(forceBluetoothProfileRefresh: false)
            return
        }

        isStarted = true
        rapooMonitor.onSnapshotChange = { [weak self] snapshot in
            self?.rapooSnapshot = snapshot
            self?.rebuildSnapshot()
        }
        powerSourceObserver.onChange = { [weak self] in
            self?.handlePowerSourceChange()
        }
        bluetoothConnectionObserver.onConnectionChange = { [weak self] in
            self?.handleBluetoothConnectionChange()
        }
        reconcileSamplingDemand(forceBluetoothProfileRefresh: true)
    }

    func stop() {
        cancelSampling()
        powerSourceObserver.stop()
        bluetoothConnectionObserver.stop()
        powerSourceObserver.onChange = nil
        bluetoothConnectionObserver.onConnectionChange = nil
        rapooMonitor.stop()
        rapooMonitor.onSnapshotChange = nil
        isComponentPanelVisible = false
        isStarted = false
        clearCollectedSnapshots()
    }

    func refresh(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeAppleMobileDevices: Bool,
        includeRapooDevices: Bool
    ) {
        let wasIncludingBluetoothDevices = self.includeBluetoothDevices
        updateOptions(
            includeInternalBattery: includeInternalBattery,
            includeBluetoothDevices: includeBluetoothDevices,
            includeAppleMobileDevices: includeAppleMobileDevices,
            includeRapooDevices: includeRapooDevices
        )
        rebuildSnapshot()

        reconcileSamplingDemand(
            forceBluetoothProfileRefresh: includeBluetoothDevices && !wasIncludingBluetoothDevices
        )
    }

    func setComponentPanelVisible(_ isVisible: Bool) {
        guard isComponentPanelVisible != isVisible else { return }
        let hadSamplingDemand = hasSamplingDemand
        isComponentPanelVisible = isVisible

        reconcileSamplingDemand(
            forceBluetoothProfileRefresh: isVisible && !hadSamplingDemand
        )
    }

    func setLowBatteryMonitoringEnabled(_ isEnabled: Bool) {
        guard isLowBatteryMonitoringEnabled != isEnabled else { return }
        let hadSamplingDemand = hasSamplingDemand
        isLowBatteryMonitoringEnabled = isEnabled
        reconcileSamplingDemand(
            forceBluetoothProfileRefresh: isEnabled && !hadSamplingDemand
        )
    }

    func setApplicationActivityState(_ state: PluginApplicationActivityState) {
        guard activityState != state else { return }
        let previouslyAllowedBackgroundWork = activityState.allowsBackgroundWork
        activityState = state

        guard isStarted else { return }
        guard state.allowsBackgroundWork else {
            needsBluetoothRefreshOnResume = true
            activityResumeTask?.cancel()
            activityResumeTask = nil
            cancelSampling()
            powerSourceObserver.stop()
            bluetoothConnectionObserver.stop()
            rapooMonitor.stop()
            return
        }

        guard !previouslyAllowedBackgroundWork else { return }
        guard hasSamplingDemand else { return }
        activityResumeTask?.cancel()
        activityResumeTask = Task { @MainActor [weak self, schedule] in
            do {
                try await Self.sleep(for: schedule.activityResumeDelay)
            } catch {
                return
            }

            guard let self,
                  self.isStarted,
                  self.activityState.allowsBackgroundWork else {
                return
            }
            self.activityResumeTask = nil
            self.reconcileSamplingDemand(
                forceBluetoothProfileRefresh: self.needsBluetoothRefreshOnResume
            )
            self.needsBluetoothRefreshOnResume = false
        }
    }

    var appleMobileRefreshInterval: TimeInterval {
        isComponentPanelVisible
            ? schedule.appleMobileComponentVisible
            : schedule.appleMobileBackground
    }

    var bluetoothRefreshInterval: TimeInterval {
        isComponentPanelVisible
            ? schedule.bluetoothComponentVisible
            : schedule.bluetoothBackground
    }

    private func updateOptions(
        includeInternalBattery: Bool,
        includeBluetoothDevices: Bool,
        includeAppleMobileDevices: Bool,
        includeRapooDevices: Bool
    ) {
        self.includeInternalBattery = includeInternalBattery
        self.includeBluetoothDevices = includeBluetoothDevices
        self.includeAppleMobileDevices = includeAppleMobileDevices
        self.includeRapooDevices = includeRapooDevices

        if !includeInternalBattery {
            internalBatteryItems.removeAll()
            sourceUpdateDates.removeValue(forKey: .internalBattery)
        }
        if !includeBluetoothDevices {
            bluetoothItems.removeAll()
            sourceUpdateDates.removeValue(forKey: .bluetooth)
        }
        if !includeAppleMobileDevices {
            appleMobileItems.removeAll()
            sourceUpdateDates.removeValue(forKey: .appleMobile)
        }
        if !includeRapooDevices {
            rapooSnapshot = .idle
        }
    }

    private func restartSampling(forceBluetoothProfileRefresh: Bool) {
        guard isStarted,
              activityState.allowsBackgroundWork,
              hasSamplingDemand else {
            return
        }
        restartInternalBatterySampling()
        restartBluetoothSampling(
            forceProfileRefresh: forceBluetoothProfileRefresh,
            performActiveScan: true
        )
        restartAppleMobileSampling()
    }

    private func restartInternalBatterySampling() {
        internalBatteryTask?.cancel()
        internalBatteryTask = nil
        guard includeInternalBattery else { return }

        internalBatteryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runInternalBatteryLoop()
        }
    }

    private func restartBluetoothSampling(
        forceProfileRefresh: Bool,
        performActiveScan: Bool
    ) {
        bluetoothTask?.cancel()
        bluetoothTask = nil
        guard includeBluetoothDevices else { return }

        bluetoothTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runBluetoothLoop(
                forceProfileRefresh: forceProfileRefresh,
                performInitialActiveScan: performActiveScan
            )
        }
    }

    private func restartAppleMobileSampling() {
        appleMobileTask?.cancel()
        appleMobileTask = nil
        guard includeAppleMobileDevices else { return }

        appleMobileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runAppleMobileLoop()
        }
    }

    private func runInternalBatteryLoop() async {
        while !Task.isCancelled {
            await refreshInternalBattery()
            do {
                try await Self.sleep(for: schedule.internalBatteryFallback)
            } catch {
                return
            }
        }
    }

    private func runBluetoothLoop(
        forceProfileRefresh: Bool,
        performInitialActiveScan: Bool
    ) async {
        var shouldForceProfileRefresh = forceProfileRefresh
        var shouldPerformActiveScan = performInitialActiveScan

        while !Task.isCancelled {
            await refreshBluetooth(
                forceProfileRefresh: shouldForceProfileRefresh,
                performActiveScan: shouldPerformActiveScan
            )
            shouldForceProfileRefresh = false
            shouldPerformActiveScan = true

            do {
                try await Self.sleep(for: bluetoothRefreshInterval)
            } catch {
                return
            }
        }
    }

    private func runAppleMobileLoop() async {
        while !Task.isCancelled {
            await refreshAppleMobileDevices()
            do {
                try await Self.sleep(for: appleMobileRefreshInterval)
            } catch {
                return
            }
        }
    }

    private func refreshInternalBattery() async {
        let collectionID = beginCollection()
        defer { endCollection(collectionID) }
        let referenceDate = Date()
        let items = await sampler.collectInternalBattery(referenceDate: referenceDate)
        guard !Task.isCancelled else { return }
        internalBatteryItems = items
        sourceUpdateDates[.internalBattery] = referenceDate
        rebuildSnapshot()
    }

    private func refreshBluetooth(
        forceProfileRefresh: Bool,
        performActiveScan: Bool
    ) async {
        let collectionID = beginCollection()
        defer { endCollection(collectionID) }
        let referenceDate = Date()
        let items = await sampler.collectBluetoothDevices(
            referenceDate: referenceDate,
            options: DeviceBatteryBluetoothSamplingOptions(
                forceProfileRefresh: forceProfileRefresh,
                performActiveScan: performActiveScan
            )
        )
        guard !Task.isCancelled else { return }
        bluetoothItems = items
        sourceUpdateDates[.bluetooth] = referenceDate
        rebuildSnapshot()
    }

    private func refreshAppleMobileDevices() async {
        let collectionID = beginCollection()
        defer { endCollection(collectionID) }
        let referenceDate = Date()
        let items = await sampler.collectAppleMobileDevices(
            referenceDate: referenceDate,
            minimumRefreshInterval: appleMobileRefreshInterval
        )
        guard !Task.isCancelled else { return }
        appleMobileItems = items
        sourceUpdateDates[.appleMobile] = referenceDate
        rebuildSnapshot()
    }

    private func handlePowerSourceChange() {
        guard isStarted, includeInternalBattery else { return }
        guard activityState.allowsBackgroundWork, hasSamplingDemand else { return }
        guard activityResumeTask == nil else { return }
        restartInternalBatterySampling()
    }

    private func handleBluetoothConnectionChange() {
        guard isStarted, includeBluetoothDevices else { return }
        guard activityState.allowsBackgroundWork, hasSamplingDemand else {
            needsBluetoothRefreshOnResume = true
            return
        }
        guard activityResumeTask == nil else {
            needsBluetoothRefreshOnResume = true
            return
        }

        bluetoothEventTask?.cancel()
        bluetoothEventTask = Task { @MainActor [weak self, schedule] in
            do {
                try await Self.sleep(for: schedule.bluetoothConnectionDebounce)
            } catch {
                return
            }

            guard let self,
                  self.isStarted,
                  self.activityState.allowsBackgroundWork,
                  self.hasSamplingDemand else {
                return
            }
            self.bluetoothEventTask = nil
            self.restartBluetoothSampling(
                forceProfileRefresh: true,
                performActiveScan: true
            )
        }
    }

    private func reconcileRapooMonitoring() {
        guard includeRapooDevices,
              activityState.allowsBackgroundWork,
              hasSamplingDemand else {
            rapooMonitor.stop()
            rapooSnapshot = .idle
            rebuildSnapshot()
            return
        }

        rapooMonitor.start()
        rapooSnapshot = rapooMonitor.snapshot
    }

    private var hasSamplingDemand: Bool {
        isComponentPanelVisible || isLowBatteryMonitoringEnabled
    }

    private func reconcileSamplingDemand(forceBluetoothProfileRefresh: Bool) {
        guard isStarted else { return }
        guard activityState.allowsBackgroundWork else {
            cancelSampling()
            powerSourceObserver.stop()
            bluetoothConnectionObserver.stop()
            rapooMonitor.stop()
            rebuildSnapshot()
            return
        }
        guard hasSamplingDemand else {
            cancelSampling()
            powerSourceObserver.stop()
            bluetoothConnectionObserver.stop()
            rapooMonitor.stop()
            clearCollectedSnapshots()
            return
        }

        let shouldForceBluetoothProfileRefresh = forceBluetoothProfileRefresh
            || needsBluetoothRefreshOnResume
        needsBluetoothRefreshOnResume = false
        if includeInternalBattery {
            powerSourceObserver.start()
        } else {
            powerSourceObserver.stop()
        }
        if includeBluetoothDevices {
            bluetoothConnectionObserver.start()
        } else {
            bluetoothConnectionObserver.stop()
        }
        reconcileRapooMonitoring()
        restartSampling(
            forceBluetoothProfileRefresh: shouldForceBluetoothProfileRefresh
        )
    }

    private func cancelSampling() {
        internalBatteryTask?.cancel()
        bluetoothTask?.cancel()
        appleMobileTask?.cancel()
        bluetoothEventTask?.cancel()
        activityResumeTask?.cancel()
        internalBatteryTask = nil
        bluetoothTask = nil
        appleMobileTask = nil
        bluetoothEventTask = nil
        activityResumeTask = nil
        activeCollectionIDs.removeAll()
        rebuildSnapshot()
    }

    private func clearCollectedSnapshots() {
        internalBatteryItems.removeAll()
        bluetoothItems.removeAll()
        appleMobileItems.removeAll()
        rapooSnapshot = .idle
        sourceUpdateDates.removeAll()
        rebuildSnapshot()
    }

    private func beginCollection() -> UUID {
        let id = UUID()
        activeCollectionIDs.insert(id)
        rebuildSnapshot()
        return id
    }

    private func endCollection(_ id: UUID) {
        guard activeCollectionIDs.remove(id) != nil else { return }
        rebuildSnapshot()
    }

    private func rebuildSnapshot() {
        var items = internalBatteryItems + bluetoothItems + appleMobileItems
        items = items.filter { item in
            switch item.kind {
            case .internalBattery:
                return includeInternalBattery
            case .phone, .tablet, .mediaPlayer, .watch, .spatialComputer:
                return includeAppleMobileDevices
            case .bluetooth, .magicAccessory, .airPodsPart, .other:
                return includeBluetoothDevices
            case .rapooMouse:
                return includeRapooDevices
            }
        }

        if includeRapooDevices,
           let rapooItem = rapooSnapshot.batteryItem(localization: localization) {
            items.append(rapooItem)
        }

        let accessState = items.isEmpty && !activeCollectionIDs.isEmpty
            ? DeviceBatteryAccessState.scanning
            : resolvedAccessState(items: items)
        let visibleSourceUpdateDates = [
            includeInternalBattery ? sourceUpdateDates[.internalBattery] : nil,
            includeBluetoothDevices ? sourceUpdateDates[.bluetooth] : nil,
            includeAppleMobileDevices ? sourceUpdateDates[.appleMobile] : nil,
            includeRapooDevices ? rapooSnapshot.lastUpdated : nil
        ].compactMap { $0 }
        snapshot = DeviceBatterySnapshot(
            accessState: accessState,
            items: deduplicated(items),
            lastUpdated: visibleSourceUpdateDates.max(),
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

    private static func sleep(for interval: TimeInterval) async throws {
        let tolerance = min(max(interval * 0.15, 0.1), 30)
        try await Task.sleep(
            for: .seconds(interval),
            tolerance: .seconds(tolerance)
        )
    }
}

private enum DeviceBatterySource: Hashable {
    case internalBattery
    case bluetooth
    case appleMobile
}

@MainActor
private final class NullDeviceBatteryPowerSourceObserver: DeviceBatteryPowerSourceObserving {
    var onChange: (() -> Void)?
    func start() {}
    func stop() {}
}

@MainActor
private final class NullDeviceBatteryBluetoothConnectionObserver:
    DeviceBatteryBluetoothConnectionObserving {
    var onConnectionChange: (() -> Void)?
    func start() {}
    func stop() {}
}
