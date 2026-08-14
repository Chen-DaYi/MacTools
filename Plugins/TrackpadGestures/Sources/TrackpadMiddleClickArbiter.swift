import CoreGraphics
import Foundation
import MacToolsPluginKit

enum TrackpadNativeClickResolution: Equatable, Sendable {
    case consume
    case middleClick
}

final class TrackpadMiddleClickCandidateTimeline: @unchecked Sendable {
    struct Candidate: Equatable, Sendable {
        let deviceID: UInt64
        let observedAt: TimeInterval
        let isAmbiguous: Bool
    }

    private struct CandidateEpisode {
        var observedAt: TimeInterval
        var isAmbiguous: Bool
        // Tap recognition is delivered after the release frame, so a just-ended episode remains
        // available for the bounded candidate window without carrying into a later contact episode.
        var isActive: Bool
    }

    private let candidateWindow: TimeInterval
    private let lock = NSLock()
    private var contactCounts = Set<Int>()
    private var episodesByDevice: [UInt64: CandidateEpisode] = [:]
    private var untrustedNativeEventDeadline: TimeInterval?
    private var uncorrelatedDeadlinesByDevice: [UInt64: TimeInterval] = [:]

    init(candidateWindow: TimeInterval = 0.32) {
        self.candidateWindow = candidateWindow
    }

    func update(gestures: Set<TrackpadGesture>) {
        let counts = Set(gestures.compactMap(\.middleClickContactCount))
        lock.withLock {
            contactCounts = counts
            clearState()
        }
    }

    func observe(frame: TrackpadContactFrame, at time: TimeInterval) {
        lock.withLock {
            pruneEventDeadlines(at: time)
            pruneEpisodes(at: time)
            guard contactCounts.contains(frame.contacts.count) else {
                if var episode = episodesByDevice[frame.deviceID], episode.isActive {
                    episode.isActive = false
                    episodesByDevice[frame.deviceID] = episode
                }
                return
            }
            let startsAmbiguous = untrustedNativeEventDeadline.map { $0 > time } == true
                || uncorrelatedDeadlinesByDevice[frame.deviceID].map { $0 > time } == true
            if var episode = episodesByDevice[frame.deviceID], episode.isActive {
                episode.observedAt = time
                episode.isAmbiguous = episode.isAmbiguous || startsAmbiguous
                episodesByDevice[frame.deviceID] = episode
            } else {
                episodesByDevice[frame.deviceID] = CandidateEpisode(
                    observedAt: time,
                    isAmbiguous: startsAmbiguous,
                    isActive: true
                )
            }
        }
    }

    func takeCandidates() -> [Candidate] {
        lock.withLock {
            episodesByDevice.map { deviceID, episode in
                Candidate(
                    deviceID: deviceID,
                    observedAt: episode.observedAt,
                    isAmbiguous: episode.isAmbiguous
                )
            }
        }
    }

    func inferredTrackpadOrigin(at time: TimeInterval) -> TrackpadMiddleClickArbiter.NativeEventOrigin? {
        lock.withLock {
            pruneEventDeadlines(at: time)
            pruneEpisodes(at: time)
            let candidates = episodesByDevice.filter { !$0.value.isAmbiguous }
            guard candidates.count == 1, let deviceID = candidates.keys.first else { return nil }
            return .trackpad(deviceID: deviceID)
        }
    }

    func observeNativeEvent(
        origin: TrackpadMiddleClickArbiter.NativeEventOrigin,
        isDown: Bool,
        at time: TimeInterval
    ) {
        guard isDown else { return }
        lock.withLock {
            pruneEventDeadlines(at: time)
            pruneEpisodes(at: time)
            let deadline = time + candidateWindow
            switch origin {
            case .unknown, .external:
                untrustedNativeEventDeadline = deadline
                for deviceID in Array(episodesByDevice.keys) {
                    markEpisodeAmbiguous(deviceID: deviceID)
                }
            case let .trackpad(deviceID):
                if episodesByDevice[deviceID] == nil {
                    uncorrelatedDeadlinesByDevice[deviceID] = deadline
                }
                for otherDeviceID in Array(episodesByDevice.keys)
                    where otherDeviceID != deviceID {
                    markEpisodeAmbiguous(deviceID: otherDeviceID)
                }
            }
        }
    }

