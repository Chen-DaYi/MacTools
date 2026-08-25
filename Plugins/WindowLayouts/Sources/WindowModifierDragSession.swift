import AppKit
import ApplicationServices
import Foundation
import MacToolsPluginKit

@MainActor
protocol WindowModifierDragSessionManaging: AnyObject {
    var onFailure: (WindowLayoutError) -> Void { get set }
    var onSuccess: () -> Void { get set }
    func configure(modifiers: ShortcutModifiers)
    func start()
    func stop()
}

@MainActor
protocol WindowUnderPointerResolving {
    func resolveWindow(at point: CGPoint) async throws -> AccessibilityWindowHandle
}

@MainActor
final class SystemWindowUnderPointerResolver: WindowUnderPointerResolving {
    typealias WindowInfoProvider = () -> [[String: Any]]

    private let accessibilityTrusted: @MainActor () -> Bool
    private let windowInfoProvider: WindowInfoProvider
    private let hostWindow: @MainActor (Int) -> NSWindow?
    private let worker: WindowAccessibilityWorker

    init(
        accessibilityTrusted: @escaping @MainActor () -> Bool = AXIsProcessTrusted,
        windowInfoProvider: @escaping WindowInfoProvider = {
            CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]] ?? []
        },
        hostWindow: @escaping @MainActor (Int) -> NSWindow? = { windowNumber in
            NSApp.windows.first(where: {
                $0.windowNumber == windowNumber && $0.isVisible
            })
        },
        worker: WindowAccessibilityWorker = WindowAccessibilityWorker()
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.windowInfoProvider = windowInfoProvider
        self.hostWindow = hostWindow
        self.worker = worker
    }

    func resolveWindow(at point: CGPoint) async throws -> AccessibilityWindowHandle {
        guard accessibilityTrusted() else {
            throw WindowLayoutError.accessibilityRequired
        }
        guard let target = Self.windowTarget(at: point, in: windowInfoProvider()) else {
            throw WindowLayoutError.noWindowUnderPointer
        }

        if target.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let window = hostWindow(target.windowNumber), window.isMovable else {
                throw WindowLayoutError.windowCannotMove
            }
            return AccessibilityWindowHandle(
                identity: WindowIdentity(
                    processIdentifier: target.processIdentifier,
                    token: "window-number:\(target.windowNumber)"
                ),
                bundleIdentifier: Bundle.main.bundleIdentifier,
                title: window.title,
                windowNumber: UInt32(exactly: target.windowNumber),
                canMove: window.isMovable,
                canResize: window.styleMask.contains(.resizable),
                hostWindow: window
            )
        }

        let application = NSRunningApplication(processIdentifier: target.processIdentifier)
        return try await worker.resolveFocusedWindow(target: ExternalFocusedWindowTarget(
            processIdentifier: target.processIdentifier,
            bundleIdentifier: application?.bundleIdentifier,
            preferredWindowNumber: target.windowNumber
        ))
    }

    nonisolated static func windowTarget(
        at point: CGPoint,
        in windowInfo: [[String: Any]]
    ) -> (processIdentifier: pid_t, windowNumber: Int)? {
        for info in windowInfo {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let processIdentifier = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  processIdentifier > 0,
                  let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  windowNumber > 0,
                  let bounds = rect(from: info[kCGWindowBounds as String]),
                  bounds.width > 0,
                  bounds.height > 0,
                  bounds.contains(point)
            else {
                continue
            }
            return (processIdentifier, windowNumber)
        }
        return nil
    }

    nonisolated private static func rect(from value: Any?) -> CGRect? {
        guard let dictionary = value as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary)
    }
}

@MainActor
final class WindowModifierDragController {
    var onFailure: (WindowLayoutError) -> Void = { _ in }
    var onSuccess: () -> Void = {}

    private let resolver: any WindowUnderPointerResolving
    private let frameReader: any WindowFrameReading
    private let frameWriter: any WindowFrameWriting
    private var generation: UInt64?
    private var originPointer = CGPoint.zero
    private var pendingPointer = CGPoint.zero
    private var window: AccessibilityWindowHandle?
    private var originalFrame: CGRect?
    private var resolutionTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?

