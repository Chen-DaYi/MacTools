import Foundation
import IOBluetooth
import IOKit.ps

@MainActor
protocol DeviceBatteryPowerSourceObserving: AnyObject {
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
final class SystemDeviceBatteryPowerSourceObserver: DeviceBatteryPowerSourceObserving {
    var onChange: (() -> Void)?

    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard runLoopSource == nil else { return }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<SystemDeviceBatteryPowerSourceObserver>
                .fromOpaque(context)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                observer.onChange?()
            }
        }, context)?.takeRetainedValue() else {
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    func stop() {
        guard let runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        self.runLoopSource = nil
    }

    isolated deinit {
        stop()
    }
}

@MainActor
protocol DeviceBatteryBluetoothConnectionObserving: AnyObject {
    var onConnectionChange: (() -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
final class SystemDeviceBatteryBluetoothConnectionObserver:
    DeviceBatteryBluetoothConnectionObserving {
    var onConnectionChange: (() -> Void)?

    private let worker: DeviceBatteryBluetoothConnectionWorker
    private var isStarted = false

    init(
        registrationBackend: any DeviceBatteryBluetoothConnectionRegistering =
            SystemDeviceBatteryBluetoothConnectionRegistrationBackend()
    ) {
        worker = DeviceBatteryBluetoothConnectionWorker(
            registrationBackend: registrationBackend
        )
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        worker.start { [weak self] in
            Task { @MainActor in
                guard let self, self.isStarted else { return }
                self.onConnectionChange?()
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        worker.stop()
    }

    isolated deinit {
        worker.stop()
    }
}

protocol DeviceBatteryBluetoothConnectionRegistering: Sendable {
    func registerForConnect(
        observer: Any,
        selector: Selector
    ) -> IOBluetoothUserNotification?
    func connectedPairedDevices() -> [IOBluetoothDevice]
}

struct SystemDeviceBatteryBluetoothConnectionRegistrationBackend:
    DeviceBatteryBluetoothConnectionRegistering,
    @unchecked Sendable {
    func registerForConnect(
        observer: Any,
        selector: Selector
    ) -> IOBluetoothUserNotification? {
        IOBluetoothDevice.register(
            forConnectNotifications: observer,
            selector: selector
        )
    }

    func connectedPairedDevices() -> [IOBluetoothDevice] {
        let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return pairedDevices.filter { $0.isConnected() }
    }
}

private final class DeviceBatteryBluetoothConnectionWorker: NSObject, @unchecked Sendable {
    typealias Delivery = @Sendable () -> Void

    private struct RequestState {
        var generation: UInt = 0
        var isActive = false
        var delivery: Delivery?
    }

    private let queue = DispatchQueue(
        label: "cc.ggbond.mactools.device-battery.bluetooth-observer",
        qos: .utility
    )
    private let stateLock = NSLock()
    private let registrationBackend: any DeviceBatteryBluetoothConnectionRegistering
    private let disconnectRegistry = DeviceBatteryBluetoothDisconnectRegistry()
    private var requestState = RequestState()
    private var connectionNotification: IOBluetoothUserNotification?

    init(registrationBackend: any DeviceBatteryBluetoothConnectionRegistering) {
        self.registrationBackend = registrationBackend
    }

    func start(delivery: @escaping Delivery) {
        stateLock.lock()
        requestState.delivery = delivery
        guard !requestState.isActive else {
            stateLock.unlock()
            return
        }
        requestState.isActive = true
        requestState.generation &+= 1
        let generation = requestState.generation
        stateLock.unlock()

        queue.async { [self] in
            install(generation: generation)
        }
    }

    func stop() {
        stateLock.lock()
        requestState.delivery = nil
        requestState.isActive = false
        requestState.generation &+= 1
        stateLock.unlock()

        queue.async { [self] in
            uninstall()
        }
    }

    private func install(generation: UInt) {
        guard connectionNotification == nil else { return }
        disconnectRegistry.start()
        let notification = registrationBackend.registerForConnect(
            observer: self,
            selector: #selector(deviceDidConnect(notification:device:))
        )

        guard isCurrent(generation: generation) else {
            notification?.unregister()
            disconnectRegistry.stop()
            return
        }

        connectionNotification = notification
        for device in registrationBackend.connectedPairedDevices() {
            registerForDisconnect(of: device)
        }
    }

    private func uninstall() {
        connectionNotification?.unregister()
        connectionNotification = nil
        disconnectRegistry.stop()
    }

    private func isCurrent(generation: UInt) -> Bool {
        stateLock.lock()
        let isCurrent = requestState.isActive && requestState.generation == generation
        stateLock.unlock()
        return isCurrent
    }

    @objc nonisolated private func deviceDidConnect(
        notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        registerForDisconnect(of: device)
        publishConnectionChange()
    }

    @objc nonisolated private func deviceDidDisconnect(
        notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        disconnectRegistry.remove(device: device)
        publishConnectionChange()
    }

    nonisolated private func registerForDisconnect(of device: IOBluetoothDevice) {
        disconnectRegistry.register(
            device: device,
            observer: self,
            selector: #selector(deviceDidDisconnect(notification:device:))
        )
    }

    nonisolated private func publishConnectionChange() {
        stateLock.lock()
        let delivery = requestState.isActive ? requestState.delivery : nil
        stateLock.unlock()
        delivery?()
    }
}

private final class DeviceBatteryBluetoothDisconnectRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = false
    private var notifications: [ObjectIdentifier: IOBluetoothUserNotification] = [:]

    func start() {
        lock.lock()
        isActive = true
        lock.unlock()
    }

    func register(device: IOBluetoothDevice, observer: Any, selector: Selector) {
        let key = ObjectIdentifier(device)
        lock.lock()
        let shouldRegister = isActive && notifications[key] == nil
        lock.unlock()
        guard shouldRegister,
              let notification = device.register(
                forDisconnectNotification: observer,
                selector: selector
              ) else {
            return
        }

        lock.lock()
        if isActive, notifications[key] == nil {
            notifications[key] = notification
            lock.unlock()
        } else {
            lock.unlock()
            notification.unregister()
        }
    }

    func remove(device: IOBluetoothDevice) {
        lock.lock()
        let notification = notifications.removeValue(forKey: ObjectIdentifier(device))
        lock.unlock()
        notification?.unregister()
    }

    func stop() {
        lock.lock()
        isActive = false
        let registeredNotifications = Array(notifications.values)
        notifications.removeAll()
        lock.unlock()

        registeredNotifications.forEach { $0.unregister() }
    }
}
