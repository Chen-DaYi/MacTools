import AppKit
import Foundation
import MacToolsPluginKit

@MainActor
final class ActivityBarController: ObservableObject {
    static let pluginID = ActivityBarConstants.pluginID
    static let defaultSocketPath = ActivityBarConstants.defaultSocketPath

    enum HookInstallState: Equatable {
        case notInstalled
        case installed(timestamp: String)
        case failed
    }

    private enum StorageKey {
        static let isTrackingEnabled = "activity-bar.tracking.enabled"
        static let hooksInstalledAt = "activity-bar.hooks.installed-at"
    }

    @Published private(set) var isTrackingEnabled: Bool
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var hookInstallState: HookInstallState = .notInstalled

    let localization: PluginLocalization
    let inputStats: ActivityBarStatsStore
    let codingStats: ActivityBarCodingSessionStore

    var onStateChange: (() -> Void)?

    private let storage: PluginStorage
    private let inputMonitor: any ActivityBarInputMonitoring
    private let socketServer: any ActivityBarSocketServing
    private let inputEventNotificationDelay: Duration
    private var hookInstallerPaths: ActivityBarHookInstallerPaths
    private var inputEventNotificationTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?

    init(
        context: PluginRuntimeContext,
        inputMonitor: (any ActivityBarInputMonitoring)? = nil,
        socketServer: (any ActivityBarSocketServing)? = nil,
        inputStats: ActivityBarStatsStore? = nil,
        codingStats: ActivityBarCodingSessionStore? = nil,
        hookInstallerPaths: ActivityBarHookInstallerPaths? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        inputEventNotificationDelay: Duration = .milliseconds(750)
    ) {
        let resolvedInputStats = inputStats ?? ActivityBarStatsStore(storage: context.storage)
        let resolvedCodingStats = codingStats ?? ActivityBarCodingSessionStore(storage: context.storage)
        let resolvedInputMonitor = inputMonitor ?? ActivityBarInputMonitor()
        let resolvedHookInstallerPaths = hookInstallerPaths
            ?? ActivityBarHookInstallerPaths.defaults(
                supportDirectory: context.supportDirectory,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        let resolvedSocketServer = socketServer ?? ActivityBarHookSocketServer { event in
            resolvedCodingStats.handleEvent(event)
        }

        storage = context.storage
        self.localization = localization
        self.inputStats = resolvedInputStats
        self.codingStats = resolvedCodingStats
        self.inputMonitor = resolvedInputMonitor
        self.hookInstallerPaths = resolvedHookInstallerPaths
        self.socketServer = resolvedSocketServer
        self.inputEventNotificationDelay = inputEventNotificationDelay
        isTrackingEnabled = context.storage.bool(forKey: StorageKey.isTrackingEnabled)

        self.inputMonitor.onEvent = { [weak self] event in
            guard let self else {
                return
            }
            self.inputStats.record(event)
            self.scheduleInputEventNotification()
        }

        if let installedAt = context.storage.string(forKey: StorageKey.hooksInstalledAt) {
            hookInstallState = .installed(timestamp: installedAt)
        }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.inputStats.flushPendingChanges()
                self?.codingStats.flushActiveDurations()
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            inputEventNotificationTask?.cancel()
            if let terminateObserver {
                NotificationCenter.default.removeObserver(terminateObserver)
            }
        }
    }

    var hookStatusMessage: String? {
        switch hookInstallState {
        case .notInstalled:
            return nil
        case .installed(let timestamp):
            return localization.format("hook.status.installedWithDate", defaultValue: "已安装：%@", timestamp)
        case .failed:
            return localization.string("hook.status.installFailed", defaultValue: "安装失败")
        }
    }

    var monitorStatus: ActivityBarInputMonitorStatus {
        inputMonitor.status
    }

    var todayInputStats: ActivityBarDailyStats {
        inputStats.today
    }

    var todayCodingStats: ActivityBarCodingDailyStats {
        codingStats.today
    }

    var panelSubtitle: String {
        if let lastErrorMessage {
            return lastErrorMessage
        }

        if isTrackingEnabled {
            return localization.format(
                "panel.subtitle.todayInputs",
                defaultValue: "今日 %@ 次输入",
                ActivityBarFormatting.count(todayInputStats.totalInputs)
            )
        }

        return localization.string("panel.subtitle.default", defaultValue: "统计输入与 AI 编程活动")
    }

