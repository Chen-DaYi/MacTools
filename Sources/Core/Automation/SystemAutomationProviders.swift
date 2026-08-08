import AppKit
import EventKit
import Foundation
import IOKit.ps
import Network

struct AutomationPowerSnapshot: Equatable, Sendable {
    let source: AutomationPowerSource
    let batteryLevel: Int?
}

enum SystemAutomationTransitions {
    static func powerEvents(
        previous: AutomationPowerSnapshot,
        current: AutomationPowerSnapshot,
        thresholds: Set<Int>,
        date: Date
    ) -> [AutomationTriggerEvent] {
        var events: [AutomationTriggerEvent] = []
        if previous.source != current.source {
            switch current.source {
            case .adapter:
                events.append(.power(source: .adapter, batteryLevel: current.batteryLevel, event: .adapterConnected, date: date))
            case .battery:
                events.append(.power(source: .battery, batteryLevel: current.batteryLevel, event: .adapterDisconnected, date: date))
            case .unknown:
                break
            }
        }
        if let oldLevel = previous.batteryLevel,
           let newLevel = current.batteryLevel {
            let crossedThresholds = thresholds
                .filter { oldLevel > $0 && newLevel <= $0 }
                .sorted(by: >)
            events += crossedThresholds.map { threshold in
                .power(
                    source: current.source,
                    batteryLevel: threshold,
                    event: .batteryAtOrBelow,
                    date: date
                )
            }
        }
        return events
    }

    static func networkEvents(
        previousStatus: AutomationNetworkStatus,
        previousInterface: AutomationNetworkInterface,
        currentStatus: AutomationNetworkStatus,
        currentInterface: AutomationNetworkInterface,
        date: Date
    ) -> [AutomationTriggerEvent] {
        guard previousStatus != currentStatus || previousInterface != currentInterface else {
            return []
        }
        var events: [AutomationTriggerEvent] = []
        if previousStatus != currentStatus {
            events.append(.network(status: currentStatus, interface: .any, date: date))
        }
        if currentInterface != .any {
            events.append(.network(status: currentStatus, interface: currentInterface, date: date))
        }
        return events
    }

    static func displayEvents(
        previous: [AutomationDisplaySnapshot],
        current: [AutomationDisplaySnapshot],
        date: Date
    ) -> [AutomationTriggerEvent] {
        let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.identifier, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: current.map { ($0.identifier, $0) })
        let connected = current
            .filter { oldByID[$0.identifier] == nil }
            .map { AutomationTriggerEvent.display($0, event: .connected, date: date) }
        let disconnected = previous
            .filter { newByID[$0.identifier] == nil }
            .map { AutomationTriggerEvent.display($0, event: .disconnected, date: date) }
        return connected + disconnected
    }
}

@MainActor
final class SystemAutomationEnvironmentSnapshotProvider: AutomationEnvironmentSnapshotProviding {
    private let workspace: NSWorkspace
    private let networkState: () -> (AutomationNetworkStatus, AutomationNetworkInterface)
    private let now: () -> Date

    init(
        workspace: NSWorkspace = .shared,
        networkState: @escaping () -> (AutomationNetworkStatus, AutomationNetworkInterface),
        now: @escaping () -> Date = Date.init
    ) {
        self.workspace = workspace
        self.networkState = networkState
        self.now = now
    }

    func snapshot(at date: Date) -> AutomationEnvironmentSnapshot {
        let power = SystemPowerAutomationTriggerProvider.readPowerSnapshot()
        let network = networkState()
        return AutomationEnvironmentSnapshot(
            date: date,
            frontmostApplicationBundleIdentifier: workspace.frontmostApplication?.bundleIdentifier,
            batteryLevel: power.batteryLevel,
            powerSource: power.source,
            connectedDisplays: SystemDisplayAutomationTriggerProvider.displaySnapshots(),
            networkStatus: network.0,
            networkInterface: network.1
        )
    }
}

@MainActor
final class SystemScheduleAutomationTriggerProvider: AutomationTriggerProviding {
    let kind: AutomationTriggerKind = .schedule
    var availability: AutomationTriggerAvailability { .available }

