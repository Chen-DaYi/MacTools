import AppKit
import CoreAudio
import Darwin
import Foundation

@MainActor
final class CoreAudioApplicationMonitor: AudioApplicationMonitoring {
    var onUpdate: ((AudioApplicationSnapshot) -> Void)?

    private let scanLoop = AudioApplicationScanLoop()
    private var lastSnapshot = AudioApplicationSnapshot.empty
    private var isRunning = false

    func start() {
        isRunning = true
        scanLoop.start { [weak self] snapshot in
            Task { @MainActor in
                self?.publish(snapshot)
            }
        }
    }

    func refresh() {
        scanLoop.refresh { [weak self] snapshot in
            Task { @MainActor in
                self?.publish(snapshot)
            }
        }
    }

    func stop() {
        isRunning = false
        scanLoop.stop()
        lastSnapshot = .empty
    }

    private func publish(_ snapshot: AudioApplicationSnapshot) {
        guard isRunning, snapshot != lastSnapshot else {
            return
        }

        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }
}

private final class AudioApplicationScanLoop: @unchecked Sendable {
    typealias Delivery = @Sendable (AudioApplicationSnapshot) -> Void

    private let queue = DispatchQueue(
        label: "cc.ggbond.mactools.app-volume.scan",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?

    func start(delivery: @escaping Delivery) {
        queue.async { [weak self] in
            guard let self, timer == nil else {
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(150))
            timer.setEventHandler {
                delivery(CoreAudioApplicationQuery.snapshot())
            }
            self.timer = timer
            timer.resume()
        }
    }

    func refresh(delivery: @escaping Delivery) {
        queue.async {
            delivery(CoreAudioApplicationQuery.snapshot())
        }
    }

    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }
}

private enum CoreAudioApplicationQuery {
    private struct Group {
        var displayName: String
        var bundleIdentifier: String?
        var processObjectIDs: [AudioObjectID]
    }

    static func snapshot() -> AudioApplicationSnapshot {
        let processIDs = objectIDArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList
        )
        var groups: [String: Group] = [:]

        for processObjectID in processIDs {
            guard boolProperty(
                objectID: processObjectID,
                selector: kAudioProcessPropertyIsRunningOutput
            ), let pid = pidProperty(objectID: processObjectID), pid != getpid() else {
                continue
            }

            let audioBundleIdentifier = stringProperty(
                objectID: processObjectID,
                selector: kAudioProcessPropertyBundleID
            )
            let runningApplication = responsibleApplication(
                processID: pid,
                audioBundleIdentifier: audioBundleIdentifier
            )
            let bundleIdentifier = runningApplication?.bundleIdentifier ?? audioBundleIdentifier
            let stableID = bundleIdentifier ?? "pid.\(pid)"
            let displayName = runningApplication?.localizedName
                ?? bundleIdentifier?.split(separator: ".").last.map(String.init)
                ?? "PID \(pid)"

            if var group = groups[stableID] {
                group.processObjectIDs.append(processObjectID)
                groups[stableID] = group
            } else {
                groups[stableID] = Group(
                    displayName: displayName,
                    bundleIdentifier: bundleIdentifier,
                    processObjectIDs: [processObjectID]
                )
            }
        }

        let applications = groups.map { id, group in
            AudioApplication(
                id: id,
                displayName: group.displayName,
                bundleIdentifier: group.bundleIdentifier,
                processObjectIDs: group.processObjectIDs.sorted()
            )
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        return AudioApplicationSnapshot(
            applications: applications,
            outputDeviceUID: defaultOutputDeviceUID()
        )
    }

    private static func defaultOutputDeviceUID() -> String? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return stringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func objectIDArray(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var address = propertyAddress(selector: selector)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioObjectID>.size else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var values = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard status == noErr else {
            return []
        }

        return values.filter { $0 != kAudioObjectUnknown }
    }

    private static func pidProperty(objectID: AudioObjectID) -> pid_t? {
        var pid = pid_t(0)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        var address = propertyAddress(selector: kAudioProcessPropertyPID)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &pid
        )
        return status == noErr && pid > 0 ? pid : nil
    }

    private static func boolProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var address = propertyAddress(selector: selector)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        return status == noErr && value != 0
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var address = propertyAddress(selector: selector)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else {
            return nil
        }

        return value as String?
    }

    private static func responsibleApplication(
        processID: pid_t,
        audioBundleIdentifier: String?
    ) -> NSRunningApplication? {
        var visited: Set<pid_t> = []
        var candidateProcessID = processID

        while candidateProcessID > 0, visited.insert(candidateProcessID).inserted {
            if let application = NSRunningApplication(processIdentifier: candidateProcessID),
               application.activationPolicy == .regular {
                return application
            }

            guard let parentProcessID = parentProcessID(processID: candidateProcessID),
                  parentProcessID != candidateProcessID else {
                break
            }
            candidateProcessID = parentProcessID
        }

        guard let audioBundleIdentifier else {
            return nil
        }

        return NSWorkspace.shared.runningApplications.first { application in
            guard application.activationPolicy == .regular,
                  let bundleIdentifier = application.bundleIdentifier else {
                return false
            }

            return audioBundleIdentifier == bundleIdentifier
                || audioBundleIdentifier.hasPrefix(bundleIdentifier + ".")
        }
    }

    private static func parentProcessID(processID: pid_t) -> pid_t? {
        var processInfo = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.stride
        let result = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &processInfo,
            Int32(infoSize)
        )
        guard result == Int32(infoSize), processInfo.pbi_ppid > 0 else {
            return nil
        }

        return pid_t(processInfo.pbi_ppid)
    }

    private static func propertyAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
