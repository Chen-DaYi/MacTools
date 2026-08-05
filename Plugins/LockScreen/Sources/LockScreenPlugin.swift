import Darwin
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class LockScreenPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        LockScreenPluginProvider(context: context)
    }
}

@MainActor
private struct LockScreenPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [LockScreenPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class LockScreenPlugin:
    MacToolsPlugin,
    PluginPrimaryPanel,
    PluginCommandProviding,
    PluginActionProviding
{
    let metadata: PluginMetadata

    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "LockScreenPlugin"
    )
    private let localization: PluginLocalization

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "lock-screen",
            title: localization.string("metadata.title", defaultValue: "锁定屏幕"),
            iconName: "lock",
            iconTint: Color(nsColor: .systemGray),
            order: 96,
            defaultDescription: localization.string("metadata.description", defaultValue: "立即锁定屏幕")
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.lock", defaultValue: "锁定") }
        )
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: metadata.defaultDescription,
            isOn: false,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var commandDefinitions: [PluginCommandDefinition] {
        [
            PluginCommandDefinition(
                id: "execute",
                title: localization.string(
                    "metadata.title",
                    defaultValue: "锁定屏幕"
                ),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "立即锁定屏幕"
                ),
                systemImage: metadata.iconName
            )
        ]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: "execute"),
                title: localization.string("metadata.title", defaultValue: "锁定屏幕"),
                description: localization.string(
                    "metadata.description",
                    defaultValue: "立即锁定屏幕"
                ),
                keywords: [
                    localization.string("metadata.title", defaultValue: "锁定屏幕"),
                    localization.string("metadata.description", defaultValue: "立即锁定屏幕"),
                ],
                systemImage: metadata.iconName,
                confirmation: ActionConfirmation(
                    title: localization.string(
                        "action.confirmation.title",
                        defaultValue: "锁定屏幕？"
                    ),
                    message: localization.string(
                        "action.confirmation.message",
                        defaultValue: "此运行链接将立即锁定屏幕。"
                    ),
                    confirmButtonTitle: localization.string(
                        "action.confirmation.confirm",
                        defaultValue: "锁定"
                    )
                ),
                externalInvocationPolicy: .confirmAlways,
                capabilities: [.background, .foregroundInteractive]
            ),
        ]
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        lockScreen()
        return ActionExecutionHandle { .succeeded() }
    }

    func handleCommand(id: String) {
        guard id == "execute" else {
            return
        }

        handleAction(.invokeAction(controlID: "execute"))
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(controlID) = action, controlID == "execute" else {
            return
        }

        lockScreen()
    }

    private func lockScreen() {
        let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            logger.error("Failed to open login.framework; falling back to ScreenSaverEngine")
            startScreenSaverFallback()
            return
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            logger.error("SACLockScreenImmediate not found; falling back to ScreenSaverEngine")
            startScreenSaverFallback()
            return
        }

        typealias LockScreenFunction = @convention(c) () -> Int32
        let lockScreenImmediately = unsafeBitCast(symbol, to: LockScreenFunction.self)
        let result = lockScreenImmediately()
        if result == 0 {
            logger.info("Screen locked successfully")
        } else {
            logger.error("SACLockScreenImmediate returned \(result); falling back to ScreenSaverEngine")
            startScreenSaverFallback()
        }
    }

    private func startScreenSaverFallback() {
        let task = Process()
        task.executableURL = URL(
            fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app/Contents/MacOS/ScreenSaverEngine"
        )

        do {
            try task.run()
        } catch {
            logger.error("Failed to start ScreenSaverEngine fallback: \(error.localizedDescription)")
        }
    }
}
