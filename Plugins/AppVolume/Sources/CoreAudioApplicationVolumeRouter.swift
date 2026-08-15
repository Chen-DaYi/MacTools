import CoreAudio
import Foundation
import OSLog
import Synchronization

@MainActor
final class CoreAudioApplicationVolumeRouter: ApplicationVolumeRouting {
    let isSupported: Bool

    private let worker: any ApplicationVolumeRouteWorking

    init() {
        if #available(macOS 15.0, *) {
            isSupported = true
            worker = ApplicationVolumeRouteWorker()
        } else {
            isSupported = false
            worker = UnsupportedApplicationVolumeRouteWorker()
        }
    }

    func update(targets: [ApplicationVolumeTarget], outputDeviceUID: String?) {
        worker.update(targets: targets, outputDeviceUID: outputDeviceUID)
    }

    func applyAndWait(
        targets: [ApplicationVolumeTarget],
        outputDeviceUID: String?
    ) async -> ApplicationVolumeRouteResult {
        await worker.applyAndWait(targets: targets, outputDeviceUID: outputDeviceUID)
    }

    func requestSystemAudioAccess() async -> Bool {
        await worker.requestSystemAudioAccess()
    }

    func stop() {
        worker.stop()
    }
}

private protocol ApplicationVolumeRouteWorking: Sendable {
    func update(targets: [ApplicationVolumeTarget], outputDeviceUID: String?)
    func applyAndWait(
        targets: [ApplicationVolumeTarget],
        outputDeviceUID: String?
    ) async -> ApplicationVolumeRouteResult
    func requestSystemAudioAccess() async -> Bool
    func stop()
}

private final class UnsupportedApplicationVolumeRouteWorker: ApplicationVolumeRouteWorking {
    func update(targets: [ApplicationVolumeTarget], outputDeviceUID: String?) {}
    func applyAndWait(
        targets: [ApplicationVolumeTarget],
        outputDeviceUID: String?
    ) async -> ApplicationVolumeRouteResult { .failed }
    func requestSystemAudioAccess() async -> Bool { false }
    func stop() {}
}

@available(macOS 15.0, *)
protocol ApplicationVolumeRouteSession: AnyObject {
    var processObjectIDs: [AudioObjectID] { get }
    var outputDeviceUID: String { get }
    var isStopped: Bool { get }

    func setGain(_ gain: Float)
    func stop() -> Bool
}

@available(macOS 15.0, *)
final class ApplicationVolumeRouteWorker: ApplicationVolumeRouteWorking, @unchecked Sendable {
    typealias SessionFactory = (
        _ processObjectIDs: [AudioObjectID],
        _ outputDeviceUID: String,
        _ initialGain: Float
    ) -> (any ApplicationVolumeRouteSession)?

    private enum SessionPhase {
        case active
        case retiring
    }

    private struct SessionEntry {
        let session: any ApplicationVolumeRouteSession
        var phase: SessionPhase
    }

