import AppKit
import ApplicationServices
import Foundation
import MacToolsPluginKit

struct AutoInputEditableFocusIdentity: Hashable, Sendable {
    private let rawValue: UUID

    init() {
        rawValue = UUID()
    }
}

struct AutoInputEditableFocus: Equatable, Sendable {
    let frame: CGRect
    let avoidanceFrame: CGRect
    let applicationProcessIdentifier: pid_t?
    let applicationBundleIdentifier: String?
    let isFromAccessoryApplication: Bool
    let identity: AutoInputEditableFocusIdentity

    init(
        frame: CGRect,
        avoidanceFrame: CGRect? = nil,
        applicationProcessIdentifier: pid_t? = nil,
        applicationBundleIdentifier: String? = nil,
        isFromAccessoryApplication: Bool = false,
        identity: AutoInputEditableFocusIdentity = AutoInputEditableFocusIdentity()
    ) {
        self.frame = frame
        self.avoidanceFrame = avoidanceFrame ?? frame
        self.applicationProcessIdentifier = applicationProcessIdentifier
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.isFromAccessoryApplication = isFromAccessoryApplication
        self.identity = identity
    }
}

@MainActor
protocol AutoInputFocusObserving: AnyObject {
    var onEditableFocusChanged: ((AutoInputEditableFocus?) -> Void)? { get set }
    var onAccessibilityInvalidated: (() -> Void)? { get set }

    func start()
    func stop()
    func refreshFocusedElement()
}

@MainActor
protocol AutoInputAccessibilityChecking: AnyObject {
    var isTrusted: Bool { get }

    @discardableResult
    func requestTrust(prompt: Bool) -> Bool
}

struct AutoInputObservationLifecycle {
    private(set) var generation = 0
    private(set) var isRunning = false

    mutating func start() -> Int {
        generation &+= 1
        isRunning = true
        return generation
    }

    mutating func stop() {
        isRunning = false
        generation &+= 1
    }

    func accepts(_ scheduledGeneration: Int) -> Bool {
        isRunning && generation == scheduledGeneration
    }
}

struct AutoInputObservationRetryPolicy {
    private let retryInterval: TimeInterval
    private var failedProcessIdentifier: pid_t?
    private var retryAfter: TimeInterval?

    init(retryInterval: TimeInterval = 5) {
        self.retryInterval = retryInterval
    }

    func shouldAttempt(processIdentifier: pid_t, at time: TimeInterval) -> Bool {
        guard failedProcessIdentifier == processIdentifier,
              let retryAfter else { return true }
        return time >= retryAfter
    }

    mutating func recordFailure(processIdentifier: pid_t, at time: TimeInterval) {
        failedProcessIdentifier = processIdentifier
        retryAfter = time + retryInterval
    }

    mutating func recordSuccess() {
        failedProcessIdentifier = nil
        retryAfter = nil
    }

    mutating func reset() {
        recordSuccess()
    }
}

@MainActor
final class SystemAutoInputAccessibilityCheck: AutoInputAccessibilityChecking {
    var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestTrust(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

@MainActor
final class AccessibilityAutoInputFocusObserver: AutoInputFocusObserving {
    typealias CallbackContext = PluginCallbackContext<AccessibilityAutoInputFocusObserver>

    var onEditableFocusChanged: ((AutoInputEditableFocus?) -> Void)?
    var onAccessibilityInvalidated: (() -> Void)?

    private let workspace: NSWorkspace
    private let notificationCenter: NotificationCenter
    private let focusedProcessResolver: @Sendable () -> pid_t?
    private let now: @Sendable () -> TimeInterval

    private var activationObserver: NSObjectProtocol?
    private var accessibilityObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedApplicationProcessIdentifier: pid_t?
    private var observedApplicationBundleIdentifier: String?
    private var observedApplicationIsAccessory = false
    private var focusedAccessibilityElement: AXUIElement?
    private var focusedElementIdentity: AutoInputEditableFocusIdentity?
    private var callbackContext: CallbackContext?
    private var retainedCallbackPointer: UnsafeMutableRawPointer?
    private var focusedApplicationPollingTask: Task<Void, Never>?
    private var lifecycle = AutoInputObservationLifecycle()
    private var observationRetryPolicy = AutoInputObservationRetryPolicy()

    init(
        workspace: NSWorkspace = .shared,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        focusedProcessResolver: @escaping @Sendable () -> pid_t? = {
            AccessibilityAutoInputFocusObserver.systemWideFocusedProcessIdentifier()
        },
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.workspace = workspace
        self.notificationCenter = notificationCenter
        self.focusedProcessResolver = focusedProcessResolver
        self.now = now
    }

    func start() {
        guard activationObserver == nil else {
            if lifecycle.isRunning {
                inspectFocusedElement()
            }
            return
        }

        let generation = lifecycle.start()
        observationRetryPolicy.reset()

        activationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lifecycle.accepts(generation) else { return }
                self.observe(application, generation: generation)
            }
        }

        startFocusedApplicationPolling(generation: generation)
        if let application = workspace.frontmostApplication {
            observe(application, generation: generation)
        } else {
            publishNoEditableFocus()
        }
    }

