import AppKit
import SwiftUI

private enum WindowSwitcherOverlayPresentation {
    case direct
    case keyWindow
}

@MainActor
private final class WindowSwitcherOverlayModel: ObservableObject {
    @Published var entries: [WindowSwitcherAppEntry] = []
    @Published var selectedID: String?
    @Published var pendingKeyPrefix: String?
    @Published var presentation: WindowSwitcherOverlayPresentation = .keyWindow
    @Published var columnCount: Int = 1
    @Published var shortcutText: String = ""
}

@MainActor
final class WindowSwitcherOverlayController: NSObject, NSWindowDelegate {
    var onSelect: ((WindowSwitcherAppEntry) -> Void)?
    var onQuit: ((WindowSwitcherAppEntry) -> Void)?
    var onCancel: (() -> Void)?

    private final class KeyablePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private let model = WindowSwitcherOverlayModel()
    private var panel: KeyablePanel?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var pendingKeyWorkItem: DispatchWorkItem?
    private var hostingView: NSView?
    private var isClosing = false

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func showDirect(
        entries: [WindowSwitcherAppEntry],
        selectedID: String?,
        shortcutText: String
    ) {
        show(
            entries: entries,
            selectedID: selectedID,
            presentation: .direct,
            shortcutText: shortcutText,
            activatesApp: false
        )
    }

    func showKeyWindow(
        entries: [WindowSwitcherAppEntry],
        shortcutText: String
    ) {
        show(
            entries: entries,
            selectedID: nil,
            presentation: .keyWindow,
            shortcutText: shortcutText,
            activatesApp: true
        )
    }

    func updateDirectSelection(selectedID: String?) {
        model.selectedID = selectedID
    }

    func updateEntries(entries: [WindowSwitcherAppEntry], selectedID: String?) {
        model.entries = entries
        model.selectedID = selectedID
        model.columnCount = columnCount(
            for: entries.count,
            presentation: model.presentation,
            screen: targetScreen()
        )

        if entries.isEmpty {
            hide()
        } else if let panel {
            resize(panel)
            center(panel, on: targetScreen())
        }
    }

    func hide() {
        pendingKeyWorkItem?.cancel()
        pendingKeyWorkItem = nil
        model.pendingKeyPrefix = nil
        removeKeyMonitor()
        removeClickMonitor()
        isClosing = true
        panel?.orderOut(nil)
        isClosing = false
    }

