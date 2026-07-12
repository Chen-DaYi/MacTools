import XCTest
import MacToolsPluginKit
@testable import ActivityBarPlugin

@MainActor
final class ActivityBarPluginTests: XCTestCase {
    func testMonthDayFormattingUsesLocaleSpecificFieldOrder() {
        let date = Calendar(identifier: .gregorian).date(
            from: DateComponents(
                timeZone: TimeZone(secondsFromGMT: 0),
                year: 2026,
                month: 1,
                day: 2,
                hour: 12
            )
        )!
        let locale = Locale(identifier: "de_DE")
        let expectedFormatter = DateFormatter()
        expectedFormatter.locale = locale
        expectedFormatter.setLocalizedDateFormatFromTemplate("MMM d")

        XCTAssertEqual(
            ActivityBarFormatting.monthDay(date, locale: locale),
            expectedFormatter.string(from: date)
        )
    }

    func testMetadataAndPanelsAreExposed() {
        let harness = makeHarness()

        XCTAssertEqual(harness.plugin.metadata.id, "activity-bar")
        XCTAssertEqual(harness.plugin.metadata.title, "活动统计")
        XCTAssertEqual(harness.plugin.primaryPanelDescriptor.controlStyle, .disclosure)
        XCTAssertEqual(harness.plugin.descriptor.span, PluginComponentSpan(width: 4, height: 127)!)
    }

    func testVisibleCodingToolsIncludeCursor() {
        XCTAssertEqual(ActivityBarComponentView.visibleCodingTools, [.claudeCode, .cursor, .codex])
    }

    func testPrimaryPanelStartsCollapsed() {
        let harness = makeHarness()

        XCTAssertFalse(harness.plugin.primaryPanelState.isExpanded)
        XCTAssertNil(harness.plugin.primaryPanelState.detail)
    }

    func testPrimaryPanelExpandsWithTrackingSwitchAndActions() throws {
        let harness = makeHarness()

        harness.plugin.handleAction(.setDisclosureExpanded(true))

        let state = harness.plugin.primaryPanelState
        let controls = try XCTUnwrap(state.detail?.primaryControls)

        XCTAssertTrue(state.isExpanded)
        XCTAssertEqual(controls.map(\.id), [
            "tracking-enabled",
            "open-input-monitoring",
            "install-hooks",
            "reset-today"
        ])
        XCTAssertEqual(controls.first?.kind, .switchRow)
        XCTAssertFalse(state.isOn)
    }

