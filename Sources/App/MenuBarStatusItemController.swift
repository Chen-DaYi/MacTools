import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

enum MenuBarStatusItemInvocation: Equatable {
    case featurePanel
    case componentPanel

    static func invocation(
        for event: NSEvent?,
        swapped: Bool = false
    ) -> MenuBarStatusItemInvocation {
        // Option+left-click always triggers the right-click action.
        let isSecondary: Bool = {
            guard let event else { return false }
            let isLeftClick = event.type == .leftMouseDown || event.type == .leftMouseUp
            if isLeftClick, event.modifierFlags.contains(.option) {
                return true
            }
            return event.type == .rightMouseDown || event.type == .rightMouseUp
        }()

        let primary: MenuBarStatusItemInvocation = swapped ? .featurePanel : .componentPanel
        let secondary: MenuBarStatusItemInvocation = swapped ? .componentPanel : .featurePanel
        return isSecondary ? secondary : primary
    }
}

struct MenuBarGlobalMouseEvent: Equatable, Sendable {
    let screenX: Double
    let screenY: Double
}

enum MenuBarGlobalMouseEventPolicy {
    static func isStatusItemClick(
        for event: MenuBarGlobalMouseEvent,
        buttonFrame: NSRect?
    ) -> Bool {
        let location = NSPoint(x: event.screenX, y: event.screenY)
        guard let buttonFrame, !buttonFrame.isEmpty else { return false }
        return buttonFrame.contains(location)
    }
}

@MainActor
final class MenuBarStatusItemController: NSObject {
    private let pluginHost: PluginHost
    private let windowRouter: AppWindowRouter
    private let iconSettings: MenuBarIconSettings
    private var statusItem: NSStatusItem
    private var panelPresenter: MenuBarPanelPresenter!
    private var cancellables: Set<AnyCancellable> = []
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private var statusItemWindowMoveObserver: NSObjectProtocol?
    private var animationTimer: DispatchSourceTimer?
    private var animationFrames: [NSImage] = []
    private var animationFrameIndex = 0
    private var animationFrameDuration: TimeInterval = 1.0 / MenuBarIconProcessing.animationFramesPerSecond

    init(
        pluginHost: PluginHost,
        windowRouter: AppWindowRouter,
        iconSettings: MenuBarIconSettings
    ) {
        self.pluginHost = pluginHost
        self.windowRouter = windowRouter
        self.iconSettings = iconSettings
        MenuBarControlItemDefaults.prepareVisibleControlItem()
        self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
        self.statusItem.autosaveName = MenuBarControlItemDefaults.visibleAutosaveName
        super.init()
        panelPresenter = MenuBarPanelPresenter(
            pluginHost: pluginHost,
            onDismiss: { [weak self] in
                self?.requestPanelClose()
            },
            onOpenSettings: { [weak self] in
                self?.windowRouter.showSettings()
            },
            onPresentDiskCleanConfiguration: { [weak self] in
                self?.pluginHost.presentPluginConfiguration(pluginID: "disk-clean")
            },
            onPresentLaunchControlConfiguration: { [weak self] in
                self?.pluginHost.presentPluginConfiguration(pluginID: "launch-control")
            },
            onAllPanelsClosed: { [weak self] in
                self?.removeDismissMonitorsIfNeeded()
            }
        )
        observeStatusItemPositionPersistence()
        configureStatusItem()
        observePluginHost()
        observeIconSettings()
        updateStatusIcon()
        pluginHost.resetStatusItemPosition = { [weak self] in
            self?.resetStatusItemPosition()
        }
        pluginHost.statusItemButtonFrameProvider = { [weak self] in
            self?.statusItemButtonScreenRect()
        }
    }