    init(
        resolver: any WindowUnderPointerResolving,
        frameReader: any WindowFrameReading,
        frameWriter: any WindowFrameWriting
    ) {
        self.resolver = resolver
        self.frameReader = frameReader
        self.frameWriter = frameWriter
    }

    func begin(generation: UInt64, origin: CGPoint, pointer: CGPoint) {
        cancelAll()
        self.generation = generation
        originPointer = origin
        pendingPointer = pointer
        resolutionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let window = try await resolver.resolveWindow(at: origin)
                guard window.canMove else { throw WindowLayoutError.windowCannotMove }
                let frame = try await frameReader.frame(of: window)
                guard !Task.isCancelled, self.generation == generation else { return }
                self.window = window
                self.originalFrame = frame
                self.resolutionTask = nil
                self.flush(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.fail(error as? WindowLayoutError ?? .windowUnavailable)
            }
        }
    }

    func update(generation: UInt64, pointer: CGPoint) {
        guard self.generation == generation else { return }
        pendingPointer = pointer
        flush(generation: generation)
    }

    func cancel(generation: UInt64) {
        guard self.generation == generation else { return }
        cancelAll()
    }

    func stop() {
        cancelAll()
    }

    private func flush(generation: UInt64) {
        guard writeTask == nil,
              self.generation == generation,
              let window,
              let originalFrame
        else { return }

        let pointer = pendingPointer
        let targetFrame = CGRect(
            origin: CGPoint(
                x: originalFrame.minX + pointer.x - originPointer.x,
                y: originalFrame.minY + pointer.y - originPointer.y
            ),
            size: originalFrame.size
        )
        writeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await frameWriter.setFrame(targetFrame, of: window, resize: false)
                guard !Task.isCancelled, self.generation == generation else { return }
                self.onSuccess()
                self.writeTask = nil
                if self.pendingPointer != pointer {
                    self.flush(generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.fail(error as? WindowLayoutError ?? .frameWriteFailed)
            }
        }
    }

    private func fail(_ error: WindowLayoutError) {
        cancelAll()
        onFailure(error)
    }

    private func cancelAll() {
        resolutionTask?.cancel()
        writeTask?.cancel()
        resolutionTask = nil
        writeTask = nil
        generation = nil
        window = nil
        originalFrame = nil
    }
}

struct WindowModifierDragActionQueue {
    private var epoch: UInt64 = 0
    private var isActive = false
    private var isDrainScheduled = false
    private var actions: [WindowModifierDragGestureAction] = []

    mutating func activate() -> UInt64 {
        epoch &+= 1
        isActive = true
        isDrainScheduled = false
        actions.removeAll(keepingCapacity: true)
        return epoch
    }

    mutating func deactivate() {
        epoch &+= 1
        isActive = false
        isDrainScheduled = false
        actions.removeAll(keepingCapacity: true)
    }

    mutating func enqueue(_ action: WindowModifierDragGestureAction) -> UInt64? {
        guard isActive else { return nil }

        if case let .update(generation, _) = action,
           let last = actions.last,
           case let .update(lastGeneration, _) = last,
           generation == lastGeneration {
            actions[actions.index(before: actions.endIndex)] = action
        } else {
            actions.append(action)
        }

        guard !isDrainScheduled else { return nil }
        isDrainScheduled = true
        return epoch
    }

    mutating func nextAction(for drainEpoch: UInt64) -> WindowModifierDragGestureAction? {
        guard isActive, epoch == drainEpoch else { return nil }
        guard !actions.isEmpty else {
            isDrainScheduled = false
            return nil
        }
        return actions.removeFirst()
    }
}

