import AppKit

/// Resolves plugin-provided SF Symbol names to a drawable system image name.
///
/// Action and folder icons can come from dynamically installed plugins or a
/// restored backup, so the host must tolerate names unavailable on the current
/// macOS release instead of rendering a blank image.
@MainActor
public enum PluginSystemImage {
    public static let fallbackName = "questionmark.square.dashed"

    private static var availabilityByName: [String: Bool] = [:]

    public static func resolvedName(
        _ candidate: String,
        fallback: String = fallbackName
    ) -> String {
        if isAvailable(candidate) {
            return candidate
        }
        if isAvailable(fallback) {
            return fallback
        }
        return "questionmark"
    }

    public static func isAvailable(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if let cached = availabilityByName[name] {
            return cached
        }
        let isAvailable = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        ) != nil
        availabilityByName[name] = isAvailable
        return isAvailable
    }
}
