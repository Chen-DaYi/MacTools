import AppKit
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class DisplayTrueColorPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DisplayTrueColorPluginProvider(context: context)
    }
}

@MainActor
private struct DisplayTrueColorPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DisplayTrueColorPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

/// Controls True Tone through CoreBrightness's private `CBAdaptationClient`.
@MainActor
final class DisplayTrueColorPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "DisplayTrueColorPlugin")
    private let localization: PluginLocalization
    private let client: TrueToneClient
    private var isTrueColorEnabled: Bool = false
    private var isSupported: Bool = false

    init(
        client: TrueToneClient = CoreBrightnessTrueToneClient(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.client = client
        self.metadata = PluginMetadata(
            id: "display-true-color",
            title: localization.string("metadata.title", defaultValue: "原彩显示"),
            iconName: "circle.righthalf.filled",
            iconTint: Color(nsColor: .systemCyan),
            order: 25,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "自动调节显示器颜色以适应环境光"
            )
        )
        isSupported = client.isSupported
        isTrueColorEnabled = isSupported ? (client.isEnabled ?? false) : false
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: subtitle,
            isOn: isTrueColorEnabled,
            isExpanded: false,
            isEnabled: isSupported,
            isVisible: true,
            detail: nil,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    func refresh() {
        guard isSupported else { return }
        let current = client.isEnabled ?? false
        if current != isTrueColorEnabled {
            isTrueColorEnabled = current
            onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enable) = action else { return }
        guard isSupported else { return }
        client.setEnabled(enable)
        isTrueColorEnabled = client.isEnabled ?? enable
        onStateChange?()
        logger.info("True Tone set to \(enable ? "enabled" : "disabled")")
    }

    // MARK: - Private

    private var subtitle: String {
        if !isSupported {
            return localization.string("panel.subtitle.unsupported", defaultValue: "不支持")
        }
        return isTrueColorEnabled
            ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
            : localization.string("panel.subtitle.disabled", defaultValue: "已关闭")
    }
}

// MARK: - TrueToneClient Protocol

@MainActor
protocol TrueToneClient {
    var isSupported: Bool { get }
    var isEnabled: Bool? { get }
    func setEnabled(_ enabled: Bool)
}

// MARK: - CoreBrightness Implementation

final class CoreBrightnessTrueToneClient: TrueToneClient {
    private typealias BoolIMP = @convention(c) (AnyObject, Selector) -> Bool
    private typealias SetBoolIMP = @convention(c) (AnyObject, Selector, Bool) -> Void

    private let adaptationClient: NSObject?
    private let supportedSel = NSSelectorFromString("supported")
    private let getEnabledSel = NSSelectorFromString("getEnabled")
    private let setEnabledSel = NSSelectorFromString("setEnabled:")

    init() {
        let bundle = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")
        _ = bundle?.load()
        guard let cls = NSClassFromString("CBAdaptationClient") as? NSObject.Type else {
            adaptationClient = nil
            return
        }
        adaptationClient = cls.init()
    }

    var isSupported: Bool {
        guard let obj = adaptationClient,
              let imp = class_getMethodImplementation(type(of: obj), supportedSel) else {
            return false
        }
        return unsafeBitCast(imp, to: BoolIMP.self)(obj, supportedSel)
    }

    var isEnabled: Bool? {
        guard let obj = adaptationClient,
              let imp = class_getMethodImplementation(type(of: obj), getEnabledSel) else {
            return nil
        }
        return unsafeBitCast(imp, to: BoolIMP.self)(obj, getEnabledSel)
    }

    func setEnabled(_ enabled: Bool) {
        guard let obj = adaptationClient,
              let imp = class_getMethodImplementation(type(of: obj), setEnabledSel) else {
            return
        }
        unsafeBitCast(imp, to: SetBoolIMP.self)(obj, setEnabledSel, enabled)
    }
}