    func reset() {
        lock.withLock {
            clearState()
        }
    }

    private func pruneEventDeadlines(at time: TimeInterval) {
        if let deadline = untrustedNativeEventDeadline, deadline <= time {
            untrustedNativeEventDeadline = nil
        }
        uncorrelatedDeadlinesByDevice = uncorrelatedDeadlinesByDevice.filter {
            $0.value > time
        }
    }

    private func clearState() {
        episodesByDevice.removeAll()
        untrustedNativeEventDeadline = nil
        uncorrelatedDeadlinesByDevice.removeAll()
    }

    private func markEpisodeAmbiguous(deviceID: UInt64) {
        guard var episode = episodesByDevice[deviceID] else { return }
        episode.isAmbiguous = true
        episodesByDevice[deviceID] = episode
    }

    private func pruneEpisodes(at time: TimeInterval) {
        episodesByDevice = episodesByDevice.filter {
            $0.value.isActive || $0.value.observedAt + candidateWindow > time
        }
    }
}

struct TrackpadMiddleClickArbiter: Sendable {
    enum Button: Equatable, Sendable {
        case left
        case right
    }

    enum NativeEvent: Equatable, Sendable {
        case down(Button)
        case up(Button)
    }

    enum NativeEventOrigin: Equatable, Sendable {
        case trackpad(deviceID: UInt64)
        case external
        case unknown
    }

    enum CurrentEventDecision: Equatable, Sendable {
        case passThrough
        case suppressAndBuffer
        case suppress
        case rewriteAsMiddle
    }

    enum DeferredAction: Equatable, Sendable {
        case replayBuffered
        case discardBuffered
        case convertBuffered
        case synthesizeMiddleClick
        case releaseConvertedMiddleButton
    }

    struct NativeEventOutcome: Equatable, Sendable {
        let decision: CurrentEventDecision
        let deferredActions: [DeferredAction]
    }

    private let candidateWindow: TimeInterval
    private let postRecognitionWindow: TimeInterval
    private let convertedReleaseWindow: TimeInterval
    private var candidateDeadlinesByDevice: [UInt64: TimeInterval] = [:]
    private var ambiguousDeadlinesByDevice: [UInt64: TimeInterval] = [:]
    private var bufferedEvents: [NativeEvent] = []
    private var bufferedDeviceID: UInt64?
    private var bufferedDeadline: TimeInterval?
    private var recognizedDeviceID: UInt64?
    private var recognizedResolution: TrackpadNativeClickResolution?
    private var recognitionDeadline: TimeInterval?
    private var convertedButton: Button?
    private var convertedDeviceID: UInt64?
    private var convertedReleaseDeadline: TimeInterval?
    private var consumedButton: Button?
    private var consumedDeviceID: UInt64?
    private var consumedReleaseDeadline: TimeInterval?
    private var uncorrelatableNativeEventDeadline: TimeInterval?
    private var uncorrelatedTrackpadDeadlinesByDevice: [UInt64: TimeInterval] = [:]

    init(
        candidateWindow: TimeInterval = 0.32,
        postRecognitionWindow: TimeInterval = 0.08,
        convertedReleaseWindow: TimeInterval = 5
    ) {
        self.candidateWindow = candidateWindow
        self.postRecognitionWindow = postRecognitionWindow
        self.convertedReleaseWindow = convertedReleaseWindow
    }

    var nextDeadline: TimeInterval? {
        // Candidate-only state is pruned by the next contact/native/recognition input and has no
        // externally visible timeout action. Schedule work only when an event must be replayed or
        // a recognized gesture may need synthesis.
        let deadlines = [
            bufferedDeadline,
            recognitionDeadline,
            convertedReleaseDeadline,
            consumedReleaseDeadline,
        ].compactMap { $0 }
        return deadlines.min()
    }

    @discardableResult
    mutating func observeCandidate(
        deviceID: UInt64,
        at time: TimeInterval,
        isAmbiguous: Bool = false
    ) -> [DeferredAction] {
        let actions = expire(at: time)
        let deadline = time + candidateWindow
        candidateDeadlinesByDevice[deviceID] = deadline
        if isAmbiguous
            || ambiguousDeadlinesByDevice[deviceID] != nil
            || uncorrelatableNativeEventDeadline.map({ $0 > time }) == true
            || uncorrelatedTrackpadDeadlinesByDevice[deviceID].map({ $0 > time }) == true {
            ambiguousDeadlinesByDevice[deviceID] = deadline
        }
        return actions
    }

