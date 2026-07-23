import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

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
        pluginHost.appPresentationHandler = { [weak self] request in
            guard case let .settings(settingsRequest) = request else {
                return
            }
            self?.presentSettings(settingsRequest)
        }
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
        let window = settingsWindow ?? makeSettingsWindow()
        show(window)
        settingsWindow = window
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.settingsWindowTitle
        window.minSize = NSSize(width: 860, height: 560)
        window.contentView = NSHostingView(
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
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        settingsNavigationCoordinator = navigationCoordinator
        return window
    }

    func presentSettings(_ request: SettingsPresentationRequest) {
        let window = settingsWindow ?? makeSettingsWindow()

        switch request {
        case .settings:
            break
        case .pluginMarketplace:
            settingsNavigationCoordinator?.navigate(to: .plugins(.marketplace))
        case let .pluginConfiguration(pluginID):
            settingsNavigationCoordinator?.navigate(to: .plugins(.configuration(pluginID)))
        }

        show(window)
        settingsWindow = window
        onProgrammaticSettingsPresentation()
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
