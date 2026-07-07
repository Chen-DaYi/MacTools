import Foundation
import OSLog
import ServiceManagement

/// Minimal abstraction over `SMAppService.mainApp` so tests can inject a controllable fake.
@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let appService: SMAppService

    init(appService: SMAppService = .mainApp) {
        self.appService = appService
    }

    var isRegistered: Bool {
        appService.status == .enabled
    }

    func register() throws {
        try appService.register()
    }

    func unregister() throws {
        try appService.unregister()
    }
}

/// Maintains launch-at-login state and wraps `SMAppService.mainApp` register/unregister calls.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var lastErrorMessage: String?

    private let service: LaunchAtLoginServicing
    private let logger: Logger

    init(
        service: LaunchAtLoginServicing = SystemLaunchAtLoginService(),
        logger: Logger = AppLog.launchAtLogin
    ) {
        self.service = service
        self.logger = logger
        self.isEnabled = service.isRegistered
    }

    /// Toggles login-item registration and rolls `isEnabled` back to the system state on failure.
    func setEnabled(_ enabled: Bool) {
        let currentStatus = service.isRegistered
        guard currentStatus != enabled else {
            if isEnabled != currentStatus {
                isEnabled = currentStatus
            }
            lastErrorMessage = nil
            return
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            lastErrorMessage = nil
        } catch {
            logger.error(
                "Failed to \(enabled ? "register" : "unregister", privacy: .public) login item: \(error.localizedDescription, privacy: .public)"
            )
            lastErrorMessage = enabled
                ? AppL10n.settings(
                    "launchAtLogin.error.enableFailed",
                    defaultValue: "无法开启开机自启动，请稍后重试或前往系统设置 > 通用 > 登录项中检查权限。"
                )
                : AppL10n.settings(
                    "launchAtLogin.error.disableFailed",
                    defaultValue: "无法关闭开机自启动，请稍后重试或前往系统设置 > 通用 > 登录项中手动移除。"
                )
        }

        let updated = service.isRegistered
        if isEnabled != updated {
            isEnabled = updated
        }
    }

    /// Re-reads registration state from the system, such as after changes in System Settings.
    func refreshStatus() {
        let updated = service.isRegistered
        if isEnabled != updated {
            isEnabled = updated
        }
    }

    func clearError() {
        lastErrorMessage = nil
    }
}