    mutating func recognize(
        deviceID: UInt64,
        resolution: TrackpadNativeClickResolution = .middleClick,
        at time: TimeInterval
    ) -> [DeferredAction] {
        var actions = expire(at: time)
        let activeCandidateIDs = Set(candidateDeadlinesByDevice.keys)
        guard activeCandidateIDs == [deviceID],
              ambiguousDeadlinesByDevice[deviceID] == nil
        else {
            if !bufferedEvents.isEmpty {
                actions.append(.replayBuffered)
                markBufferedDeviceAmbiguous()
            }
            clearBufferedState()
            clearRecognitionState()
            return actions
        }

        if !bufferedEvents.isEmpty {
            guard bufferedDeviceID == deviceID,
                  let downButton = validBufferedDownButton()
            else {
                actions.append(.replayBuffered)
                markBufferedDeviceAmbiguous()
                clearBufferedState()
                clearRecognitionState()
                return actions
            }
            actions.append(resolution == .middleClick ? .convertBuffered : .discardBuffered)
            if bufferedEvents.count == 1 {
                if resolution == .middleClick {
                    beginConvertedClick(button: downButton, deviceID: deviceID, at: time)
                } else {
                    beginConsumedClick(button: downButton, deviceID: deviceID, at: time)
                }
            }
            clearBufferedState()
            clearRecognitionState()
            return actions
        }

        recognizedDeviceID = deviceID
        recognizedResolution = resolution
        // Native click delivery can lag recognition. Keep the fallback pending until both the
        // short post-recognition grace period and the complete candidate ambiguity window have
        // elapsed, so a late unknown/external click can still cancel synthesis.
        recognitionDeadline = max(
            time + postRecognitionWindow,
            candidateDeadlinesByDevice[deviceID] ?? time
        )
        return actions
    }

    mutating func handleNativeEvent(
        _ event: NativeEvent,
        origin: NativeEventOrigin,
        at time: TimeInterval
    ) -> NativeEventOutcome {
        var actions = expire(at: time)

        if let convertedButton, let convertedDeviceID {
            if event == .up(convertedButton), origin == .trackpad(deviceID: convertedDeviceID) {
                clearConvertedState()
                return NativeEventOutcome(
                    decision: .rewriteAsMiddle,
                    deferredActions: actions
                )
            }
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }

        if let consumedButton, let consumedDeviceID {
            if event == .up(consumedButton), origin == .trackpad(deviceID: consumedDeviceID) {
                clearConsumedState()
                return NativeEventOutcome(decision: .suppress, deferredActions: actions)
            }
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }

        guard case let .trackpad(originDeviceID) = origin else {
            if !bufferedEvents.isEmpty {
                actions.append(.replayBuffered)
                markBufferedDeviceAmbiguous()
                clearBufferedState()
            }
            if event.isDown {
                markNativeEventUncorrelatable(at: time)
            }
            clearRecognitionState()
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }

        if let recognizedDeviceID, let recognizedResolution {
            let activeCandidateIDs = Set(candidateDeadlinesByDevice.keys)
            guard activeCandidateIDs == [recognizedDeviceID], originDeviceID == recognizedDeviceID else {
                clearRecognitionState()
                return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
            }
            switch event {
            case let .down(button):
                if recognizedResolution == .middleClick {
                    beginConvertedClick(button: button, deviceID: recognizedDeviceID, at: time)
                } else {
                    beginConsumedClick(button: button, deviceID: recognizedDeviceID, at: time)
                }
                clearRecognitionState()
                return NativeEventOutcome(
                    decision: recognizedResolution == .middleClick ? .rewriteAsMiddle : .suppress,
                    deferredActions: actions
                )
            case .up:
                // Seeing an Up without its Down means correlation is ambiguous. Preserve the
                // native event and do not add a synthetic middle click.
                clearRecognitionState()
                return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
            }
        }

        if !bufferedEvents.isEmpty {
            guard let downButton = validBufferedDownButton() else {
                actions.append(.replayBuffered)
                markBufferedDeviceAmbiguous()
                clearBufferedState()
                return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
            }
            if event == .up(downButton), bufferedEvents.count == 1 {
                bufferedEvents.append(event)
                return NativeEventOutcome(
                    decision: .suppressAndBuffer,
                    deferredActions: actions
                )
            }
            actions.append(.replayBuffered)
            markBufferedDeviceAmbiguous()
            clearBufferedState()
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }

        guard case .down = event else {
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }
        guard candidateDeadlinesByDevice.count == 1,
              let candidateDeviceID = candidateDeadlinesByDevice.keys.first,
              originDeviceID == candidateDeviceID,
              ambiguousDeadlinesByDevice[candidateDeviceID] == nil
        else {
            markTrackpadEventUncorrelated(deviceID: originDeviceID, at: time)
            return NativeEventOutcome(decision: .passThrough, deferredActions: actions)
        }

        bufferedEvents = [event]
        bufferedDeviceID = candidateDeviceID
        bufferedDeadline = time + candidateWindow
        return NativeEventOutcome(
            decision: .suppressAndBuffer,
            deferredActions: actions
        )
    }

