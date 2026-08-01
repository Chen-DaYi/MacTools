import Foundation
import OSLog

@MainActor
final class AutoInputController: ObservableObject {
    @Published private(set) var sources: [AutoInputSource] = []
    @Published private(set) var errorMessage: String?

    var onStateChange: (() -> Void)?

    private let store: AutoInputStore
    private let sourceController: AutoInputSourceControlling
    private let applicationMonitor: AutoInputApplicationMonitoring
    private let switchErrorMessage: () -> String
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "AutoInputPlugin"
    )

    private var currentApplication: AutoInputApplication?
    private var isStarted = false
    private var isInteractive = true
    private var operationGeneration = 0

    var currentSourceID: String? {
        sourceController.currentSourceID
    }

    init(
        store: AutoInputStore,
        sourceController: AutoInputSourceControlling,
        applicationMonitor: AutoInputApplicationMonitoring,
        switchErrorMessage: @escaping () -> String = { "无法切换输入法" }
    ) {
        self.store = store
        self.sourceController = sourceController
        self.applicationMonitor = applicationMonitor
        self.switchErrorMessage = switchErrorMessage
        self.sources = sourceController.sources
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
        sourceController.start()
        applicationMonitor.start()
        sourceController.refresh()
        sources = sourceController.sources

        if let application = applicationMonitor.frontmostApplication {
            handleApplicationActivated(application)
        }
    }

    func stop() {
        guard isStarted else { return }
        operationGeneration += 1
        sourceController.stop()
        applicationMonitor.stop()
        sourceController.onSourcesChanged = nil
        applicationMonitor.onApplicationActivated = nil
        isStarted = false
    }

    func setInteractive(_ value: Bool) {
        guard isInteractive != value else { return }
        isInteractive = value
        if value {
            sourceController.refresh()
            sources = sourceController.sources
            if let application = applicationMonitor.frontmostApplication {
                handleApplicationActivated(application)
            }
        } else {
            operationGeneration += 1
        }
    }

    func configurationDidChange() {
        if !store.isEnabled {
            operationGeneration += 1
            errorMessage = nil
            onStateChange?()
            return
        }

        guard isStarted, isInteractive,
              let application = applicationMonitor.frontmostApplication
        else {
            onStateChange?()
            return
        }
        handleApplicationActivated(application)
    }

    func refresh() {
        sourceController.refresh()
        sources = sourceController.sources
        onStateChange?()
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
        onStateChange?()
    }

    private func handleApplicationActivated(_ application: AutoInputApplication) {
        if let previousApplication = currentApplication,
           previousApplication.bundleIdentifier != application.bundleIdentifier {
            rememberCurrentSourceIfNeeded(for: previousApplication.bundleIdentifier)
        }
        currentApplication = application
        operationGeneration += 1
        let generation = operationGeneration

        guard isStarted, isInteractive, store.isEnabled else { return }
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
        guard isStarted, isInteractive, store.isEnabled, store.remembersLastInputSource,
              let bundleIdentifier = currentApplication?.bundleIdentifier
                ?? applicationMonitor.frontmostApplication?.bundleIdentifier,
              let sourceID = validCurrentSourceID
        else { return }

        store.remember(inputSourceID: sourceID, for: bundleIdentifier)
    }

    private func rememberCurrentSourceIfNeeded(for bundleIdentifier: String) {
        guard isStarted, isInteractive, store.isEnabled, store.remembersLastInputSource,
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
}