    private let calendar: Calendar
    private let now: () -> Date
    private var handler: (@MainActor (AutomationTriggerEvent) -> Void)?
    private var configurations: [ScheduleAutomationTrigger] = []
    private var timer: Timer?

    init(calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
    }

    func start(handler: @escaping @MainActor (AutomationTriggerEvent) -> Void) {
        self.handler = handler
        reschedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
    }

    func refresh(rules: [AutomationRule]) {
        configurations = Array(Set(rules.compactMap {
            guard case let .schedule(value) = $0.trigger else { return nil }
            return value
        }))
        reschedule()
    }

    nonisolated static func nextFireDate(
        for configuration: ScheduleAutomationTrigger,
        after date: Date,
        calendar: Calendar
    ) -> Date? {
        configuration.weekdays.compactMap { weekday in
            calendar.nextDate(
                after: date,
                matching: DateComponents(
                    calendar: calendar,
                    timeZone: calendar.timeZone,
                    hour: configuration.hour,
                    minute: configuration.minute,
                    second: 0,
                    weekday: weekday
                ),
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .forward
            )
        }.min()
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard handler != nil else { return }
        let currentDate = now()
        guard let next = configurations.compactMap({
            Self.nextFireDate(for: $0, after: currentDate, calendar: calendar)
        }).min() else {
            return
        }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.now().timeIntervalSince(next) <= 90 {
                    self.handler?(.schedule(next))
                }
                self.reschedule()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

@MainActor
final class SystemCalendarAutomationTriggerProvider: AutomationTriggerProviding {
    struct ScheduledEvent: Equatable {
        let fireDate: Date
        let identifier: String
        let title: String
        let calendarIdentifier: String?
        let phase: CalendarAutomationPhase
        let offsetMinutes: Int
    }

    struct SchedulePlan: Equatable {
        let nextBatch: [ScheduledEvent]
        let maintenanceDate: Date

        var nextTimerDate: Date {
            guard let eventDate = nextBatch.first?.fireDate else {
                return maintenanceDate
            }
            return min(eventDate, maintenanceDate)
        }

        static func make(
            candidates: [ScheduledEvent],
            after currentDate: Date,
            maintenanceInterval: TimeInterval = 24 * 60 * 60
        ) -> Self {
            let future = candidates
                .filter { $0.fireDate > currentDate }
                .sorted { lhs, rhs in
                    if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
                    return lhs.identifier < rhs.identifier
                }
            let firstDate = future.first?.fireDate
            return Self(
                nextBatch: firstDate.map { date in
                    future.filter { $0.fireDate == date }
                } ?? [],
                maintenanceDate: currentDate.addingTimeInterval(maintenanceInterval)
            )
        }

        func dueEvents(at currentDate: Date, tolerance: TimeInterval = 90) -> [ScheduledEvent] {
            guard let fireDate = nextBatch.first?.fireDate,
                  currentDate >= fireDate,
                  currentDate.timeIntervalSince(fireDate) <= tolerance else {
                return []
            }
            return nextBatch
        }
    }

    let kind: AutomationTriggerKind = .calendar

    var availability: AutomationTriggerAvailability {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .available
        case .notDetermined: .unavailable(FeatureL10n.string("需要日历访问权限。"))
        case .denied, .restricted, .writeOnly: .unavailable(FeatureL10n.string("日历访问权限不可用。"))
        @unknown default: .unavailable(FeatureL10n.string("无法确定日历访问状态。"))
        }
    }

    private let eventStore: EKEventStore
    private let notificationCenter: NotificationCenter
    private let now: () -> Date
    private var handler: (@MainActor (AutomationTriggerEvent) -> Void)?
    private var configurations: [CalendarAutomationTrigger] = []
    private var timer: Timer?
    private var storeObserver: NSObjectProtocol?

    init(
        eventStore: EKEventStore = EKEventStore(),
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.eventStore = eventStore
        self.notificationCenter = notificationCenter
        self.now = now
    }

    func start(handler: @escaping @MainActor (AutomationTriggerEvent) -> Void) {
        self.handler = handler
        if storeObserver == nil {
            storeObserver = notificationCenter.addObserver(
                forName: .EKEventStoreChanged,
                object: eventStore,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reschedule() }
            }
        }
        reschedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let storeObserver {
            notificationCenter.removeObserver(storeObserver)
        }
        storeObserver = nil
        handler = nil
    }

