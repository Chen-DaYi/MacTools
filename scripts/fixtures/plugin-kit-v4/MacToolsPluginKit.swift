import SwiftUI

// Frozen client-facing declaration from plugins-1.1.6. This module is compiled
// without an implementation and linked against the current framework so the
// smoke test exercises the real cross-module value ABI.
public struct ShortcutBinding {}

public enum PluginShortcutRecordingResult: Equatable {
    case accepted
    case rejected(String)
}

public struct PluginShortcutRecorder: View {
    public let title: String
    public let displayText: String
    public let placeholder: String
    public let minWidth: CGFloat
    public let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    public let onBeginRecording: (() -> Void)?
    public let onEndRecording: (() -> Void)?

    @State private var isPresented = false
    @State private var isHovered = false

    public init(
        title: String,
        displayText: String,
        placeholder: String = "Not set",
        minWidth: CGFloat = 90,
        onRecord: @escaping (ShortcutBinding) -> PluginShortcutRecordingResult,
        onBeginRecording: (() -> Void)? = nil,
        onEndRecording: (() -> Void)? = nil
    ) {
        fatalError("The compatibility client must link this initializer from the current framework")
    }

    public var body: some View {
        fatalError("The compatibility client must link this getter from the current framework")
    }
}
