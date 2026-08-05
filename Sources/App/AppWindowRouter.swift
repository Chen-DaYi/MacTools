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

enum StandaloneCommandPaletteLayout {
    static let contentSize = NSSize(width: 720, height: 660)

    static func frame(
        contentSize: NSSize = contentSize,
        pointerLocation: NSPoint,
        visibleFrames: [NSRect]
    ) -> NSRect {
        guard let visibleFrame = visibleFrames.first(where: { $0.contains(pointerLocation) })
            ?? visibleFrames.first
        else {
            return NSRect(origin: .zero, size: contentSize)
        }

        let size = NSSize(
            width: min(contentSize.width, visibleFrame.width),
            height: min(contentSize.height, visibleFrame.height)
        )
        let proposedOrigin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2)
        )
        let origin = NSPoint(
            x: min(max(proposedOrigin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: min(max(proposedOrigin.y, visibleFrame.minY), visibleFrame.maxY - size.height)
        )
        return NSRect(origin: origin, size: size)
    }
}

enum CommandPaletteTogglePolicy {
    static func settingsPaletteIsVisible(
        isPresented: Bool,
        isWindowVisible: Bool,
        isWindowMiniaturized: Bool,
        isWindowOnActiveSpace: Bool
    ) -> Bool {
        isPresented
            && isWindowVisible
            && !isWindowMiniaturized
            && isWindowOnActiveSpace
    }
}

enum AppWindowPresentation {
    static func perform(
        isMiniaturized: Bool,
        activate: () -> Void,
        deminiaturize: () -> Void,
        orderFront: () -> Void
    ) {
        activate()
        if isMiniaturized {
            deminiaturize()
        }
        orderFront()
    }
}

@MainActor
final class StandaloneCommandPaletteState: ObservableObject {
    @Published private(set) var presentationOrigin: UnifiedSearchPresentationOrigin?
    @Published private(set) var shortcutHint: String?
    @Published private(set) var focusRequestID: UInt = 0
    @Published private(set) var resetRequestID: UInt = 0
    @Published private(set) var quickSelectionRequest: UnifiedSearchQuickSelectionRequest?
    @Published private(set) var localizationRevision: UInt = 0

    private var nextQuickSelectionRequestID: UInt = 0

    func prepareForPresentation(shortcutLabel: String) {
        presentationOrigin = .globalShortcut(shortcutLabel)
        shortcutHint = shortcutLabel
        quickSelectionRequest = nil
        resetRequestID &+= 1
        focusRequestID &+= 1
    }

    @discardableResult
    func requestQuickSelection(number: Int) -> Bool {
        guard (1...MacToolsSearchPresentation.quickSelectionLimit).contains(number) else {
            return false
        }

        nextQuickSelectionRequestID &+= 1
        quickSelectionRequest = UnifiedSearchQuickSelectionRequest(
            id: nextQuickSelectionRequestID,
            number: number
        )
        return true
    }

    @discardableResult
    func consumeQuickSelectionRequest(_ request: UnifiedSearchQuickSelectionRequest) -> Bool {
        guard quickSelectionRequest == request else {
            return false
        }

        quickSelectionRequest = nil
        return true
    }

    func refreshLocalization() {
        localizationRevision &+= 1
    }
}

@MainActor
final class MacToolsCommandPalettePanel: NSPanel {
    var onQuickSelection: ((Int) -> Bool)?
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if case let .selectUnifiedSearchResult(number) = MacToolsLocalKeyboardCommand.resolve(for: event),
           onQuickSelection?(number) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}

struct StandaloneCommandPaletteRootView: View {
    let pluginHost: PluginHost
    @ObservedObject var state: StandaloneCommandPaletteState
    let actions: UnifiedSearchPaletteActions

