import AppKit
import Foundation
import MacToolsPluginKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol R2ClipboardWriting: AnyObject {
    func copy(_ value: String)
}

@MainActor
final class R2SystemClipboardWriter: R2ClipboardWriting {
    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
protocol R2UploadCompletionNotifying: AnyObject {
    func notify(fileName: String, result: R2UploadResult) -> Bool
}

@MainActor
final class R2SystemUploadCompletionNotifier: R2UploadCompletionNotifying {
    func notify(fileName: String, result: R2UploadResult) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "R2 上传完成"
        alert.informativeText = "\(fileName) 已上传到 R2。"
        if result.url != nil {
            alert.addButton(withTitle: "复制链接")
        }
        alert.addButton(withTitle: "好的")
        PluginPresentationSafety.prepareForWindowOrdering()
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return result.url != nil && response == .alertFirstButtonReturn
    }
}

final class R2ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (Double) -> Void
    private var lastPercentage = 0

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(_ progress: Double) {
        let clamped = min(1, max(0, progress))
        let percentage = Int(clamped * 100)
        let shouldReport = lock.withLock {
            guard percentage > lastPercentage else { return false }
            lastPercentage = percentage
            return true
        }
        guard shouldReport else { return }
        handler(Double(percentage) / 100)
    }
}

public final class CloudflareR2PluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(
        context: PluginRuntimeContext
    ) throws -> any PluginProvider {
        CloudflareR2PluginProvider(context: context)
    }
}

@MainActor
private struct CloudflareR2PluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [CloudflareR2Plugin(context: context)]
    }
}

