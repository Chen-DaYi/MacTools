import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class WindowSwitcherPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        WindowSwitcherPluginProvider(context: context)
    }
}

@MainActor
private struct WindowSwitcherPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            WindowSwitcherPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class WindowSwitcherPlugin: MacToolsPlugin, AccessibilityPermissionRefreshing, PluginShortcutEventHandling {
    private enum Session {
        case direct(entries: [WindowSwitcherAppEntry], selectedIndex: Int)
        case keyWindow(entries: [WindowSwitcherAppEntry])
    }

    let metadata: PluginMetadata

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    let store: WindowSwitcherStore

    private let localization: PluginLocalization
    private let appCatalog: WindowSwitcherAppCatalog
    private let overlayController: WindowSwitcherOverlayController
    private let shortcutTap: WindowSwitcherShortcutTap
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool

    private var isAccessibilityGranted: Bool
    private var lastErrorMessage: String?
    private var session: Session?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: WindowSwitcherConstants.pluginID),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        appCatalog: WindowSwitcherAppCatalog = WindowSwitcherAppCatalog(),
        overlayController: WindowSwitcherOverlayController = WindowSwitcherOverlayController(),
        shortcutTap: WindowSwitcherShortcutTap = WindowSwitcherShortcutTap(),
        accessibilityTrusted: @escaping @MainActor () -> Bool = WindowSwitcherAccessibilityCheck.isTrusted,
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = WindowSwitcherAccessibilityCheck.requestTrust(prompt:)
    ) {
        self.localization = localization
        self.store = WindowSwitcherStore(storage: context.storage)
        self.appCatalog = appCatalog
        self.overlayController = overlayController
        self.shortcutTap = shortcutTap
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.isAccessibilityGranted = accessibilityTrusted()
        self.metadata = PluginMetadata(
            id: WindowSwitcherConstants.pluginID,
            title: localization.string("metadata.title", defaultValue: "窗口切换"),
            iconName: "rectangle.2.swap",
            iconTint: Color(nsColor: .systemIndigo),
            order: 64,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "快速切换正在运行的窗口"
            )
        )

        self.appCatalog.onChange = { [weak self] in
            self?.onStateChange?()
        }
        self.overlayController.onSelect = { [weak self] entry in
            self?.select(entry)
        }
        self.overlayController.onQuit = { [weak self] entry in
            self?.quit(entry)
        }
        self.overlayController.onCancel = { [weak self] in
            self?.cancelSession()
        }
        self.shortcutTap.onShortcutPressed = { [weak self] reversed, isRepeat in
            self?.handleShortcutPressed(reversed: reversed, isRepeat: isRepeat)
        }
        self.shortcutTap.onShortcutReleased = { [weak self] in
            self?.handleShortcutReleased()
        }
        self.shortcutTap.onEscape = { [weak self] in
            self?.cancelSession()
        }
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: WindowSwitcherConstants.accessibilityPermissionID,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于接管切换快捷键并切换其他应用窗口。"
                )
            ),
        ]
    }

    var settingsSections: [PluginSettingsSection] { [] }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [
            PluginShortcutDefinition(
                id: WindowSwitcherConstants.shortcutDefinitionID,
                title: localization.string("shortcut.switcher.title", defaultValue: "窗口切换"),
                description: localization.string(
                    "shortcut.switcher.description",
                    defaultValue: "显示或切换正在运行的窗口。"
                ),
                actionID: WindowSwitcherConstants.shortcutActionID,
                scope: .whilePluginActive,
                defaultBinding: WindowSwitcherShortcutBindingStore.defaultBinding,
                isRequired: true,
                settingsGroupID: "window-switcher",
                settingsGroupTitle: localization.string("shortcut.group.title", defaultValue: "窗口切换"),
                settingsGroupDescription: localization.string(
                    "shortcut.group.description",
                    defaultValue: "修改用于唤起窗口切换的快捷键。"
                ),
                settingsControlTitle: localization.string("shortcut.control.title", defaultValue: "切换快捷键"),
                settingsControlSystemImage: "command"
            ),
        ]
    }

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [weak self] _ in
            guard let self else {
                return AnyView(EmptyView())
            }

            return AnyView(
                WindowSwitcherSettingsView(
                    store: self.store,
                    localization: self.localization,
                    onChange: { [weak self] in
                        self?.configurationDidChange()
                    }
                )
            )
        }
    }

    func activate(context: PluginRuntimeContext) {
        appCatalog.start()
        refreshAccessibilityPermission()
        syncShortcutTap()
    }

    func deactivate(reason: PluginDeactivationReason) {
        shortcutTap.stop()
        appCatalog.stop()
        overlayController.hide()
        session = nil
    }

    func refresh() {
        refreshAccessibilityPermission()
        syncShortcutTap()
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == WindowSwitcherConstants.accessibilityPermissionID else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        return PluginPermissionState(
            isGranted: isAccessibilityGranted,
            footnote: isAccessibilityGranted
                ? nil
                : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "系统设置 → 隐私与安全性 → 辅助功能，允许 MacTools。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == WindowSwitcherConstants.accessibilityPermissionID else {
            return
        }

        handleAccessibilityPermissionAction()
    }

    func handleSettingsAction(id: String) {}

    func handleShortcutAction(id: String) {
        guard id == WindowSwitcherConstants.shortcutActionID,
              store.configuration.isEnabled
        else {
            return
        }

        handleShortcutPressed(reversed: false, isRepeat: false)
    }

    func handleShortcutEvent(id: String, phase: PluginShortcutEventPhase) {
        guard id == WindowSwitcherConstants.shortcutActionID,
              store.configuration.isEnabled
        else {
            return
        }

        switch phase {
        case .pressed:
            handleShortcutPressed(reversed: false, isRepeat: false)
        case .released:
            handleShortcutReleased()
        }
    }

    func refreshAccessibilityPermission() {
        let previous = isAccessibilityGranted
        isAccessibilityGranted = accessibilityTrusted()

        if previous && !isAccessibilityGranted {
            shortcutTap.stop()
            overlayController.hide()
            session = nil
            if store.configuration.isEnabled {
                lastErrorMessage = localization.string(
                    "error.accessibilityRevoked",
                    defaultValue: "辅助功能权限已关闭，窗口切换已暂停。"
                )
            }
        } else if !previous && isAccessibilityGranted {
            lastErrorMessage = nil
            syncShortcutTap()
        }

        if previous != isAccessibilityGranted {
            onStateChange?()
        }
    }

    private func configurationDidChange() {
        overlayController.hide()
        session = nil
        if !store.configuration.isEnabled {
            lastErrorMessage = nil
        }
        syncShortcutTap()
        onStateChange?()
    }

    private func handleShortcutPressed(reversed: Bool, isRepeat: Bool) {
        guard store.configuration.isEnabled else {
            return
        }

        guard ensureAccessibilityForInvocation() else {
            return
        }

        switch store.configuration.mode {
        case .keyWindow:
            beginKeyWindowSession()
        case .directCycle:
            if case .direct = session {
                advanceDirectSession(by: reversed ? -1 : 1)
            } else {
                beginDirectSession(reversed: reversed)
            }
        }
    }

    private func handleShortcutReleased() {
        guard store.configuration.isEnabled else {
            return
        }

        guard case .direct = session else {
            return
        }

        commitDirectSession()
    }

    private func beginDirectSession(reversed: Bool) {
        let entries = appCatalog.entries(sortMode: store.configuration.sortMode)
        guard !entries.isEmpty else {
            return
        }

        let selectedIndex = initialDirectSelectionIndex(in: entries, reversed: reversed)

        session = .direct(entries: entries, selectedIndex: selectedIndex)
        overlayController.showDirect(
            entries: entries,
            selectedID: entries[selectedIndex].id,
            shortcutText: currentShortcutText
        )
    }

    private func advanceDirectSession(by delta: Int) {
        guard case let .direct(entries, selectedIndex) = session,
              !entries.isEmpty
        else {
            return
        }

        let nextIndex = (selectedIndex + delta + entries.count) % entries.count
        session = .direct(entries: entries, selectedIndex: nextIndex)
        overlayController.updateDirectSelection(selectedID: entries[nextIndex].id)
    }

    private func commitDirectSession() {
        guard case let .direct(entries, selectedIndex) = session,
              entries.indices.contains(selectedIndex)
        else {
            cancelSession()
            return
        }

        let entry = entries[selectedIndex]
        overlayController.hide()
        session = nil
        appCatalog.activate(entry)
    }

    private func beginKeyWindowSession() {
        guard ensureAccessibilityForInvocation() else {
            return
        }

        if case .keyWindow(_) = session, overlayController.isVisible {
            return
        }

        let entries = store.assignShortcuts(
            to: appCatalog.entries(sortMode: store.configuration.sortMode)
        )
        guard !entries.isEmpty else {
            return
        }

        session = .keyWindow(entries: entries)
        overlayController.showKeyWindow(
            entries: entries,
            shortcutText: currentShortcutText
        )
    }

    private func initialDirectSelectionIndex(in entries: [WindowSwitcherAppEntry], reversed: Bool) -> Int {
        guard entries.count > 1 else {
            return 0
        }

        let anchorIndex = appCatalog.frontmostApplicationID().flatMap { appID in
            entries.firstIndex { $0.appIdentifier == appID }
        } ?? 0
        let delta = reversed ? -1 : 1
        return (anchorIndex + delta + entries.count) % entries.count
    }

    private func select(_ entry: WindowSwitcherAppEntry) {
        session = nil
        appCatalog.activate(entry)
    }

    private func quit(_ entry: WindowSwitcherAppEntry) {
        appCatalog.quitApplication(entry)
        removeEntries(forAppIdentifier: entry.appIdentifier)
    }

    private func cancelSession() {
        overlayController.hide()
        session = nil
    }

    private func removeEntries(forAppIdentifier appIdentifier: String) {
        switch session {
        case let .direct(entries, selectedIndex):
            let filteredEntries = entries.filter { $0.appIdentifier != appIdentifier }
            guard !filteredEntries.isEmpty else {
                cancelSession()
                return
            }

            let nextIndex = min(selectedIndex, filteredEntries.count - 1)
            session = .direct(entries: filteredEntries, selectedIndex: nextIndex)
            overlayController.updateEntries(
                entries: filteredEntries,
                selectedID: filteredEntries[nextIndex].id
            )
        case let .keyWindow(entries):
            let filteredEntries = entries.filter { $0.appIdentifier != appIdentifier }
            guard !filteredEntries.isEmpty else {
                cancelSession()
                return
            }

            session = .keyWindow(entries: filteredEntries)
            overlayController.updateEntries(entries: filteredEntries, selectedID: nil)
        case nil:
            return
        }
    }

    private func ensureAccessibilityForInvocation() -> Bool {
        refreshAccessibilityPermission()
        guard isAccessibilityGranted else {
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "窗口切换需要辅助功能权限，请先前往设置完成授权。"
            )
            requestPermissionGuidance?(WindowSwitcherConstants.accessibilityPermissionID)
            onStateChange?()
            return false
        }

        lastErrorMessage = nil
        syncShortcutTap()
        return true
    }

    private func handleAccessibilityPermissionAction() {
        if isAccessibilityGranted {
            refreshAccessibilityPermission()
            return
        }

        isAccessibilityGranted = requestAccessibilityTrust(true)
        if isAccessibilityGranted {
            lastErrorMessage = nil
            syncShortcutTap()
        } else {
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "窗口切换需要辅助功能权限，请先前往设置完成授权。"
            )
        }
        onStateChange?()
    }

    private func syncShortcutTap() {
        shortcutTap.reloadBinding()
        if store.configuration.isEnabled && isAccessibilityGranted {
            shortcutTap.start()
        } else {
            shortcutTap.stop()
        }
    }

    private var currentShortcutText: String {
        let binding = shortcutBindingResolver?(WindowSwitcherConstants.shortcutDefinitionID)
            ?? WindowSwitcherShortcutBindingStore.resolvedBinding()
            ?? WindowSwitcherShortcutBindingStore.defaultBinding
        return ShortcutFormatter.displayString(for: binding)
    }
}
