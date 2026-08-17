import AppKit
import Foundation

enum AppleShortcutsVisualMetadataError: Error, Equatable, Sendable {
    case automationUnavailable
    case malformedReply
}

protocol AppleShortcutsVisualMetadataLoading: Sendable {
    func loadVisualMetadata() async -> Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError>
}

struct AppleShortcutsVisualMetadataLoader: AppleShortcutsVisualMetadataLoading {
    private static let scriptSource = """
    tell application id "com.apple.shortcuts"
        set shortcutRows to {}
        repeat with shortcutItem in every shortcut
            set {redValue, greenValue, blueValue} to (color of shortcutItem)
            set end of shortcutRows to {id of shortcutItem as text, redValue, greenValue, blueValue, icon of shortcutItem}
        end repeat
        return shortcutRows
    end tell
    """

    func loadVisualMetadata() async -> Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.loadSynchronously())
            }
        }
    }

    static func color(
        red: Int32,
        green: Int32,
        blue: Int32
    ) -> AppleShortcutVisualMetadata.Color? {
        let components = [red, green, blue]
        guard components.allSatisfy({ (0 ... Int32(UInt16.max)).contains($0) }) else {
            return nil
        }
        return AppleShortcutVisualMetadata.Color(
            red: Double(red) / Double(UInt16.max),
            green: Double(green) / Double(UInt16.max),
            blue: Double(blue) / Double(UInt16.max)
        )
    }

    private static func loadSynchronously() -> Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError> {
        guard let script = NSAppleScript(source: scriptSource) else {
            return .failure(.automationUnavailable)
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            return .failure(.automationUnavailable)
        }
        return parse(result)
    }

    static func parse(
        _ result: NSAppleEventDescriptor
    ) -> Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError> {
        var metadataByID: [UUID: AppleShortcutVisualMetadata] = [:]
        for index in 1 ... result.numberOfItems {
            guard let row = result.atIndex(index),
                  row.numberOfItems == 5,
                  let idString = row.atIndex(1)?.stringValue,
                  let id = UUID(uuidString: idString),
                  let red = row.atIndex(2)?.int32Value,
                  let green = row.atIndex(3)?.int32Value,
                  let blue = row.atIndex(4)?.int32Value,
                  let color = color(red: red, green: green, blue: blue) else {
                return .failure(.malformedReply)
            }
            let rawIconData: Data? = row.atIndex(5)?.data
            let iconData: Data? = if let rawIconData,
                                     rawIconData.count <= 4 * 1_024 * 1_024 {
                rawIconData
            } else {
                nil
            }
            metadataByID[id] = AppleShortcutVisualMetadata(
                color: color,
                iconTIFFData: iconData
            )
        }
        return .success(metadataByID)
    }
}
