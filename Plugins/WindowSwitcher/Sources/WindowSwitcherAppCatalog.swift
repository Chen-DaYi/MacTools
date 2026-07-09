import AppKit
import ApplicationServices
import Foundation

@MainActor
final class WindowSwitcherAppCatalog {
    var onChange: (() -> Void)?

    private struct WindowSnapshot {
        let element: AXUIElement
        let title: String
        let isMinimized: Bool
        let position: CGPoint
    }

    private static let axTimeout: Float = 0.2
    private static let minimumWindowSize = CGSize(width: 80, height: 60)

    private var mruIDs: [String] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else {
            refreshFrontmostApplication()
            return
        }

        refreshFrontmostApplication()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let activated = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let appID: String?
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               Self.isUserFacingApplication(app) {
                appID = Self.identifier(for: app)
            } else {
                appID = nil
            }

            MainActor.assumeIsolated {
                if let appID {
                    self?.recordActivationID(appID)
                }
                self?.onChange?()
            }
        }

        let launched = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onChange?()
            }
        }

        let terminated = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let appID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                .map(Self.identifier(for:))

            MainActor.assumeIsolated {
                if let appID {
                    self?.removeApplicationID(appID)
                }
                self?.onChange?()
            }
        }

        observers = [activated, launched, terminated]
    }

    func stop() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    func entries(sortMode: WindowSwitcherSortMode) -> [WindowSwitcherAppEntry] {
        refreshFrontmostApplication()
        let apps = NSWorkspace.shared.runningApplications.filter(Self.isUserFacingApplication)
        let ranks = Dictionary(uniqueKeysWithValues: mruIDs.enumerated().map { ($0.element, $0.offset) })

        return apps
            .sorted { lhs, rhs in
                switch sortMode {
                case .recentUse:
                    let lhsID = Self.identifier(for: lhs)
                    let rhsID = Self.identifier(for: rhs)
                    let lhsRank = ranks[lhsID] ?? Int.max
                    let rhsRank = ranks[rhsID] ?? Int.max

                    if lhsRank != rhsRank {
                        return lhsRank < rhsRank
                    }

                    let lhsLaunchDate = lhs.launchDate ?? .distantPast
                    let rhsLaunchDate = rhs.launchDate ?? .distantPast
                    if lhsLaunchDate != rhsLaunchDate {
                        return lhsLaunchDate > rhsLaunchDate
                    }
                case .fixed:
                    break
                }

                let lhsName = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
                let rhsName = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
                let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }

                let lhsBundleID = lhs.bundleIdentifier ?? ""
                let rhsBundleID = rhs.bundleIdentifier ?? ""
                if lhsBundleID != rhsBundleID {
                    return lhsBundleID < rhsBundleID
                }

                return lhs.processIdentifier < rhs.processIdentifier
            }
            .flatMap(Self.entries(for:))
    }

    func frontmostApplicationID() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              Self.isUserFacingApplication(app)
        else {
            return nil
        }

        return Self.identifier(for: app)
    }

    func activate(_ entry: WindowSwitcherAppEntry) {
        guard let app = NSRunningApplication(processIdentifier: entry.processIdentifier) else {
            return
        }

        app.unhide()
        app.activate(options: [])

        if let windowElement = entry.windowElement {
            if entry.isMinimized {
                AXUIElementSetAttributeValue(
                    windowElement,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse
                )
            }

            AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(windowElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        }

        recordActivationID(Self.identifier(for: entry))
        onChange?()
    }

    func quitApplication(_ entry: WindowSwitcherAppEntry) {
        guard let app = NSRunningApplication(processIdentifier: entry.processIdentifier),
              !app.isTerminated
        else {
            return
        }

        app.terminate()
        removeApplicationID(Self.identifier(for: entry))
        onChange?()
    }

    private func refreshFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return
        }

        recordActivation(app)
    }

    private func recordActivation(_ app: NSRunningApplication) {
        guard Self.isUserFacingApplication(app) else {
            return
        }

        recordActivationID(Self.identifier(for: app))
    }

    private func recordActivationID(_ id: String) {
        mruIDs.removeAll { $0 == id }
        mruIDs.insert(id, at: 0)
        mruIDs = Array(mruIDs.prefix(80))
    }

    private func removeApplicationID(_ id: String) {
        mruIDs.removeAll { $0 == id }
    }

    private static func entries(for app: NSRunningApplication) -> [WindowSwitcherAppEntry] {
        let appID = identifier(for: app)
        let windows = windows(for: app)
        guard !windows.isEmpty else {
            return [appEntry(for: app, id: appID)]
        }

        return windows.enumerated().map { index, window in
            WindowSwitcherAppEntry(
                id: "window:\(app.processIdentifier):\(index)",
                processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                appName: app.localizedName ?? "App",
                windowTitle: window.title,
                icon: app.icon,
                windowElement: window.element,
                isMinimized: window.isMinimized,
                shortcutToken: nil
            )
        }
    }

    private static func appEntry(for app: NSRunningApplication, id: String) -> WindowSwitcherAppEntry {
        WindowSwitcherAppEntry(
            id: id,
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? "App",
            windowTitle: nil,
            icon: app.icon,
            windowElement: nil,
            isMinimized: false,
            shortcutToken: nil
        )
    }

    private static func windows(for app: NSRunningApplication) -> [WindowSnapshot] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)

        var windows = copyWindows(from: appElement)
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            if let window = copyWindowAttribute(appElement, attribute as String) {
                appendUnique(window, to: &windows)
            }
        }

        return windows
            .compactMap(windowSnapshot(for:))
            .sorted { lhs, rhs in
                if lhs.isMinimized != rhs.isMinimized {
                    return !lhs.isMinimized
                }
                if lhs.position.y != rhs.position.y {
                    return lhs.position.y < rhs.position.y
                }
                if lhs.position.x != rhs.position.x {
                    return lhs.position.x < rhs.position.x
                }

                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private static func copyWindows(from appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success,
              let windows = value as? [AXUIElement]
        else {
            return []
        }

        return windows
    }

    private static func windowSnapshot(for window: AXUIElement) -> WindowSnapshot? {
        AXUIElementSetMessagingTimeout(window, axTimeout)

        let attributes = [
            kAXRoleAttribute,
            kAXSubroleAttribute,
            kAXTitleAttribute,
            kAXMinimizedAttribute,
            kAXPositionAttribute,
            kAXSizeAttribute,
        ] as CFArray
        var rawValues: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            window,
            attributes,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &rawValues
        )
        guard result == .success,
              let values = rawValues as? [Any],
              values.count == 6,
              isUserFacingWindow(role: values[0] as? String, subrole: values[1] as? String)
        else {
            return nil
        }

        let isMinimized = (values[3] as? Bool) ?? false
        let size = decodeSize(values[5])
        guard isMinimized || isSwitchableWindowSize(size) else {
            return nil
        }

        return WindowSnapshot(
            element: window,
            title: values[2] as? String ?? "",
            isMinimized: isMinimized,
            position: decodePoint(values[4])
        )
    }

    private static func isUserFacingWindow(role: String?, subrole: String?) -> Bool {
        guard role == (kAXWindowRole as String) else {
            return false
        }

        guard let subrole else {
            return true
        }

        return subrole == (kAXStandardWindowSubrole as String)
            || subrole == (kAXDialogSubrole as String)
            || subrole == "AXFullScreenWindow"
    }

    private static func isSwitchableWindowSize(_ size: CGSize) -> Bool {
        size.width >= minimumWindowSize.width && size.height >= minimumWindowSize.height
    }

    private static func decodePoint(_ value: Any) -> CGPoint {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return .zero
        }

        var point = CGPoint.zero
        AXValueGetValue(cfValue as! AXValue, .cgPoint, &point)
        return point
    }

    private static func decodeSize(_ value: Any) -> CGSize {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else {
            return .zero
        }

        var size = CGSize.zero
        AXValueGetValue(cfValue as! AXValue, .cgSize, &size)
        return size
    }

    private static func copyWindowAttribute(_ appElement: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func appendUnique(_ window: AXUIElement, to windows: inout [AXUIElement]) {
        guard !windows.contains(where: { CFEqual($0, window) }) else {
            return
        }

        windows.append(window)
    }

    nonisolated private static func identifier(for app: NSRunningApplication) -> String {
        if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }

        return "pid:\(app.processIdentifier)"
    }

    nonisolated private static func identifier(for entry: WindowSwitcherAppEntry) -> String {
        if let bundleIdentifier = entry.bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }

        return "pid:\(entry.processIdentifier)"
    }

    nonisolated private static func isUserFacingApplication(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular,
              !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return false
        }

        if let hostBundleID = Bundle.main.bundleIdentifier,
           app.bundleIdentifier == hostBundleID {
            return false
        }

        return true
    }
}