    mutating func expire(at time: TimeInterval) -> [DeferredAction] {
        candidateDeadlinesByDevice = candidateDeadlinesByDevice.filter { $0.value > time }
        ambiguousDeadlinesByDevice = ambiguousDeadlinesByDevice.filter { $0.value > time }
        uncorrelatedTrackpadDeadlinesByDevice = uncorrelatedTrackpadDeadlinesByDevice.filter {
            $0.value > time
        }
        if let deadline = uncorrelatableNativeEventDeadline, deadline <= time {
            uncorrelatableNativeEventDeadline = nil
        }
        var actions: [DeferredAction] = []

        if let bufferedDeadline, bufferedDeadline <= time, !bufferedEvents.isEmpty {
            actions.append(.replayBuffered)
            markBufferedDeviceAmbiguous()
            clearBufferedState()
        }
        if let recognitionDeadline, recognitionDeadline <= time {
            if recognizedResolution == .middleClick {
                actions.append(.synthesizeMiddleClick)
            }
            clearRecognitionState()
        }
        if let convertedReleaseDeadline, convertedReleaseDeadline <= time, convertedButton != nil {
            actions.append(.releaseConvertedMiddleButton)
            clearConvertedState()
        }
        if let consumedReleaseDeadline, consumedReleaseDeadline <= time {
            clearConsumedState()
        }
        return actions
    }

    mutating func reset() -> [DeferredAction] {
        var actions: [DeferredAction] = bufferedEvents.isEmpty ? [] : [.replayBuffered]
        if convertedButton != nil {
            actions.append(.releaseConvertedMiddleButton)
        }
        candidateDeadlinesByDevice.removeAll()
        ambiguousDeadlinesByDevice.removeAll()
        uncorrelatableNativeEventDeadline = nil
        uncorrelatedTrackpadDeadlinesByDevice.removeAll()
        clearBufferedState()
        clearRecognitionState()
        clearConvertedState()
        clearConsumedState()
        return actions
    }

    private func validBufferedDownButton() -> Button? {
        guard case let .down(button)? = bufferedEvents.first,
              bufferedEvents.count <= 2
        else {
            return nil
        }
        if bufferedEvents.count == 2, bufferedEvents[1] != .up(button) {
            return nil
        }
        return button
    }

    private mutating func clearBufferedState() {
        bufferedEvents.removeAll()
        bufferedDeviceID = nil
        bufferedDeadline = nil
    }

    private mutating func clearRecognitionState() {
        recognizedDeviceID = nil
        recognizedResolution = nil
        recognitionDeadline = nil
    }

    private mutating func beginConvertedClick(
        button: Button,
        deviceID: UInt64,
        at time: TimeInterval
    ) {
        convertedButton = button
        convertedDeviceID = deviceID
        convertedReleaseDeadline = time + convertedReleaseWindow
    }

    private mutating func clearConvertedState() {
        convertedButton = nil
        convertedDeviceID = nil
        convertedReleaseDeadline = nil
    }

    private mutating func beginConsumedClick(
        button: Button,
        deviceID: UInt64,
        at time: TimeInterval
    ) {
        consumedButton = button
        consumedDeviceID = deviceID
        consumedReleaseDeadline = time + convertedReleaseWindow
    }