    private func statusItemButtonScreenRect() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    deinit {
        MainActor.assumeIsolated {
            animationTimer?.cancel()
            if let appearanceObserver {
                DistributedNotificationCenter.default().removeObserver(appearanceObserver)
            }
            if let appTerminationObserver {
                NotificationCenter.default.removeObserver(appTerminationObserver)
            }
            if let statusItemWindowMoveObserver {
                NotificationCenter.default.removeObserver(statusItemWindowMoveObserver)
            }
            if let localEventMonitor {
                NSEvent.removeMonitor(localEventMonitor)
            }
            if let globalEventMonitor {
                NSEvent.removeMonitor(globalEventMonitor)
            }
            if let appActivationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
            }
        }
    }

    func dismissPanels() {
        panelPresenter.dismissPanels()
        removeDismissMonitorsIfNeeded()
    }

    private func requestPanelClose() {
        dismissPanels()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.toolTip = AppMetadata.appName

        // MacTools intentionally uses one target/action route on every OS.
        // AppKit's expanded-interface delegate models one undifferentiated
        // interface and carries no NSEvent, so it cannot represent the app's
        // distinct left- and right-click panels without a competing owner.
    }

    private func observePluginHost() {
        pluginHost.$hasActivePlugin
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        pluginHost.$settingsPresentationRequestCount
            .dropFirst()
            .sink { [weak self] _ in
                self?.windowRouter.showSettings()
                // Settings can be opened from a panel, so close any menu-bar
                // panel after routing to the settings window.
                self?.requestPanelClose()
            }
            .store(in: &cancellables)
    }

    private func observeIconSettings() {
        iconSettings.$settingsRevision
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusIcon()
            }
        }
    }

    private func updateStatusIcon() {
        let payload = iconSettings.imagePayload(for: statusItem.button?.effectiveAppearance)
        payload.image.isTemplate = payload.isTemplate

        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.image = payload.image
        statusItem.button?.imagePosition = .imageOnly
        configureAnimationIfNeeded(payload)
    }

    private func observeStatusItemPositionPersistence() {
        appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition()
        }

        statusItemWindowMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let movedWindowIdentifier = (notification.object as? NSWindow).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated {
                self?.snapshotVisibleControlItemPreferredPositionIfNeeded(
                    forMovedWindowIdentifier: movedWindowIdentifier
                )
            }
        }
    }

    private func snapshotVisibleControlItemPreferredPositionIfNeeded(
        forMovedWindowIdentifier movedWindowIdentifier: ObjectIdentifier?
    ) {
        guard
            let movedWindowIdentifier,
            let statusItemWindow = statusItem.button?.window,
            movedWindowIdentifier == ObjectIdentifier(statusItemWindow)
        else {
            return
        }

        MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition()
    }

    private func resetStatusItemPosition() {
        // Dismiss panels while their owning status item is still alive.
        requestPanelClose()

        let oldItem = statusItem
        NSStatusBar.system.removeStatusItem(oldItem)
        MenuBarControlItemDefaults.resetVisibleControlItemPosition()
        MenuBarControlItemDefaults.snapshotVisibleControlItemPreferredPosition()

        let newItem = NSStatusBar.system.statusItem(withLength: 0)
        newItem.autosaveName = MenuBarControlItemDefaults.visibleAutosaveName
        statusItem = newItem

        configureStatusItem()
        updateStatusIcon()
    }

    private func configureAnimationIfNeeded(_ payload: MenuBarIconImagePayload) {
        animationTimer?.cancel()
        animationTimer = nil
        animationFrames = []
        animationFrameIndex = 0
        animationFrameDuration = max(payload.frameDuration, 0.04)

        guard payload.isAnimated else {
            return
        }

        animationFrames = payload.animationFrames
        scheduleAnimationTimer()
    }

    private func scheduleAnimationTimer() {
        animationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + animationFrameDuration,
            repeating: animationFrameDuration,
            leeway: .milliseconds(Int((animationFrameDuration * 500).rounded()))
        )
        timer.setEventHandler { [weak self] in
            self?.advanceAnimationFrame()
        }
        animationTimer = timer
        timer.resume()
    }

    private func advanceAnimationFrame() {
        guard
            !animationFrames.isEmpty,
            let button = statusItem.button
        else {
            animationTimer?.cancel()
            animationTimer = nil
            return
        }

        animationFrameIndex = (animationFrameIndex + 1) % animationFrames.count
        button.image = animationFrames[animationFrameIndex]
        button.needsDisplay = true
    }

    @objc
    private func handleStatusItemAction(_ sender: NSStatusBarButton) {
        // Read the preference live on each click so a settings change takes
        // effect immediately without re-observing.
        let swapped = MenuBarClickBehaviorPreference.current().isSwapped
        switch MenuBarStatusItemInvocation.invocation(for: NSApp.currentEvent, swapped: swapped) {
        case .featurePanel:
            toggleFeaturePanel(relativeTo: sender)
        case .componentPanel:
            toggleComponentPanel(relativeTo: sender)
        }
    }

    private func toggleFeaturePanel(relativeTo button: NSStatusBarButton) {
        panelPresenter.toggleFeaturePanel(relativeTo: button)
        handlePresentationResult()
    }

    private func toggleComponentPanel(relativeTo button: NSStatusBarButton) {
        panelPresenter.toggleComponentPanel(relativeTo: button)
        handlePresentationResult()
    }

    private func handlePresentationResult() {
        guard panelPresenter.isAnyPanelShown else {
            return
        }

        installDismissMonitorsIfNeeded()
    }

    private func installDismissMonitorsIfNeeded() {
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]

        if localEventMonitor == nil {
            localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
                self?.handleLocalMouseEvent(event) ?? event
            }
        }

        installGlobalMouseMonitorIfNeeded()

        if appActivationObserver == nil {
            appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard !Self.isCurrentApplicationActivationNotification(notification) else {
                    return
                }

                Task { @MainActor in
                    self?.requestPanelClose()
                }
            }
        }
    }

    private func removeDismissMonitorsIfNeeded() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }

        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func handleLocalMouseEvent(_ event: NSEvent) -> NSEvent {
        guard panelPresenter.isAnyPanelShown else {
            removeDismissMonitorsIfNeeded()
            return event
        }

        guard !isEventInsidePresentedPanel(event), !isEventInsideStatusButton(event) else {
            return event
        }

        requestPanelClose()
        return event
    }

    private func installGlobalMouseMonitorIfNeeded() {
        guard globalEventMonitor == nil else { return }
        let mouseEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            let location = event.locationInWindow
            let snapshot = MenuBarGlobalMouseEvent(
                screenX: Double(location.x),
                screenY: Double(location.y)
            )
            Task { @MainActor [weak self] in
                self?.handleGlobalMouseEvent(snapshot)
            }
        }
    }

    private func handleGlobalMouseEvent(_ event: MenuBarGlobalMouseEvent) {
        if MenuBarGlobalMouseEventPolicy.isStatusItemClick(
            for: event,
            buttonFrame: statusItemButtonScreenRect()
        ) {
            return
        }

        guard panelPresenter.isAnyPanelShown else { return }
        requestPanelClose()
    }

    private func isEventInsidePresentedPanel(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window else {
            return false
        }

        return panelPresenter.containsPresentedWindow(eventWindow)
    }

    private func isEventInsideStatusButton(_ event: NSEvent) -> Bool {
        guard
            let button = statusItem.button,
            event.window === button.window
        else {
            return false
        }

        let pointInButton = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(pointInButton)
    }

    nonisolated private static func isCurrentApplicationActivationNotification(_ notification: Notification) -> Bool {
        guard
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            return false
        }

        return activatedApplication.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

}