    var componentSubtitle: String {
        if isTrackingEnabled {
            return localization.format(
                "component.subtitle.inputs",
                defaultValue: "%@ 次输入",
                ActivityBarFormatting.count(todayInputStats.totalInputs)
            )
        }
        return localization.string("component.subtitle.disabled", defaultValue: "未开启")
    }

    var inputMonitoringFootnote: String? {
        switch inputMonitor.status {
        case .inputMonitoringDenied:
            return localization.string(
                "settings.inputMonitoring.footnote",
                defaultValue: "键盘、鼠标和滚动统计需要在系统设置中允许 MacTools 进行输入监控。前台应用使用时长仍可记录。"
            )
        case .idle, .running:
            return nil
        }
    }

    var hookInstallFootnote: String {
        localization.string(
            "settings.aiHooks.footnote",
            defaultValue: "点击后会写入 Claude Code、Cursor 和 Codex 的 hook 配置；脚本只在本机通过 Unix socket 发送活动事件。"
        )
    }

    func activate(context: PluginRuntimeContext) {
        hookInstallerPaths = ActivityBarHookInstallerPaths.defaults(
            supportDirectory: context.supportDirectory,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )

        if isTrackingEnabled {
            startTracking()
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        guard reason.requiresStateCleanup else {
            return
        }

        stopRuntime()
        inputEventNotificationTask?.cancel()
        inputEventNotificationTask = nil
        inputStats.flushPendingChanges()
    }

    func refresh() {
        inputStats.flushPendingChanges()
        codingStats.flushActiveDurations()
        notifyChange()
    }

    func setTrackingEnabled(_ enabled: Bool) {
        isTrackingEnabled = enabled
        storage.set(enabled, forKey: StorageKey.isTrackingEnabled)

        if enabled {
            startTracking()
        } else {
            stopRuntime()
            lastErrorMessage = nil
        }

        notifyChange()
    }

    func resetToday() {
        inputStats.resetToday()
        codingStats.resetToday()
        notifyChange()
    }

    func installHooks() {
        let installer = ActivityBarHookInstaller(paths: hookInstallerPaths)

        do {
            let summary = try installer.install()
            let timestamp = Self.installTimestamp()
            storage.set(timestamp, forKey: StorageKey.hooksInstalledAt)
            hookInstallState = .installed(timestamp: timestamp)
            lastErrorMessage = nil
            ActivityBarLog.hooks.info(
                "Activity bar hooks installed in \(summary.scriptDirectory.path, privacy: .public)"
            )
        } catch {
            lastErrorMessage = localization.format(
                "error.hook.installFailed",
                defaultValue: "Hook 安装失败：%@",
                localizedDescription(for: error)
            )
            hookInstallState = .failed
            ActivityBarLog.hooks.error("Activity bar hook installation failed: \(error.localizedDescription, privacy: .public)")
        }

        notifyChange()
    }

    func openInputMonitoringSettings() {
        openPrivacyPane(anchor: "Privacy_ListenEvent")
    }

    private func startTracking() {
        lastErrorMessage = nil
        inputMonitor.start()

        do {
            try socketServer.start()
        } catch {
            lastErrorMessage = localization.format(
                "error.socket.startFailed",
                defaultValue: "AI 活动监听启动失败：%@",
                localizedDescription(for: error)
            )
            ActivityBarLog.socket.error("Activity bar socket start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopRuntime() {
        inputMonitor.stop()
        socketServer.stop()
        inputStats.flushPendingChanges()
        codingStats.flushActiveDurations()
    }

    private func openPrivacyPane(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func notifyChange() {
        inputEventNotificationTask?.cancel()
        inputEventNotificationTask = nil
        objectWillChange.send()
        onStateChange?()
    }

    private func scheduleInputEventNotification() {
        guard inputEventNotificationTask == nil else {
            return
        }

        inputEventNotificationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: inputEventNotificationDelay)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            inputEventNotificationTask = nil
            objectWillChange.send()
            onStateChange?()
        }
    }

    private func localizedDescription(for error: Error) -> String {
        if let hookError = error as? ActivityBarHookInstallerError {
            return hookError.localizedDescription(localization: localization)
        }
        if let socketError = error as? ActivityBarSocketError {
            return socketError.localizedDescription(localization: localization)
        }
        return error.localizedDescription
    }

    private static func installTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}