@MainActor
final class CloudflareR2Plugin: ObservableObject, MacToolsPlugin, PluginPrimaryPanel,
    PluginSettingsPresenting, PluginActionProviding
{
    enum ControlID {
        static let upload = "execute"
    }

    enum ShortcutID {
        static let upload = "upload-file"
    }

    enum ActionID {
        static let upload = "upload-file"
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor: PluginPrimaryPanelDescriptor
    let configurationStore: R2ConfigurationStore
    @Published private(set) var status = R2UploadStatus.idle

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    private let uploader: R2Uploading
    private let filePicker: @MainActor @Sendable () -> URL?
    private let clipboard: any R2ClipboardWriting
    private let completionNotifier: any R2UploadCompletionNotifying
    private let logger: Logger
    private let terminalStatusDuration: Duration?
    private var uploadTask: Task<R2UploadResult, Error>?
    private var statusResetTask: Task<Void, Never>?
    private var uploadGeneration: UInt64 = 0

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "cloudflare-r2"),
        uploader: R2Uploading = R2UploadService(),
        configurationStore: R2ConfigurationStore? = nil,
        filePicker: (@MainActor @Sendable () -> URL?)? = nil,
        clipboard: (any R2ClipboardWriting)? = nil,
        completionNotifier: (any R2UploadCompletionNotifying)? = nil,
        logger: Logger? = nil,
        terminalStatusDuration: Duration? = .seconds(5)
    ) {
        self.configurationStore = configurationStore
            ?? R2ConfigurationStore(storage: context.storage)
        self.uploader = uploader
        self.filePicker = filePicker ?? Self.chooseFile
        self.clipboard = clipboard ?? R2SystemClipboardWriter()
        self.completionNotifier = completionNotifier ?? R2SystemUploadCompletionNotifier()
        self.logger = logger ?? Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
            category: "CloudflareR2Plugin"
        )
        self.terminalStatusDuration = terminalStatusDuration
        metadata = PluginMetadata(
            id: "cloudflare-r2",
            title: "Cloudflare R2 上传",
            iconName: "icloud.and.arrow.up.fill",
            iconTint: Color(nsColor: .systemOrange),
            order: 75,
            defaultDescription: "上传文件并复制链接"
        )
        primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { "选择" }
        )
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [PluginShortcutDefinition(
            id: ShortcutID.upload,
            title: "选择文件并上传",
            description: "打开文件选择器并上传到 Cloudflare R2。",
            actionID: ShortcutID.upload,
            scope: .global,
            defaultBinding: nil,
            isRequired: false,
            settingsGroupID: "upload",
            settingsGroupTitle: "上传",
            settingsGroupDescription: "设置打开 R2 文件上传器的全局快捷键。"
        )]
    }

    var actionDefinitions: [ActionDefinition] {
        [ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.upload),
            title: "选择文件并上传到 R2",
            description: metadata.defaultDescription,
            keywords: ["R2", "S3", "Cloudflare", "上传"],
            systemImage: metadata.iconName,
            externalInvocationPolicy: .unavailable,
            capabilities: [.foregroundInteractive, .cancellable],
            concurrencyPolicy: .rejectWhileRunning,
            executionTimeoutSeconds: 3600
        )]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key == actionDefinitions.first?.key else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return isConfigured
            ? .available
            : .unavailable("请先完成 R2 配置。")
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let availability = actionAvailability(for: invocation.reference)
        guard availability.isAvailable else {
            return ActionExecutionHandle {
                .failed(message: availability.reason ?? PluginKitLocalization.actionUnavailable)
            }
        }

        return ActionExecutionHandle(operation: { [weak self] in
            guard let self, !Task.isCancelled else { return .cancelled }
            guard let fileURL = self.filePicker() else { return .cancelled }
            guard !Task.isCancelled else { return .cancelled }
            let task = self.beginUpload(fileURL)
            do {
                _ = try await task.value
                return .succeeded()
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }, cancel: { [weak self] in
            self?.cancelUpload()
        })
    }

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: status.subtitle,
            isOn: status.isUploading,
            isExpanded: false,
            isEnabled: !status.isUploading,
            isVisible: true,
            detail: nil,
            errorMessage: status.errorMessage
        )
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription, scrolling: .host) { [weak self] _ in
            if let self {
                R2SettingsView(plugin: self)
            } else {
                EmptyView()
            }
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        cancelUpload()
    }

    func handleShortcutAction(id: String) {
        guard id == ShortcutID.upload else { return }
        chooseAndUpload()
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(id) = action, id == ControlID.upload else { return }
        chooseAndUpload()
    }

    func chooseAndUpload() {
        guard isConfigured else {
            status = .failed("请先在设置中完成 R2 配置。")
            notifyStateChange()
            scheduleStatusReset(generation: uploadGeneration)
            requestSettingsPresentation?()
            return
        }
        guard let fileURL = filePicker() else { return }
        let task = beginUpload(fileURL)
        Task {
            _ = try? await task.value
        }
    }

    @discardableResult
    func beginUpload(_ fileURL: URL) -> Task<R2UploadResult, Error> {
        cancelActiveUpload(updateStatus: false)
        uploadGeneration &+= 1
        let generation = uploadGeneration
        let fileName = fileURL.lastPathComponent
        status = .uploading(fileName, progress: 0)
        notifyStateChange()

        let progressRelay = R2ProgressRelay { [weak self] progress in
            Task { @MainActor in
                self?.updateProgress(
                    progress,
                    fileName: fileName,
                    generation: generation
                )
            }
        }
        let task = Task { [weak self] () throws -> R2UploadResult in
            guard let self else { throw CancellationError() }
            return try await self.performUpload(
                fileURL,
                generation: generation,
                progressRelay: progressRelay
            )
        }
        uploadTask = task
        return task
    }

    func cancelUpload() {
        cancelActiveUpload(updateStatus: true)
    }

    private var isConfigured: Bool {
        configurationStore.configuration.isComplete
            && configurationStore.hasStoredSecret
    }

    private func performUpload(
        _ fileURL: URL,
        generation: UInt64,
        progressRelay: R2ProgressRelay
    ) async throws -> R2UploadResult {
        let configuration = configurationStore.configuration
        do {
            let secret = try configurationStore.loadSecret()
            let result = try await uploader.upload(
                fileURL: fileURL,
                configuration: configuration,
                secretAccessKey: secret,
                progress: progressRelay.report
            )
            try Task.checkCancellation()
            guard generation == uploadGeneration else {
                throw CancellationError()
            }

            uploadTask = nil
            status = .succeeded(result)
            notifyStateChange()
            let shouldCopyLink = completionNotifier.notify(
                fileName: fileURL.lastPathComponent,
                result: result
            )
            if shouldCopyLink, let url = result.url {
                clipboard.copy(url.absoluteString)
            }
            scheduleStatusReset(generation: generation)
            logger.info(
                "R2 upload succeeded for object \(result.objectKey, privacy: .public)"
            )
            return result
        } catch {
            guard generation == uploadGeneration,
                  !Task.isCancelled,
                  !Self.isCancellation(error) else {
                throw CancellationError()
            }
            uploadTask = nil
            status = .failed(error.localizedDescription)
            notifyStateChange()
            scheduleStatusReset(generation: generation)
            logger.error(
                "R2 upload failed: \(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    private func cancelActiveUpload(updateStatus: Bool) {
        uploadGeneration &+= 1
        uploadTask?.cancel()
        uploadTask = nil
        statusResetTask?.cancel()
        statusResetTask = nil
        if updateStatus, status != .idle {
            status = .idle
            notifyStateChange()
            logger.info("R2 upload cancelled")
        }
    }

    private func updateProgress(
        _ progress: Double,
        fileName: String,
        generation: UInt64
    ) {
        guard generation == uploadGeneration, status.isUploading else { return }
        status = .uploading(fileName, progress: min(1, max(0, progress)))
        notifyStateChange()
    }

    private func scheduleStatusReset(generation: UInt64) {
        statusResetTask?.cancel()
        guard let terminalStatusDuration else { return }
        statusResetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: terminalStatusDuration)
            } catch {
                return
            }
            guard let self,
                  generation == self.uploadGeneration,
                  !self.status.isUploading else {
                return
            }
            self.status = .idle
            self.statusResetTask = nil
            self.notifyStateChange()
        }
    }

    private func notifyStateChange() {
        onStateChange?()
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择要上传到 R2 的文件"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        PluginPresentationSafety.prepareForWindowOrdering()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum R2UploadStatus: Equatable {
    case idle
    case uploading(String, progress: Double)
    case succeeded(R2UploadResult)
    case failed(String)

    var isUploading: Bool {
        if case .uploading = self { true } else { false }
    }

    var errorMessage: String? {
        if case let .failed(message) = self { message } else { nil }
    }

    var subtitle: String {
        switch self {
        case .idle:
            "上传文件并复制链接"
        case let .uploading(name, progress):
            "正在上传 \(name)… \(Int(progress * 100))%"
        case let .succeeded(result):
            "上传完成：\(result.objectKey)"
        case .failed:
            "上传失败"
        }
    }
}
