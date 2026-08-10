import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class MiddleClickPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        MiddleClickPluginProvider(context: context)
    }
}

@MainActor
private struct MiddleClickPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            MiddleClickPlugin(
                context: context,
                localization: PluginLocalization(bundle: context.resourceBundle)
            )
        ]
    }
}

/// Converts a trackpad tap with the configured finger count into a middle-button click.
@MainActor
final class MiddleClickPlugin: MacToolsPlugin, AccessibilityPermissionRefreshing {
    private enum PermissionID {
        static let accessibility = "accessibility"
    }

    private enum SettingsID {
        static let section = "click-behavior"
        static let enabled = "enabled"
        static let fingerCount = "finger-count"
    }

    let metadata: PluginMetadata

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    let store: MiddleClickStore

    private let localization: PluginLocalization
    private let makeSession: @MainActor () -> any MiddleClickSessionManaging
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "MiddleClickPlugin"
    )

    private var isAccessibilityGranted: Bool
    private var session: (any MiddleClickSessionManaging)?
    private var hasAccessibilityError = false

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "middle-click"),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        makeSession: @escaping @MainActor () -> any MiddleClickSessionManaging = {
            MiddleClickSession()
        },
        accessibilityTrusted: @escaping @MainActor () -> Bool = MiddleClickAccessibilityCheck.isTrusted,
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = MiddleClickAccessibilityCheck.requestTrust(prompt:)
    ) {
        self.localization = localization
        self.store = MiddleClickStore(storage: context.storage)
        self.makeSession = makeSession
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.isAccessibilityGranted = accessibilityTrusted()
        self.metadata = PluginMetadata(
            id: "middle-click",
            title: localization.string("metadata.title", defaultValue: "模拟鼠标中键"),
            iconName: "hand.tap",
            iconTint: Color(nsColor: .systemIndigo),
            order: 55,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "触控板轻点 → 模拟鼠标中键"
            )
        )
    }

    func activate(context: PluginRuntimeContext) {
        refreshAccessibilityPermission()
        applyCurrentConfiguration()
    }

    func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup else { return }
        stopSession()
        onStateChange?()
    }

    func refresh() {
        refreshAccessibilityPermission()
        applyCurrentConfiguration()
        onStateChange?()
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string(
                    "permission.accessibility.title",
                    defaultValue: "辅助功能授权"
                ),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "模拟鼠标中键需要辅助功能权限才能正常工作。"
                )
            )
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var settingsPage: PluginSettingsPage? {
        let localizedTitle = localization.string(
            "metadata.title",
            defaultValue: "模拟鼠标中键"
        )
        let localizedDescription = localization.string(
            "metadata.description",
            defaultValue: "触控板轻点 → 模拟鼠标中键"
        )

        return .form(description: localizedDescription, sections: [
            PluginSettingsSection(
                id: SettingsID.section,
                title: localization.string("settings.section.title", defaultValue: "设置"),
                systemImage: "hand.tap",
                rows: [
                    PluginSettingsRow(
                        id: SettingsID.enabled,
                        title: localizedTitle,
                        description: localizedDescription,
                        systemImage: "power",
                        error: hasAccessibilityError ? accessibilityRequiredMessage : nil,
                        control: .toggle(isOn: store.isEnabled)
                    ),
                    PluginSettingsRow(
                        id: SettingsID.fingerCount,
                        title: localization.string(
                            "settings.fingerCount.title",
                            defaultValue: "手指数量"
                        ),
                        description: localization.string(
                            "settings.fingerCount.description",
                            defaultValue: "用指定数量的手指在触控板上轻点，将模拟鼠标中键点击"
                        ),
                        systemImage: "hand.raised",
                        control: .picker(
                            selectionID: String(store.requiredFingerCount),
                            options: [3, 4, 5].map { count in
                                PluginSettingsOption(
                                    id: String(count),
                                    title: localization.format(
                                        "settings.fingerCount.optionFormat",
                                        defaultValue: "%d指",
                                        count
                                    )
                                )
                            },
                            style: .segmented
                        )
                    )
                ]
            )
        ])
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.accessibility else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        return PluginPermissionState(
            isGranted: isAccessibilityGranted,
            footnote: isAccessibilityGranted ? nil : localization.string(
                "permission.accessibility.footnote",
                defaultValue: "前往系统设置 → 隐私与安全性 → 辅助功能，授权 MacTools。"
            )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.accessibility else { return }

        if isAccessibilityGranted {
            refresh()
            return
        }

        isAccessibilityGranted = requestAccessibilityTrust(true)
        if isAccessibilityGranted {
            hasAccessibilityError = false
            applyCurrentConfiguration()
        } else {
            hasAccessibilityError = true
        }
        onStateChange?()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        switch action {
        case let .setBoolean(controlID, value):
            guard controlID == SettingsID.enabled else { return }
            setEnabled(value)

        case let .setSelection(controlID, optionID):
            guard controlID == SettingsID.fingerCount,
                  let count = Int(optionID),
                  (3...5).contains(count)
            else {
                return
            }

            store.setRequiredFingerCount(count)
            session?.requiredFingerCount = store.requiredFingerCount
            onStateChange?()

        default:
            return
        }
    }

    func handleShortcutAction(id: String) {}

    func refreshAccessibilityPermission() {
        let previous = isAccessibilityGranted
        isAccessibilityGranted = accessibilityTrusted()

        if previous && !isAccessibilityGranted {
            stopSession()
            store.setEnabled(false)
            hasAccessibilityError = true
        } else if !previous && isAccessibilityGranted {
            hasAccessibilityError = false
            applyCurrentConfiguration()
        }

        if previous != isAccessibilityGranted {
            onStateChange?()
        }
    }

    private func setEnabled(_ isEnabled: Bool) {
        hasAccessibilityError = false

        guard isEnabled else {
            store.setEnabled(false)
            stopSession()
            onStateChange?()
            return
        }

        isAccessibilityGranted = accessibilityTrusted()
        if !isAccessibilityGranted {
            isAccessibilityGranted = requestAccessibilityTrust(true)
        }

        guard isAccessibilityGranted else {
            hasAccessibilityError = true
            requestPermissionGuidance?(PermissionID.accessibility)
            onStateChange?()
            return
        }

        store.setEnabled(true)
        startSession()
        onStateChange?()
    }

    private func applyCurrentConfiguration() {
        guard store.isEnabled else {
            stopSession()
            return
        }

        guard isAccessibilityGranted else {
            stopSession()
            hasAccessibilityError = true
            return
        }

        startSession()
    }

    private func startSession() {
        if let session {
            session.requiredFingerCount = store.requiredFingerCount
            return
        }

        let newSession = makeSession()
        newSession.requiredFingerCount = store.requiredFingerCount
        newSession.activate()
        session = newSession
        logger.info(
            "middle click enabled requiredFingerCount=\(self.store.requiredFingerCount, privacy: .public)"
        )
    }

    private func stopSession() {
        guard let session else { return }
        session.deactivate()
        self.session = nil
        logger.info("middle click disabled")
    }

    private var accessibilityRequiredMessage: String {
        localization.string(
            "error.accessibilityRequired",
            defaultValue: "模拟鼠标中键需要辅助功能权限，请先前往设置完成授权。"
        )
    }
}