    var body: some View {
        GeometryReader { geometry in
            UnifiedSearchPaletteView(
                pluginHost: pluginHost,
                availableSize: geometry.size,
                presentationOrigin: state.presentationOrigin,
                shortcutHint: state.shortcutHint,
                focusRequestID: state.focusRequestID,
                resetRequestID: state.resetRequestID,
                quickSelectionRequest: state.quickSelectionRequest,
                showsCustomShadow: false,
                actions: actions
            )
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(state.localizationRevision)
        .background(Color.clear)
        .environment(\.locale, PluginRuntimeLocalization.locale)
        .environment(
            \.layoutDirection,
            Self.layoutDirection(for: PluginRuntimeLocalization.locale)
        )
    }

    static func layoutDirection(for locale: Locale) -> LayoutDirection {
        locale.language.characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
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
    private(set) var commandPalettePanel: NSPanel?
    private(set) var commandPaletteState: StandaloneCommandPaletteState?
    private var runtimeLocaleCancellable: AnyCancellable?
    private var appDeactivationObserver: NSObjectProtocol?
    private var panelPresentationActions = SettingsPanelPresentationActions()
    private var onProgrammaticSettingsPresentation: () -> Void = {}

    static var settingsWindowTitle: String {
        AppL10n.settings("settings.window.title", defaultValue: "设置")
    }

    static var commandPaletteWindowTitle: String {
        AppL10n.search("search.title", defaultValue: "搜索 MacTools")
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
                    self?.commandPalettePanel?.setAccessibilityTitle(Self.commandPaletteWindowTitle)
                    self?.commandPaletteState?.refreshLocalization()
                }
            }
        appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissCommandPalette()
            }
        }
    }

    isolated deinit {
        runtimeLocaleCancellable?.cancel()
        if let appDeactivationObserver {
            NotificationCenter.default.removeObserver(appDeactivationObserver)
        }
    }

    func showSettings() {
        presentSettings(.settings)
    }

    func showUnifiedSearch() {
        presentSettings(.settings)
        settingsNavigationCoordinator?.presentUnifiedSearch(origin: .keyboard)
    }

    func toggleCommandPalette() {
        if settingsNavigationCoordinator?.isUnifiedSearchPresented == true {
            if CommandPaletteTogglePolicy.settingsPaletteIsVisible(
                isPresented: true,
                isWindowVisible: settingsWindow?.isVisible == true,
                isWindowMiniaturized: settingsWindow?.isMiniaturized == true,
                isWindowOnActiveSpace: settingsWindow?.isOnActiveSpace == true
            ) {
                settingsNavigationCoordinator?.dismissUnifiedSearch()
                return
            }

            settingsNavigationCoordinator?.dismissUnifiedSearch()
        }

        if commandPalettePanel?.isVisible == true {
            dismissCommandPalette()
            return
        }

        onProgrammaticSettingsPresentation()
        let state = commandPaletteState ?? StandaloneCommandPaletteState()
        let panel = commandPalettePanel ?? makeCommandPalettePanel(state: state)
        commandPaletteState = state
        commandPalettePanel = panel

        let shortcutLabel = pluginHost.appShortcutItems.first {
            $0.action == .openCommandPalette
        }?.bindingText ?? ""
        state.prepareForPresentation(shortcutLabel: shortcutLabel)

        let screens = NSScreen.screens
        let pointerLocation = NSEvent.mouseLocation
        let orderedVisibleFrames = screens
            .filter { $0.frame.contains(pointerLocation) }
            .map(\.visibleFrame)
            + [NSScreen.main?.visibleFrame].compactMap { $0 }
            + screens.map(\.visibleFrame)
        panel.setFrame(
            StandaloneCommandPaletteLayout.frame(
                pointerLocation: pointerLocation,
                visibleFrames: orderedVisibleFrames
            ),
            display: true
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismissCommandPalette() {
        commandPalettePanel?.orderOut(nil)
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
        AppWindowPresentation.perform(
            isMiniaturized: window.isMiniaturized,
            activate: {
                NSApplication.shared.activate(ignoringOtherApps: true)
            },
            deminiaturize: {
                window.deminiaturize(nil)
            },
            orderFront: {
                window.makeKeyAndOrderFront(nil)
            }
        )
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

    private func makeCommandPalettePanel(
        state: StandaloneCommandPaletteState
    ) -> MacToolsCommandPalettePanel {
        let panel = MacToolsCommandPalettePanel(
            contentRect: NSRect(origin: .zero, size: StandaloneCommandPaletteLayout.contentSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let actions = UnifiedSearchPaletteActions(
            dismiss: { [weak self] in
                self?.dismissCommandPalette()
            },
            navigate: { [weak self] destination, target in
                self?.navigateFromStandaloneSearch(to: destination, target: target) ?? false
            },
            consumeQuickSelection: state.consumeQuickSelectionRequest
        )
        let hostingView = NSHostingView(
            rootView: StandaloneCommandPaletteRootView(
                pluginHost: pluginHost,
                state: state,
                actions: actions
            )
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setAccessibilityTitle(Self.commandPaletteWindowTitle)
        panel.onQuickSelection = state.requestQuickSelection
        panel.onDismiss = { [weak self] in
            self?.dismissCommandPalette()
        }
        return panel
    }

    @discardableResult
    func navigateFromStandaloneSearch(
        to destination: SettingsNavigationDestination,
        target: SettingsSearchRevealTarget?
    ) -> Bool {
        let validator = settingsNavigationCoordinator
            ?? SettingsNavigationCoordinator(pluginHost: pluginHost)
        guard validator.canNavigateFromSearch(to: destination, target: target) else {
            return false
        }

        dismissCommandPalette()
        presentSettings(.settings)
        return settingsNavigationCoordinator?.navigateFromSearch(
            to: destination,
            target: target
        ) ?? false
    }

    func presentSettings(_ request: SettingsPresentationRequest) {
        dismissCommandPalette()
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