    private mutating func clearConsumedState() {
        consumedButton = nil
        consumedDeviceID = nil
        consumedReleaseDeadline = nil
    }

    private mutating func markNativeEventUncorrelatable(at time: TimeInterval) {
        let deadline = time + candidateWindow
        uncorrelatableNativeEventDeadline = deadline
        for deviceID in candidateDeadlinesByDevice.keys {
            ambiguousDeadlinesByDevice[deviceID] = candidateDeadlinesByDevice[deviceID]
        }
    }

    private mutating func markTrackpadEventUncorrelated(
        deviceID: UInt64,
        at time: TimeInterval
    ) {
        let deadline = time + candidateWindow
        uncorrelatedTrackpadDeadlinesByDevice[deviceID] = deadline
        if candidateDeadlinesByDevice[deviceID] != nil {
            ambiguousDeadlinesByDevice[deviceID] = deadline
        }
    }

    private mutating func markBufferedDeviceAmbiguous() {
        guard let bufferedDeviceID,
              let candidateDeadline = candidateDeadlinesByDevice[bufferedDeviceID]
        else {
            return
        }
        ambiguousDeadlinesByDevice[bufferedDeviceID] = candidateDeadline
    }
}

@MainActor
final class TrackpadMiddleClickCoordinator {
    static let replayMarker: Int64 = 0x4D_54_4D_49_44_44_4C_45

    private var arbiter = TrackpadMiddleClickArbiter()
    private var clickResolutions: [TrackpadGesture: TrackpadNativeClickResolution] = [:]
    private var bufferedEvents: [CGEvent] = []
    private var expirationWorkItem: DispatchWorkItem?
    private let clock: @Sendable () -> TimeInterval
    private let synthesizeMiddleClick: @Sendable @MainActor () -> Void
    private let releaseMiddleButton: @Sendable @MainActor () -> Void
    private let postEvent: @Sendable @MainActor (CGEvent) -> Void
    private let candidateTimeline: TrackpadMiddleClickCandidateTimeline
    private let eventOrigin: @Sendable @MainActor (CGEvent) -> TrackpadMiddleClickArbiter.NativeEventOrigin

    init(
        clock: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        synthesizeMiddleClick: @escaping @Sendable @MainActor () -> Void = {
            TrackpadGestureActionExecutor().execute(.middleClick)
        },
        releaseMiddleButton: @escaping @Sendable @MainActor () -> Void = {
            TrackpadMiddleClickEventPoster.postButtonUp(
                eventSourceMarker: TrackpadMiddleClickCoordinator.replayMarker
            )
        },
        postEvent: @escaping @Sendable @MainActor (CGEvent) -> Void = {
            $0.post(tap: .cghidEventTap)
        },
        candidateTimeline: TrackpadMiddleClickCandidateTimeline = .init(),
        eventOrigin: @escaping @Sendable @MainActor (CGEvent) -> TrackpadMiddleClickArbiter.NativeEventOrigin = { _ in
            // Public CGEvent metadata does not expose a trustworthy hardware device identifier.
            // The coordinator infers trackpad origin only during one unambiguous contact episode;
            // otherwise unknown input passes through.
            .unknown
        }
    ) {
        self.clock = clock
        self.synthesizeMiddleClick = synthesizeMiddleClick
        self.releaseMiddleButton = releaseMiddleButton
        self.postEvent = postEvent
        self.candidateTimeline = candidateTimeline
        self.eventOrigin = eventOrigin
    }

    func updateClickResolutions(_ resolutions: [TrackpadGesture: TrackpadNativeClickResolution]) {
        guard resolutions != clickResolutions else { return }
        process(arbiter.reset())
        clickResolutions = resolutions
        candidateTimeline.update(gestures: Set(resolutions.keys))
        scheduleExpiration()
    }

    func updateMiddleClickGestures(_ gestures: Set<TrackpadGesture>) {
        updateClickResolutions(Dictionary(uniqueKeysWithValues: gestures.map { ($0, .middleClick) }))
    }

    func observe(frame: TrackpadContactFrame) {
        let now = clock()
        candidateTimeline.observe(frame: frame, at: now)
        synchronizeCandidates(at: now)
        scheduleExpiration()
    }