    private let queue = DispatchQueue(
        label: "cc.ggbond.mactools.app-volume.route",
        qos: .userInitiated
    )
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "AppVolumeRouter"
    )
    private let makeSession: SessionFactory
    private let uptime: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let stopTimeout: TimeInterval
    private let stopRetryInterval: TimeInterval
    private let fadeDelay: TimeInterval
    private var sessions: [String: SessionEntry] = [:]

    init(
        makeSession: @escaping SessionFactory = { processObjectIDs, outputDeviceUID, gain in
            AudioRouteGainSession(
                processObjectIDs: processObjectIDs,
                outputDeviceUID: outputDeviceUID,
                initialGain: gain
            )
        },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        stopTimeout: TimeInterval = 0.6,
        stopRetryInterval: TimeInterval = 0.02,
        fadeDelay: TimeInterval = 0.015
    ) {
        self.makeSession = makeSession
        self.uptime = uptime
        self.sleep = sleep
        self.stopTimeout = stopTimeout
        self.stopRetryInterval = stopRetryInterval
        self.fadeDelay = fadeDelay
    }

    func update(targets: [ApplicationVolumeTarget], outputDeviceUID: String?) {
        queue.async { [weak self] in
            _ = self?.apply(targets: targets, outputDeviceUID: outputDeviceUID)
        }
    }

    func applyAndWait(
        targets: [ApplicationVolumeTarget],
        outputDeviceUID: String?
    ) async -> ApplicationVolumeRouteResult {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(
                    returning: self?.apply(
                        targets: targets,
                        outputDeviceUID: outputDeviceUID
                    ) ?? .failed
                )
            }
        }
    }

    func requestSystemAudioAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.probeSystemAudioAccess())
            }
        }
    }

    func stop() {
        queue.sync {
            _ = stopAllSessions()
        }
    }

    private func apply(
        targets: [ApplicationVolumeTarget],
        outputDeviceUID: String?
    ) -> ApplicationVolumeRouteResult {
        guard retryRetiringSessions() else {
            return .failed
        }
        let requiresRoutes = targets.contains {
            !$0.processObjectIDs.isEmpty && !Self.isUnity($0.gain)
        }
        guard let outputDeviceUID else {
            let stopped = stopAllSessions()
            return requiresRoutes || !stopped ? .failed : .succeeded
        }

        let desiredTargets = Dictionary(
            uniqueKeysWithValues: targets
                .filter { !$0.processObjectIDs.isEmpty && !Self.isUnity($0.gain) }
                .map { ($0.id, $0) }
        )

        for id in Array(sessions.keys) where desiredTargets[id] == nil {
            guard retireSession(id: id) else { return .failed }
        }

        for (id, target) in desiredTargets {
            let gain = Float(max(0, min(1, target.gain)))

            if let entry = sessions[id],
               entry.phase == .active,
               entry.session.processObjectIDs == target.processObjectIDs,
               entry.session.outputDeviceUID == outputDeviceUID {
                entry.session.setGain(gain)
                continue
            }

            guard retireSession(id: id) else { return .failed }
            guard let session = makeSession(
                target.processObjectIDs,
                outputDeviceUID,
                gain
            ) else {
                logger.error("Unable to create an app audio route for \(id, privacy: .public)")
                return .failed
            }

            sessions[id] = SessionEntry(session: session, phase: .active)
        }
        return .succeeded
    }

    private func retryRetiringSessions() -> Bool {
        for id in Array(sessions.keys) where sessions[id]?.phase == .retiring {
            guard finishRetiringSession(id: id) else { return false }
        }
        return true
    }

    private func retireSession(id: String) -> Bool {
        guard var entry = sessions[id] else { return true }
        if entry.phase == .active {
            entry.phase = .retiring
            sessions[id] = entry
            entry.session.setGain(1)
            if fadeDelay > 0 { sleep(fadeDelay) }
        }
        return finishRetiringSession(id: id)
    }

    private func finishRetiringSession(id: String) -> Bool {
        guard let entry = sessions[id] else { return true }
        guard stop(session: entry.session) else { return false }
        sessions.removeValue(forKey: id)
        return true
    }

    private func stopAllSessions() -> Bool {
        var fadedAnySession = false
        for id in Array(sessions.keys) {
            guard var entry = sessions[id], entry.phase == .active else { continue }
            entry.phase = .retiring
            sessions[id] = entry
            entry.session.setGain(1)
            fadedAnySession = true
        }
        if fadedAnySession, fadeDelay > 0 {
            sleep(fadeDelay)
        }
        var stoppedAll = true
        for id in Array(sessions.keys) {
            if !finishRetiringSession(id: id) {
                stoppedAll = false
            }
        }
        return stoppedAll
    }

    private func stop(session: any ApplicationVolumeRouteSession) -> Bool {
        let deadline = uptime() + stopTimeout
        while true {
            if session.stop() || session.isStopped { return true }
            guard uptime() < deadline else {
                logger.error("Timed out while removing an application audio route")
                return false
            }
            sleep(stopRetryInterval)
        }
    }

    private static func probeSystemAudioAccess() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "MacTools Application Volume Permission"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            return false
        }

        AudioHardwareDestroyProcessTap(tapID)
        return true
    }

    private static func isUnity(_ gain: Double) -> Bool {
        abs(gain - 1) < 0.005
    }
}

@available(macOS 15.0, *)
private final class AudioRouteGainSession: ApplicationVolumeRouteSession, @unchecked Sendable {
    let processObjectIDs: [AudioObjectID]
    let outputDeviceUID: String

