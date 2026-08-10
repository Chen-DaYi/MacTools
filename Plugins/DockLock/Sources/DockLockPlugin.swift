import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import SwiftUI
import MacToolsPluginKit

protocol DockLockMonitoring: AnyObject {
    @discardableResult
    func start() -> Bool
    func stop()
}

enum DockLockCursorBoundary {
    static let bottomInset: CGFloat = 4

    static func clampedQuartzLocation(
        for location: CGPoint,
        primaryDisplayHeight: CGFloat,
        screenFrames: [CGRect]
    ) -> CGPoint? {
        guard primaryDisplayHeight > 0 else {
            return nil
        }

        let appKitLocation = CGPoint(x: location.x, y: primaryDisplayHeight - location.y)
        guard let screenFrame = screenFrames.first(where: { $0.contains(appKitLocation) }) else {
            return nil
        }
        guard appKitLocation.y - screenFrame.minY < bottomInset else {
            return nil
        }

        return CGPoint(
            x: location.x,
            y: primaryDisplayHeight - (screenFrame.minY + bottomInset)
        )
    }
}

enum DockLockDockOrientation {
    static func isBottom(preferenceValue: Any?) -> Bool {
        guard let orientation = preferenceValue as? String else {
            return false
        }
        return orientation.caseInsensitiveCompare("bottom") == .orderedSame
    }
}

final class DockLockMonitor: NSObject, DockLockMonitoring {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "DockLockPlugin"
    )
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dockPositionTimer: Timer?
    private var isDockAtBottom = true

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }

        let events: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: events,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Failed to create Dock Lock event tap")
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create Dock Lock run loop source")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        refreshDockPosition()
        startDockPositionPolling()
        return true
    }

    func stop() {
        guard let eventTap else {
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
        dockPositionTimer?.invalidate()
        dockPositionTimer = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<DockLockMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(event: event, type: type)
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isDockAtBottom else {
            return Unmanaged.passUnretained(event)
        }

        let screens = NSScreen.screens
        let screenFrames = screens.map(\.frame)
        let primaryDisplayHeight = screens.first(where: { $0.frame.minX == 0 && $0.frame.minY == 0 })?.frame.height ?? 0
        if let clampedLocation = DockLockCursorBoundary.clampedQuartzLocation(
            for: event.location,
            primaryDisplayHeight: primaryDisplayHeight,
            screenFrames: screenFrames
        ) {
            event.location = clampedLocation
        }
        return Unmanaged.passUnretained(event)
    }

    private func startDockPositionPolling() {
        let timer = Timer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(refreshDockPosition),
            userInfo: nil,
            repeats: true
        )
        dockPositionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func refreshDockPosition() {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        isDockAtBottom = DockLockDockOrientation.isBottom(
            preferenceValue: dockDefaults?.object(forKey: "orientation")
        )
    }
}

public final class DockLockPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        DockLockPluginProvider(context: context)
    }
}

@MainActor
private struct DockLockPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [DockLockPlugin(context: context, localization: PluginLocalization(bundle: context.resourceBundle))]
    }
}

@MainActor
final class DockLockPlugin: MacToolsPlugin, PluginPrimaryPanel, AccessibilityPermissionRefreshing {
    private enum PermissionID {
        static let accessibility = "accessibility"
    }

    private enum StorageKey {
        static let isEnabled = "dock-lock.enabled"
    }

