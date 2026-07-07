import AppKit
import OSLog

// MARK: - MenuBarStatusItemExpandedInterface
//
// Runtime-only bridge to the `NSStatusItem.expandedInterfaceDelegate` channel.
// The app builds with older SDKs and a macOS 14.0 target, so every touchpoint
// goes through selector-based dispatch. When the API is absent, the status item
// stays on the normal button action route.

@MainActor
final class MenuBarStatusItemExpandedInterfaceAdapter: NSObject {
    static let delegateSetterSelectorName = "setExpandedInterfaceDelegate:"
    static let delegateGetterKey = "expandedInterfaceDelegate"
    static let sessionDidBeginSelectorName = "statusItem:didBeginExpandedInterfaceSession:"
    static let sessionDidEndSelectorName = "statusItemDidEndExpandedInterfaceSession:animated:"
    static let sessionCancelSelectorName = "cancel"

    var onSessionBegin: ((_ session: NSObject) -> Void)?
    var onSessionEnd: ((_ animated: Bool) -> Void)?

    static func isSupported(by item: NSStatusItem) -> Bool {
        item.responds(to: NSSelectorFromString(delegateSetterSelectorName))
    }

    /// Sets this adapter as the item's expanded-interface delegate and
    /// verifies the write by reading the property back. Returns true only
    /// when the read-back is this exact adapter. The caller must retain the
    /// adapter for as long as it is attached (the item's reference is weak).
    func attach(to item: NSStatusItem) -> Bool {
        guard Self.isSupported(by: item) else { return false }
        // perform(_:with:), not KVC: setValue(forKey:) with a wrong key
        // raises an ObjC exception Swift cannot catch.
        _ = item.perform(NSSelectorFromString(Self.delegateSetterSelectorName), with: self)

        // The read-back KVC key resolves through the property getter; a
        // responds check must guard it for the same uncatchable-exception
        // reason as above.
        guard item.responds(to: NSSelectorFromString(Self.delegateGetterKey)) else {
            rollBackAttach(on: item)
            AppLog.pluginHost.error(
                "Status item responds to the expanded-interface delegate setter but not the getter; attach aborted"
            )
            return false
        }
        guard (item.value(forKey: Self.delegateGetterKey) as? NSObject) === self else {
            rollBackAttach(on: item)
            AppLog.pluginHost.error(
                "Expanded-interface delegate read-back mismatch after attach; falling back to the action route"
            )
            return false
        }
        return true
    }

    /// Every failed attach must end with the delegate cleared: an attached
    /// delegate replaces the button action channel, so a false return that
    /// leaves it set would strand the status item with neither route.
    private func rollBackAttach(on item: NSStatusItem) {
        _ = item.perform(NSSelectorFromString(Self.delegateSetterSelectorName), with: nil)
    }

    /// Cancels an expanded-interface session. `cancel` triggers the didEnd
    /// callback synchronously on this same call stack; callers must have
    /// their state ready for that re-entry BEFORE calling this.
    static func cancel(session: NSObject) {
        let selector = NSSelectorFromString(sessionCancelSelectorName)
        guard session.responds(to: selector) else {
            // A session that cannot be cancelled stays active host-side and
            // leaves the status item inert; this must never be silent.
            AppLog.pluginHost.error(
                "Expanded-interface session \(String(describing: type(of: session)), privacy: .public) does not respond to cancel; session left active"
            )
            return
        }
        _ = session.perform(selector)
    }

    // MARK: ObjC delegate callbacks (host-invoked; selectors must match the
    // probed strings exactly)

    @objc(statusItem:didBeginExpandedInterfaceSession:)
    func statusItemDidBeginExpandedInterfaceSession(_ statusItem: NSStatusItem, session: NSObject) {
        onSessionBegin?(session)
    }

    @objc(statusItemDidEndExpandedInterfaceSession:animated:)
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        onSessionEnd?(animated)
    }
}

// MARK: - MenuBarExpandedSessionCoordinator

/// Pure expanded-session bookkeeping, free of AppKit so it is testable
/// headless. The close path clears state before calling `cancel` because AppKit
/// may synchronously call the did-end delegate callback.
@MainActor
final class MenuBarExpandedSessionCoordinator {
    private(set) var activeSession: NSObject?
    private var isHandlingSessionEnd = false

    func sessionDidBegin(_ session: NSObject) {
        activeSession = session
    }

    /// Single close gate. With an active session the close must go through
    /// `cancel(session)`: `activeSession` is cleared first because cancel
    /// may synchronously re-enter via didEnd. Without a session the request
    /// falls through to `directDismiss()`.
    func requestClose(cancel: (NSObject) -> Void, directDismiss: () -> Void) {
        guard let session = activeSession else {
            directDismiss()
            return
        }
        activeSession = nil
        cancel(session)
    }

    /// didEnd handler. The re-entry guard prevents a dismiss implementation
    /// from recursively routing back into this path.
    func sessionDidEnd(dismiss: () -> Void) {
        if isHandlingSessionEnd { return }
        isHandlingSessionEnd = true
        defer { isHandlingSessionEnd = false }
        activeSession = nil
        dismiss()
    }
}
