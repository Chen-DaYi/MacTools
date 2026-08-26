import AppKit
import SwiftUI

/// Records one physical key. Modifier keys are captured from `flagsChanged`,
/// preserving left/right identity through their distinct virtual key codes.
public struct PluginKeyTapRecorder: View {
    public let title: String
    public let displayText: String
    public let prompt: String
    public let minWidth: CGFloat
    public let onRecord: (KeyboardKeyTap) -> Void
    public let onBeginRecording: (() -> Void)?
    public let onEndRecording: (() -> Void)?

    @State private var isPresented = false
    @State private var isHovered = false

    public init(
        title: String,
        displayText: String,
        prompt: String = PluginKitLocalization.keyboardKeyTapPrompt,
        minWidth: CGFloat = 90,
        onRecord: @escaping (KeyboardKeyTap) -> Void,
        onBeginRecording: (() -> Void)? = nil,
        onEndRecording: (() -> Void)? = nil
    ) {
        self.title = title
        self.displayText = displayText
        self.prompt = prompt
        self.minWidth = minWidth
        self.onRecord = onRecord
        self.onBeginRecording = onBeginRecording
        self.onEndRecording = onEndRecording
    }

    public var body: some View {
        Button {
            isPresented = true
        } label: {
            PluginShortcutRecorderField(
                displayText: displayText,
                isRecording: isPresented,
                minWidth: minWidth
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(
            cornerRadius: PluginSettingsTheme.Radius.field,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(isHovered && !isPresented ? 0.45 : 0),
                    lineWidth: PluginSettingsTheme.Stroke.standard
                )
                .allowsHitTesting(false)
        }
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isPresented ? prompt : displayText))
        .accessibilityHint(Text(
            "\(PluginKitLocalization.shortcutRecorderHelp(title: title)) "
                + PluginKitLocalization.keyboardKeyTapUnsupportedHelp
        ))
        .onHover { hovering in
            isHovered = hovering
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onDisappear {
            guard isHovered else { return }
            isHovered = false
            NSCursor.arrow.set()
        }
        .background {
            GeometryReader { proxy in
                PluginKeyTapRecorderPopoverAnchor(
                    isPresented: $isPresented,
                    prompt: prompt,
                    onRecord: onRecord,
                    onBeginRecording: onBeginRecording,
                    onEndRecording: onEndRecording
                )
                .frame(width: max(proxy.size.width, 1), height: max(proxy.size.height, 1))
                .allowsHitTesting(false)
            }
        }
    }
}

private struct PluginKeyTapRecorderPopoverView: View {
    let prompt: String

    var body: some View {
        VStack(spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Label(prompt, systemImage: "keyboard")
                .font(PluginSettingsTheme.Typography.secondaryLabel)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
            Text(PluginKitLocalization.keyboardKeyTapUnsupportedHelp)
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, PluginSettingsTheme.Spacing.rowContentControl)
        .padding(.vertical, PluginSettingsTheme.Spacing.controlCluster)
        .frame(minWidth: 210, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field, style: .continuous)
                .fill(PluginSettingsTheme.Palette.recordingBackground)
        )
        .padding(PluginSettingsTheme.Spacing.rowContentControl)
    }
}

private struct PluginKeyTapRecorderPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let prompt: String
    let onRecord: (KeyboardKeyTap) -> Void
    let onBeginRecording: (() -> Void)?
    let onEndRecording: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            isPresented: isPresented,
            sourceView: nsView,
            prompt: prompt,
            onRecord: onRecord,
            onDismiss: { isPresented = false },
            onBeginRecording: onBeginRecording,
            onEndRecording: onEndRecording
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private var popover: NSPopover?
        private var keyMonitor: Any?
        private var wantsPresentation = false
        private var presentationRetryScheduled = false
        private var onRecord: ((KeyboardKeyTap) -> Void)?
        private var onDismiss: (() -> Void)?
        private var onBeginRecording: (() -> Void)?
        private var onEndRecording: (() -> Void)?

        func update(
            isPresented: Bool,
            sourceView: NSView,
            prompt: String,
            onRecord: @escaping (KeyboardKeyTap) -> Void,
            onDismiss: @escaping () -> Void,
            onBeginRecording: (() -> Void)?,
            onEndRecording: (() -> Void)?
        ) {
            wantsPresentation = isPresented
            self.onRecord = onRecord
            self.onDismiss = onDismiss
            self.onBeginRecording = onBeginRecording
            self.onEndRecording = onEndRecording

            if isPresented {
                requestPresentation(from: sourceView, prompt: prompt)
            } else if popover != nil {
                close()
            }
        }

        func close() {
            wantsPresentation = false
            let dismiss = onDismiss
            let endRecording = onEndRecording
            let wasRecording = popover != nil
            if let popover {
                popover.delegate = nil
                self.popover = nil
                popover.close()
            }
            cleanup()
            dismiss?()
            if wasRecording {
                endRecording?()
            }
        }

        func popoverDidClose(_ notification: Notification) {
            close()
        }

        private func requestPresentation(from sourceView: NSView, prompt: String) {
            guard wantsPresentation, popover == nil else { return }
            guard sourceView.window != nil, sourceView.bounds.width > 0, sourceView.bounds.height > 0 else {
                guard !presentationRetryScheduled else { return }
                presentationRetryScheduled = true
                DispatchQueue.main.async { [weak self, weak sourceView] in
                    guard let self, let sourceView else { return }
                    self.presentationRetryScheduled = false
                    self.requestPresentation(from: sourceView, prompt: prompt)
                }
                return
            }

            onBeginRecording?()
            let controller = NSHostingController(rootView: PluginKeyTapRecorderPopoverView(prompt: prompt))
            controller.view.layoutSubtreeIfNeeded()
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.contentSize = controller.view.fittingSize
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            self.popover = popover

            keyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: NSEvent.EventTypeMask.keyDown.union(.flagsChanged)
            ) { [weak self] event in
                self?.record(event)
                return event.type == .keyDown ? nil : event
            }

            PluginPresentationSafety.prepareForWindowOrdering()
            popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        }

        private func record(_ event: NSEvent) {
            guard popover?.isShown == true else { return }
            let keyTap = KeyboardKeyTap(keyCode: event.keyCode)
            guard keyTap.isSupported else {
                NSSound.beep()
                return
            }
            if event.type == .flagsChanged {
                let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
                guard KeyboardKeyTapEventTransition.isModifierPress(
                    keyCode: event.keyCode,
                    flags: flags
                ) else {
                    return
                }
            } else {
                guard event.type == .keyDown else { return }
            }
            let record = onRecord
            close()
            record?(keyTap)
        }

        private func cleanup() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
            presentationRetryScheduled = false
            onRecord = nil
            onDismiss = nil
            onBeginRecording = nil
            onEndRecording = nil
        }
    }
}
