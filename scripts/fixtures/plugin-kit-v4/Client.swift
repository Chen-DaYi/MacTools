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

        let binding = ShortcutBinding(keyCode: 40, modifiers: [.command, .shift])
        let definition = PluginShortcutDefinition(
            id: "compatibility",
            title: "Compatibility",
            description: "Frozen v4 shortcut definition",
            actionID: "run",
            scope: .global,
            defaultBinding: binding,
            isRequired: false,
            sharedBindingGroupID: "compatibility",
            settingsGroupID: "settings",
            settingsGroupTitle: "Settings",
            settingsGroupDescription: "Compatibility",
            settingsControlTitle: "Run",
            settingsControlSystemImage: "command"
        )
        guard definition.id == "compatibility",
              definition.defaultBinding?.keyCode == 40,
              definition.defaultBinding?.modifiers == [.command, .shift],
              definition.settingsControlSystemImage == "command" else {
            fatalError("PluginShortcutDefinition v4 value ABI changed")
        }

        let requirement = PluginPermissionRequirement(
            id: "accessibility",
            kind: .accessibility,
            title: "Accessibility",
            description: "Compatibility"
        )
        let state = PluginPermissionState(
            isGranted: false,
            footnote: "Grant access",
            statusText: "Required",
            statusSystemImage: "exclamationmark.triangle",
            statusTone: .caution
        )
        guard requirement.id == "accessibility",
              requirement.title == "Accessibility",
              !state.isGranted,
              state.footnote == "Grant access",
              state.statusText == "Required" else {
            fatalError("Plugin permission v4 value ABI changed")
        }
    }
}
