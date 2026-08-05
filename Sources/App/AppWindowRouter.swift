import AppKit
import Carbon
import Combine
import SwiftUI
import MacToolsPluginKit

enum MacToolsLocalKeyboardCommand: Equatable {
    case showSettings
    case focusSearch
    case showUnifiedSearch
    case selectUnifiedSearchResult(Int)

    static func resolve(for event: NSEvent) -> MacToolsLocalKeyboardCommand? {
        guard event.type == .keyDown else {
            return nil
        }

        let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(relevantModifiers) == .command else {
            return nil
        }

        if let selectionNumber = physicalNumberRowSelection(for: event.keyCode) {
            return .selectUnifiedSearchResult(selectionNumber)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case ",":
            return .showSettings
        case "f":
            return .focusSearch
        case "k":
            return .showUnifiedSearch
        default:
            return nil
        }
    }

    private static func physicalNumberRowSelection(for keyCode: UInt16) -> Int? {
        switch keyCode {
        case UInt16(kVK_ANSI_1):
            1
        case UInt16(kVK_ANSI_2):
            2
        case UInt16(kVK_ANSI_3):
            3
        case UInt16(kVK_ANSI_4):
            4
        case UInt16(kVK_ANSI_5):
            5
        case UInt16(kVK_ANSI_6):
            6
        case UInt16(kVK_ANSI_7):
            7
        case UInt16(kVK_ANSI_8):
            8
        case UInt16(kVK_ANSI_9):
            9
        default:
            nil
        }
    }
}

@MainActor
final class MacToolsCommandWindow: NSWindow {
    var onLocalKeyboardCommand: ((MacToolsLocalKeyboardCommand) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard
            let command = MacToolsLocalKeyboardCommand.resolve(for: event),
            let onLocalKeyboardCommand
        else {
            return super.performKeyEquivalent(with: event)
        }

        guard onLocalKeyboardCommand(command) else {
            return super.performKeyEquivalent(with: event)
        }

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

    func showUnifiedSearch() {
        presentSettings(.settings)
        settingsNavigationCoordinator?.presentUnifiedSearch(origin: .keyboard)
    }

    func windowForActionConfirmation() -> NSWindow? {
        presentSettings(.settings)
        return settingsWindow
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
            self?.handleLocalKeyboardCommand(command) ?? false
        }
        window.center()
        settingsNavigationCoordinator = navigationCoordinator
        return window
    }

    func presentSettings(_ request: SettingsPresentationRequest) {
        let window = settingsWindow ?? makeSettingsWindow()
        let wasVisible = window.isVisible
        let pendingAppUpdateVersion: String?

        settingsNavigationCoordinator?.dismissUnifiedSearch()

        switch request {
        case .settings:
            pendingAppUpdateVersion = nil
        case .general:
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .general)
        case .about:
            pendingAppUpdateVersion = nil
            settingsNavigationCoordinator?.navigate(to: .about)
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

        if !wasVisible {
            clearAutomaticInitialFocusAfterPresentation(in: window)
        }
    }

    private func clearAutomaticInitialFocusAfterPresentation(in window: NSWindow) {
        // SwiftUI assigns an initial responder after installing the visible hierarchy.
        // Wait for that pass, then leave focus entry to Tab or an explicit search request.
        Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard
                let self,
                let window,
                settingsWindow === window,
                window.isVisible,
                settingsNavigationCoordinator?.isUnifiedSearchPresented != true,
                settingsNavigationCoordinator?.focusedSearchField == nil
            else {
                return
            }

            window.makeFirstResponder(nil)
        }
    }

    private func handleLocalKeyboardCommand(_ command: MacToolsLocalKeyboardCommand) -> Bool {
        switch command {
        case .showSettings:
            showSettings()
            return true
        case .focusSearch:
            settingsNavigationCoordinator?.requestSearchFocus()
            return true
        case .showUnifiedSearch:
            showUnifiedSearch()
            return true
        case let .selectUnifiedSearchResult(number):
            guard let settingsNavigationCoordinator else {
                return false
            }

            if settingsNavigationCoordinator.requestUnifiedSearchQuickSelection(number: number) {
                return true
            }

            switch number {
            case 1:
                settingsNavigationCoordinator.selectSettingsDestination(.general)
            case 2:
                settingsNavigationCoordinator.selectSettingsDestination(.pluginConfiguration)
            case 3:
                settingsNavigationCoordinator.selectSettingsDestination(.about)
            default:
                return false
            }
            return true
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
