import AppKit
import MacToolsPluginKit
import SwiftUI

struct ResolvedActionGridEntry: Identifiable, Equatable {
    let id: String
    let reference: ActionReference
    let title: String
    let ownerTitle: String
    let systemImage: String
    let availability: ActionAvailability

    var accessibilityLabel: String {
        "\(title)，\(ownerTitle)，\(availability.isAvailable ? "可用" : (availability.reason ?? "不可用"))"
    }
}

enum ActionGridKeyboardDirection: Equatable {
    case left
    case right
    case up
    case down
}

enum ActionGridKeyCommand: Equatable {
    case dismiss
    case move(ActionGridKeyboardDirection)
    case activateSelected
    case select(Int)

    static func resolve(keyCode: UInt16, characters: String?) -> ActionGridKeyCommand? {
        switch keyCode {
        case 53: .dismiss
        case 123: .move(.left)
        case 124: .move(.right)
        case 125: .move(.down)
        case 126: .move(.up)
        case 36, 76: .activateSelected
        default:
            if let characters, let number = Int(characters), (1 ... 9).contains(number) {
                .select(number)
            } else {
                nil
            }
        }
    }
}

enum ActionGridKeyboardNavigation {
    static func nextIndex(
        from current: Int,
        direction: ActionGridKeyboardDirection,
        itemCount: Int,
        columns: Int
    ) -> Int {
        guard itemCount > 0, columns > 0 else { return 0 }
        let index = min(max(0, current), itemCount - 1)
        let candidate: Int = switch direction {
        case .left: index - 1
        case .right: index + 1
        case .up: index - columns
        case .down: index + columns
        }
        guard (0 ..< itemCount).contains(candidate) else { return index }
        if direction == .left, index % columns == 0 { return index }
        if direction == .right, index % columns == columns - 1 { return index }
        return candidate
    }
}

enum ActionGridOverlayGeometry {
    static func columnCount(for itemCount: Int) -> Int {
        itemCount <= 6 ? 2 : 3
    }

    static func contentSize(for itemCount: Int) -> CGSize {
        let columns = columnCount(for: itemCount)
        let rows = max(1, Int(ceil(Double(max(1, itemCount)) / Double(columns))))
        return CGSize(
            width: CGFloat(columns) * 160 + CGFloat(columns - 1) * 12 + 32,
            height: CGFloat(rows) * 104 + CGFloat(rows - 1) * 12 + 32
        )
    }

    static func targetFrame(
        pointer: CGPoint,
        visibleFrame: CGRect,
        itemCount: Int
    ) -> CGRect {
        let size = contentSize(for: itemCount)
        let margin: CGFloat = 10
        let offset: CGFloat = 16
        var origin = CGPoint(x: pointer.x + offset, y: pointer.y - size.height - offset)
        if origin.y < visibleFrame.minY + margin {
            origin.y = pointer.y + offset
        }
        origin.x = min(
            max(origin.x, visibleFrame.minX + margin),
            visibleFrame.maxX - size.width - margin
        )
        origin.y = min(
            max(origin.y, visibleFrame.minY + margin),
            visibleFrame.maxY - size.height - margin
        )
        return CGRect(origin: origin, size: size)
    }
}

@MainActor
final class ActionGridOverlayModel: ObservableObject {
    @Published private(set) var entries: [ResolvedActionGridEntry] = []
    @Published var selectedIndex = 0
    @Published private(set) var feedback: String?
    @Published private(set) var isExecuting = false

    private let resolver: (ActionGridPresentationEntry) -> ResolvedActionGridEntry
    private let executor: (ActionReference) async -> ActionExecutionOutcome
    var onSuccessfulExecution: (() -> Void)?

    init(
        resolver: @escaping (ActionGridPresentationEntry) -> ResolvedActionGridEntry,
        executor: @escaping (ActionReference) async -> ActionExecutionOutcome
    ) {
        self.resolver = resolver
        self.executor = executor
    }