    func stop() {
        lifecycle.stop()
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        focusedApplicationPollingTask?.cancel()
        focusedApplicationPollingTask = nil
        observationRetryPolicy.reset()
        stopObservingApplication()
        publishNoEditableFocus()
    }

    func refreshFocusedElement() {
        guard lifecycle.isRunning else { return }
        inspectFocusedElement()
    }

    private func startFocusedApplicationPolling(generation: Int) {
        focusedApplicationPollingTask?.cancel()
        let focusedProcessResolver = focusedProcessResolver
        focusedApplicationPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let processIdentifier = await Task.detached(priority: .utility) {
                    focusedProcessResolver()
                }.value
                guard !Task.isCancelled,
                      let self,
                      self.lifecycle.accepts(generation) else { return }
                if let processIdentifier {
                    _ = self.followSystemWideFocusedApplication(
                        processIdentifier: processIdentifier,
                        generation: generation
                    )
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    @discardableResult
    private func followSystemWideFocusedApplication(
        processIdentifier: pid_t,
        generation: Int
    ) -> Bool {
        guard lifecycle.accepts(generation),
              processIdentifier != observedApplicationProcessIdentifier,
              observationRetryPolicy.shouldAttempt(
                  processIdentifier: processIdentifier,
                  at: now()
              ),
              let application = NSRunningApplication(processIdentifier: processIdentifier)
        else { return false }

        observe(application, generation: generation)
        return true
    }

    private func observe(_ application: NSRunningApplication, generation: Int) {
        let processIdentifier = application.processIdentifier
        guard lifecycle.accepts(generation),
              observationRetryPolicy.shouldAttempt(
                  processIdentifier: processIdentifier,
                  at: now()
              ) else { return }
        stopObservingApplication()

        guard AXIsProcessTrusted() else {
            accessibilityWasInvalidated()
            return
        }
        var observer: AXObserver?
        let createStatus = AXObserverCreate(
            application.processIdentifier,
            Self.accessibilityCallback,
            &observer
        )
        guard createStatus == .success, let observer else {
            observationRetryPolicy.recordFailure(
                processIdentifier: processIdentifier,
                at: now()
            )
            handleAccessibilityFailure(createStatus)
            return
        }

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let context = CallbackContext(owner: self)
        let retainedPointer = Unmanaged.passRetained(context).toOpaque()
        let addStatus = AXObserverAddNotification(
            observer,
            applicationElement,
            kAXFocusedUIElementChangedNotification as CFString,
            retainedPointer
        )
        guard addStatus == .success else {
            Unmanaged<CallbackContext>.fromOpaque(retainedPointer).release()
            observationRetryPolicy.recordFailure(
                processIdentifier: processIdentifier,
                at: now()
            )
            handleAccessibilityFailure(addStatus)
            return
        }

        accessibilityObserver = observer
        observedApplication = applicationElement
        observedApplicationProcessIdentifier = application.processIdentifier
        observedApplicationBundleIdentifier = application.bundleIdentifier
        observedApplicationIsAccessory = application.activationPolicy == .accessory
        observationRetryPolicy.recordSuccess()
        callbackContext = context
        retainedCallbackPointer = retainedPointer
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        inspectFocusedElement()
    }

    private func stopObservingApplication() {
        callbackContext?.invalidate()

        if let observer = accessibilityObserver,
           let application = observedApplication {
            AXObserverRemoveNotification(
                observer,
                application,
                kAXFocusedUIElementChangedNotification as CFString
            )
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        accessibilityObserver = nil
        observedApplication = nil
        observedApplicationProcessIdentifier = nil
        observedApplicationBundleIdentifier = nil
        observedApplicationIsAccessory = false
        focusedAccessibilityElement = nil
        focusedElementIdentity = nil
        callbackContext = nil
        if let retainedCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(retainedCallbackPointer).release()
            self.retainedCallbackPointer = nil
        }
    }

    private func inspectFocusedElement() {
        guard let observedApplication else {
            publishNoEditableFocus()
            return
        }

        var focusedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            observedApplication,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard status == .success else {
            if status == .noValue || status == .attributeUnsupported {
                publishNoEditableFocus()
            } else {
                handleAccessibilityFailure(status)
            }
            return
        }
        guard let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            publishNoEditableFocus()
            return
        }

        let element = focusedValue as! AXUIElement
        guard Self.isEditable(
            element,
            applicationBundleIdentifier: observedApplicationBundleIdentifier
        ),
              let elementAccessibilityFrame = Self.elementAccessibilityFrame(of: element) else {
            publishNoEditableFocus()
            return
        }
        let preferredAccessibilityFrame = Self.preferredAccessibilityFrame(
            elementFrame: elementAccessibilityFrame,
            selectionFrame: Self.selectedTextBounds(of: element)
        )

        onEditableFocusChanged?(AutoInputEditableFocus(
            frame: Self.appKitFrame(
                fromAccessibilityFrame: preferredAccessibilityFrame,
                primaryScreenFrame: Self.primaryScreenFrame
            ),
            avoidanceFrame: Self.appKitFrame(
                fromAccessibilityFrame: elementAccessibilityFrame,
                primaryScreenFrame: Self.primaryScreenFrame
            ),
            applicationProcessIdentifier: observedApplicationProcessIdentifier,
            applicationBundleIdentifier: observedApplicationBundleIdentifier,
            isFromAccessoryApplication: observedApplicationIsAccessory,
            identity: identity(for: element)
        ))
    }

    private func identity(for element: AXUIElement) -> AutoInputEditableFocusIdentity {
        if let focusedAccessibilityElement,
           CFEqual(focusedAccessibilityElement, element),
           let focusedElementIdentity {
            return focusedElementIdentity
        }

        let identity = AutoInputEditableFocusIdentity()
        focusedAccessibilityElement = element
        focusedElementIdentity = identity
        return identity
    }

    private func publishNoEditableFocus() {
        focusedAccessibilityElement = nil
        focusedElementIdentity = nil
        onEditableFocusChanged?(nil)
    }

    private func handleAccessibilityFailure(_ status: AXError) {
        if status == .apiDisabled || status == .notImplemented || !AXIsProcessTrusted() {
            accessibilityWasInvalidated()
        } else {
            publishNoEditableFocus()
        }
    }

    private func accessibilityWasInvalidated() {
        stopObservingApplication()
        publishNoEditableFocus()
        onAccessibilityInvalidated?()
    }

    private nonisolated static let accessibilityCallback: AXObserverCallback = {
        _, _, notification, reference in
        guard notification as String == kAXFocusedUIElementChangedNotification as String,
              let reference else { return }

        let context = Unmanaged<CallbackContext>.fromOpaque(reference).takeUnretainedValue()
        context.withOwner { owner in
            DispatchQueue.main.async { [weak owner] in
                owner?.inspectFocusedElement()
            }
        }
    }

    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.mitchellh.ghostty",
    ]

