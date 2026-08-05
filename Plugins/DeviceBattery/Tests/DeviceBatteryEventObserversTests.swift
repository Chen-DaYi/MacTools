import IOBluetooth
import XCTest
@testable import DeviceBatteryPlugin

@MainActor
final class DeviceBatteryEventObserversTests: XCTestCase {
    func testBluetoothObserverStartAndStopDoNotBlockMainActorDuringRegistration() async {
        let backend = BlockingBluetoothConnectionRegistrationBackend()
        let observer = SystemDeviceBatteryBluetoothConnectionObserver(
            registrationBackend: backend
        )

        observer.start()
        await fulfillment(of: [backend.registrationStarted], timeout: 1)

        XCTAssertFalse(backend.registrationRanOnMainThread)
        observer.stop()
        backend.allowRegistrationToFinish.signal()

        await fulfillment(of: [backend.registrationFinished], timeout: 1)
    }
}

private final class BlockingBluetoothConnectionRegistrationBackend:
    DeviceBatteryBluetoothConnectionRegistering,
    @unchecked Sendable {
    let registrationStarted = XCTestExpectation(description: "Bluetooth registration started")
    let registrationFinished = XCTestExpectation(description: "Bluetooth registration finished")
    let allowRegistrationToFinish = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var didRunOnMainThread = false

    var registrationRanOnMainThread: Bool {
        lock.lock()
        let value = didRunOnMainThread
        lock.unlock()
        return value
    }

    func registerForConnect(
        observer: Any,
        selector: Selector
    ) -> IOBluetoothUserNotification? {
        lock.lock()
        didRunOnMainThread = Thread.isMainThread
        lock.unlock()
        registrationStarted.fulfill()
        allowRegistrationToFinish.wait()
        registrationFinished.fulfill()
        return nil
    }

    func connectedPairedDevices() -> [IOBluetoothDevice] {
        []
    }
}
