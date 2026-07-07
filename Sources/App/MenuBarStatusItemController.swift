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

    /// Expanded-interface session callbacks carry no NSEvent; Option held at
    /// session begin selects the right-click action.
    static func invocationForExpandedSession(
        swapped: Bool,
        liveModifierFlags: NSEvent.ModifierFlags
    ) -> MenuBarStatusItemInvocation {
        let isSecondary = liveModifierFlags.contains(.option)
        let primary: MenuBarStatusItemInvocation = swapped ? .featurePanel : .componentPanel
        let secondary: MenuBarStatusItemInvocation = swapped ? .componentPanel : .featurePanel
        return isSecondary ? secondary : primary
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
    // The status item holds its expanded-interface delegate weakly; the
    // controller must own the adapter strongly or callbacks silently stop.
    private let expandedInterfaceAdapter = MenuBarStatusItemExpandedInterfaceAdapter()
    private let expandedSessionCoordinator = MenuBarExpandedSessionCoordinator()
    private var animationTimer: DispatchSourceTimer?
    private var animationLoadSampleTimer: Timer?
    private let animationLoadMonitor = MenuBarIconAnimationLoadMonitor()
    private var animationFrames: [NSImage] = []
    private var animationFrameIndex = 0
    private var animationBaseFrameDuration: TimeInterval = 1.0 / MenuBarIconProcessing.animationFramesPerSecond
    private var animationSpeedMode: MenuBarIconAnimationSpeedMode = .manual
    private var manualAnimationSpeedMultiplier: Double = MenuBarIconAnimationSpeedPolicy.defaultManualMultiplier
    private var currentAnimationSystemLoad: MenuBarIconAnimationSystemLoad?

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
            animationLoadSampleTimer?.invalidate()
            if let appearanceObserver {
                DistributedNotificationCenter.default().removeObserver(appearanceObserver)
            }
            if let appTerminationObserver {
                NotificationCenter.default.removeObserver(appTerminationObserver)
            }
            if let statusItemWindowMoveObserver {
                NotificationCenter.default.removeObserver(statusItemWindowMoveObserver)
            }
        }
    }

    func dismissPanels() {
        panelPresenter.dismissPanels()
        removeDismissMonitorsIfNeeded()
    }

    /// Single close gate for user-driven dismissals. While an expanded
    /// interface session is active, close through `cancel()` so AppKit owns
    /// the session lifecycle. With no active session this is a plain
    /// `dismissPanels()`.
    private func requestPanelClose() {
        expandedSessionCoordinator.requestClose(
            cancel: { session in
                MenuBarStatusItemExpandedInterfaceAdapter.cancel(session: session)
            },
            directDismiss: { [weak self] in
                self?.dismissPanels()
            }
        )
    }

    /// Expanded-interface session begin. No NSEvent exists on this path, so
    /// the target panel comes from the click-behavior preference plus the live
    /// keyboard state.
    private func handleExpandedSessionBegin(_ session: NSObject) {
        if let activeSession = expandedSessionCoordinator.activeSession, activeSession !== session {
            MenuBarStatusItemExpandedInterfaceAdapter.cancel(session: activeSession)
        }
        expandedSessionCoordinator.sessionDidBegin(session)

        if panelPresenter.isAnyPanelShown {
            // A fresh session means the host considers nothing presented, so
            // settle stale panels before reopening.
            panelPresenter.dismissPanels()
        }

        let swapped = MenuBarClickBehaviorPreference.current().isSwapped
        let invocation = MenuBarStatusItemInvocation.invocationForExpandedSession(
            swapped: swapped,
            liveModifierFlags: NSEvent.modifierFlags
        )
        guard let button = statusItem.button else {
            // Nothing to anchor to. Leaving the session open would make the
            // item permanently inert (no further didBegin until it ends), so
            // close it instead of failing silently.
            AppLog.pluginHost.error(
                "Expanded session began but the status item button is unavailable; cancelling the session"
            )
            requestPanelClose()
            return
        }

        switch invocation {
        case .featurePanel:
            toggleFeaturePanel(relativeTo: button)
        case .componentPanel:
            toggleComponentPanel(relativeTo: button)
        }

        if !panelPresenter.isAnyPanelShown {
            // Presentation failed (the desync guard above closed everything,
            // so the toggle can only have tried to open). A session left open
            // with nothing shown keeps the item inert — no further didBegin
            // arrives until the session ends — so cancel it.
            AppLog.pluginHost.error(
                "Expanded session began but no panel was presented; cancelling the session"
            )
            requestPanelClose()
        }
    }

    /// Expanded-interface session end. Reached synchronously from `cancel()`
    /// inside `requestPanelClose()` (coordinator re-entry guard absorbs the
    /// loop) or directly should the host ever end a session itself.
    private func handleExpandedSessionEnd() {
        expandedSessionCoordinator.sessionDidEnd { [weak self] in
            self?.dismissPanels()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.toolTip = AppMetadata.appName

        // Expanded-interface route. The API is discovered at runtime so the
        // app can still build and run on older systems. When
        // attached, the session route replaces the button action channel;
        // failed attach falls back to the action route above.
        if MenuBarStatusItemExpandedInterfaceAdapter.isSupported(by: statusItem) {
            expandedInterfaceAdapter.onSessionBegin = { [weak self] session in
                self?.handleExpandedSessionBegin(session)
            }
            expandedInterfaceAdapter.onSessionEnd = { [weak self] _ in
                self?.handleExpandedSessionEnd()
            }
            let attached = expandedInterfaceAdapter.attach(to: statusItem)
            if !attached {
                AppLog.pluginHost.warning(
                    "Expanded-interface delegate attach failed; status item falls back to the action route"
                )
            }
        }

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
                // Route through the session gate: settings can be opened from
                // a panel while an expanded-interface session is still active.
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
        // Cancel any active expanded-interface session while its owning item
        // is still alive.
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
        animationLoadSampleTimer?.invalidate()
        animationLoadSampleTimer = nil
        animationFrames = []
        animationFrameIndex = 0
        animationBaseFrameDuration = payload.frameDuration
        animationSpeedMode = payload.speedMode
        manualAnimationSpeedMultiplier = payload.manualSpeedMultiplier
        currentAnimationSystemLoad = nil

        guard payload.isAnimated else {
            return
        }

        animationFrames = payload.animationFrames
        refreshAnimationLoadIfNeeded()
        scheduleAnimationTimer()
        scheduleAnimationLoadSamplingIfNeeded()
    }

    private func scheduleAnimationTimer() {
        animationTimer?.cancel()
        let frameDuration = effectiveAnimationFrameDuration()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + frameDuration,
            repeating: frameDuration,
            leeway: .milliseconds(Int((frameDuration * 500).rounded()))
        )
        timer.setEventHandler { [weak self] in
            self?.advanceAnimationFrame()
        }
        animationTimer = timer
        timer.resume()
    }

    private func scheduleAnimationLoadSamplingIfNeeded() {
        guard animationSpeedMode == .adaptiveSystemLoad else {
            return
        }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAnimationLoadIfNeeded()
                self?.scheduleAnimationTimer()
            }
        }
        timer.tolerance = 2
        animationLoadSampleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshAnimationLoadIfNeeded() {
        guard animationSpeedMode == .adaptiveSystemLoad else {
            return
        }

        currentAnimationSystemLoad = animationLoadMonitor.sample()
    }

    private func effectiveAnimationFrameDuration() -> TimeInterval {
        let multiplier = MenuBarIconAnimationSpeedPolicy.multiplier(
            mode: animationSpeedMode,
            manualMultiplier: manualAnimationSpeedMultiplier,
            systemLoad: currentAnimationSystemLoad
        )
        let normalizedMultiplier = max(multiplier, MenuBarIconAnimationSpeedPolicy.minimumMultiplier)
        return max(animationBaseFrameDuration / normalizedMultiplier, 0.04)
    }

    private func advanceAnimationFrame() {
        guard
            !animationFrames.isEmpty,
            let button = statusItem.button
        else {
            animationTimer?.cancel()
            animationTimer = nil
            animationLoadSampleTimer?.invalidate()
            animationLoadSampleTimer = nil
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

        if globalEventMonitor == nil {
            globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
                Task { @MainActor in
                    self?.requestPanelClose()
                }
            }
        }

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