    private static func isEditable(
        _ element: AXUIElement,
        applicationBundleIdentifier: String?
    ) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, from: element),
              isEditableRole(role),
              boolAttribute(kAXEnabledAttribute, from: element) != false else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )
        return acceptsFocusedInput(
            role: role,
            valueIsSettable: status == .success ? isSettable.boolValue : nil,
            applicationBundleIdentifier: applicationBundleIdentifier
        )
    }

    static func isEditableRole(_ role: String) -> Bool {
        role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || role == kAXComboBoxRole as String
    }

    static func acceptsFocusedInput(
        role: String,
        valueIsSettable: Bool?,
        applicationBundleIdentifier: String?
    ) -> Bool {
        guard isEditableRole(role) else { return false }
        if valueIsSettable == true { return true }
        guard valueIsSettable == false else { return false }

        // Terminal surfaces expose their screen buffer as a focused text area, but intentionally
        // do not allow Accessibility clients to replace that buffer through AXValue. Keep this
        // narrow so read-only text areas in ordinary apps do not trigger the HUD.
        return role == kAXTextAreaRole as String
            && applicationBundleIdentifier.map(terminalBundleIdentifiers.contains) == true
    }

    private static func elementAccessibilityFrame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    static func preferredAccessibilityFrame(
        elementFrame: CGRect,
        selectionFrame: CGRect?
    ) -> CGRect {
        guard var selectionFrame,
              selectionFrame.height > 0,
              selectionFrame.minX.isFinite,
              selectionFrame.minY.isFinite,
              selectionFrame.width.isFinite,
              selectionFrame.height.isFinite,
              !selectionFrame.isNull else {
            return elementFrame
        }
        selectionFrame.size.width = max(selectionFrame.width, 1)
        return selectionFrame
    }

    private static func selectedTextBounds(of element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }

        let axBounds = boundsValue as! AXValue
        guard AXValueGetType(axBounds) == .cgRect else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &bounds) else { return nil }
        return bounds
    }

    static func appKitFrame(
        fromAccessibilityFrame frame: CGRect,
        primaryScreenFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private nonisolated static func systemWideFocusedProcessIdentifier() -> pid_t? {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, 0.2)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedValue as! AXUIElement, &processIdentifier) == .success,
              processIdentifier > 0 else {
            return nil
        }
        return processIdentifier
    }

    private static var primaryScreenFrame: CGRect {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
            ?? NSScreen.screens.first?.frame
            ?? .zero
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        guard let value = axValueAttribute(attribute, from: element),
              AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        guard let value = axValueAttribute(attribute, from: element),
              AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func axValueAttribute(_ attribute: String, from element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