    private func show(
        entries: [WindowSwitcherAppEntry],
        selectedID: String?,
        presentation: WindowSwitcherOverlayPresentation,
        shortcutText: String,
        activatesApp: Bool
    ) {
        let screen = targetScreen()
        model.entries = entries
        model.selectedID = selectedID
        model.pendingKeyPrefix = nil
        model.presentation = presentation
        model.shortcutText = shortcutText
        model.columnCount = columnCount(for: entries.count, presentation: presentation, screen: screen)

        let panel = panel ?? makePanel()
        self.panel = panel
        resize(panel)
        center(panel, on: screen)

        switch presentation {
        case .direct:
            removeKeyMonitor()
            removeClickMonitor()
            panel.orderFrontRegardless()
        case .keyWindow:
            installKeyMonitor()
            installClickMonitor()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 22
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true

        let hostingView = NSHostingView(
            rootView: WindowSwitcherOverlayView(model: model) { [weak self] entry in
                self?.select(entry)
            } onQuit: { [weak self] entry in
                self?.quit(entry)
            }
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        self.hostingView = hostingView
        panel.contentView = effectView
        return panel
    }

    private func resize(_ panel: NSPanel) {
        guard let hostingView else {
            return
        }

        hostingView.layoutSubtreeIfNeeded()
        panel.setContentSize(hostingView.fittingSize)
    }

    private func center(_ panel: NSPanel, on screen: NSScreen?) {
        guard let frame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }

        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
    }

    private func columnCount(
        for entryCount: Int,
        presentation: WindowSwitcherOverlayPresentation,
        screen: NSScreen?
    ) -> Int {
        guard entryCount > 0 else {
            return 1
        }

        let frame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let tileWidth: CGFloat = presentation == .direct ? 96 : 102
        let horizontalPadding: CGFloat = 40
        let spacing: CGFloat = 12
        let maxWidth = min(frame.width - 96, presentation == .direct ? 980 : 1040)
        let capacity = Int((maxWidth - horizontalPadding + spacing) / (tileWidth + spacing))
        return max(1, min(entryCount, capacity))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        clickMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard model.presentation == .keyWindow else {
            return false
        }

        if event.keyCode == 53 {
            cancel()
            return true
        }

        if event.keyCode == 51 {
            model.pendingKeyPrefix = nil
            pendingKeyWorkItem?.cancel()
            return true
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let character = chars.first,
              character >= "a",
              character <= "z"
        else {
            return false
        }

        handleShortcutCharacter(String(character))
        return true
    }

    private func handleShortcutCharacter(_ character: String) {
        let candidate = (model.pendingKeyPrefix ?? "") + character
        if resolveShortcutToken(candidate) {
            return
        }

        model.pendingKeyPrefix = nil
        _ = resolveShortcutToken(character)
    }

    @discardableResult
    private func resolveShortcutToken(_ token: String) -> Bool {
        let entries = model.entries
        let exact = entries.first { $0.shortcutToken == token }
        let hasLongerMatch = entries.contains {
            guard let shortcutToken = $0.shortcutToken else {
                return false
            }
            return shortcutToken.hasPrefix(token) && shortcutToken.count > token.count
        }

        if let exact, !hasLongerMatch {
            select(exact)
            return true
        }

        if let exact, hasLongerMatch {
            model.pendingKeyPrefix = token
            schedulePendingSelection(exact)
            return true
        }

        let hasPrefixMatch = entries.contains {
            $0.shortcutToken?.hasPrefix(token) == true
        }
        guard hasPrefixMatch else {
            return false
        }

        model.pendingKeyPrefix = token
        schedulePendingClear()
        return true
    }

    private func schedulePendingSelection(_ entry: WindowSwitcherAppEntry) {
        pendingKeyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.model.pendingKeyPrefix == entry.shortcutToken else {
                    return
                }
                self?.select(entry)
            }
        }
        pendingKeyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
    }

    private func schedulePendingClear() {
        pendingKeyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.model.pendingKeyPrefix = nil
            }
        }
        pendingKeyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: workItem)
    }

    private func select(_ entry: WindowSwitcherAppEntry) {
        hide()
        onSelect?(entry)
    }

    private func quit(_ entry: WindowSwitcherAppEntry) {
        onQuit?(entry)
    }

    private func cancel() {
        hide()
        onCancel?()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isClosing, model.presentation == .keyWindow else {
            return
        }

        cancel()
    }
}

@MainActor
private struct WindowSwitcherOverlayView: View {
    @ObservedObject var model: WindowSwitcherOverlayModel
    let onSelect: (WindowSwitcherAppEntry) -> Void
    let onQuit: (WindowSwitcherAppEntry) -> Void

    private var tileWidth: CGFloat {
        model.presentation == .direct ? 96 : 102
    }

    private var tileHeight: CGFloat {
        model.presentation == .direct ? 108 : 128
    }

    private var spacing: CGFloat {
        12
    }

    private var contentWidth: CGFloat {
        let columns = max(1, model.columnCount)
        let gridWidth = CGFloat(columns) * tileWidth + CGFloat(max(0, columns - 1)) * spacing
        return max(220, gridWidth)
    }

    var body: some View {
        VStack(spacing: 12) {
            if model.entries.isEmpty {
                emptyState
            } else {
                appGrid
            }
        }
        .frame(width: contentWidth)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .fixedSize()
    }