    func refresh(rules: [AutomationRule]) {
        configurations = rules.compactMap {
            guard case let .calendar(value) = $0.trigger else { return nil }
            return value
        }
        reschedule()
    }

    func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            reschedule()
            return granted
        } catch {
            return false
        }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard handler != nil, availability.isAvailable, !configurations.isEmpty else { return }
        let currentDate = now()
        guard let endDate = Calendar.current.date(byAdding: .day, value: 31, to: currentDate) else {
            return
        }
        let queryStartDate = Self.queryStartDate(
            currentDate: currentDate,
            configurations: configurations
        )
        let predicate = eventStore.predicateForEvents(
            withStart: queryStartDate,
            end: endDate,
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
        var scheduled: [ScheduledEvent] = []
        for configuration in configurations {
            for event in events where matches(event, configuration: configuration) {
                guard let eventDate = configuration.phase == .starts ? event.startDate : event.endDate else {
                    continue
                }
                let fireDate = eventDate.addingTimeInterval(TimeInterval(configuration.offsetMinutes * 60))
                guard fireDate > currentDate else { continue }
                let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
                let title = event.title ?? ""
                let calendarIdentifier = event.calendar.calendarIdentifier
                scheduled.append(ScheduledEvent(
                    fireDate: fireDate,
                    identifier: identifier,
                    title: title,
                    calendarIdentifier: calendarIdentifier,
                    phase: configuration.phase,
                    offsetMinutes: configuration.offsetMinutes
                ))
            }
        }
        let plan = SchedulePlan.make(candidates: scheduled, after: currentDate)
        let timer = Timer(
            fire: plan.nextTimerDate,
            interval: 0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for event in plan.dueEvents(at: self.now()) {
                    self.handler?(.calendar(
                        identifier: event.identifier,
                        title: event.title,
                        calendarIdentifier: event.calendarIdentifier,
                        phase: event.phase,
                        offsetMinutes: event.offsetMinutes,
                        date: event.fireDate
                    ))
                }
                self.reschedule()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    nonisolated static func queryStartDate(
        currentDate: Date,
        configurations: [CalendarAutomationTrigger]
    ) -> Date {
        let maximumPositiveOffset = configurations
            .map(\.offsetMinutes)
            .filter { $0 > 0 }
            .max() ?? 0
        return currentDate.addingTimeInterval(TimeInterval(-maximumPositiveOffset * 60))
    }

    private func matches(_ event: EKEvent, configuration: CalendarAutomationTrigger) -> Bool {
        let calendarMatches = normalized(configuration.calendarIdentifier).map {
            $0 == event.calendar.calendarIdentifier
        } ?? true
        let titleMatches = normalized(configuration.titleContains).map {
            (event.title ?? "").localizedCaseInsensitiveContains($0)
        } ?? true
        return calendarMatches && titleMatches
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

@MainActor
final class SystemApplicationAutomationTriggerProvider: AutomationTriggerProviding {
    let kind: AutomationTriggerKind = .application
    var availability: AutomationTriggerAvailability { .available }

    private let notificationCenter: NotificationCenter
    private let now: () -> Date
    private var handler: (@MainActor (AutomationTriggerEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        now: @escaping () -> Date = Date.init
    ) {
        self.notificationCenter = notificationCenter
        self.now = now
    }

    func start(handler: @escaping @MainActor (AutomationTriggerEvent) -> Void) {
        self.handler = handler
        guard observers.isEmpty else { return }
        observe(NSWorkspace.didLaunchApplicationNotification, event: .launches)
        observe(NSWorkspace.didActivateApplicationNotification, event: .activates)
    }

    func stop() {
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
        handler = nil
    }

    private func observe(_ name: Notification.Name, event: ApplicationAutomationEvent) {
        observers.append(
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let bundleIdentifier = (
                    notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                )?.bundleIdentifier
                Task { @MainActor in
                    guard let self, let bundleIdentifier else {
                        return
                    }
                    self.handler?(.application(bundleIdentifier: bundleIdentifier, event: event, date: self.now()))
                }
            }
        )
    }
}

@MainActor
final class SystemPowerAutomationTriggerProvider: AutomationTriggerProviding {
    typealias NotificationSourceFactory = (UnsafeMutableRawPointer) -> CFRunLoopSource?

    let kind: AutomationTriggerKind = .power

    private enum AvailabilityState {
        case available
        case notificationSourceUnavailable
    }

    private let now: () -> Date
    private let notificationSourceFactory: NotificationSourceFactory
    private var availabilityState: AvailabilityState = .available
    private var handler: (@MainActor (AutomationTriggerEvent) -> Void)?
    private var source: CFRunLoopSource?
    private var previous = readPowerSnapshot()
    private var thresholds: Set<Int> = []

    var availability: AutomationTriggerAvailability {
        switch availabilityState {
        case .available:
            .available
        case .notificationSourceUnavailable:
            .unavailable(FeatureL10n.string("无法监听电源状态。"))
        }
    }

    init(
        now: @escaping () -> Date = Date.init,
        notificationSourceFactory: @escaping NotificationSourceFactory = { context in
            IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let provider = Unmanaged<SystemPowerAutomationTriggerProvider>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                Task { @MainActor in provider.powerStateChanged() }
            }, context)?.takeRetainedValue()
        }
    ) {
        self.now = now
        self.notificationSourceFactory = notificationSourceFactory
    }

    func start(handler: @escaping @MainActor (AutomationTriggerEvent) -> Void) {
        self.handler = handler
        previous = Self.readPowerSnapshot()
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = notificationSourceFactory(context) else {
            availabilityState = .notificationSourceUnavailable
            return
        }
        availabilityState = .available
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        source = nil
        handler = nil
    }

    func refresh(rules: [AutomationRule]) {
        thresholds = Set(rules.compactMap {
            guard case let .power(value) = $0.trigger,
                  value.event == .batteryAtOrBelow else { return nil }
            return value.batteryLevel
        })
    }

    static func readPowerSnapshot() -> AutomationPowerSnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return AutomationPowerSnapshot(source: .unknown, batteryLevel: nil)
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let state = description[kIOPSPowerSourceStateKey] as? String
            let current = description[kIOPSCurrentCapacityKey] as? Int
            let maximum = description[kIOPSMaxCapacityKey] as? Int
            let level = current.flatMap { current in
                maximum.flatMap { $0 > 0 ? Int((Double(current) / Double($0) * 100).rounded()) : nil }
            }
            let powerSource: AutomationPowerSource = switch state {
            case kIOPSACPowerValue: .adapter
            case kIOPSBatteryPowerValue: .battery
            default: .unknown
            }
            return AutomationPowerSnapshot(source: powerSource, batteryLevel: level)
        }
        return AutomationPowerSnapshot(source: .unknown, batteryLevel: nil)
    }

    private func powerStateChanged() {
        let current = Self.readPowerSnapshot()
        let events = SystemAutomationTransitions.powerEvents(
            previous: previous,
            current: current,
            thresholds: thresholds,
            date: now()
        )
        previous = current
        events.forEach { handler?($0) }
    }
}

