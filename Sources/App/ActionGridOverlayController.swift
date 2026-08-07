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
    var slotIndex: Int = 0
    var children: [ActionGridPresentationEntry]? = nil

    var isFolder: Bool { children != nil }

    var accessibilityLabel: String {
        FeatureL10n.joined([
            title,
            ownerTitle,
            availability.isAvailable
                ? FeatureL10n.string("可用")
                : (availability.reason ?? FeatureL10n.string("不可用")),
        ])
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
    static func preferredInitialSlot(
        occupiedSlots: Set<Int>,
        columns: Int = 3,
        maximumSlots: Int = ActionGridPresentationLimits.maximumEntriesPerGrid
    ) -> Int {
        guard !occupiedSlots.isEmpty, columns > 0, maximumSlots > 0 else { return 0 }
        let validSlots = occupiedSlots.filter { (0 ..< maximumSlots).contains($0) }
        guard !validSlots.isEmpty else { return 0 }
        let centerSlot = min(maximumSlots - 1, (maximumSlots / 2))
        let centerRow = centerSlot / columns
        let centerColumn = centerSlot % columns

        return validSlots
            .min { lhs, rhs in
                let lhsDistance = abs(lhs / columns - centerRow) + abs(lhs % columns - centerColumn)
                let rhsDistance = abs(rhs / columns - centerRow) + abs(rhs % columns - centerColumn)
                return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
            } ?? 0
    }

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

    static func nextOccupiedSlot(
        from current: Int,
        direction: ActionGridKeyboardDirection,
        occupiedSlots: Set<Int>,
        columns: Int = 3,
        maximumSlots: Int = ActionGridPresentationLimits.maximumEntriesPerGrid
    ) -> Int {
        guard occupiedSlots.contains(current), columns > 0 else {
            return occupiedSlots.min() ?? 0
        }
        let step: Int = switch direction {
        case .left: -1
        case .right: 1
        case .up: -columns
        case .down: columns
        }
        var candidate = current + step
        while (0 ..< maximumSlots).contains(candidate) {
            if direction == .left, candidate / columns != current / columns { break }
            if direction == .right, candidate / columns != current / columns { break }
            if occupiedSlots.contains(candidate) { return candidate }
            candidate += step
        }
        return current
    }
}

enum ActionGridOverlayGeometry {
    static func columnCount(for itemCount: Int) -> Int {
        itemCount > 0 ? 3 : 0
    }

    static func contentSize(for itemCount: Int) -> CGSize {
        let columns = max(1, columnCount(for: itemCount))
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
        let preferredOrigin = CGPoint(
            x: pointer.x - size.width / 2,
            y: pointer.y - size.height / 2
        )
        let minimumX = visibleFrame.minX + margin
        let maximumX = visibleFrame.maxX - size.width - margin
        let minimumY = visibleFrame.minY + margin
        let maximumY = visibleFrame.maxY - size.height - margin
        let origin = CGPoint(
            x: maximumX >= minimumX
                ? min(max(preferredOrigin.x, minimumX), maximumX)
                : visibleFrame.midX - size.width / 2,
            y: maximumY >= minimumY
                ? min(max(preferredOrigin.y, minimumY), maximumY)
                : visibleFrame.midY - size.height / 2
        )
        return CGRect(origin: origin, size: size)
    }
}

enum ActionGridPointerActivationPolicy {
    /// Prevents the touch release that completed a trackpad gesture from
    /// becoming a click on the cell that appears beneath the pointer.
    static let presentationGraceInterval: TimeInterval = 0.35
    static let trackpadPresentationGraceInterval: TimeInterval = 0.8

    static func acceptsPointerEvent(
        eventUptime: TimeInterval,
        presentationUptime: TimeInterval,
        source: ActionExecutionSource
    ) -> Bool {
        let interval = source == .trackpadGesture
            ? trackpadPresentationGraceInterval
            : presentationGraceInterval
        return eventUptime - presentationUptime >= interval
    }
}

struct ActionGridOverlayAccessibilityPolicy: Equatable {
    let reduceMotion: Bool
    let reduceTransparency: Bool