    private var appGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.fixed(tileWidth), spacing: spacing),
                count: max(1, model.columnCount)
            ),
            spacing: 10
        ) {
            ForEach(model.entries) { entry in
                WindowSwitcherAppTile(
                    entry: entry,
                    isSelected: entry.id == model.selectedID,
                    isPending: isPending(entry),
                    showsShortcut: model.presentation == .keyWindow,
                    tileWidth: tileWidth,
                    tileHeight: tileHeight,
                    onSelect: { onSelect(entry) },
                    onQuit: { onQuit(entry) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("没有可切换的窗口")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
    }

    private func isPending(_ entry: WindowSwitcherAppEntry) -> Bool {
        guard let prefix = model.pendingKeyPrefix,
              let shortcutToken = entry.shortcutToken
        else {
            return false
        }

        return shortcutToken.hasPrefix(prefix)
    }
}

private struct WindowSwitcherAppTile: View {
    let entry: WindowSwitcherAppEntry
    let isSelected: Bool
    let isPending: Bool
    let showsShortcut: Bool
    let tileWidth: CGFloat
    let tileHeight: CGFloat
    let onSelect: () -> Void
    let onQuit: () -> Void

    @State private var isTileHovered = false
    @State private var isContentHovered = false
    @State private var isQuitHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                VStack(spacing: showsShortcut ? 6 : 0) {
                    if showsShortcut {
                        shortcutBadge
                            .frame(height: 22)
                    } else {
                        Color.clear
                            .frame(height: 14)
                    }

                    highlightedContent
                }
                .frame(width: tileWidth, height: tileHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            quitButton
        }
        .frame(width: tileWidth, height: tileHeight)
        .onHover { isTileHovered = $0 }
    }

    private var shortcutBadge: some View {
        Text(entry.shortcutDisplay ?? "")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(isPending ? Color.accentColor : .secondary)
            .frame(minWidth: 22)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(isPending ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.07))
            )
    }

    private var quitButton: some View {
        Button(action: onQuit) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(quitForegroundColor)
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(quitBackgroundColor)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(showsQuitButton ? 1 : 0)
        .allowsHitTesting(showsQuitButton)
        .padding(.top, 7)
        .padding(.trailing, 7)
        .onHover { isQuitHovered = $0 }
        .help("退出 \(entry.appName)")
        .animation(.easeOut(duration: 0.12), value: showsQuitButton)
        .animation(.easeOut(duration: 0.12), value: isQuitHovered)
    }

    private var highlightedContent: some View {
        VStack(spacing: 6) {
            iconView

            VStack(spacing: 1) {
                Text(entry.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)

                if let subtitle = entry.displaySubtitle {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: tileWidth - 10)
        }
        .frame(width: tileWidth, height: highlightedContentHeight)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(contentBackgroundColor)
        )
        .onHover { isContentHovered = $0 }
        .help(accessibilityTitle)
        .animation(.easeOut(duration: 0.12), value: isContentHovered)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isPending)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = entry.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
        }
    }

    private var highlightedContentHeight: CGFloat {
        if showsShortcut {
            return tileHeight - 28
        }

        return tileHeight - 14
    }

    private var contentBackgroundColor: Color {
        if isSelected || (showsShortcut && isContentHovered) {
            return Color.accentColor.opacity(0.16)
        }
        if isPending {
            return Color.accentColor.opacity(0.09)
        }
        return .clear
    }

    private var showsQuitButton: Bool {
        isTileHovered || isSelected || isQuitHovered
    }

    private var quitForegroundColor: Color {
        isQuitHovered ? Color(nsColor: .systemRed) : .secondary
    }

    private var quitBackgroundColor: Color {
        isQuitHovered ? Color(nsColor: .systemRed).opacity(0.16) : Color.primary.opacity(0.08)
    }

    private var accessibilityTitle: String {
        if let subtitle = entry.displaySubtitle {
            return "\(entry.displayName)，\(subtitle)"
        }

        return entry.displayName
    }
}