@MainActor
final class SystemDisplayAutomationTriggerProvider: AutomationTriggerProviding {
    let kind: AutomationTriggerKind = .display
    var availability: AutomationTriggerAvailability { .available }

    private let notificationCenter: NotificationCenter
    private let now: () -> Date
    private var handler: (@MainActor (AutomationTriggerEvent) -> Void)?
    private var observer: NSObjectProtocol?
    private var previous = displaySnapshots()

    init(notificationCenter: NotificationCenter = .default, now: @escaping () -> Date = Date.init) {
        self.notificationCenter = notificationCenter
        self.now = now
    }

    func start(handler: @escaping @MainActor (AutomationTriggerEvent) -> Void) {
        self.handler = handler
        previous = Self.displaySnapshots()
        guard observer == nil else { return }
        observer = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
    }

    func stop() {
        if let observer { notificationCenter.removeObserver(observer) }
        observer = nil
        handler = nil
    }

    static func displaySnapshots() -> [AutomationDisplaySnapshot] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return AutomationDisplaySnapshot(
                identifier: String(number.uint32Value),
                name: screen.localizedName
            )
        }
        .sorted { $0.identifier < $1.identifier }
    }

    private func screensChanged() {
        let current = Self.displaySnapshots()
        let events = SystemAutomationTransitions.displayEvents(
            previous: previous,
            current: current,
            date: now()
        )
        previous = current
        events.forEach { handler?($0) }
    }
}

