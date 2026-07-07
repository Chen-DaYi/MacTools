import AppKit
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

// MARK: - Factory

public final class FixDamagedAppPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        FixDamagedAppPluginProvider(context: context)
    }
}

@MainActor
private struct FixDamagedAppPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [FixDamagedAppPlugin(context: context)]
    }
}

// MARK: - Plugin

@MainActor
final class FixDamagedAppPlugin: MacToolsPlugin, PluginPrimaryPanel, DropZoneAnchorProviding {

    // MARK: Metadata

    let metadata: PluginMetadata

    // MARK: State

    private enum FixState: Equatable {
        case idle
        case running
        case success(appName: String)
        case failure(message: String)
    }

    private var selectedApp: URL?
    private var fixState: FixState = .idle

    // MARK: Drag Detection State

    private let storage: PluginStorage
    private var mouseDownMonitor: Any?
    private var dragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var dropZonePanel: FixDamagedAppDropZonePanel?
    private var isDragPanelShowing = false
    private var isMouseButtonDown = false
    /// Drag pasteboard change count captured at mouseDown to identify a new drag session.
    private var dragSessionPasteboardChangeCount: Int = Int.min
    private let localization: PluginLocalization

    // MARK: DropZoneAnchorProviding

    var anchorRectProvider: (() -> NSRect?)?

    var isDragDetectionEnabled: Bool {
        storage.bool(forKey: StorageKey.isDragDetectionEnabled)
    }

    // MARK: Storage Keys

    private enum StorageKey {
        static let isDragDetectionEnabled = "drag-detection-enabled"
    }