    var columns: Int { ActionGridOverlayGeometry.columnCount(for: entries.count) }

    func update(_ entries: [ActionGridPresentationEntry]) {
        self.entries = entries.map(resolver)
        selectedIndex = min(selectedIndex, max(0, entries.count - 1))
        feedback = nil
    }

    func move(_ direction: ActionGridKeyboardDirection) {
        selectedIndex = ActionGridKeyboardNavigation.nextIndex(
            from: selectedIndex,
            direction: direction,
            itemCount: entries.count,
            columns: columns
        )
    }

    func select(number: Int) {
        let index = number - 1
        guard entries.indices.contains(index) else { return }
        selectedIndex = index
        activateSelected()
    }

    func activateSelected() {
        guard entries.indices.contains(selectedIndex) else { return }
        activate(entries[selectedIndex])
    }

    func activate(_ entry: ResolvedActionGridEntry) {
        guard !isExecuting else { return }
        guard entry.availability.isAvailable else {
            feedback = entry.availability.reason ?? "操作不可用。"
            return
        }
        isExecuting = true
        feedback = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await executor(entry.reference)
            isExecuting = false
            switch outcome {
            case .completed(.succeeded):
                onSuccessfulExecution?()
            case let .completed(.failed(message)):
                feedback = message
            case .completed(.cancelled):
                feedback = "操作已取消。"
            case let .rejected(rejection):
                feedback = Self.message(for: rejection)
            }
        }
    }

    private static func message(for rejection: ActionExecutionRejection) -> String {
        switch rejection {
        case .unknownAction: "操作不存在。"
        case let .invalidParameters(reason): "操作参数无效：\(reason)"
        case let .unavailable(reason): reason ?? "操作不可用。"
        case .backgroundExecutionUnsupported: "操作不能在后台运行。"
        case .foregroundExecutionUnsupported: "操作不能以交互方式运行。"
        case .externalInvocationUnavailable: "操作不允许外部调用。"
        case .confirmationUnavailable: "无法显示操作确认。"
        case .confirmationDenied: "操作未获确认。"
        case .confirmationTimedOut: "操作确认已超时。"
        case .providerChanged: "操作提供者已发生变化，请重试。"
        case let .providerFailure(message): message
        case .executionTimedOut: "操作执行超时。"
        }
    }
}

private final class ActionGridOverlayPanel: NSPanel {
    var keyEventHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyEventHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

private final class ActionGridDismissTokens {
    var localMouse: Any?
    var globalMouse: Any?
    var resignKey: NSObjectProtocol?

    func removeAll() {
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let resignKey { NotificationCenter.default.removeObserver(resignKey) }
        localMouse = nil
        globalMouse = nil
        resignKey = nil
    }

    deinit { removeAll() }
}

@MainActor
final class ActionGridOverlayController: NSObject, NSWindowDelegate {
    static let panelIdentifier = NSUserInterfaceItemIdentifier("mactools.action-grid.overlay")
    private let pluginHost: PluginHost
    private let model: ActionGridOverlayModel
    private let tokens = ActionGridDismissTokens()
    private var panel: ActionGridOverlayPanel?
    private var previousApplication: NSRunningApplication?

    init(pluginHost: PluginHost) {
        self.pluginHost = pluginHost
        self.model = ActionGridOverlayModel(
            resolver: { [weak pluginHost] entry in
                guard let pluginHost,
                      case let .success(action) = pluginHost.actionRegistry.registeredAction(for: entry.reference) else {
                    return ResolvedActionGridEntry(
                        id: entry.id,
                        reference: entry.reference,
                        title: entry.customTitle ?? "不可用操作",
                        ownerTitle: entry.reference.key.providerID,
                        systemImage: "questionmark.square.dashed",
                        availability: .unavailable("操作提供者不可用。")
                    )
                }
                let ownerTitle = pluginHost.actionSurfaceOwnerTitle(
                    providerID: entry.reference.key.providerID
                )
                return ResolvedActionGridEntry(
                    id: entry.id,
                    reference: entry.reference,
                    title: entry.customTitle ?? action.catalogEntry?.title ?? action.definition.title,
                    ownerTitle: ownerTitle,
                    systemImage: action.definition.systemImage,
                    availability: pluginHost.actionRegistry.availability(for: entry.reference)
                )
            },
            executor: { [weak pluginHost] reference in
                guard let pluginHost else {
                    return .rejected(.unavailable("MacTools 不可用。"))
                }
                return await pluginHost.actionExecutor.execute(
                    ActionInvocation(reference: reference, source: .actionGrid, mode: .foreground)
                )
            }
        )
        super.init()
        model.onSuccessfulExecution = { [weak self] in self?.close() }
    }