nonisolated final class WindowModifierDragSession: @unchecked Sendable,
    WindowModifierDragSessionManaging
{
    private typealias CallbackContext = PluginCallbackContext<WindowModifierDragSession>
    @MainActor var onFailure: (WindowLayoutError) -> Void {
        get { controller.onFailure }
        set { controller.onFailure = newValue }
    }
    @MainActor var onSuccess: () -> Void {
        get { controller.onSuccess }
        set { controller.onSuccess = newValue }
    }

    private let lock = NSLock()
    private let controller: WindowModifierDragController
    private var gesture: WindowModifierDragGesture
    private var actionQueue = WindowModifierDragActionQueue()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var callbackPointer: UnsafeMutableRawPointer?

    @MainActor
    init(
        modifiers: ShortcutModifiers = WindowLayoutsStore.defaultModifierDragModifiers,
        resolver: (any WindowUnderPointerResolving)? = nil,
        frameAdapter: AccessibilityWindowFrameAdapter? = nil
    ) {
        let adapter = frameAdapter ?? AccessibilityWindowFrameAdapter()
        self.controller = WindowModifierDragController(
            resolver: resolver ?? SystemWindowUnderPointerResolver(),
            frameReader: adapter,
            frameWriter: adapter
        )
        self.gesture = WindowModifierDragGesture(requiredModifiers: modifiers)
    }

    @MainActor
    func configure(modifiers: ShortcutModifiers) {
        let cancellation = lock.withLock { () -> WindowModifierDragGestureAction? in
            let cancellation = gesture.reset()
            gesture.requiredModifiers = modifiers
            return cancellation
        }
        dispatch(cancellation)
    }

    @MainActor
    func start() {
        guard lock.withLock({ tap == nil }) else { return }
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        let callbackContext = CallbackContext(owner: self)
        let callbackPointer = Unmanaged.passRetained(callbackContext).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.eventCallback,
            userInfo: callbackPointer
        ) else {
            callbackContext.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            onFailure(.accessibilityRequired)
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            callbackContext.invalidate()
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
            onFailure(.accessibilityRequired)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        lock.withLock {
            self.tap = tap
            self.runLoopSource = source
            self.callbackPointer = callbackPointer
            _ = self.actionQueue.activate()
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    @MainActor
    func stop() {
        let state = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?, UnsafeMutableRawPointer?) in
            _ = gesture.reset()
            actionQueue.deactivate()
            let state = (tap, runLoopSource, callbackPointer)
            tap = nil
            runLoopSource = nil
            callbackPointer = nil
            return state
        }
        controller.stop()
        if let callbackPointer = state.2 {
            Unmanaged<CallbackContext>
                .fromOpaque(callbackPointer)
                .takeUnretainedValue()
                .invalidate()
        }
        if let tap = state.0 {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource = state.1 {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap = state.0 {
            CFMachPortInvalidate(tap)
        }
        if let callbackPointer = state.2 {
            Unmanaged<CallbackContext>.fromOpaque(callbackPointer).release()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            let cancellation = lock.withLock { gesture.reset() }
            dispatch(cancellation)
            return Unmanaged.passUnretained(event)
        }

        let modifiers = ShortcutModifiers.from(event.flags)
        let action = lock.withLock { () -> WindowModifierDragGestureAction? in
            switch type {
            case .flagsChanged:
                return gesture.modifiersChanged(modifiers, pointer: event.location)
            case .mouseMoved:
                return gesture.pointerMoved(to: event.location, modifiers: modifiers)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                return gesture.mouseButtonPressed()
            default:
                return nil
            }
        }
        dispatch(action)
        return Unmanaged.passUnretained(event)
    }

    private func dispatch(_ action: WindowModifierDragGestureAction?) {
        guard let action else { return }
        let drainEpoch = lock.withLock { actionQueue.enqueue(action) }
        guard let drainEpoch else { return }
        Task { @MainActor [weak self] in
            self?.drainActions(epoch: drainEpoch)
        }
    }

    @MainActor
    private func drainActions(epoch: UInt64) {
        while let action = lock.withLock({ actionQueue.nextAction(for: epoch) }) {
            switch action {
            case let .begin(generation, origin, pointer):
                controller.begin(generation: generation, origin: origin, pointer: pointer)
            case let .update(generation, pointer):
                controller.update(generation: generation, pointer: pointer)
            case let .cancel(generation):
                controller.cancel(generation: generation)
            }
        }
    }

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<CallbackContext>.fromOpaque(userInfo).takeUnretainedValue()
        return context.withOwner { session in
            session.handle(type: type, event: event)
        } ?? Unmanaged.passUnretained(event)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
