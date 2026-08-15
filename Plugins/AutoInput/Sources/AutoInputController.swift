import AppKit
import Foundation
import OSLog

struct AutoInputHUDTriggerPolicy {
    private var applicationID: String?
    private var sourceID: String?
    private var hasPendingPresentation = false

    init(currentSourceID: String?) {
        sourceID = currentSourceID
    }

    mutating func applicationDidActivate(_ applicationID: String) -> Bool {
        guard self.applicationID != applicationID else { return false }
        self.applicationID = applicationID
        hasPendingPresentation = true
        return true
    }

    mutating func inputSourceDidChange(to sourceID: String?) -> Bool {
        guard self.sourceID != sourceID else { return false }
        self.sourceID = sourceID
        hasPendingPresentation = true
        return true
    }

    mutating func consumePresentation() -> Bool {
        guard hasPendingPresentation else { return false }
        hasPendingPresentation = false
        return true
    }

    mutating func reset(currentSourceID: String?) {
        applicationID = nil
        sourceID = currentSourceID
        hasPendingPresentation = false
    }
}

@MainActor
final class AutoInputController: ObservableObject {
    @Published private(set) var sources: [AutoInputSource] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isAccessibilityGranted: Bool

    var onStateChange: (() -> Void)?

    private let store: AutoInputStore
    private let sourceController: AutoInputSourceControlling
    private let applicationMonitor: AutoInputApplicationMonitoring
    private let focusObserver: AutoInputFocusObserving
    private let hudPresenter: InputSourceHUDPresenting
    private let hudLabelResolver: InputSourceHUDLabelResolving
    private let accessibilityCheck: AutoInputAccessibilityChecking
    private let applicationNotificationCenter: NotificationCenter
    private let switchErrorMessage: () -> String
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "AutoInputPlugin"
    )

    private var currentApplication: AutoInputApplication?
    private var focusedElement: AutoInputEditableFocus?
    private var isStarted = false
    private var isInteractive = true
    private var isSourceMonitoringActive = false
    private var isApplicationMonitoringActive = false
    private var isFocusMonitoringActive = false
    private var applicationActivationObserver: NSObjectProtocol?
    private var operationGeneration = 0
    private var hudTriggerPolicy: AutoInputHUDTriggerPolicy

    var currentSourceID: String? {
        sourceController.currentSourceID
    }

    init(
        store: AutoInputStore,
        sourceController: AutoInputSourceControlling,
        applicationMonitor: AutoInputApplicationMonitoring,
        focusObserver: AutoInputFocusObserving = AccessibilityAutoInputFocusObserver(),
        hudPresenter: InputSourceHUDPresenting = InputSourceHUDController(),
        hudLabelResolver: InputSourceHUDLabelResolving = StandardInputSourceHUDLabelResolver(),
        accessibilityCheck: AutoInputAccessibilityChecking = SystemAutoInputAccessibilityCheck(),
        applicationNotificationCenter: NotificationCenter = .default,
        switchErrorMessage: @escaping () -> String = { "无法切换输入法" }
    ) {
        self.store = store
        self.sourceController = sourceController
        self.applicationMonitor = applicationMonitor
        self.focusObserver = focusObserver
        self.hudPresenter = hudPresenter
        self.hudLabelResolver = hudLabelResolver
        self.accessibilityCheck = accessibilityCheck
        self.applicationNotificationCenter = applicationNotificationCenter
        self.switchErrorMessage = switchErrorMessage
        self.sources = sourceController.sources
        self.isAccessibilityGranted = accessibilityCheck.isTrusted
        self.hudTriggerPolicy = AutoInputHUDTriggerPolicy(
            currentSourceID: sourceController.currentSourceID
        )
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        sourceController.onSourcesChanged = { [weak self] in
            self?.handleSourcesChanged()
        }
        applicationMonitor.onApplicationActivated = { [weak self] application in
            self?.handleApplicationActivated(application)
        }
        focusObserver.onEditableFocusChanged = { [weak self] focus in
            self?.handleEditableFocusChanged(focus)
        }
        focusObserver.onAccessibilityInvalidated = { [weak self] in
            self?.handleAccessibilityInvalidated()
        }
        refreshAccessibilityPermission(prompt: false)
        reconcilePermissionObservation()
        reconcileActiveServices()
    }

    func stop() {
        guard isStarted else { return }
        operationGeneration += 1
        stopFocusMonitoring()
        stopApplicationMonitoring()
        stopSourceMonitoring()
        hudPresenter.dismiss()
        hudTriggerPolicy.reset(currentSourceID: sourceController.currentSourceID)
        sourceController.onSourcesChanged = nil
        applicationMonitor.onApplicationActivated = nil
        focusObserver.onEditableFocusChanged = nil
        focusObserver.onAccessibilityInvalidated = nil
        removeApplicationActivationObserver()
        isStarted = false
    }

    func setInteractive(_ value: Bool) {
        guard isInteractive != value else { return }
        isInteractive = value
        reconcilePermissionObservation()
        if value {
            reconcileActiveServices()
        } else {
            operationGeneration += 1
            reconcileActiveServices()
        }
    }

    func configurationDidChange(promptForAccessibility: Bool = false) {
        if !store.isAutoSwitchEnabled {
            operationGeneration += 1
            errorMessage = nil
        }

        refreshAccessibilityPermission(prompt: promptForAccessibility && store.isInputHUDEnabled)
        reconcilePermissionObservation()
        reconcileActiveServices()
        onStateChange?()
    }

    func refresh() {
        refreshAccessibilityPermission(prompt: false)
        reconcilePermissionObservation()
        sourceController.refresh()
        sources = sourceController.sources
        reconcileActiveServices()
        onStateChange?()
    }

    func settingsVisibilityDidChange(_ isVisible: Bool) {
        guard isVisible else { return }
        sourceController.refresh()
        sources = sourceController.sources
        onStateChange?()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        refreshAccessibilityPermission(prompt: true)
        reconcileActiveServices()
        onStateChange?()
        return isAccessibilityGranted
    }

    func target(for bundleIdentifier: String) -> AutoInputTarget? {
        let availableSources = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        if let rule = store.rule(for: bundleIdentifier),
           let source = availableSources[rule.inputSourceID] {
            return AutoInputTarget(source: source, reason: .fixedRule)
        }
        if store.remembersLastInputSource,
           let rememberedID = store.rememberedInputSourceID(for: bundleIdentifier),
           let source = availableSources[rememberedID] {
            return AutoInputTarget(source: source, reason: .remembered)
        }
        return nil
    }

    private func handleSourcesChanged() {
        sources = sourceController.sources
        rememberCurrentSourceIfNeeded()
        let sourceChanged = hudTriggerPolicy.inputSourceDidChange(
            to: sourceController.currentSourceID
        )
        if store.isInputHUDEnabled && !accessibilityCheck.isTrusted {
            handleAccessibilityInvalidated()
            return
        }
        if sourceChanged {
            refreshPendingHUDFromAccessibility()
        }
        onStateChange?()
    }

    private func handleApplicationActivated(_ application: AutoInputApplication) {
        let applicationChanged = hudTriggerPolicy.applicationDidActivate(
            application.bundleIdentifier
        )
        if hudPermissionObservationActive && !isAccessibilityGranted {
            let wasGranted = isAccessibilityGranted
            refreshAccessibilityPermission(prompt: false)
            if !wasGranted && isAccessibilityGranted {
                setSourceMonitoring(active: autoSwitchActive || hudActive)
                setFocusMonitoring(active: hudActive)
            }
        }
        if applicationChanged && hudActive && !focusBelongs(to: application) {
            focusedElement = nil
            hudPresenter.dismiss()
        }
        if let previousApplication = currentApplication,
           previousApplication.bundleIdentifier != application.bundleIdentifier {
            rememberCurrentSourceIfNeeded(for: previousApplication.bundleIdentifier)
        }
        currentApplication = application
        operationGeneration += 1
        let generation = operationGeneration
        var shouldRefreshHUD = applicationChanged
        defer {
            if shouldRefreshHUD {
                refreshPendingHUDFromAccessibility()
            }
        }

        guard autoSwitchActive else { return }
        guard let target = target(for: application.bundleIdentifier) else {
            clearErrorIfNeeded()
            return
        }
        guard target.source.id != sourceController.currentSourceID else {
            clearErrorIfNeeded()
            return
        }

        do {
            try sourceController.selectSource(id: target.source.id)
            guard generation == operationGeneration,
                  currentApplication?.bundleIdentifier == application.bundleIdentifier
            else { return }

            shouldRefreshHUD = hudTriggerPolicy.inputSourceDidChange(to: target.source.id)
                || shouldRefreshHUD
            errorMessage = nil
            if store.remembersLastInputSource {
                store.remember(inputSourceID: target.source.id, for: application.bundleIdentifier)
            }
            onStateChange?()
        } catch {
            guard generation == operationGeneration else { return }
            logger.error("Failed to select input source: \(error.localizedDescription, privacy: .public)")
            errorMessage = switchErrorMessage()
            onStateChange?()
        }
    }

    private func rememberCurrentSourceIfNeeded() {
        guard autoSwitchActive, store.remembersLastInputSource,
              let bundleIdentifier = currentApplication?.bundleIdentifier
                ?? applicationMonitor.frontmostApplication?.bundleIdentifier,
              let sourceID = validCurrentSourceID
        else { return }

        store.remember(inputSourceID: sourceID, for: bundleIdentifier)
    }

    private func rememberCurrentSourceIfNeeded(for bundleIdentifier: String) {
        guard autoSwitchActive, store.remembersLastInputSource,
              let sourceID = validCurrentSourceID
        else { return }

        store.remember(inputSourceID: sourceID, for: bundleIdentifier)
    }

    private var validCurrentSourceID: String? {
        guard let sourceID = sourceController.currentSourceID,
              sources.contains(where: { $0.id == sourceID })
        else { return nil }
        return sourceID
    }

    private func clearErrorIfNeeded() {
        guard errorMessage != nil else { return }
        errorMessage = nil
        onStateChange?()
    }

    private var autoSwitchActive: Bool {
        isStarted && isInteractive && store.isAutoSwitchEnabled
    }

    private var hudActive: Bool {
        isStarted && isInteractive && store.isInputHUDEnabled && isAccessibilityGranted
    }

    private var hudPermissionObservationActive: Bool {
        isStarted && isInteractive && store.isInputHUDEnabled
    }

    private func reconcileActiveServices() {
        let shouldMonitorSources = autoSwitchActive || hudActive
        let shouldMonitorApplications = autoSwitchActive || hudPermissionObservationActive
        setSourceMonitoring(active: shouldMonitorSources)
        setApplicationMonitoring(active: shouldMonitorApplications)

        if shouldMonitorApplications,
           let application = applicationMonitor.frontmostApplication {
            handleApplicationActivated(application)
        }
        setFocusMonitoring(active: hudActive)
        if !hudActive {
            focusedElement = nil
            hudPresenter.dismiss()
            hudTriggerPolicy.reset(currentSourceID: sourceController.currentSourceID)
        }
    }

    private func setSourceMonitoring(active: Bool) {
        guard active != isSourceMonitoringActive else { return }
        isSourceMonitoringActive = active
        if active {
            sourceController.start()
            sourceController.refresh()
            sources = sourceController.sources
        } else {
            sourceController.stop()
        }
    }

    private func setApplicationMonitoring(active: Bool) {
        guard active != isApplicationMonitoringActive else { return }
        isApplicationMonitoringActive = active
        if active {
            applicationMonitor.start()
        } else {
            applicationMonitor.stop()
            currentApplication = nil
        }
    }

    private func setFocusMonitoring(active: Bool) {
        guard active != isFocusMonitoringActive else { return }
        if active {
            isFocusMonitoringActive = true
            focusObserver.start()
        } else {
            stopFocusMonitoring()
        }
    }

    private func stopSourceMonitoring() {
        guard isSourceMonitoringActive else { return }
        sourceController.stop()
        isSourceMonitoringActive = false
    }

    private func stopApplicationMonitoring() {
        guard isApplicationMonitoringActive else { return }
        applicationMonitor.stop()
        isApplicationMonitoringActive = false
        currentApplication = nil
    }

    private func stopFocusMonitoring() {
        guard isFocusMonitoringActive else { return }
        focusObserver.stop()
        isFocusMonitoringActive = false
        focusedElement = nil
        hudPresenter.dismiss()
    }

    private func handleEditableFocusChanged(_ focus: AutoInputEditableFocus?) {
        guard hudActive else {
            focusedElement = nil
            hudPresenter.dismiss()
            return
        }
        guard accessibilityCheck.isTrusted else {
            handleAccessibilityInvalidated()
            return
        }

        focusedElement = focus
        guard focus != nil else {
            hudPresenter.dismiss()
            return
        }
        showPendingHUDForCurrentFocus()
    }

    private func showPendingHUDForCurrentFocus() {
        guard hudActive,
              let focusedElement,
              focusBelongsToCurrentApplication(focusedElement),
              let sourceID = sourceController.currentSourceID,
              let source = sources.first(where: { $0.id == sourceID }),
              hudTriggerPolicy.consumePresentation()
        else { return }
        hudPresenter.show(
            label: hudLabelResolver.displayLabel(for: source),
            near: focusedElement.frame,
            configuration: AutoInputHUDConfiguration(
                size: store.inputHUDSize,
                position: store.inputHUDPosition
            )
        )
    }

    private func refreshPendingHUDFromAccessibility() {
        guard hudActive, isFocusMonitoringActive else { return }
        focusObserver.refreshFocusedElement()
    }

    private func focusBelongs(to application: AutoInputApplication) -> Bool {
        guard let focusedElement else { return false }
        guard let focusProcessIdentifier = focusedElement.applicationProcessIdentifier,
              let applicationProcessIdentifier = application.processIdentifier else {
            return true
        }
        return focusProcessIdentifier == applicationProcessIdentifier
    }

    private func focusBelongsToCurrentApplication(_ focus: AutoInputEditableFocus) -> Bool {
        guard let currentApplication else { return false }
        guard let focusProcessIdentifier = focus.applicationProcessIdentifier,
              let applicationProcessIdentifier = currentApplication.processIdentifier else {
            return true
        }
        return focusProcessIdentifier == applicationProcessIdentifier
    }

    private func refreshAccessibilityPermission(prompt: Bool) {
        let previous = isAccessibilityGranted
        isAccessibilityGranted = prompt
            ? accessibilityCheck.requestTrust(prompt: true)
            : accessibilityCheck.isTrusted
        if previous != isAccessibilityGranted {
            onStateChange?()
        }
    }

    private func handleAccessibilityInvalidated() {
        isAccessibilityGranted = false
        hudPresenter.dismiss()
        hudTriggerPolicy.reset(currentSourceID: sourceController.currentSourceID)
        reconcileActiveServices()
        onStateChange?()
    }

    private func reconcilePermissionObservation() {
        if hudPermissionObservationActive {
            observeApplicationActivation()
        } else {
            removeApplicationActivationObserver()
        }
    }

    private func observeApplicationActivation() {
        guard applicationActivationObserver == nil else { return }
        applicationActivationObserver = applicationNotificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAccessibilityPermission(prompt: false)
                self.reconcileActiveServices()
            }
        }
    }

    private func removeApplicationActivationObserver() {
        guard let applicationActivationObserver else { return }
        applicationNotificationCenter.removeObserver(applicationActivationObserver)
        self.applicationActivationObserver = nil
    }
}
