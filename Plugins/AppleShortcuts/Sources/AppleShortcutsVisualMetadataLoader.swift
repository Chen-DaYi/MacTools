import AppKit
import Foundation

enum AppleShortcutsVisualMetadataError: Error, Equatable, Sendable {
    case automationUnavailable
    case malformedReply
}

protocol AppleShortcutsVisualMetadataLoading: Sendable {
    /// Loads compact color metadata for the complete library. Icon bytes are fetched separately.
    func loadVisualMetadata() async -> Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError>
    func loadIcon(for shortcutID: UUID) async -> Result<Data?, AppleShortcutsVisualMetadataError>
}

struct AppleShortcutsVisualMetadataLoader: AppleShortcutsVisualMetadataLoading {
    static let scriptTimeoutSeconds = 10
    static let maximumIconByteCount = 4 * 1_024 * 1_024
    static let maximumTotalIconByteCount = 128 * 1_024 * 1_024

    private static let scriptSource = """
    with timeout of \(scriptTimeoutSeconds) seconds
        tell application id "com.apple.shortcuts"
            set shortcutRows to {}
            repeat with shortcutItem in every shortcut
                set {redValue, greenValue, blueValue} to (color of shortcutItem)
                set end of shortcutRows to {id of shortcutItem as text, redValue, greenValue, blueValue}
            end repeat
            return shortcutRows
        end tell
    end timeout
    """

    func loadVisualMetadata() async -> Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.loadSynchronously())
            }
        }
    }

    func loadIcon(for shortcutID: UUID) async -> Result<Data?, AppleShortcutsVisualMetadataError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.loadIconSynchronously(for: shortcutID))
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

    private static func loadIconSynchronously(
        for shortcutID: UUID
    ) -> Result<Data?, AppleShortcutsVisualMetadataError> {
        let source = """
        with timeout of \(scriptTimeoutSeconds) seconds
            tell application id "com.apple.shortcuts"
                return icon of shortcut id "\(shortcutID.uuidString.lowercased())"
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else {
            return .failure(.automationUnavailable)
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            return .failure(.automationUnavailable)
        }
        let iconData = result.data
        guard iconData.count <= maximumIconByteCount else {
            return .success(nil)
        }
        return .success(iconData)
    }

    static func parse(
        _ result: NSAppleEventDescriptor
    ) -> Result<[UUID: AppleShortcutVisualMetadata], AppleShortcutsVisualMetadataError> {
        var metadataByID: [UUID: AppleShortcutVisualMetadata] = [:]
        for index in 1 ... result.numberOfItems {
            guard let row = result.atIndex(index),
                  row.numberOfItems == 4,
                  let idString = row.atIndex(1)?.stringValue,
                  let id = UUID(uuidString: idString),
                  let red = row.atIndex(2)?.int32Value,
                  let green = row.atIndex(3)?.int32Value,
                  let blue = row.atIndex(4)?.int32Value,
                  let color = color(red: red, green: green, blue: blue) else {
                return .failure(.malformedReply)
            }
            metadataByID[id] = AppleShortcutVisualMetadata(
                color: color,
                iconTIFFData: nil
            )
        }
        return .success(metadataByID)
    }

    static func retainedIconData(
        _ rawIconData: Data?,
        remainingByteCount: inout Int
    ) -> Data? {
        guard let rawIconData,
              rawIconData.count <= maximumIconByteCount,
              rawIconData.count <= remainingByteCount else {
            return nil
        }
        remainingByteCount -= rawIconData.count
        return rawIconData
    }
}