    let metadata: PluginMetadata
    let primaryPanelDescriptor = PluginPrimaryPanelDescriptor(
        controlStyle: .switch,
        menuActionBehavior: .keepPresented
    )

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let storage: any PluginStorage
    private let monitor: any DockLockMonitoring
    private let localization: PluginLocalization
    private let accessibilityTrusted: @MainActor () -> Bool
    private let requestAccessibilityTrust: @MainActor (Bool) -> Bool
    private var isEnabled: Bool
    private var isAccessibilityGranted: Bool
    private var lastErrorMessage: String?

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "dock-lock"),
        monitor: (any DockLockMonitoring)? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        accessibilityTrusted: @escaping @MainActor () -> Bool = DockLockPlugin.isAccessibilityTrusted,
        requestAccessibilityTrust: @escaping @MainActor (Bool) -> Bool = DockLockPlugin.requestAccessibilityTrust
    ) {
        self.storage = context.storage
        self.monitor = monitor ?? DockLockMonitor()
        self.localization = localization
        self.accessibilityTrusted = accessibilityTrusted
        self.requestAccessibilityTrust = requestAccessibilityTrust
        self.isEnabled = context.storage.object(forKey: StorageKey.isEnabled) == nil
            ? false
            : context.storage.bool(forKey: StorageKey.isEnabled)
        self.isAccessibilityGranted = accessibilityTrusted()
        self.metadata = PluginMetadata(
            id: "dock-lock",
            title: localization.string("metadata.title", defaultValue: "锁定程序坞"),
            iconName: "lock.rectangle",
            iconTint: Color(nsColor: .systemIndigo),
            order: 46,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "防止程序坞在多显示器之间意外移动"
            )
        )
    }

    func activate(context: PluginRuntimeContext) {
        applyLockState(promptForPermission: false)
    }

    func deactivate(reason: PluginDeactivationReason) {
        monitor.stop()
    }

    func refresh() {}

    var primaryPanelState: PluginPanelState {
        PluginPanelState(
            subtitle: panelSubtitle,
            isOn: isEnabled,
            isExpanded: false,
            isEnabled: true,
            isVisible: true,
            detail: nil,
            errorMessage: lastErrorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于在屏幕底部拦截鼠标移动，防止程序坞跳到其他显示器。"
                )
            ),
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .setSwitch(isEnabled) = action else {
            return
        }
        self.isEnabled = isEnabled
        storage.set(isEnabled, forKey: StorageKey.isEnabled)
        applyLockState(promptForPermission: isEnabled)
        onStateChange?()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.accessibility else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        return PluginPermissionState(
            isGranted: isAccessibilityGranted,
            footnote: isAccessibilityGranted
                ? nil
                : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "在系统设置的“隐私与安全性 > 辅助功能”中允许 MacTools。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.accessibility else {
            return
        }
        isAccessibilityGranted = requestAccessibilityTrust(true)
        applyLockState(promptForPermission: false)
        onStateChange?()
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func refreshAccessibilityPermission() {
        let wasGranted = isAccessibilityGranted
        isAccessibilityGranted = accessibilityTrusted()
        guard wasGranted != isAccessibilityGranted else {
            return
        }

        if isAccessibilityGranted {
            lastErrorMessage = nil
            applyLockState(promptForPermission: false)
        } else {
            monitor.stop()
            lastErrorMessage = localization.string(
                "error.accessibilityRevoked",
                defaultValue: "辅助功能权限已关闭，Dock 锁定已暂停。"
            )
        }
        onStateChange?()
    }

    private var panelSubtitle: String {
        if isEnabled && !isAccessibilityGranted {
            return localization.string("panel.subtitle.needsPermission", defaultValue: "需要辅助功能授权")
        }
        return isEnabled
            ? localization.string("panel.subtitle.enabled", defaultValue: "已开启")
            : localization.string("panel.subtitle.disabled", defaultValue: "已关闭")
    }

    private func applyLockState(promptForPermission: Bool) {
        guard isEnabled else {
            monitor.stop()
            lastErrorMessage = nil
            return
        }

        isAccessibilityGranted = accessibilityTrusted()
        if !isAccessibilityGranted, promptForPermission {
            isAccessibilityGranted = requestAccessibilityTrust(true)
        }
        guard isAccessibilityGranted else {
            monitor.stop()
            lastErrorMessage = localization.string(
                "error.accessibilityRequired",
                defaultValue: "Dock 锁定需要辅助功能权限。"
            )
            requestPermissionGuidance?(PermissionID.accessibility)
            return
        }

        guard monitor.start() else {
            lastErrorMessage = localization.string(
                "error.startFailed",
                defaultValue: "无法启动 Dock 锁定，请检查辅助功能权限。"
            )
            return
        }
        lastErrorMessage = nil
    }

    private static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    private static func requestAccessibilityTrust(prompt: Bool) -> Bool {
        guard prompt else {
            return AXIsProcessTrusted()
        }
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
