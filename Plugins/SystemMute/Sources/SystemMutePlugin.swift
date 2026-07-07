import CoreAudio
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class SystemMutePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        SystemMutePluginProvider(context: context)
    }
}

@MainActor
private struct SystemMutePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [SystemMutePlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

protocol SystemAudioControlling {
    func readMuteState() -> Bool
    func setMuteState(_ muted: Bool) -> Bool
}

struct CoreAudioSystemOutputController: SystemAudioControlling {
    func readMuteState() -> Bool {
        guard let deviceID = Self.defaultOutputDeviceID() else { return false }
        return Self.getMuteState(deviceID: deviceID) ?? false
    }

    func setMuteState(_ muted: Bool) -> Bool {
        guard let deviceID = Self.defaultOutputDeviceID() else { return false }
        return Self.applyMuteState(deviceID: deviceID, muted: muted)
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func getMuteState(deviceID: AudioDeviceID) -> Bool? {
        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &mute)
        guard status == noErr else { return nil }
        return mute != 0
    }

    private static func applyMuteState(deviceID: AudioDeviceID, muted: Bool) -> Bool {
        var mute: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue else {
            return false
        }
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mute)
        return status == noErr
    }
}

@MainActor
final class SystemMutePlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SystemMutePlugin"
    )
    private let localization: PluginLocalization
    private let controller: any SystemAudioControlling
    private var isMuted: Bool = false
    private var lastErrorMessage: String?

    init(
        controller: any SystemAudioControlling = CoreAudioSystemOutputController(),
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.controller = controller
        self.metadata = PluginMetadata(
            id: "system-mute",
            title: localization.string("metadata.title", defaultValue: "系统静音"),
            iconName: "speaker.slash",
            iconTint: Color(nsColor: .systemOrange),
            order: 48,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "快速静音或恢复系统音频输出"
            )
        )
        self.isMuted = controller.readMuteState()
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: isMuted
                ? localization.string("panel.subtitle.muted", defaultValue: "已静音")
                : localization.string("panel.subtitle.unmuted", defaultValue: "未静音"),
            isOn: isMuted,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        let current = controller.readMuteState()
        if current != isMuted {
            isMuted = current
            onStateChange?()
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup, isMuted else { return }
        _ = controller.setMuteState(false)
        isMuted = false
        onStateChange?()
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(enable) = action else { return }
        applyMute(enable)
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    // MARK: - Private

    private func applyMute(_ muted: Bool) {
        let success = controller.setMuteState(muted)
        if success {
            isMuted = muted
            lastErrorMessage = nil
        } else {
            logger.error("Failed to set system mute to \(muted, privacy: .public)")
            lastErrorMessage = muted
                ? localization.string("error.muteFailed", defaultValue: "静音操作失败")
                : localization.string("error.unmuteFailed", defaultValue: "取消静音失败")
        }
        onStateChange?()
    }
}
