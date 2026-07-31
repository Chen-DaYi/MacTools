import AppKit
import Foundation
import SwiftUI
import MacToolsPluginKit

public final class AppVolumePluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        AppVolumePluginProvider(context: context)
    }
}

@MainActor
private struct AppVolumePluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [
            AppVolumePlugin(
                storage: context.storage,
                localization: PluginLocalization(bundle: context.resourceBundle)
            ),
        ]
    }
}

@MainActor
final class AppVolumePlugin: MacToolsPlugin, PluginPrimaryPanel {
    private enum ControlID {
        static let volumePrefix = "application-volume."
        static let openPermission = "open-system-audio-permission"
    }

    private enum PermissionID {
        static let systemAudio = "system-audio-recording"
    }

    private enum StorageKey {
        static let volumes = "applicationVolumes"
    }

    let metadata: PluginMetadata

    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .disclosure,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let monitor: any AudioApplicationMonitoring
    private let router: any ApplicationVolumeRouting
    private let storage: PluginStorage
    private let localization: PluginLocalization

    private var snapshot = AudioApplicationSnapshot.empty
    private var volumes: [String: Double]
    private var controlApplicationIDs: [String: String] = [:]
    private var isExpanded = false
    private var accessState = AppVolumeAccessState.unknown
    private var accessTask: Task<Void, Never>?

    init(
        storage: PluginStorage? = nil,
        monitor: (any AudioApplicationMonitoring)? = nil,
        router: (any ApplicationVolumeRouting)? = nil,
        localization: PluginLocalization? = nil
    ) {
        let storage = storage ?? UserDefaultsPluginStorage(pluginID: "app-volume")
        let monitor = monitor ?? CoreAudioApplicationMonitor()
        let router = router ?? CoreAudioApplicationVolumeRouter()
        let localization = localization ?? PluginLocalization(bundle: .main)

        self.storage = storage
        self.monitor = monitor
        self.router = router
        self.localization = localization
        self.volumes = Self.loadVolumes(storage: storage)
        self.metadata = PluginMetadata(
            id: "app-volume",
            title: localization.string("metadata.title", defaultValue: "应用音量"),
            iconName: "speaker.wave.2.bubble",
            iconTint: Color(nsColor: .systemBlue),
            order: 46,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "分别调节正在播放音频的应用音量"
            )
        )

