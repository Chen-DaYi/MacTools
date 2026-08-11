import MacToolsPluginKit

@main
struct PluginKitV4CompatibilityClient {
    @MainActor
    static func main() {
        let recorder = PluginShortcutRecorder(
            title: "Compatibility",
            displayText: "⌘K",
            onRecord: { _ in .accepted }
        )
        let labels = Mirror(reflecting: recorder).children.compactMap(\.label).map { label in
            label.hasPrefix("__") ? String(label.dropFirst()) : label
        }
        guard labels == [
            "title",
            "displayText",
            "placeholder",
            "minWidth",
            "onRecord",
            "onBeginRecording",
            "onEndRecording",
            "_isPresented",
            "_isHovered",
        ] else {
            fatalError("PluginShortcutRecorder v4 stored layout changed: \(labels)")
        }
        _ = recorder.body
    }
}
