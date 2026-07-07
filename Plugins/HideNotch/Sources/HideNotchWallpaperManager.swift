import AppKit
import CoreGraphics
import Foundation
import MacToolsPluginKit

enum HideNotchDesktopMaskManagerError: LocalizedError {
    case maskWindowCreationFailed(displayName: String, underlyingMessage: String, PluginLocalization)

    var errorDescription: String? {
        switch self {
        case let .maskWindowCreationFailed(displayName, underlyingMessage, localization):
            return localization.format(
                "error.maskWindowCreationFailedFormat",
                defaultValue: "无法为 %@ 创建刘海遮挡层：%@",
                displayName,
                underlyingMessage
            )
        }
    }
}

@MainActor
final class HideNotchDesktopMaskManager: HideNotchDesktopMaskManaging {
    private struct ManagedWindow {
        let display: HideNotchDisplayContext
        let window: HideNotchDesktopMaskWindowing
    }

    private let windowBuilder: HideNotchDesktopMaskWindowBuilding
    private let localization: PluginLocalization
    private let logger = HideNotchLog.overlayManager

    private var windowsByDisplayIdentifier: [String: ManagedWindow] = [:]

    init(
        windowBuilder: HideNotchDesktopMaskWindowBuilding? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.localization = localization
        self.windowBuilder = windowBuilder ?? HideNotchDesktopMaskWindowBuilder(localization: localization)
    }

    var managedDisplayIdentifiers: Set<String> {
        Set(windowsByDisplayIdentifier.keys)
    }

    func synchronizeMasks(for displays: [HideNotchDisplayContext]) throws {
        let supportedDisplays = displays.filter(\.isSupported)
        let desiredDisplayIdentifiers = Set(supportedDisplays.map(\.displayIdentifier))

        for displayIdentifier in windowsByDisplayIdentifier.keys.sorted()
        where !desiredDisplayIdentifiers.contains(displayIdentifier) {
            if let managedWindow = windowsByDisplayIdentifier.removeValue(forKey: displayIdentifier) {
                managedWindow.window.close()
                logger.info(
                    "hide-notch removed desktop mask display=\(displayIdentifier, privacy: .public)"
                )
            }
        }

        for display in supportedDisplays {
            let frame = Self.maskFrame(for: display)
            guard !frame.isEmpty else {
                if let managedWindow = windowsByDisplayIdentifier.removeValue(forKey: display.displayIdentifier) {
                    managedWindow.window.close()
                }
                continue
            }

            if let managedWindow = windowsByDisplayIdentifier[display.displayIdentifier] {
                managedWindow.window.setFrame(frame)
                managedWindow.window.show()
                windowsByDisplayIdentifier[display.displayIdentifier] = ManagedWindow(
                    display: display,
                    window: managedWindow.window
                )
                continue
            }

            do {
                let window = try windowBuilder.makeWindow(frame: frame)
                window.show()
                windowsByDisplayIdentifier[display.displayIdentifier] = ManagedWindow(
                    display: display,
                    window: window
                )
                logger.info(
                    "hide-notch created desktop mask display=\(display.displayIdentifier, privacy: .public) frame=\(NSStringFromRect(frame), privacy: .public)"
                )
            } catch {
                throw HideNotchDesktopMaskManagerError.maskWindowCreationFailed(
                    displayName: display.name,
                    underlyingMessage: error.localizedDescription,
                    localization
                )
            }
        }

        if HideNotchLog.isVerboseLoggingEnabled {
            let activeDisplays = managedDisplayIdentifiers.sorted().joined(separator: ",")
            logger.debug(
                "hide-notch active desktop masks=\(activeDisplays, privacy: .public)"
            )
        }
    }

    func hideAllMasks() {
        guard !windowsByDisplayIdentifier.isEmpty else {
            return
        }

        for managedWindow in windowsByDisplayIdentifier.values {
            managedWindow.window.close()
        }
        windowsByDisplayIdentifier.removeAll()
        logger.info("hide-notch cleared all desktop masks")
    }

    static func maskFrame(for display: HideNotchDisplayContext) -> CGRect {
        let height = min(display.frame.height, max(0, display.notchHeightPoints))
        guard height > 0 else {
            return .zero
        }

        return CGRect(
            x: display.frame.minX,
            y: display.frame.maxY - height,
            width: display.frame.width,
            height: height
        )
    }
}
