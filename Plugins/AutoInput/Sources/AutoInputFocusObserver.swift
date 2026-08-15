import AppKit
import ApplicationServices
import Foundation
import MacToolsPluginKit

struct AutoInputEditableFocus: Equatable, Sendable {
    let frame: CGRect
}

@MainActor
protocol AutoInputFocusObserving: AnyObject {
    var onEditableFocusChanged: ((AutoInputEditableFocus?) -> Void)? { get set }
    var onAccessibilityInvalidated: (() -> Void)? { get set }

    func start()
    func stop()
}

@MainActor
protocol AutoInputAccessibilityChecking: AnyObject {
    var isTrusted: Bool { get }

    @discardableResult
    func requestTrust(prompt: Bool) -> Bool
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
    private let ignoredProcessIdentifier: pid_t

    private var activationObserver: NSObjectProtocol?
    private var accessibilityObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var callbackContext: CallbackContext?
    private var retainedCallbackPointer: UnsafeMutableRawPointer?

    init(
        workspace: NSWorkspace = .shared,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        ignoredProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.workspace = workspace
        self.notificationCenter = notificationCenter
        self.ignoredProcessIdentifier = ignoredProcessIdentifier
    }

    func start() {
        guard activationObserver == nil else {
            inspectFocusedElement()
            return
        }

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
                self?.observe(application)
            }
        }

        if let application = workspace.frontmostApplication {
            observe(application)
        } else {
            onEditableFocusChanged?(nil)
        }
    }

    func stop() {
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        stopObservingApplication()
        onEditableFocusChanged?(nil)
    }

    private func observe(_ application: NSRunningApplication) {
        stopObservingApplication()

        guard AXIsProcessTrusted() else {
            accessibilityWasInvalidated()
            return
        }
        guard application.processIdentifier != ignoredProcessIdentifier else {
            onEditableFocusChanged?(nil)
            return
        }

        var observer: AXObserver?
        let createStatus = AXObserverCreate(
            application.processIdentifier,
            Self.accessibilityCallback,
            &observer
        )
        guard createStatus == .success, let observer else {
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
            handleAccessibilityFailure(addStatus)
            return
        }

        accessibilityObserver = observer
        observedApplication = applicationElement
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
        callbackContext = nil
        if let retainedCallbackPointer {
            Unmanaged<CallbackContext>.fromOpaque(retainedCallbackPointer).release()
            self.retainedCallbackPointer = nil
        }
    }

    private func inspectFocusedElement() {
        guard let observedApplication else {
            onEditableFocusChanged?(nil)
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
                onEditableFocusChanged?(nil)
            } else {
                handleAccessibilityFailure(status)
            }
            return
        }
        guard let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            onEditableFocusChanged?(nil)
            return
        }

        let element = focusedValue as! AXUIElement
        guard Self.isEditable(element),
              let accessibilityFrame = Self.accessibilityFrame(of: element) else {
            onEditableFocusChanged?(nil)
            return
        }

        onEditableFocusChanged?(AutoInputEditableFocus(
            frame: Self.appKitFrame(
                fromAccessibilityFrame: accessibilityFrame,
                primaryScreenFrame: Self.primaryScreenFrame
            )
        ))
    }

    private func handleAccessibilityFailure(_ status: AXError) {
        if status == .apiDisabled || status == .notImplemented || !AXIsProcessTrusted() {
            accessibilityWasInvalidated()
        } else {
            onEditableFocusChanged?(nil)
        }
    }

    private func accessibilityWasInvalidated() {
        stopObservingApplication()
        onEditableFocusChanged?(nil)
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

    private static func isEditable(_ element: AXUIElement) -> Bool {
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
            valueIsSettable: status == .success ? isSettable.boolValue : nil
        )
    }

    static func isEditableRole(_ role: String) -> Bool {
        role == kAXTextFieldRole as String
            || role == kAXTextAreaRole as String
            || role == kAXComboBoxRole as String
    }

    static func acceptsFocusedInput(role: String, valueIsSettable: Bool?) -> Bool {
        guard isEditableRole(role) else { return false }

        // Terminal surfaces expose their screen buffer as a focused text area, but intentionally
        // do not allow Accessibility clients to replace that buffer through AXValue.
        if role == kAXTextAreaRole as String {
            return true
        }
        return valueIsSettable != false
    }

    private static func accessibilityFrame(of element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
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
