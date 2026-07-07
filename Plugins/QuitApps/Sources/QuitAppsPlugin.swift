import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

// MARK: - Factory

public final class QuitAppsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        QuitAppsPluginProvider(context: context)
    }
}

@MainActor
private struct QuitAppsPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [QuitAppsPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

// MARK: - Plugin

@MainActor
final class QuitAppsPlugin: MacToolsPlugin, PluginPrimaryPanel, DropZoneAnchorProviding {

    // MARK: Metadata

    let metadata: PluginMetadata

    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    // MARK: DropZoneAnchorProviding

    var anchorRectProvider: (() -> NSRect?)?

    // MARK: Callbacks

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    // MARK: Private State

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "QuitAppsPlugin"
    )
    private let localization: PluginLocalization
    private var selectionWindow: QuitAppsSelectionWindow?
    private var runningAppCount: Int = 0
    private var appObservers: [NSObjectProtocol] = []

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "quit-apps",
            title: localization.string("metadata.title", defaultValue: "退出应用"),
            iconName: "power",
            iconTint: Color(nsColor: .systemRed),
            order: 96,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "选择并退出正在运行的应用"
            )
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitle: localization.string("panel.button.choose", defaultValue: "选择")
        )
    }

    // MARK: PluginPrimaryPanel

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: runningAppCount > 0
                ? localization.format(
                    "panel.subtitle.runningCountFormat",
                    defaultValue: "正在运行 %d 个应用",
                    runningAppCount
                )
                : localization.string("panel.subtitle.none", defaultValue: "无正在运行的应用"),
            isOn: false,
            isExpanded: false,
            isEnabled: runningAppCount > 0,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    // MARK: Lifecycle

    func activate(context: PluginRuntimeContext) {
        refreshRunningAppCount()
        setupAppObservers()
    }

    func deactivate(reason: PluginDeactivationReason) {
        removeAppObservers()
        closeSelectionWindow()
    }

    func refresh() {
        refreshRunningAppCount()
    }

    // MARK: Action

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case .invokeAction(let controlID):
            if controlID == "execute" {
                showSelectionWindow()
            }
        default:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    // MARK: Private – App Count

    private func refreshRunningAppCount() {
        let count = Self.countUserFacingApps()
        if runningAppCount != count {
            runningAppCount = count
            onStateChange?()
        }
    }

    nonisolated private static func countUserFacingApps() -> Int {
        NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
            && app.bundleIdentifier != Bundle.main.bundleIdentifier
        }.count
    }

    private func setupAppObservers() {
        guard appObservers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter
        let launched = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRunningAppCount() }
        }
        let terminated = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRunningAppCount() }
        }
        appObservers = [launched, terminated]
    }

    private func removeAppObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for obs in appObservers { nc.removeObserver(obs) }
        appObservers.removeAll()
    }

    // MARK: Private – Window

    private func showSelectionWindow() {
        if let existing = selectionWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = QuitAppsSelectionWindow(
            localization: localization,
            onDismiss: { [weak self] in
                self?.closeSelectionWindow()
            }
        )
        positionWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        selectionWindow = window
    }

    private func closeSelectionWindow() {
        selectionWindow?.cleanup()
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
    }

    private func positionWindow(_ window: NSWindow) {
        let windowSize = window.frame.size

        if let anchorRect = anchorRectProvider?() {
            let screenMaxX = NSScreen.main?.frame.maxX ?? 1440
            let rawX = anchorRect.midX - windowSize.width / 2
            let x = max(8, min(rawX, screenMaxX - windowSize.width - 8))
            let y = anchorRect.minY - windowSize.height - 4
            window.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        guard let screen = NSScreen.main else { return }
        let menuBarThickness = NSStatusBar.system.thickness
        let x = screen.frame.midX - windowSize.width / 2
        let y = screen.frame.maxY - menuBarThickness - windowSize.height - 12
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
