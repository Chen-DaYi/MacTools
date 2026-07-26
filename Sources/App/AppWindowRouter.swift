import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

enum MacToolsLocalKeyboardCommand: Equatable {
    case showSettings
    case focusSearch

    static func resolve(for event: NSEvent) -> MacToolsLocalKeyboardCommand? {
        guard event.type == .keyDown else {
            return nil
        }

        let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(relevantModifiers) == .command else {
            return nil
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case ",":
            return .showSettings
        case "f":
            return .focusSearch
        default:
            return nil
        }
    }
}

@MainActor
final class MacToolsCommandWindow: NSWindow {
    var onLocalKeyboardCommand: ((MacToolsLocalKeyboardCommand) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard
            let command = MacToolsLocalKeyboardCommand.resolve(for: event),
            let onLocalKeyboardCommand
        else {
            return super.performKeyEquivalent(with: event)
        }

        onLocalKeyboardCommand(command)
        return true
    }
}

enum SettingsPanelPresentationTarget {
    case dashboard
    case featurePanel
}

struct SettingsPanelPresentationActions {
    var showDashboard: () -> Void = {}
    var showFeaturePanel: () -> Void = {}

    func present(_ target: SettingsPanelPresentationTarget) {
        switch target {
        case .dashboard:
            showDashboard()
        case .featurePanel:
            showFeaturePanel()
        }
    }
}

enum SettingsWindowLayout {
    static let defaultContentSize = NSSize(width: 1040, height: 720)
    static let minimumContentSize = NSSize(width: 860, height: 560)
}

@MainActor
final class AppWindowRouter: NSObject, NSWindowDelegate {
    private let pluginHost: PluginHost
    private let appUpdater: AppUpdater
    private let menuBarIconSettings: MenuBarIconSettings
    private let menuBarIconGallery: MenuBarIconGalleryLibrary
    private let launchAtLoginController: LaunchAtLoginController
    private(set) var settingsWindow: NSWindow?
    private(set) var settingsNavigationCoordinator: SettingsNavigationCoordinator?
    private var runtimeLocaleCancellable: AnyCancellable?
    private var panelPresentationActions = SettingsPanelPresentationActions()
    private var onProgrammaticSettingsPresentation: () -> Void = {}

    static var settingsWindowTitle: String {
        AppL10n.settings("settings.window.title", defaultValue: "设置")
    }

    init(
        pluginHost: PluginHost,
        appUpdater: AppUpdater,
        menuBarIconSettings: MenuBarIconSettings,
        menuBarIconGallery: MenuBarIconGalleryLibrary,
        launchAtLoginController: LaunchAtLoginController
    ) {
        self.pluginHost = pluginHost
        self.appUpdater = appUpdater
        self.menuBarIconSettings = menuBarIconSettings
        self.menuBarIconGallery = menuBarIconGallery
        self.launchAtLoginController = launchAtLoginController
        super.init()
        runtimeLocaleCancellable = PluginRuntimeLocalization.source.$revision
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.settingsWindow?.title = Self.settingsWindowTitle
                }
            }
    }

    isolated deinit {
        runtimeLocaleCancellable?.cancel()
    }

    func showSettings() {
        presentSettings(.settings)
    }

    func setPanelPresentationActions(
        showDashboard: @escaping () -> Void,
        showFeaturePanel: @escaping () -> Void
    ) {
        panelPresentationActions = SettingsPanelPresentationActions(
            showDashboard: showDashboard,
            showFeaturePanel: showFeaturePanel
        )
    }

    func setProgrammaticSettingsPresentationAction(_ action: @escaping () -> Void) {
        onProgrammaticSettingsPresentation = action
    }

    private func show(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let navigationCoordinator = SettingsNavigationCoordinator(pluginHost: pluginHost)
        let window = MacToolsCommandWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowLayout.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.settingsWindowTitle
        let hostingView = NSHostingView(
            rootView: SettingsView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator,
                appUpdater: appUpdater,
                menuBarIconSettings: menuBarIconSettings,
                menuBarIconGallery: menuBarIconGallery,
                launchAtLoginController: launchAtLoginController,
                showDashboard: { [weak self] in
                    self?.panelPresentationActions.present(.dashboard)
                },
                showFeaturePanel: { [weak self] in
                    self?.panelPresentationActions.present(.featurePanel)
                }
            )
        )
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.toolbarStyle = .unified
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.onLocalKeyboardCommand = { [weak self] command in
            self?.handleLocalKeyboardCommand(command)
        }
        window.center()
        settingsNavigationCoordinator = navigationCoordinator
        return window
    }

    func presentSettings(_ request: SettingsPresentationRequest) {
        let window = settingsWindow ?? makeSettingsWindow()
        let pendingAppUpdateVersion: String?

        switch request {
        case .settings:
            pendingAppUpdateVersion = nil
        case .appUpdate:
            pendingAppUpdateVersion = appUpdater.availableUpdateVersion
            settingsNavigationCoordinator?.navigate(to: .about)
        case .pluginMarketplace:
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .plugins(.marketplace))
        case let .pluginConfiguration(pluginID):
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .plugins(.configuration(pluginID)))
        }

        let contentSize = window.contentView?.bounds.size ?? SettingsWindowLayout.defaultContentSize
        settingsWindow = window
        show(window)
        // SwiftUI installs its toolbar when the window becomes visible. Finish that
        // layout before restoring the content size.
        window.layoutIfNeeded()
        window.setContentSize(contentSize)
        window.layoutIfNeeded()
        onProgrammaticSettingsPresentation()

        if let pendingAppUpdateVersion {
            settingsNavigationCoordinator?.requestAboutUpdateAction(
                version: pendingAppUpdateVersion
            )
        }
    }

    private func handleLocalKeyboardCommand(_ command: MacToolsLocalKeyboardCommand) {
        switch command {
        case .showSettings:
            showSettings()
        case .focusSearch:
            settingsNavigationCoordinator?.requestSearchFocus()
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === settingsWindow else {
            return frameSize
        }

        let minimumFrameSize = sender.frameRect(
            forContentRect: NSRect(origin: .zero, size: SettingsWindowLayout.minimumContentSize)
        ).size
        return NSSize(
            width: max(frameSize.width, minimumFrameSize.width),
            height: max(frameSize.height, minimumFrameSize.height)
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else {
            return
        }

        window.delegate = nil
        window.contentView = nil
        settingsWindow = nil
        settingsNavigationCoordinator = nil
    }
}