    private let gainState: RealtimeGainState
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    init?(
        processObjectIDs: [AudioObjectID],
        outputDeviceUID: String,
        initialGain: Float
    ) {
        guard !processObjectIDs.isEmpty else {
            return nil
        }

        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.gainState = RealtimeGainState(initialGain: initialGain)

        guard Self.outputChannelCount(deviceUID: outputDeviceUID) == 2 else {
            return nil
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDescription.name = "MacTools Application Volume \(UUID().uuidString)"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped

        guard AudioHardwareCreateProcessTap(tapDescription, &tapID) == noErr,
              tapID != kAudioObjectUnknown,
              let format = Self.tapFormat(tapID: tapID),
              Self.supports(format: format) else {
            cleanUpAfterFailedStart()
            return nil
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacTools Application Volume Route",
            kAudioAggregateDeviceUIDKey: "cc.ggbond.mactools.app-volume.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]

        guard AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        ) == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            cleanUpAfterFailedStart()
            return nil
        }

        let gainState = gainState
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            nil
        ) { _, inputData, _, outputData, _ in
            Self.render(
                inputData: inputData,
                outputData: outputData,
                format: format,
                gainState: gainState
            )
        }
        guard createStatus == noErr, let ioProcID else {
            cleanUpAfterFailedStart()
            return nil
        }