    func recognize(deviceID: UInt64, resolution: TrackpadNativeClickResolution = .middleClick) {
        let now = clock()
        synchronizeCandidates(at: now)
        process(arbiter.recognize(deviceID: deviceID, resolution: resolution, at: now))
        scheduleExpiration()
    }

    func handleNativeEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
            return Unmanaged.passUnretained(event)
        }
        guard let nativeEvent = nativeEvent(for: type) else {
            return Unmanaged.passUnretained(event)
        }

        let now = clock()
        let reportedOrigin = eventOrigin(event)
        let origin: TrackpadMiddleClickArbiter.NativeEventOrigin
        if reportedOrigin == .unknown,
           let inferredOrigin = candidateTimeline.inferredTrackpadOrigin(at: now) {
            origin = inferredOrigin
        } else {
            origin = reportedOrigin
        }
        candidateTimeline.observeNativeEvent(
            origin: origin,
            isDown: nativeEvent.isDown,
            at: now
        )
        synchronizeCandidates(at: now)
        let outcome = arbiter.handleNativeEvent(
            nativeEvent,
            origin: origin,
            at: now
        )
        process(outcome.deferredActions)
        defer { scheduleExpiration() }

        switch outcome.decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .rewriteAsMiddle:
            rewriteAsMiddle(event, isDown: nativeEvent.isDown)
            return Unmanaged.passUnretained(event)
        case .suppress:
            return nil
        case .suppressAndBuffer:
            guard let eventCopy = event.copy() else {
                process(arbiter.reset())
                return Unmanaged.passUnretained(event)
            }
            bufferedEvents.append(eventCopy)
            return nil
        }
    }

    func reset() {
        expirationWorkItem?.cancel()
        expirationWorkItem = nil
        process(arbiter.reset())
        candidateTimeline.reset()
    }

    private func process(_ actions: [TrackpadMiddleClickArbiter.DeferredAction]) {
        for action in actions {
            switch action {
            case .replayBuffered:
                bufferedEvents.forEach(post)
                bufferedEvents.removeAll()
            case .discardBuffered:
                bufferedEvents.removeAll()
            case .convertBuffered:
                bufferedEvents.forEach { event in
                    rewriteAsMiddle(event, isDown: nativeEvent(for: event.type)?.isDown == true)
                    post(event)
                }
                bufferedEvents.removeAll()
            case .synthesizeMiddleClick:
                synthesizeMiddleClick()
            case .releaseConvertedMiddleButton:
                releaseMiddleButton()
            }
        }
    }

    private func synchronizeCandidates(at time: TimeInterval) {
        for candidate in candidateTimeline.takeCandidates() {
            process(arbiter.observeCandidate(
                deviceID: candidate.deviceID,
                at: candidate.observedAt,
                isAmbiguous: candidate.isAmbiguous
            ))
        }
        process(arbiter.expire(at: time))
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
        postEvent(event)
    }

    private func rewriteAsMiddle(_ event: CGEvent, isDown: Bool) {
        event.type = isDown ? .otherMouseDown : .otherMouseUp
        event.setIntegerValueField(
            .mouseEventButtonNumber,
            value: Int64(CGMouseButton.center.rawValue)
        )
    }

    private func nativeEvent(for type: CGEventType) -> TrackpadMiddleClickArbiter.NativeEvent? {
        switch type {
        case .leftMouseDown: .down(.left)
        case .leftMouseUp: .up(.left)
        case .rightMouseDown: .down(.right)
        case .rightMouseUp: .up(.right)
        default: nil
        }
    }

    private func scheduleExpiration() {
        expirationWorkItem?.cancel()
        expirationWorkItem = nil
        guard let deadline = arbiter.nextDeadline else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.expirationWorkItem = nil
            self.synchronizeCandidates(at: self.clock())
            self.scheduleExpiration()
        }
        expirationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, deadline - clock()),
            execute: workItem
        )
    }
}

private extension TrackpadMiddleClickArbiter.NativeEvent {
    var isDown: Bool {
        if case .down = self { return true }
        return false
    }
}

private extension TrackpadGesture {
    var middleClickContactCount: Int? {
        if let count = fingerTapCount ?? longTouchFingerCount {
            return count
        }
        return tipTapConfiguration.map { $0.fixedFingerCount + 1 }
    }
}