    var animatesSelection: Bool { !reduceMotion }
    var usesMaterialBackground: Bool { !reduceTransparency }
}

@MainActor
final class ActionGridOverlayModel: ObservableObject {
    private struct NavigationLevel {
        let title: String
        let entries: [ActionGridPresentationEntry]
        let selectedIndex: Int
    }

    @Published private(set) var entries: [ResolvedActionGridEntry] = []
    @Published var selectedIndex = 0
    @Published private(set) var feedback: String?
    @Published private(set) var isExecuting = false
    @Published private(set) var folderPath: [String] = []

    private let resolver: (ActionGridPresentationEntry) -> ResolvedActionGridEntry
    private let executor: (ActionReference) async -> ActionExecutionOutcome
    private var sourceEntries: [ActionGridPresentationEntry] = []
    private var navigationStack: [NavigationLevel] = []
    var onSuccessfulExecution: (() -> Void)?

    init(
        resolver: @escaping (ActionGridPresentationEntry) -> ResolvedActionGridEntry,
        executor: @escaping (ActionReference) async -> ActionExecutionOutcome
    ) {
        self.resolver = resolver
        self.executor = executor
    }

    var columns: Int { ActionGridOverlayGeometry.columnCount(for: slotCount) }
    @Published private(set) var slotCount = 0
    var isAtRoot: Bool { navigationStack.isEmpty }
    var navigationTitle: String? { folderPath.last }

    func update(_ entries: [ActionGridPresentationEntry]) {
        navigationStack = []
        folderPath = []
        sourceEntries = entries
        refreshLocalization()
        selectedIndex = preferredInitialSelection()
        feedback = nil
    }

    func refreshLocalization() {
        entries = sourceEntries.enumerated().map { offset, entry in
            var resolved = resolver(entry)
            resolved.slotIndex = entry.slotIndex ?? offset
            return resolved
        }
        .sorted { $0.slotIndex < $1.slotIndex }
        slotCount = min(
            ActionGridPresentationLimits.maximumEntriesPerGrid,
            max(1, (entries.map(\.slotIndex).max() ?? 0) + 1)
        )
        if entry(at: selectedIndex) == nil {
            selectedIndex = preferredInitialSelection()
        }
    }

    func move(_ direction: ActionGridKeyboardDirection) {
        selectedIndex = ActionGridKeyboardNavigation.nextOccupiedSlot(
            from: selectedIndex,
            direction: direction,
            occupiedSlots: Set(entries.map(\.slotIndex)),
            columns: columns
        )
    }

    func select(number: Int) {
        let index = number - 1
        guard entry(at: index) != nil else { return }
        selectedIndex = index
        activateSelected()
    }

    func activateSelected() {
        guard let entry = entry(at: selectedIndex) else { return }
        activate(entry)
    }

