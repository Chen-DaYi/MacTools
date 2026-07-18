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
final class SystemDeviceBatteryBluetoothConnectionObserver: NSObject,
    DeviceBatteryBluetoothConnectionObserving {
    var onConnectionChange: (() -> Void)?

    private var connectionNotification: IOBluetoothUserNotification?
    private nonisolated let disconnectRegistry = DeviceBatteryBluetoothDisconnectRegistry()

    func start() {
        guard connectionNotification == nil else { return }
        disconnectRegistry.start()
        connectionNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(notification:device:))
        )

        let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        for device in pairedDevices where device.isConnected() {
            registerForDisconnect(of: device)
        }
    }

    func stop() {
        connectionNotification?.unregister()
        connectionNotification = nil
        disconnectRegistry.stop()
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
        Task { @MainActor [weak self] in
            self?.onConnectionChange?()
        }
    }

    isolated deinit {
        stop()
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