    var isShown: Bool { panel != nil }
    var presentedEntryIDs: [String] { model.entries.map(\.id) }

    @discardableResult
    func present(entries: [ActionGridPresentationEntry]) -> Bool {
        guard (1 ... 9).contains(entries.count) else { return false }
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return true
        }
        model.update(entries)

        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let screen else { return false }
        let frame = ActionGridOverlayGeometry.targetFrame(
            pointer: pointer,
            visibleFrame: screen.visibleFrame,
            itemCount: entries.count
        )
        let panel = ActionGridOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.delegate = self
        panel.identifier = Self.panelIdentifier
        panel.setAccessibilityLabel("操作网格")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.keyEventHandler = { [weak self] event in self?.handleKeyEvent(event) ?? false }
        panel.contentView = NSHostingView(
            rootView: ActionGridOverlayView(model: model, onDismiss: { [weak self] in self?.close() })
        )
        previousApplication = NSWorkspace.shared.frontmostApplication == .current
            ? nil
            : NSWorkspace.shared.frontmostApplication
        self.panel = panel
        installDismissHandlers(panel: panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        return true
    }

    func close(restoringFocus: Bool = true) {
        guard let panel else { return }
        tokens.removeAll()
        panel.keyEventHandler = nil
        panel.delegate = nil
        self.panel = nil
        panel.orderOut(nil)
        panel.close()
        if restoringFocus {
            previousApplication?.activate()
        }
        previousApplication = nil
    }

    func windowWillClose(_ notification: Notification) {
        if panel != nil { close() }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let command = ActionGridKeyCommand.resolve(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers
        ) else {
            return false
        }
        switch command {
        case .dismiss:
            close()
        case let .move(direction):
            model.move(direction)
        case .activateSelected:
            model.activateSelected()
        case let .select(number):
            model.select(number: number)
        }
        return true
    }

    private func installDismissHandlers(panel: NSPanel) {
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        tokens.localMouse = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self, weak panel] event in
            guard let self, let panel else { return event }
            if event.window !== panel { self.close() }
            return event
        }
        tokens.globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, let frame = self.panel?.frame, !frame.contains(point) else { return }
                self.close()
            }
        }
        tokens.resignKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.close(restoringFocus: false) }
        }
    }
}

private struct ActionGridOverlayView: View {
    @ObservedObject var model: ActionGridOverlayModel
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(160), spacing: 12), count: model.columns),
                spacing: 12
            ) {
                ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                    Button { model.activate(entry) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: entry.systemImage)
                                .font(.system(size: 27, weight: .medium))
                            Text(entry.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(entry.availability.isAvailable ? entry.ownerTitle : (entry.availability.reason ?? "不可用"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 160, height: 104)
                        .contentShape(Rectangle())
                        .background(tileBackground(selected: index == model.selectedIndex))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isExecuting)
                    .accessibilityLabel("\(index + 1)，\(entry.accessibilityLabel)")
                }
            }
            if let feedback = model.feedback {
                Label(feedback, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : Color.clear)
                .background(reduceTransparency ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.ultraThinMaterial))
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.selectedIndex)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("操作网格")
    }

    private func tileBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2)
                }
            }
    }
}
