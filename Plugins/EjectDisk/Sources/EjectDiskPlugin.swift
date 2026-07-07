import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

public final class EjectDiskPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        EjectDiskPluginProvider(context: context)
    }
}

@MainActor
private struct EjectDiskPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [EjectDiskPlugin(localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class EjectDiskPlugin: MacToolsPlugin, PluginPrimaryPanel {
    let metadata: PluginMetadata

    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let localization: PluginLocalization
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "EjectDiskPlugin")
    private var isEjecting = false
    private var ejectableDiskCount: Int = 0
    private var lastErrorMessage: String?
    private var volumeMountObservers: [NSObjectProtocol] = []

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
        self.metadata = PluginMetadata(
            id: "eject-disk",
            title: localization.string("metadata.title", defaultValue: "推出磁盘"),
            iconName: "eject",
            iconTint: Color(nsColor: .systemGray),
            order: 92,
            defaultDescription: localization.string("metadata.description", defaultValue: "推出所有可移动磁盘")
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .keepPresented,
            buttonTitle: localization.string("panel.button.eject", defaultValue: "推出")
        )
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: subtitle,
            isOn: false,
            isExpanded: false,
            isEnabled: !isEjecting && ejectableDiskCount > 0,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func refresh() {
        let count = Self.ejectableDiskCountSync()
        if self.ejectableDiskCount != count {
            self.ejectableDiskCount = count
            self.onStateChange?()
        }
        
        setupVolumeMountObserver()
    }
    
    private func setupVolumeMountObserver() {
        guard volumeMountObservers.isEmpty else { return }
        
        let workspace = NSWorkspace.shared
        let notificationCenter = NSWorkspace.shared.notificationCenter
        
        let mountObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForEjectableDiskAndUpdate()
            }
        }
        
        let unmountObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForEjectableDiskAndUpdate()
            }
        }
        
        volumeMountObservers.append(mountObserver)
        volumeMountObservers.append(unmountObserver)
    }
    
    private func checkForEjectableDiskAndUpdate() {
        let count = Self.ejectableDiskCountSync()
        if self.ejectableDiskCount != count {
            self.ejectableDiskCount = count
            self.onStateChange?()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .invokeAction(controlID):
            if controlID == "execute" {
                ejectAllDisks()
            }
        default:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(id: String) {}
    func handleShortcutAction(id: String) {}

    // MARK: - Private

    private var subtitle: String {
        if isEjecting {
            return localization.string("panel.subtitle.ejecting", defaultValue: "推出中...")
        }
        if ejectableDiskCount == 0 {
            return localization.string("panel.subtitle.none", defaultValue: "无可推出的磁盘")
        }
        return localization.format(
            "panel.subtitle.countFormat",
            defaultValue: "%d 个可推出的磁盘",
            ejectableDiskCount
        )
    }

    nonisolated private static func ejectableDiskCountSync() -> Int {
        let fileManager = FileManager.default
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools", category: "EjectDiskPlugin")
        
        do {
            let volumesPath = "/Volumes"
            guard fileManager.fileExists(atPath: volumesPath) else {
                return 0
            }
            
            let ejectableVolumes = try getEjectableVolumes(from: volumesPath)
            logger.debug("Found \(ejectableVolumes.count) ejectable volumes")
            return ejectableVolumes.count
            
        } catch {
            logger.error("Failed to check ejectable disks: \(error)")
            return 0
        }
    }
    
    nonisolated private static func getEjectableVolumes(from volumesPath: String) throws -> [String] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(atPath: volumesPath)
        
        return contents.filter { name in
            if name == "Macintosh HD" || name.hasPrefix(".") {
                return false
            }
            
            let volumePath = "\(volumesPath)/\(name)"
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: volumePath, isDirectory: &isDir)
            
            return exists && isDir.boolValue
        }
    }

    private func ejectAllDisks() {
        guard !isEjecting else { return }

        isEjecting = true
        lastErrorMessage = nil
        onStateChange?()

        Task {
            do {
                try await executeEjectAll()

                await MainActor.run {
                    isEjecting = false
                    lastErrorMessage = nil
                    onStateChange?()
                }
            } catch {
                let errorMessage = error.localizedDescription
                logger.error("Failed to eject disks: \(errorMessage)")

                await MainActor.run {
                    isEjecting = false
                    lastErrorMessage = errorMessage
                    onStateChange?()
                }
            }
        }
    }

    private func executeEjectAll() async throws {
        let fileManager = FileManager.default
        let volumesPath = "/Volumes"
        
        guard fileManager.fileExists(atPath: volumesPath) else {
            throw NSError(
                domain: "EjectDiskPlugin",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: localization.string(
                        "error.volumesUnavailable",
                        defaultValue: "/Volumes 目录不可用"
                    )
                ]
            )
        }
        
        let ejectableVolumes = try Self.getEjectableVolumes(from: volumesPath)
        
        guard !ejectableVolumes.isEmpty else {
            throw NSError(
                domain: "EjectDiskPlugin",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: localization.string(
                        "error.noEjectableDisks",
                        defaultValue: "未找到可推出的磁盘"
                    )
                ]
            )
        }
        
        var successCount = 0
        var errorMessages: [String] = []
        
        for volumeName in ejectableVolumes {
            let volumePath = "\(volumesPath)/\(volumeName)"
            
            do {
                try await ejectVolume(at: volumePath)
                successCount += 1
                logger.info("Successfully ejected volume: \(volumeName)")
            } catch {
                errorMessages.append("- \(volumeName): \(error.localizedDescription)")
                logger.error("Failed to eject volume '\(volumeName)': \(error.localizedDescription)")
            }
        }
        
        if !errorMessages.isEmpty {
            let message = localization.format(
                "error.partialFailureFormat",
                defaultValue: "已推出 %d 个磁盘，%d 个失败:\n%@",
                successCount,
                errorMessages.count,
                errorMessages.joined(separator: "\n")
            )
            throw NSError(domain: "EjectDiskPlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func ejectVolume(at volumePath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", volumePath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorMessage = output.isEmpty
                ? localization.string("error.ejectFailed", defaultValue: "推出失败")
                : output
            throw NSError(domain: "EjectDiskPlugin", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }
}
