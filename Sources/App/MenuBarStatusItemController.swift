import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

enum MenuBarStatusItemInvocation: Equatable {
    case featurePanel
    case componentPanel

    static func invocation(for event: NSEvent?) -> MenuBarStatusItemInvocation {
        guard let event else {
            return .componentPanel
        }

        if event.type == .rightMouseDown
            || event.type == .rightMouseUp
            || event.modifierFlags.contains(.control) {
            return .featurePanel
        }

        return .componentPanel
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
        MenuBarControlItemDefaults.recoverVisibleAndHiddenControlItemDefaultPositions()
        self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
        self.statusItem.autosaveName = MenuBarControlItemDefaults.visibleAutosaveName
        super.init()
        panelPresenter = MenuBarPanelPresenter(
            pluginHost: pluginHost,
            onDismiss: { [weak self] in
                self?.dismissPanels()
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
        }
    }

    func dismissPanels() {
        panelPresenter.dismissPanels()
        removeDismissMonitorsIfNeeded()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.toolTip = AppMetadata.appName
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
                self?.dismissPanels()
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

    private func resetStatusItemPosition() {
        dismissPanels()
        MenuBarControlItemDefaults.recoverVisibleAndHiddenControlItemDefaultPositions()

        let oldItem = statusItem
        NSStatusBar.system.removeStatusItem(oldItem)
        MenuBarControlItemDefaults.recoverVisibleAndHiddenControlItemDefaultPositions()

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
        switch MenuBarStatusItemInvocation.invocation(for: NSApp.currentEvent) {
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
                    self?.dismissPanels()
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
                    self?.dismissPanels()
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

        dismissPanels()
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