    func activate(_ entry: ResolvedActionGridEntry) {
        guard !isExecuting else { return }
        if let children = entry.children {
            navigationStack.append(
                NavigationLevel(
                    title: entry.title,
                    entries: sourceEntries,
                    selectedIndex: selectedIndex
                )
            )
            folderPath.append(entry.title)
            sourceEntries = children
            feedback = nil
            refreshLocalization()
            selectedIndex = preferredInitialSelection()
            return
        }
        guard entry.availability.isAvailable else {
            feedback = entry.availability.reason ?? FeatureL10n.string("操作不可用。")
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
                feedback = FeatureL10n.string("操作已取消。")
            case let .rejected(rejection):
                feedback = Self.message(for: rejection)
            }
        }
    }

    private func preferredInitialSelection() -> Int {
        ActionGridKeyboardNavigation.preferredInitialSlot(
            occupiedSlots: Set(entries.map(\.slotIndex)),
            columns: columns
        )
    }

    @discardableResult
    func navigateBack() -> Bool {
        guard let level = navigationStack.popLast() else { return false }
        sourceEntries = level.entries
        selectedIndex = level.selectedIndex
        if !folderPath.isEmpty { folderPath.removeLast() }
        feedback = nil
        refreshLocalization()
        return true
    }

    private static func message(for rejection: ActionExecutionRejection) -> String {
        switch rejection {
        case .unknownAction: FeatureL10n.string("找不到对应操作。")
        case let .invalidParameters(reason): FeatureL10n.format("操作参数无效：%@", reason)
        case let .unavailable(reason): reason ?? FeatureL10n.string("操作不可用。")
        case .backgroundExecutionUnsupported: FeatureL10n.string("操作不能在后台运行。")
        case .foregroundExecutionUnsupported: FeatureL10n.string("操作不能以交互方式运行。")
        case .externalInvocationUnavailable: FeatureL10n.string("此操作不允许从外部调用。")
        case .confirmationUnavailable: FeatureL10n.string("无法显示操作确认。")
        case .confirmationDenied: FeatureL10n.string("操作已取消。")
        case .confirmationTimedOut: FeatureL10n.string("确认已超时。")
        case .providerChanged: FeatureL10n.string("操作提供方已发生变化，请重试。")
        case let .providerFailure(message): message
        case .executionTimedOut: FeatureL10n.string("操作超时。")
        }
    }

    func entry(at slot: Int) -> ResolvedActionGridEntry? {
        entries.first { $0.slotIndex == slot }
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
    private var presentationUptime: TimeInterval = 0
    private var presentationSource = ActionExecutionSource.manual

    init(pluginHost: PluginHost) {
        self.pluginHost = pluginHost
        self.model = ActionGridOverlayModel(
            resolver: { [weak pluginHost] entry in
                if let children = entry.children {
                    return ResolvedActionGridEntry(
                        id: entry.id,
                        reference: entry.reference,
                        title: entry.customTitle ?? FeatureL10n.string("文件夹"),
                        ownerTitle: FeatureL10n.string("文件夹"),
                        systemImage: entry.folderSystemImage ?? "folder.fill",
                        availability: .available,
                        children: children
                    )
                }
                guard let pluginHost,
                      case let .success(action) = pluginHost.actionRegistry.registeredAction(for: entry.reference) else {
                    return ResolvedActionGridEntry(
                        id: entry.id,
                        reference: entry.reference,
                        title: entry.customTitle ?? FeatureL10n.string("操作不可用。"),
                        ownerTitle: entry.reference.key.providerID,
                        systemImage: "questionmark.square.dashed",
                        availability: .unavailable(FeatureL10n.string("操作提供方当前不可用。"))
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
                    return .rejected(.unavailable(FeatureL10n.string("操作提供方当前不可用。")))
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
    var presentedPanelFrame: CGRect? { panel?.frame }
    var presentedPanelCollectionBehavior: NSWindow.CollectionBehavior? {
        panel?.collectionBehavior
    }

    @discardableResult
    func present(
        entries: [ActionGridPresentationEntry],
        source: ActionExecutionSource = .manual
    ) -> Bool {
        guard (1 ... ActionGridPresentationLimits.maximumEntriesPerGrid).contains(entries.count),
              Self.hasValidSlots(entries) else {
            return false
        }
        presentationUptime = ProcessInfo.processInfo.systemUptime
        presentationSource = source
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
            itemCount: model.slotCount
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
        panel.setAccessibilityLabel(FeatureL10n.string("操作网格"))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.keyEventHandler = { [weak self] event in self?.processKeyEvent(event) ?? false }
        panel.contentView = NSHostingView(
            rootView: ActionGridOverlayRootView(
                model: model,
                onDismiss: { [weak self] in self?.close() }
            )
        )
        previousApplication = NSWorkspace.shared.frontmostApplication == .current
            ? nil
            : NSWorkspace.shared.frontmostApplication
        self.panel = panel
        installDismissHandlers(panel: panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    private static func hasValidSlots(_ entries: [ActionGridPresentationEntry]) -> Bool {
        let resolvedSlots = entries.enumerated().map { offset, entry in entry.slotIndex ?? offset }
        return resolvedSlots.allSatisfy {
            (0 ..< ActionGridPresentationLimits.maximumEntriesPerGrid).contains($0)
        } && Set(resolvedSlots).count == resolvedSlots.count
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

    func processKeyEvent(_ event: NSEvent) -> Bool {
        guard let command = ActionGridKeyCommand.resolve(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers
        ) else {
            return false
        }
        switch command {
        case .dismiss:
            if !model.navigateBack() {
                close()
            }
        case let .move(direction):
            model.move(direction)
        case .activateSelected:
            model.activateSelected()
        case let .select(number):
            model.select(number: number)
        }
        return true
    }

    func dismissIfPointerIsOutside(_ point: CGPoint) {
        guard let frame = panel?.frame, !frame.contains(point) else { return }
        close()
    }

    private func installDismissHandlers(panel: NSPanel) {
        let mouseMask: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
        ]
        tokens.localMouse = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self, weak panel] event in
            guard let self, let panel else { return event }
            if event.window === panel,
               !ActionGridPointerActivationPolicy.acceptsPointerEvent(
                   eventUptime: ProcessInfo.processInfo.systemUptime,
                   presentationUptime: self.presentationUptime,
                   source: self.presentationSource
               ) {
                return nil
            }
            if event.window !== panel { self.close() }
            return event
        }
        tokens.globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] _ in
            let point = NSEvent.mouseLocation
            DispatchQueue.main.async {
                self?.dismissIfPointerIsOutside(point)
            }
        }
        tokens.resignKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.close(restoringFocus: false)
            }
        }
    }
}

struct ActionGridOverlayRootView: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    @ObservedObject var model: ActionGridOverlayModel
    let onDismiss: () -> Void

    var body: some View {
        ActionGridOverlayView(model: model, onDismiss: onDismiss)
            .environment(\.locale, PluginRuntimeLocalization.locale)
            .environment(
                \.layoutDirection,
                Self.layoutDirection(for: PluginRuntimeLocalization.locale)
            )
            .onChange(of: runtimeLocale.revision) { _, _ in
                model.refreshLocalization()
            }
    }

    static func layoutDirection(for locale: Locale) -> LayoutDirection {
        locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

private struct ActionGridOverlayView: View {
    @ObservedObject var model: ActionGridOverlayModel
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var accessibilityPolicy: ActionGridOverlayAccessibilityPolicy {
        ActionGridOverlayAccessibilityPolicy(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            if let navigationTitle = model.navigationTitle {
                HStack {
                    Button {
                        _ = model.navigateBack()
                    } label: {
                        Label(FeatureL10n.string("返回"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Text(navigationTitle)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(160), spacing: 12), count: model.columns),
                spacing: 12
            ) {
                ForEach(0 ..< model.slotCount, id: \.self) { slot in
                    if let entry = model.entry(at: slot) {
                    Button { model.activate(entry) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: entry.systemImage)
                                .font(.system(size: 27, weight: .medium))
                            Text(entry.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(
                                entry.isFolder
                                    ? FeatureL10n.string("打开文件夹")
                                    : entry.availability.isAvailable
                                    ? entry.ownerTitle
                                    : (entry.availability.reason ?? FeatureL10n.string("不可用"))
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 160, height: 104)
                        .contentShape(Rectangle())
                        .background(tileBackground(selected: slot == model.selectedIndex))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isExecuting)
                    .accessibilityLabel(FeatureL10n.joined([String(slot + 1), entry.accessibilityLabel]))
                    } else {
                        Color.clear
                            .frame(width: 160, height: 104)
                            .accessibilityHidden(true)
                    }
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
                .fill(
                    accessibilityPolicy.usesMaterialBackground
                        ? Color.clear
                        : Color(nsColor: .windowBackgroundColor)
                )
                .background(
                    accessibilityPolicy.usesMaterialBackground
                        ? AnyShapeStyle(.ultraThinMaterial)
                        : AnyShapeStyle(Color.clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .animation(
            accessibilityPolicy.animatesSelection ? .easeOut(duration: 0.16) : nil,
            value: model.selectedIndex
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FeatureL10n.string("操作网格"))
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