        monitor.onUpdate = { [weak self] snapshot in
            self?.receive(snapshot)
        }
    }

    var primaryPanelState: PluginPanelState {
        rebuildControlApplicationIDs()
        let applications = snapshot.applications

        return PluginPanelState(
            subtitle: panelSubtitle,
            isOn: applications.contains { !Self.isUnity(volume(for: $0.id)) },
            isExpanded: isExpanded,
            isEnabled: router.isSupported,
            isVisible: true,
            detail: panelDetail(applications: applications),
            errorMessage: panelErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        guard router.isSupported else {
            return []
        }

        return [
            PluginPermissionRequirement(
                id: PermissionID.systemAudio,
                kind: .screenRecording,
                title: localization.string(
                    "permission.systemAudio.title",
                    defaultValue: "系统音频录制"
                ),
                description: localization.string(
                    "permission.systemAudio.description",
                    defaultValue: "仅在本机实时处理应用音频，不会录制、保存或上传声音。"
                )
            ),
        ]
    }

    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func activate(context: PluginRuntimeContext) {
        monitor.start()
    }

    func deactivate(reason: PluginDeactivationReason) {
        accessTask?.cancel()
        accessTask = nil
        monitor.stop()
        router.stop()
        snapshot = .empty
        onStateChange?()
    }

    func refresh() {
        monitor.refresh()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.systemAudio else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }

        switch accessState {
        case .unknown:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.systemAudio.footnote.unknown",
                    defaultValue: "首次调节应用音量时，macOS 会请求系统音频录制权限。"
                ),
                statusText: localization.string("permission.status.onDemand", defaultValue: "按需授权"),
                statusSystemImage: "waveform",
                statusTone: .neutral
            )
        case .requesting:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.systemAudio.footnote.requesting",
                    defaultValue: "请在 macOS 权限提示中允许 MacTools。"
                ),
                statusText: localization.string("permission.status.requesting", defaultValue: "正在请求"),
                statusSystemImage: "ellipsis.circle",
                statusTone: .neutral
            )
        case .granted:
            return PluginPermissionState(isGranted: true, footnote: nil)
        case .denied:
            return PluginPermissionState(
                isGranted: false,
                footnote: localization.string(
                    "permission.systemAudio.footnote.denied",
                    defaultValue: "前往系统设置 → 隐私与安全性 → 屏幕与系统音频录制，授权 MacTools。"
                )
            )
        }
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.systemAudio else {
            return
        }

        requestAccess(force: true, openSettingsOnFailure: true)
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            if expanded {
                monitor.refresh()
            }
            onStateChange?()
        case let .setSlider(controlID, value, phase):
            guard let applicationID = controlApplicationIDs[controlID] else {
                return
            }

            volumes[applicationID] = max(0, min(1, value))
            if phase == .ended {
                saveVolumes()
            }
            if !Self.isUnity(volume(for: applicationID)), accessState == .unknown {
                requestAccess(force: false, openSettingsOnFailure: false)
            }
            applyCurrentTargets()
            onStateChange?()
        case let .invokeAction(controlID) where controlID == ControlID.openPermission:
            requestAccess(force: true, openSettingsOnFailure: true)
        default:
            break
        }
    }

    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    // MARK: - Snapshot and routing

    private func receive(_ snapshot: AudioApplicationSnapshot) {
        self.snapshot = snapshot
        rebuildControlApplicationIDs()
        applyCurrentTargets()
        onStateChange?()
    }

    private func applyCurrentTargets() {
        let targets = snapshot.applications.map { application in
            ApplicationVolumeTarget(
                id: application.id,
                processObjectIDs: application.processObjectIDs,
                gain: volume(for: application.id)
            )
        }
        let needsProcessing = targets.contains { !Self.isUnity($0.gain) }

        guard needsProcessing else {
            router.update(targets: [], outputDeviceUID: snapshot.outputDeviceUID)
            return
        }

        switch accessState {
        case .granted:
            router.update(targets: targets, outputDeviceUID: snapshot.outputDeviceUID)
        case .unknown, .requesting, .denied:
            break
        }
    }

    private func requestAccess(force: Bool, openSettingsOnFailure: Bool) {
        if accessState == .granted {
            applyCurrentTargets()
            return
        }
        guard accessTask == nil, force || accessState == .unknown else {
            if openSettingsOnFailure, accessState == .denied {
                Self.openSystemAudioPrivacySettings()
            }
            return
        }

        accessState = .requesting
        onStateChange?()
        accessTask = Task { [weak self] in
            guard let self else {
                return
            }

            let granted = await router.requestSystemAudioAccess()
            guard !Task.isCancelled else {
                return
            }

            accessState = granted ? .granted : .denied
            accessTask = nil
            if granted {
                applyCurrentTargets()
            } else {
                router.update(targets: [], outputDeviceUID: snapshot.outputDeviceUID)
                if openSettingsOnFailure {
                    Self.openSystemAudioPrivacySettings()
                }
            }
            onStateChange?()
        }
    }

    // MARK: - Panel presentation

    private var panelSubtitle: String {
        guard router.isSupported else {
            return localization.string("panel.subtitle.unsupported", defaultValue: "需要 macOS 15 或更高版本")
        }

        let count = snapshot.applications.count
        guard count > 0 else {
            return localization.string("panel.subtitle.empty", defaultValue: "暂无正在播放音频的应用")
        }

        return localization.format(
            "panel.subtitle.countFormat",
            defaultValue: "%d 个应用正在播放",
            count
        )
    }

    private var panelErrorMessage: String? {
        guard router.isSupported else {
            return localization.string(
                "error.unsupported",
                defaultValue: "应用独立音量需要 macOS 15 或更高版本"
            )
        }

        guard accessState == .denied else {
            return nil
        }

        return localization.string("error.permissionDenied", defaultValue: "需要系统音频录制权限")
    }

    private func panelDetail(applications: [AudioApplication]) -> PluginPanelDetail? {
        guard router.isSupported, isExpanded else {
            return nil
        }

        var controls = applications.map { application in
            let value = volume(for: application.id)
            return PluginPanelControl(
                id: controlID(applicationID: application.id),
                kind: .slider,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: application.displayName,
                sliderValue: value,
                sliderBounds: 0...1,
                sliderStep: 0.01,
                valueLabel: Self.percentLabel(value),
                isEnabled: accessState != .requesting
            )
        }

        if accessState == .denied {
            controls.append(
                PluginPanelControl(
                    id: ControlID.openPermission,
                    kind: .actionRow,
                    options: [],
                    selectedOptionID: nil,
                    dateValue: nil,
                    minimumDate: nil,
                    displayedComponents: nil,
                    datePickerStyle: nil,
                    sectionTitle: localization.string(
                        "panel.permission.description",
                        defaultValue: "允许后才能实时处理其他应用的音频。"
                    ),
                    actionTitle: localization.string(
                        "panel.permission.openSettings",
                        defaultValue: "打开隐私设置"
                    ),
                    actionIconSystemName: "lock.open",
                    showsLeadingDivider: !controls.isEmpty,
                    isEnabled: true
                )
            )
        }

        return PluginPanelDetail(controls: controls)
    }

    private func rebuildControlApplicationIDs() {
        controlApplicationIDs = Dictionary(
            uniqueKeysWithValues: snapshot.applications.map {
                (controlID(applicationID: $0.id), $0.id)
            }
        )
    }

    private func controlID(applicationID: String) -> String {
        ControlID.volumePrefix + Data(applicationID.utf8).base64EncodedString()
    }

    private func volume(for applicationID: String) -> Double {
        max(0, min(1, volumes[applicationID] ?? 1))
    }

    // MARK: - Persistence

    private static func loadVolumes(storage: PluginStorage) -> [String: Double] {
        guard let data = storage.data(forKey: StorageKey.volumes),
              let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
            return [:]
        }

        return decoded.mapValues { max(0, min(1, $0)) }
    }

    private func saveVolumes() {
        guard let data = try? JSONEncoder().encode(volumes) else {
            return
        }
        storage.set(data, forKey: StorageKey.volumes)
    }

    private static func percentLabel(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func isUnity(_ gain: Double) -> Bool {
        abs(gain - 1) < 0.005
    }

    private static func openSystemAudioPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate), NSWorkspace.shared.open(url) else {
                continue
            }
            return
        }
    }
}