@MainActor
final class SystemNetworkAutomationTriggerProvider: AutomationTriggerProviding {
    let kind: AutomationTriggerKind = .network
    var availability: AutomationTriggerAvailability { .available }
    private(set) var currentStatus: AutomationNetworkStatus = .unavailable
    private(set) var currentInterface: AutomationNetworkInterface = .any

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let now: () -> Date
    private var handler: (@MainActor (AutomationTriggerEvent) -> Void)?
    private var hasReceivedInitialPath = false
    private var isRunning = false

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        queue: DispatchQueue = DispatchQueue(label: "com.mactools.automation.network"),
        now: @escaping () -> Date = Date.init
    ) {
        self.monitor = monitor
        self.queue = queue
        self.now = now
    }

    func start(handler: @escaping @MainActor (AutomationTriggerEvent) -> Void) {
        self.handler = handler
        guard !isRunning else { return }
        isRunning = true
        monitor.pathUpdateHandler = { [weak self] path in
            let state = Self.state(for: path)
            Task { @MainActor in self?.pathChanged(status: state.0, interface: state.1) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isRunning else { return }
        monitor.cancel()
        monitor.pathUpdateHandler = nil
        isRunning = false
        handler = nil
    }

    nonisolated static func state(for path: NWPath) -> (AutomationNetworkStatus, AutomationNetworkInterface) {
        let status: AutomationNetworkStatus = path.status == .satisfied ? .available : .unavailable
        let interface: AutomationNetworkInterface
        if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wiredEthernet
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.availableInterfaces.isEmpty {
            interface = .any
        } else {
            interface = .other
        }
        return (status, interface)
    }

    private func pathChanged(status: AutomationNetworkStatus, interface: AutomationNetworkInterface) {
        let events = SystemAutomationTransitions.networkEvents(
            previousStatus: currentStatus,
            previousInterface: currentInterface,
            currentStatus: status,
            currentInterface: interface,
            date: now()
        )
        currentStatus = status
        currentInterface = interface
        guard hasReceivedInitialPath else {
            hasReceivedInitialPath = true
            return
        }
        events.forEach { handler?($0) }
    }
}

@MainActor
struct SystemAutomationServices {
    let providers: [any AutomationTriggerProviding]
    let snapshotProvider: SystemAutomationEnvironmentSnapshotProvider
    let calendarProvider: SystemCalendarAutomationTriggerProvider

    static func make() -> Self {
        let calendar = SystemCalendarAutomationTriggerProvider()
        let network = SystemNetworkAutomationTriggerProvider()
        let providers: [any AutomationTriggerProviding] = [
            SystemScheduleAutomationTriggerProvider(),
            calendar,
            SystemApplicationAutomationTriggerProvider(),
            SystemPowerAutomationTriggerProvider(),
            SystemDisplayAutomationTriggerProvider(),
            network,
        ]
        let snapshot = SystemAutomationEnvironmentSnapshotProvider {
            (network.currentStatus, network.currentInterface)
        }
        return Self(providers: providers, snapshotProvider: snapshot, calendarProvider: calendar)
    }
}
