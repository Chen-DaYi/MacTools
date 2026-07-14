import Darwin
import Foundation
import ObjectiveC.runtime
import OSLog

@MainActor
protocol SidecarServicing: AnyObject {
    var availability: SidecarServiceAvailability { get }
    var isMinimumTestedSystem: Bool { get }
    var onDevicesChanged: (() -> Void)? { get set }

    func reachableDevices() -> [SidecarDevice]
    func connect(
        to device: SidecarDevice,
        wiredOnly: Bool,
        completion: @escaping (Result<Void, SidecarServiceError>) -> Void
    )
    func disconnect(
        from device: SidecarDevice,
        completion: @escaping (Result<Void, SidecarServiceError>) -> Void
    )
}

/// A runtime-only bridge to SidecarCore. The plugin never links SidecarCore at build time.
@MainActor
final class SidecarCoreService: NSObject, SidecarServicing {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore"
    private static let devicesChangedNotification = Notification.Name("SidecarDevicesChangedNotification")
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SidecarCoreService"
    )

    // Private SidecarCore transport value mirrored from the local sidecarctl implementation that
    // was verified against this SidecarCore runtime. Keep this behind the explicit wired-only
    // action so automatic transport selection is never requested for a wired-only connection.
    private static let wiredTransportRawValue: Int64 = 2

    private typealias IntegerSetter = @convention(c) (AnyObject, Selector, Int64) -> Void
    private typealias IntegerGetter = @convention(c) (AnyObject, Selector) -> Int64
    private typealias OperationCompletion = @convention(block) (NSError?) -> Void
    private typealias WiredDeviceOperation = @convention(c) (
        AnyObject,
        Selector,
        AnyObject,
        AnyObject,
        OperationCompletion
    ) -> Void

    private let manager: NSObject?
    let availability: SidecarServiceAvailability
    let isMinimumTestedSystem: Bool
    var onDevicesChanged: (() -> Void)?

    private let canReadConnectedDevices: Bool
    private var deviceReferences: [String: NSObject] = [:]
    nonisolated(unsafe) private var devicesChangedObserver: NSObjectProtocol?

    init(processInfo: ProcessInfo = .processInfo) {
        let version = processInfo.operatingSystemVersion
        isMinimumTestedSystem = Self.isMinimumTested(version)

        guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil else {
            manager = nil
            canReadConnectedDevices = false
            availability = .unsupported(.frameworkLoadFailed)
            super.init()
            return
        }

        guard let managerType = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else {
            manager = nil
            canReadConnectedDevices = false
            availability = .unsupported(.missingManager)
            super.init()
            return
        }

        guard
            let deviceType = NSClassFromString("SidecarDevice") as? NSObject.Type,
            let configType = NSClassFromString("SidecarDisplayConfig") as? NSObject.Type
        else {
            manager = nil
            canReadConnectedDevices = false
            availability = .unsupported(.missingTypes)
            super.init()
            return
        }

        let sharedManager = NSSelectorFromString("sharedManager")
        guard
            managerType.responds(to: sharedManager),
            let shared = managerType.perform(sharedManager)?.takeUnretainedValue() as? NSObject
        else {
            manager = nil
            canReadConnectedDevices = false
            availability = .unsupported(.managerInitializationFailed)
            super.init()
            return
        }

        let requiredSelectors = [
            NSSelectorFromString("devices"),
            NSSelectorFromString("connectToDevice:completion:"),
            NSSelectorFromString("connectToDevice:withConfig:completion:"),
            NSSelectorFromString("disconnectFromDevice:completion:")
        ]
        let requiredDeviceSelectors = [
            NSSelectorFromString("identifier"),
            NSSelectorFromString("name")
        ]
        guard
            requiredSelectors.allSatisfy(shared.responds(to:)),
            requiredDeviceSelectors.allSatisfy(deviceType.instancesRespond(to:)),
            configType.instancesRespond(to: NSSelectorFromString("setTransport:"))
        else {
            manager = nil
            canReadConnectedDevices = false
            availability = .unsupported(.missingInterfaces)
            super.init()
            return
        }

        manager = shared
        canReadConnectedDevices = shared.responds(to: NSSelectorFromString("connectedDevices"))
        availability = .available
        super.init()

        if !isMinimumTestedSystem {
            Self.logger.warning("SidecarCore is running on an untested macOS version")
        }

        // Best-effort private notification. Operations also trigger explicit refreshes so the UI
        // does not depend on this guessed notification firing on every macOS release.
        devicesChangedObserver = NotificationCenter.default.addObserver(
            forName: Self.devicesChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onDevicesChanged?()
            }
        }
    }

    deinit {
        if let devicesChangedObserver {
            NotificationCenter.default.removeObserver(devicesChangedObserver)
        }
    }

    func reachableDevices() -> [SidecarDevice] {
        guard let manager, case .available = availability else { return [] }

        let reachableObjects = objectValue(from: manager, selectorName: "devices") as? [NSObject] ?? []
        let connectedObjects = canReadConnectedDevices
            ? (objectValue(from: manager, selectorName: "connectedDevices") as? [NSObject] ?? [])
            : []
        let connectedIDs = Set(connectedObjects.compactMap(identifierValue(from:)))
        var references: [String: NSObject] = [:]
        var devicesByID: [String: SidecarDevice] = [:]

        for device in reachableObjects + connectedObjects {
            guard let identifier = identifierValue(from: device) else {
                continue
            }

            let name = stringValue(from: device, selectorName: "name")
            let displayName = name?.isEmpty == false ? name! : "Sidecar Display"
            references[identifier] = device
            devicesByID[identifier] = SidecarDevice(
                id: identifier,
                name: displayName,
                connectionState: connectionState(for: identifier, connectedIDs: connectedIDs)
            )
        }

        deviceReferences = references
        return devicesByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func connect(
        to device: SidecarDevice,
        wiredOnly: Bool,
        completion: @escaping (Result<Void, SidecarServiceError>) -> Void
    ) {
        guard let manager, case .available = availability else {
            completion(.failure(unsupportedError))
            return
        }
        guard let reference = deviceReferences[device.id] else {
            completion(.failure(.deviceUnavailable))
            return
        }

        if wiredOnly {
            connectWired(manager: manager, device: reference, completion: completion)
        } else {
            invoke(
                manager: manager,
                selectorName: "connectToDevice:completion:",
                device: reference,
                completion: completion
            )
        }
    }

    func disconnect(
        from device: SidecarDevice,
        completion: @escaping (Result<Void, SidecarServiceError>) -> Void
    ) {
        guard let manager, case .available = availability else {
            completion(.failure(unsupportedError))
            return
        }
        guard let reference = deviceReferences[device.id] else {
            completion(.failure(.deviceUnavailable))
            return
        }

        invoke(
            manager: manager,
            selectorName: "disconnectFromDevice:completion:",
            device: reference,
            completion: completion
        )
    }

    private var unsupportedError: SidecarServiceError {
        switch availability {
        case .available:
            .operationUnavailable
        case let .unsupported(reason):
            .unsupported(reason)
        }
    }

    private func connectionState(
        for identifier: String,
        connectedIDs: Set<String>
    ) -> SidecarConnectionState {
        guard canReadConnectedDevices else {
            return .unknown
        }

        return connectedIDs.contains(identifier) ? .connected : .disconnected
    }

    private func connectWired(
        manager: NSObject,
        device: NSObject,
        completion: @escaping (Result<Void, SidecarServiceError>) -> Void
    ) {
        guard
            let configType = NSClassFromString("SidecarDisplayConfig") as? NSObject.Type,
            let config = Optional(configType.init()),
            config.responds(to: NSSelectorFromString("setTransport:"))
        else {
            completion(.failure(.operationUnavailable))
            return
        }

        let transportSelector = NSSelectorFromString("setTransport:")
        guard let transportIMP = config.method(for: transportSelector) else {
            completion(.failure(.operationUnavailable))
            return
        }
        let setTransport = unsafeBitCast(transportIMP, to: IntegerSetter.self)
        setTransport(config, transportSelector, Self.wiredTransportRawValue)
        if let configuredTransport = integerValue(from: config, selectorName: "transport") {
            guard configuredTransport == Self.wiredTransportRawValue else {
                Self.logger.error(
                    "Sidecar wired transport verification failed requested=\(Self.wiredTransportRawValue, privacy: .public) readBack=\(configuredTransport, privacy: .public)"
                )
                completion(.failure(.operationUnavailable))
                return
            }
            Self.logger.info(
                "Sidecar wired transport configured value=\(configuredTransport, privacy: .public)"
            )
        } else {
            Self.logger.warning("Sidecar wired transport getter is unavailable; requested value=\(Self.wiredTransportRawValue, privacy: .public)")
        }

        let selector = NSSelectorFromString("connectToDevice:withConfig:completion:")
        guard let operationIMP = manager.method(for: selector) else {
            completion(.failure(.operationUnavailable))
            return
        }
        let operation = unsafeBitCast(operationIMP, to: WiredDeviceOperation.self)
        operation(manager, selector, device, config, completionBlock(completion))
    }

    private func invoke(
        manager: NSObject,
        selectorName: String,
        device: NSObject,
        completion: @escaping (Result<Void, SidecarServiceError>) -> Void
    ) {
        let selector = NSSelectorFromString(selectorName)
        guard manager.responds(to: selector) else {
            completion(.failure(.operationUnavailable))
            return
        }
        _ = manager.perform(selector, with: device, with: completionBlock(completion))
    }

    private func completionBlock(
        _ completion: @escaping (Result<Void, SidecarServiceError>) -> Void
    ) -> OperationCompletion {
        { error in
            let result: Result<Void, SidecarServiceError>
            if let error {
                result = .failure(.system(error.localizedDescription))
            } else {
                result = .success(())
            }
            Task { @MainActor in
                completion(result)
            }
        }
    }

    private func objectValue(from object: NSObject, selectorName: String) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        return object.responds(to: selector)
            ? object.perform(selector)?.takeUnretainedValue()
            : nil
    }

    private func integerValue(from object: NSObject, selectorName: String) -> Int64? {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector), let getterIMP = object.method(for: selector) else {
            return nil
        }
        let getter = unsafeBitCast(getterIMP, to: IntegerGetter.self)
        return getter(object, selector)
    }

    private func stringValue(from object: NSObject, selectorName: String) -> String? {
        objectValue(from: object, selectorName: selectorName) as? String
    }

    private func identifierValue(from object: NSObject) -> String? {
        Self.identifierString(from: objectValue(from: object, selectorName: "identifier"))
    }

    /// SidecarCore currently exposes `identifier` as an NSUUID, while some macOS releases may
    /// bridge it as an NSString. Do not stringify arbitrary Objective-C objects: an unstable
    /// description would break reference lookup for connect and disconnect actions.
    static func identifierString(from value: AnyObject?) -> String? {
        if let uuid = value as? UUID {
            return uuid.uuidString
        }
        if let string = value as? String, !string.isEmpty {
            return string
        }
        return nil
    }

    static func isMinimumTested(_ version: OperatingSystemVersion) -> Bool {
        version.majorVersion > 14 || (version.majorVersion == 14 && version.minorVersion >= 2)
    }

}