    func testHookSettingUsesSingleDynamicAction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: root,
            hookScriptsDirectory: root.appendingPathComponent("hooks")
        )
        let harness = makeHarness(hookInstallerPaths: paths)

        var hookSections = harness.plugin.settingsSections.filter { $0.id.hasPrefix("ai-hooks") }

        XCTAssertEqual(hookSections.count, 1)
        XCTAssertEqual(hookSections.first?.id, "ai-hooks")
        XCTAssertEqual(hookSections.first?.buttonTitle, "安装或更新 Hook")
        XCTAssertEqual(hookSections.first?.actionID, "install-hooks")

        harness.controller.installHooks()
        hookSections = harness.plugin.settingsSections.filter { $0.id.hasPrefix("ai-hooks") }

        XCTAssertEqual(hookSections.count, 1)
        XCTAssertEqual(hookSections.first?.id, "ai-hooks")
        XCTAssertEqual(hookSections.first?.buttonTitle, "卸载 Hook")
        XCTAssertEqual(hookSections.first?.actionID, "uninstall-hooks")
    }

    func testPrimaryPanelShowsUninstallActionAfterHooksInstalled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: root,
            hookScriptsDirectory: root.appendingPathComponent("hooks")
        )
        let harness = makeHarness(hookInstallerPaths: paths)

        harness.controller.installHooks()
        harness.plugin.handleAction(.setDisclosureExpanded(true))

        let controls = try XCTUnwrap(harness.plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(controls.map(\.id), [
            "tracking-enabled",
            "open-input-monitoring",
            "uninstall-hooks",
            "reset-today"
        ])
    }

    func testSwitchStartsAndStopsRuntime() {
        let harness = makeHarness()

        harness.plugin.handleAction(.setSwitch(true))

        XCTAssertTrue(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.startCallCount, 1)
        XCTAssertEqual(harness.socketServer.startCallCount, 0)
        XCTAssertTrue(harness.plugin.primaryPanelState.isOn)

        harness.plugin.handleAction(.setSwitch(false))

        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.stopCallCount, 1)
        XCTAssertEqual(harness.socketServer.stopCallCount, 0)
    }

    func testActivateStartsInstalledHookSocketWithoutInputTracking() {
        let storage = ActivityBarMemoryStorage()
        storage.set("2026-05-18 09:00", forKey: "activity-bar.hooks.installed-at")
        let harness = makeHarness(storage: storage)

        harness.plugin.activate(context: harness.context)

        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.startCallCount, 0)
        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertTrue(harness.socketServer.isRunning)
        XCTAssertTrue(harness.plugin.componentPanelState.isActive)
        XCTAssertEqual(harness.plugin.componentPanelState.subtitle, "AI 监听中")
    }

    func testInstallHooksStartsSocketWithoutTrackingSwitch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: root,
            hookScriptsDirectory: root.appendingPathComponent("hooks")
        )
        let harness = makeHarness(hookInstallerPaths: paths)

        harness.controller.installHooks()

        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.startCallCount, 0)
        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertTrue(harness.socketServer.isRunning)
    }

    func testDisablingTrackingKeepsInstalledHookSocketRunning() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: root,
            hookScriptsDirectory: root.appendingPathComponent("hooks")
        )
        let harness = makeHarness(hookInstallerPaths: paths)

        harness.controller.installHooks()
        harness.plugin.handleAction(.setSwitch(true))
        harness.plugin.handleAction(.setSwitch(false))

        XCTAssertFalse(harness.controller.isTrackingEnabled)
        XCTAssertEqual(harness.inputMonitor.stopCallCount, 1)
        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertEqual(harness.socketServer.stopCallCount, 0)
        XCTAssertTrue(harness.socketServer.isRunning)
    }

    func testUninstallHooksStopsSocketAndClearsInstalledState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: root,
            hookScriptsDirectory: root.appendingPathComponent("hooks")
        )
        let harness = makeHarness(hookInstallerPaths: paths)

        harness.controller.installHooks()
        harness.controller.uninstallHooks()

        XCTAssertNil(harness.storage.string(forKey: "activity-bar.hooks.installed-at"))
        XCTAssertEqual(harness.controller.hookInstallState, .notInstalled)
        XCTAssertEqual(harness.socketServer.stopCallCount, 1)
        XCTAssertFalse(harness.socketServer.isRunning)
        XCTAssertFalse(harness.plugin.componentPanelState.isActive)
    }

    func testDeactivateForUpdatingStopsHookSocket() {
        let storage = ActivityBarMemoryStorage()
        storage.set("2026-05-18 09:00", forKey: "activity-bar.hooks.installed-at")
        let harness = makeHarness(storage: storage)

        harness.plugin.activate(context: harness.context)
        harness.plugin.deactivate(reason: .updating)

        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertEqual(harness.socketServer.stopCallCount, 1)
        XCTAssertFalse(harness.socketServer.isRunning)
    }

    func testInputTrackingDoesNotHideHookSocketStartError() {
        let storage = ActivityBarMemoryStorage()
        storage.set("2026-05-18 09:00", forKey: "activity-bar.hooks.installed-at")
        storage.set(true, forKey: "activity-bar.tracking.enabled")
        let harness = makeHarness(storage: storage)
        harness.socketServer.startError = ActivityBarSocketError.socketFailed(1)

        harness.plugin.activate(context: harness.context)

        XCTAssertEqual(harness.inputMonitor.startCallCount, 1)
        XCTAssertEqual(harness.socketServer.startCallCount, 1)
        XCTAssertTrue(harness.controller.lastErrorMessage?.contains("AI 活动监听启动失败") == true)
    }

    func testExpandedTrackingSwitchReflectsEnabledState() throws {
        let harness = makeHarness()

        harness.plugin.handleAction(.setDisclosureExpanded(true))
        harness.plugin.handleAction(.setSwitch(true))

        let controls = try XCTUnwrap(harness.plugin.primaryPanelState.detail?.primaryControls)

        XCTAssertEqual(controls.first?.kind, .switchRow)
        XCTAssertTrue(harness.plugin.primaryPanelState.isOn)
    }

    func testMonitorEventsUpdateComponentSubtitle() {
        let harness = makeHarness()

        harness.plugin.handleAction(.setSwitch(true))
        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        harness.inputMonitor.emit(.pointerClick(app: "Terminal"))

        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 2)
        XCTAssertEqual(harness.plugin.componentPanelState.subtitle, "2 次输入")
    }

    func testMonitorEventsBatchPluginStateNotifications() {
        let harness = makeHarness(inputEventNotificationDelay: .seconds(60))
        var notificationCount = 0
        harness.plugin.onStateChange = {
            notificationCount += 1
        }

        harness.plugin.handleAction(.setSwitch(true))
        notificationCount = 0

        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        harness.inputMonitor.emit(.pointerClick(app: "Terminal"))
        harness.inputMonitor.emit(.scroll(app: "Terminal"))

        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 3)
        XCTAssertEqual(notificationCount, 0)

        harness.plugin.handleAction(.setSwitch(false))

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(harness.storage.setCallCount(forKey: "activity-bar.input.days.v1"), 1)
    }

    func testAppTerminationFlushesPendingInputStats() {
        let harness = makeHarness()

        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        let reloaded = ActivityBarStatsStore(storage: harness.storage)

        XCTAssertEqual(reloaded.today.totalInputs, 1)
    }

    func testAppTerminationFlushesActiveCodingDuration() {
        let storage = ActivityBarMemoryStorage()
        var now = activityBarTestDate(hour: 10)
        let codingStats = ActivityBarCodingSessionStore(
            storage: storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { now }
        )
        let harness = makeHarness(storage: storage, codingStats: codingStats)

        harness.controller.codingStats.handleEvent(
            ActivityBarHookEvent(
                sessionID: "session-1",
                cwd: "/tmp/MacTools",
                event: .sessionStart,
                status: .processing,
                userPrompt: nil,
                tool: nil,
                interactive: true
            )
        )

        now = now.addingTimeInterval(10)
        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        let reloaded = ActivityBarCodingSessionStore(
            storage: harness.storage,
            calendar: activityBarTestCalendar(),
            dateProvider: { now }
        )

        XCTAssertEqual(reloaded.today.durationSeconds, 10, accuracy: 0.1)
    }

    func testResetActionClearsToday() {
        let harness = makeHarness()

        harness.inputMonitor.emit(.keystroke(app: "Terminal"))
        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 1)

        harness.plugin.handleAction(.invokeAction(controlID: "reset-today"))

        XCTAssertEqual(harness.controller.todayInputStats.totalInputs, 0)
    }

    private func makeHarness(
        storage providedStorage: ActivityBarMemoryStorage? = nil,
        codingStats: ActivityBarCodingSessionStore? = nil,
        hookInstallerPaths: ActivityBarHookInstallerPaths? = nil,
        inputEventNotificationDelay: Duration = .milliseconds(750)
    ) -> Harness {
        let storage = providedStorage ?? ActivityBarMemoryStorage()
        let inputMonitor = ActivityBarFakeInputMonitor()
        let socketServer = ActivityBarFakeSocketServer()
        let context = PluginRuntimeContext(
            pluginID: ActivityBarConstants.pluginID,
            storage: storage,
            supportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ActivityBarPluginTests-\(UUID().uuidString)")
        )
        let controller = ActivityBarController(
            context: context,
            inputMonitor: inputMonitor,
            socketServer: socketServer,
            codingStats: codingStats,
            hookInstallerPaths: hookInstallerPaths,
            inputEventNotificationDelay: inputEventNotificationDelay
        )
        let plugin = ActivityBarPlugin(context: context, controller: controller)

        return Harness(
            plugin: plugin,
            controller: controller,
            context: context,
            storage: storage,
            inputMonitor: inputMonitor,
            socketServer: socketServer
        )
    }

    private struct Harness {
        let plugin: ActivityBarPlugin
        let controller: ActivityBarController
        let context: PluginRuntimeContext
        let storage: ActivityBarMemoryStorage
        let inputMonitor: ActivityBarFakeInputMonitor
        let socketServer: ActivityBarFakeSocketServer
    }
}