    // MARK: MacToolsPlugin

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "FixDamagedAppPlugin"
    )

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var settingsSections: [PluginSettingsSection] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    // MARK: Init

    init(context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "fix-damaged-app")) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.storage = context.storage
        self.metadata = PluginMetadata(
            id: "fix-damaged-app",
            title: localization.string("metadata.title", defaultValue: "修复损坏应用"),
            iconName: "wrench.and.screwdriver.fill",
            iconTint: Color(nsColor: .systemOrange),
            order: 94,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "移除隔离属性，解决「已损坏」或「不受信任」提示"
            )
        )
        self.primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitle: localization.string("panel.button.choose", defaultValue: "选择")
        )
    }

    // MARK: Lifecycle

    func activate(context: PluginRuntimeContext) {
        updateDragMonitoring()
    }

    func deactivate(reason: PluginDeactivationReason) {
        stopDragMonitoring()
        hideDropZonePanel()
    }

    func refresh() {}

    // MARK: Configuration

    var configuration: PluginConfiguration? {
        PluginConfiguration(description: metadata.defaultDescription) { [weak self] _ in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                FixDamagedAppSettingsView(
                    isDragDetectionEnabled: self.isDragDetectionEnabled,
                    localization: self.localization,
                    onToggle: { [weak self] isOn in
                        self?.setDragDetectionEnabled(isOn)
                    }
                )
            )
        }
    }

    func setDragDetectionEnabled(_ enabled: Bool) {
        storage.set(enabled, forKey: StorageKey.isDragDetectionEnabled)
        updateDragMonitoring()
        onStateChange?()
    }

    // MARK: PluginPrimaryPanel

    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: primarySubtitle,
            isOn: false,
            isExpanded: false,
            isEnabled: fixState != .running,
            isVisible: true,
            detail: nil,
            errorMessage: primaryError
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case .invokeAction(let controlID):
            handleControlAction(controlID: controlID)
        default:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    // MARK: Private

    private func handleControlAction(controlID: String) {
        switch controlID {
        case "execute":
            chooseApp()
        default:
            break
        }
    }

    private var primarySubtitle: String {
        switch fixState {
        case .idle:
            return selectedApp.map { $0.deletingPathExtension().lastPathComponent }
                ?? localization.string("panel.subtitle.chooseApp", defaultValue: "选择 .app 文件以修复")
        case .running:
            return localization.string("panel.subtitle.running", defaultValue: "修复中…")
        case .success(let name):
            return localization.format("panel.subtitle.successFormat", defaultValue: "已修复：%@", name)
        case .failure:
            return selectedApp.map { $0.deletingPathExtension().lastPathComponent }
                ?? localization.string("panel.subtitle.chooseApp", defaultValue: "选择 .app 文件以修复")
        }
    }

    private var primaryError: String? {
        guard case .failure(let message) = fixState else { return nil }
        return message
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = localization.string("openPanel.title", defaultValue: "选择要修复的应用")
        panel.message = localization.string("openPanel.message", defaultValue: "选择显示「已损坏」或「不受信任」的应用")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let appBundleType = UTType("com.apple.application-bundle") {
            panel.allowedContentTypes = [appBundleType]
        }
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        selectedApp = url
        fixState = .idle
        onStateChange?()
        performFix()
    }

    private func performFix() {
        guard let appURL = selectedApp, fixState != .running else { return }
        let appPath = appURL.path
        let appName = appURL.deletingPathExtension().lastPathComponent
        fixState = .running
        onStateChange?()
        Task {
            do {
                try await self.removeQuarantine(appPath: appPath)
                await MainActor.run {
                    self.fixState = .success(appName: appName)
                    self.onStateChange?()
                }
            } catch {
                let message = error.localizedDescription
                self.logger.error("Quarantine removal failed for '\(appPath)': \(message)")
                await MainActor.run {
                    self.fixState = .failure(message: message)
                    self.onStateChange?()
                }
            }
        }
    }

    private func removeQuarantine(appPath: String) async throws {
        let localization = localization
        try await Task.detached(priority: .userInitiated) {
            try runQuarantineRemoval(appPath: appPath, localization: localization)
        }.value
    }

    // MARK: Private - Drag Monitoring

    private func updateDragMonitoring() {
        stopDragMonitoring()
        guard isDragDetectionEnabled else { return }
        startDragMonitoring()
    }

    private func startDragMonitoring() {
        // Global NSEvent monitors fire on the main thread. Run synchronously with
        // `MainActor.assumeIsolated` so multiple events cannot pass the `isDragPanelShowing`
        // check while queued through async Tasks.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isMouseButtonDown = true
                // Capture the current drag pasteboard version; only a later changeCount indicates
                // that a real drag started.
                self?.dragSessionPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
            }
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleGlobalDrag()
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isMouseButtonDown = false
                self?.handleGlobalMouseUp()
            }
        }
    }

    private func stopDragMonitoring() {
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        isMouseButtonDown = false
    }

    private func handleGlobalDrag() {
        guard !isDragPanelShowing, isMouseButtonDown else { return }
        let pb = NSPasteboard(name: .drag)
        // React only after the drag pasteboard changes during this mouse-down cycle. This prevents
        // stale drag pasteboard data from showing the panel on normal clicks, such as opening Finder.
        guard pb.changeCount != dragSessionPasteboardChangeCount else { return }
        guard
            let urls = pb.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL],
            urls.contains(where: { $0.pathExtension.lowercased() == "app" })
        else { return }
        showDropZonePanel()
    }

    private func handleGlobalMouseUp() {
        guard isDragPanelShowing else { return }
        // If the pointer is inside the panel, the file was dropped into the window and the drop
        // pipeline owns dismissal. The global mouseUp arrives before SwiftUI `onDrop`, so it cannot
        // rely on `isDropPending` having been set yet.
        if let panel = dropZonePanel, panel.frame.contains(NSEvent.mouseLocation) { return }
        dropZonePanel?.dismissIfIdle()
    }

    private func showDropZonePanel() {
        isDragPanelShowing = true
        let vm = DropZoneViewModel(
            localization: localization,
            onComplete: { [weak self] appName, succeeded, errorMessage in
                guard let self else { return }
                if succeeded {
                    self.fixState = .success(appName: appName)
                } else {
                    self.fixState = .failure(
                        message: errorMessage
                            ?? self.localization.string("error.fixFailed", defaultValue: "修复失败")
                    )
                }
                self.onStateChange?()
            },
            onDismiss: { [weak self] in
                self?.hideDropZonePanel()
            }
        )
        let panel = FixDamagedAppDropZonePanel(viewModel: vm, localization: localization)
        positionDropZonePanel(panel)
        panel.makeKeyAndOrderFront(nil)
        dropZonePanel = panel
    }

    private func hideDropZonePanel() {
        dropZonePanel?.orderOut(nil)
        dropZonePanel = nil
        isDragPanelShowing = false
    }

    private func positionDropZonePanel(_ panel: NSPanel) {
        let panelSize = panel.frame.size

        if let anchorRect = anchorRectProvider?() {
            let screenMaxX = NSScreen.main?.frame.maxX ?? 1440
            let rawX = anchorRect.midX - panelSize.width / 2
            let x = max(8, min(rawX, screenMaxX - panelSize.width - 8))
            let y = anchorRect.minY - panelSize.height - 4
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        guard let screen = NSScreen.main else { return }
        let menuBarThickness = NSStatusBar.system.thickness
        let x = screen.frame.midX - panelSize.width / 2
        let y = screen.frame.maxY - menuBarThickness - panelSize.height - 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Quarantine Removal (nonisolated helper)

func runQuarantineRemoval(appPath: String) throws {
    try runQuarantineRemoval(appPath: appPath, localization: PluginLocalization(bundle: .main))
}

func runQuarantineRemoval(appPath: String, localization: PluginLocalization) throws {
    // Reject paths containing double-quote to prevent AppleScript string literal injection
    guard !appPath.contains("\"") else {
        throw NSError(
            domain: "FixDamagedAppPlugin",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: localization.string(
                    "error.unsupportedPathCharacters",
                    defaultValue: "应用路径包含不支持的字符（双引号）"
                )
            ]
        )
    }
    // Use AppleScript's `quoted form of` to safely quote the path in the shell command
    let script = """
    set appPath to "\(appPath)"
    do shell script "xattr -r -d com.apple.quarantine " & quoted form of appPath with administrator privileges
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errMsg = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if errMsg.contains("-128") || errMsg.contains("User canceled") {
            throw NSError(
                domain: "FixDamagedAppPlugin",
                code: -128,
                userInfo: [
                    NSLocalizedDescriptionKey: localization.string(
                        "error.userCancelledAuthorization",
                        defaultValue: "用户取消了授权"
                    )
                ]
            )
        }
        throw NSError(
            domain: "FixDamagedAppPlugin",
            code: Int(process.terminationStatus),
            userInfo: [
                NSLocalizedDescriptionKey: errMsg.isEmpty
                    ? localization.string("error.fixFailedUnknown", defaultValue: "修复失败（未知错误）")
                    : errMsg
            ]
        )
    }
}