        guard AudioDeviceStart(aggregateDeviceID, ioProcID) == noErr else {
            cleanUpAfterFailedStart()
            return nil
        }
        isRunning = true
    }

    func setGain(_ gain: Float) {
        gainState.store(max(0, min(1, gain)))
    }

    var isStopped: Bool {
        ioProcID == nil
            && aggregateDeviceID == kAudioObjectUnknown
            && tapID == kAudioObjectUnknown
    }

    @discardableResult
    func stop() -> Bool {
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            if isRunning {
                let status = AudioDeviceStop(aggregateDeviceID, ioProcID)
                guard Self.didStop(status) else {
                    return false
                }
                isRunning = false
            }

            let status = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            guard Self.didDestroy(status) else {
                return false
            }
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            guard Self.didDestroy(status) else {
                return false
            }
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            guard Self.didDestroy(status) else {
                return false
            }
            tapID = kAudioObjectUnknown
        }

        return true
    }

    deinit {
        stop()
    }

    private func cleanUpAfterFailedStart() {
        let deadline = Date().addingTimeInterval(0.6)
        while !stop(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func didStop(_ status: OSStatus) -> Bool {
        status == noErr
            || status == kAudioHardwareNotRunningError
            || didDestroy(status)
    }

    private static func didDestroy(_ status: OSStatus) -> Bool {
        status == noErr
            || status == kAudioHardwareBadObjectError
            || status == kAudioHardwareBadDeviceError
    }

    private static func outputChannelCount(deviceUID: String) -> Int? {
        guard let deviceID = audioDeviceID(deviceUID: deviceUID) else {
            return nil
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioBufferList>.size else {
            return nil
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(dataSize))

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            storage
        ) == noErr else {
            return nil
        }

        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func audioDeviceID(deviceUID: String) -> AudioObjectID? {
        audioObjectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices
        )
        .first { deviceID in
            stringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID
            ) == deviceUID
        }
    }

    private static func audioObjectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioObjectID>.size else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var values = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        return status == noErr ? values.filter { $0 != kAudioObjectUnknown } : []
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        return status == noErr ? value as String? : nil
    }

    private static func tapFormat(tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &dataSize,
            &format
        )
        return status == noErr ? format : nil
    }

    private static func supports(format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mBytesPerFrame > 0 else {
            return false
        }

        let flags = format.mFormatFlags
        if flags & kAudioFormatFlagIsFloat != 0 {
            return format.mBitsPerChannel == 32 || format.mBitsPerChannel == 64
        }
        if flags & kAudioFormatFlagIsSignedInteger != 0 {
            return format.mBitsPerChannel == 16 || format.mBitsPerChannel == 32
        }
        return false
    }

    private static func render(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        gainState: RealtimeGainState
    ) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard let firstBuffer = inputBuffers.first,
              format.mBytesPerFrame > 0 else {
            return
        }

        let frameCount = firstBuffer.mDataByteSize / format.mBytesPerFrame
        guard frameCount > 0 else {
            return
        }

        let ramp = gainState.nextRamp(frameCount: frameCount)
        for index in inputBuffers.indices {
            guard index < outputBuffers.count else {
                break
            }
            write(
                input: inputBuffers[index],
                output: &outputBuffers[index],
                format: format,
                ramp: ramp,
                frameCount: frameCount
            )
        }
    }

    private static func write(
        input: AudioBuffer,
        output: inout AudioBuffer,
        format: AudioStreamBasicDescription,
        ramp: GainRamp,
        frameCount: UInt32
    ) {
        guard let sourceData = input.mData,
              let destinationData = output.mData,
              input.mNumberChannels == output.mNumberChannels,
              output.mDataByteSize >= input.mDataByteSize else {
            return
        }

        output.mDataByteSize = input.mDataByteSize
        let flags = format.mFormatFlags
        let channels = max(Int(input.mNumberChannels), 1)

        if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
            scaleFloat32(
                source: sourceData,
                destination: destinationData,
                sampleCount: Int(input.mDataByteSize) / MemoryLayout<Float>.size,
                channels: channels,
                frameCount: Int(frameCount),
                ramp: ramp
            )
        } else if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 64 {
            scaleFloat64(
                source: sourceData,
                destination: destinationData,
                sampleCount: Int(input.mDataByteSize) / MemoryLayout<Double>.size,
                channels: channels,
                frameCount: Int(frameCount),
                ramp: ramp
            )
        } else if format.mBitsPerChannel == 16 {
            scaleInt16(
                source: sourceData,
                destination: destinationData,
                sampleCount: Int(input.mDataByteSize) / MemoryLayout<Int16>.size,
                channels: channels,
                frameCount: Int(frameCount),
                ramp: ramp
            )
        } else if format.mBitsPerChannel == 32 {
            scaleInt32(
                source: sourceData,
                destination: destinationData,
                sampleCount: Int(input.mDataByteSize) / MemoryLayout<Int32>.size,
                channels: channels,
                frameCount: Int(frameCount),
                ramp: ramp
            )
        }
    }

    private static func scaleFloat32(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        sampleCount: Int,
        channels: Int,
        frameCount: Int,
        ramp: GainRamp
    ) {
        let input = source.assumingMemoryBound(to: Float.self)
        let output = destination.assumingMemoryBound(to: Float.self)
        for sample in 0..<sampleCount {
            output[sample] = input[sample] * ramp.value(frame: sample / channels, frameCount: frameCount)
        }
    }

    private static func scaleFloat64(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        sampleCount: Int,
        channels: Int,
        frameCount: Int,
        ramp: GainRamp
    ) {
        let input = source.assumingMemoryBound(to: Double.self)
        let output = destination.assumingMemoryBound(to: Double.self)
        for sample in 0..<sampleCount {
            output[sample] = input[sample] * Double(ramp.value(frame: sample / channels, frameCount: frameCount))
        }
    }

    private static func scaleInt16(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        sampleCount: Int,
        channels: Int,
        frameCount: Int,
        ramp: GainRamp
    ) {
        let input = source.assumingMemoryBound(to: Int16.self)
        let output = destination.assumingMemoryBound(to: Int16.self)
        for sample in 0..<sampleCount {
            output[sample] = Int16(
                Float(input[sample]) * ramp.value(frame: sample / channels, frameCount: frameCount)
            )
        }
    }

    private static func scaleInt32(
        source: UnsafeRawPointer,
        destination: UnsafeMutableRawPointer,
        sampleCount: Int,
        channels: Int,
        frameCount: Int,
        ramp: GainRamp
    ) {
        let input = source.assumingMemoryBound(to: Int32.self)
        let output = destination.assumingMemoryBound(to: Int32.self)
        for sample in 0..<sampleCount {
            output[sample] = Int32(
                Double(input[sample]) * Double(ramp.value(frame: sample / channels, frameCount: frameCount))
            )
        }
    }
}

@available(macOS 15.0, *)
private final class RealtimeGainState: @unchecked Sendable {
    private let targetBits: Atomic<UInt32>
    private var renderedGain: Float

    init(initialGain: Float) {
        let gain = max(0, min(1, initialGain))
        targetBits = Atomic(gain.bitPattern)
        renderedGain = gain
    }

    func store(_ gain: Float) {
        targetBits.store(gain.bitPattern, ordering: .relaxed)
    }

    func nextRamp(frameCount: UInt32) -> GainRamp {
        let target = Float(bitPattern: targetBits.load(ordering: .relaxed))
        let ramp = GainRamp(start: renderedGain, end: target)
        renderedGain = target
        return ramp
    }
}

private struct GainRamp: Sendable {
    let start: Float
    let end: Float

    func value(frame: Int, frameCount: Int) -> Float {
        guard frameCount > 1 else {
            return end
        }

        let progress = Float(min(max(frame, 0), frameCount - 1)) / Float(frameCount - 1)
        return start + (end - start) * progress
    }
}
