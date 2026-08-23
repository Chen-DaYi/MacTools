import AppKit
import Foundation

/// Ends active AppKit text editing before MacTools orders another window or
/// changes the display topology.
///
/// AppKit's text-completion UI is hosted in a remote view. Ordering an unrelated
/// panel or waking a status-item window while that remote view is attached can
/// raise a ViewBridge exception. Plugins and the host share this boundary so a
/// presentation from any action surface follows the same lifecycle rule.
@MainActor
public enum PluginPresentationSafety {
    @MainActor
    public final class TextEditingRestoration {
        private weak var window: NSWindow?
        private weak var responder: NSResponder?

        fileprivate init(window: NSWindow?, responder: NSResponder?) {
            self.window = window
            self.responder = responder
        }

        public func restore() {
            guard let window, let responder else { return }
            window.makeFirstResponder(responder)
        }
    }

    /// Detaches AppKit's field editor before another window is ordered. When
    /// `restoringTextEditingIn` is supplied, call `restore()` on the returned
    /// value immediately after ordering a nonactivating auxiliary panel.
    @discardableResult
    public static func prepareForWindowOrdering(
        _ orderingWindow: NSWindow? = nil,
        windows: [NSWindow] = NSApplication.shared.windows,
        restoringTextEditingIn restorationWindow: NSWindow? = nil
    ) -> TextEditingRestoration? {
        var restoration: TextEditingRestoration?
        for window in windows where window !== orderingWindow {
            guard let fieldEditor = window.firstResponder as? NSTextView,
                  fieldEditor.isEditable else {
                continue
            }

            if window === restorationWindow {
                let responder = fieldEditor.isFieldEditor
                    ? fieldEditor.delegate as? NSResponder ?? fieldEditor
                    : fieldEditor
                restoration = TextEditingRestoration(window: window, responder: responder)
            }
            fieldEditor.inputContext?.discardMarkedText()
            window.makeFirstResponder(nil)
        }
        return restoration
    }
}

/// Keeps a C callback's context memory alive independently of its owner while allowing teardown
/// to atomically prevent any new callback from reaching that owner.
///
/// The registering object should pass-retain this box for the lifetime of the C registration,
/// call `invalidate()` before unregistering, and release the retained pointer only after the
/// system API confirms the registration has been removed.
public final class PluginCallbackContext<Owner: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var owner: Owner?

    public init(owner: Owner) {
        self.owner = owner
    }

    public func withOwner<Result>(_ body: (Owner) -> Result) -> Result? {
        let retainedOwner: Owner? = lock.withLock { owner }
        guard let retainedOwner else { return nil }
        return body(retainedOwner)
    }

    public func invalidate() {
        lock.withLock {
            owner = nil
        }
    }
}
