import AppKit
import SwiftUI
import MacToolsPluginKit

enum FeatureManagementTableMode: Equatable {
    case installed
    case surface(PluginDisplaySurface)

    var supportsReordering: Bool {
        if case .surface = self {
            return true
        }
        return false
    }
}

enum PluginSurfaceLayoutDisplayPolicy {
    static func enabledItems(
        from items: [PluginSurfaceLayoutItem]
    ) -> [PluginSurfaceLayoutItem] {
        items.filter(\.isGloballyEnabled)
    }

    static func disabledItemCount(
        in items: [PluginSurfaceLayoutItem]
    ) -> Int {
        disabledItems(from: items).count
    }

    static func disabledItems(
        from items: [PluginSurfaceLayoutItem]
    ) -> [PluginSurfaceLayoutItem] {
        items.filter { !$0.isGloballyEnabled }
    }
}

enum FeatureManagementReorderPolicy {
    static func canReorder(
        mode: FeatureManagementTableMode,
        isReorderEnabled: Bool
    ) -> Bool {
        mode.supportsReordering && isReorderEnabled
    }

    static func targetOffset(
        for pluginID: String,
        proposedRow: Int,
        items: [FeatureManagementTableItem],
        mode: FeatureManagementTableMode,
        isReorderEnabled: Bool
    ) -> Int? {
        guard canReorder(mode: mode, isReorderEnabled: isReorderEnabled) else {
            return nil
        }
        guard items.contains(where: { $0.id == pluginID }) else {
            return nil
        }

        return min(max(proposedRow, 0), items.count)
    }
}

struct FeatureManagementTableItem: Identifiable {
    let id: String
    let title: String
    let description: String
    let iconName: String
    let iconTint: Color
    let capabilities: PluginHostCapabilities
    let isGloballyEnabled: Bool
    let isActive: Bool
    let hasSettings: Bool
    let category: String?
    let releaseChannel: String?

    init(installedItem item: InstalledPluginItem, hasSettings: Bool = false) {
        id = item.id
        title = item.title
        description = item.description
        iconName = item.iconName
        iconTint = item.iconTint
        capabilities = item.capabilities
        isGloballyEnabled = item.isGloballyEnabled
        isActive = item.isActive
        self.hasSettings = hasSettings
        category = item.category
        releaseChannel = item.releaseChannel
    }

    init(surfaceItem item: PluginSurfaceLayoutItem, hasSettings: Bool = false) {
        id = item.id
        title = item.title
        description = item.description
        iconName = item.iconName
        iconTint = item.iconTint
        capabilities = item.capabilities
        isGloballyEnabled = item.isGloballyEnabled
        isActive = item.isActive
        self.hasSettings = hasSettings
        category = item.category
        releaseChannel = item.releaseChannel
    }
}

struct FeatureManagementTableView: NSViewRepresentable {
    static let rowHeight: CGFloat = 62
    static let rowSpacing: CGFloat = 6
    static let verticalContentInset: CGFloat = 6
    private static let dragType = NSPasteboard.PasteboardType("com.ggbond.mactools.feature-management-item")

    let items: [FeatureManagementTableItem]
    let mode: FeatureManagementTableMode
    var isReorderEnabled: Bool = true
    let onToggleChange: (String, Bool) -> Void
    var onMove: (String, Int) -> Void = { _, _ in }
    var onOpenSettings: (String) -> Void = { _ in }

    static func preferredHeight(for itemCount: Int) -> CGFloat {
        let visibleItemCount = max(itemCount, 1)
        let spacing = CGFloat(max(itemCount - 1, 0)) * rowSpacing
        return CGFloat(visibleItemCount) * rowHeight + spacing + verticalContentInset * 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NonScrollingTableScrollView()
        scrollView.contentView = LockedClipView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentInsets = NSEdgeInsets(
            top: Self.verticalContentInset,
            left: 0,
            bottom: Self.verticalContentInset,
            right: 0
        )

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.verticalMotionCanBeginDrag = true
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.registerForDraggedTypes([Self.dragType])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("feature"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        syncLayout(in: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        syncLayout(in: scrollView, coordinator: context.coordinator)
    }

    private func syncLayout(in scrollView: NSScrollView, coordinator: Coordinator) {
        guard let tableView = coordinator.tableView else {
            return
        }

        guard !coordinator.isDragging else {
            return
        }

        let contentHeight = Self.preferredHeight(for: items.count)
        let contentWidth = max(scrollView.contentSize.width, 1)
        let signature = FeatureManagementTableSignature(
            items: items,
            mode: mode,
            isReorderEnabled: isReorderEnabled,
            contentWidth: contentWidth
        )

        guard coordinator.lastSignature != signature else {
            return
        }

        coordinator.lastSignature = signature

        tableView.reloadData()
        tableView.noteNumberOfRowsChanged()

        tableView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FeatureManagementTableView
        weak var tableView: NSTableView?
        fileprivate var lastSignature: FeatureManagementTableSignature?

        init(parent: FeatureManagementTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            FeatureManagementTableView.rowHeight
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("FeatureManagementCell")
            let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? FeatureManagementTableCellView)
                ?? FeatureManagementTableCellView(frame: .zero)
            view.identifier = identifier

            guard parent.items.indices.contains(row) else {
                return view
            }

            let item = parent.items[row]
            view.configure(
                item: item,
                mode: parent.mode,
                showsHandle: parent.mode.supportsReordering && parent.isReorderEnabled,
                onStateChange: { [weak self] value in
                    self?.parent.onToggleChange(item.id, value)
                },
                onOpenSettings: { [weak self] in
                    self?.parent.onOpenSettings(item.id)
                }
            )
            return view
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard FeatureManagementReorderPolicy.canReorder(
                mode: parent.mode,
                isReorderEnabled: parent.isReorderEnabled
            ) else {
                return nil
            }

            guard parent.items.indices.contains(row) else {
                return nil
            }

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(parent.items[row].id, forType: FeatureManagementTableView.dragType)
            return pasteboardItem
        }

        private(set) var isDragging = false

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            isDragging = true
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .none
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            isDragging = false
            lastSignature = nil
            DispatchQueue.main.async { [weak tableView] in
                tableView?.reloadData()
                tableView?.noteNumberOfRowsChanged()
            }
        }

        func tableView(_ tableView: NSTableView, updateDraggingItemsForDrag draggingInfo: NSDraggingInfo) {
            draggingInfo.enumerateDraggingItems(
                options: [],
                for: tableView,
                classes: [NSPasteboardItem.self],
                searchOptions: [:]
            ) { [weak self] draggingItem, _, _ in
                guard
                    let self,
                    let pasteboardItem = draggingItem.item as? NSPasteboardItem,
                    let pluginID = pasteboardItem.string(forType: FeatureManagementTableView.dragType),
                    let item = parent.items.first(where: { $0.id == pluginID })
                else {
                    return
                }

                let image = FeatureManagementDragPreview.image(
                    for: item,
                    mode: parent.mode,
                    width: tableView.bounds.width
                )
                let frame = NSRect(
                    origin: draggingItem.draggingFrame.origin,
                    size: image.size
                )
                draggingItem.setDraggingFrame(frame, contents: image)
            }
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard FeatureManagementReorderPolicy.canReorder(
                mode: parent.mode,
                isReorderEnabled: parent.isReorderEnabled
            ) else {
                return []
            }

            guard info.draggingPasteboard.availableType(from: [FeatureManagementTableView.dragType]) != nil else {
                return []
            }

            let targetRow = min(max(row, 0), parent.items.count)
            tableView.setDropRow(targetRow, dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard
                let draggedID = info.draggingPasteboard.string(forType: FeatureManagementTableView.dragType),
                let targetRow = FeatureManagementReorderPolicy.targetOffset(
                    for: draggedID,
                    proposedRow: row,
                    items: parent.items,
                    mode: parent.mode,
                    isReorderEnabled: parent.isReorderEnabled
                )
            else {
                return false
            }

            DispatchQueue.main.async { [parent] in
                parent.onMove(draggedID, targetRow)
            }
            return true
        }
    }
}

fileprivate struct FeatureManagementTableSignature: Equatable {
    struct Row: Equatable {
        let id: String
        let title: String
        let description: String
        let iconName: String
        let hasSettings: Bool
        let isGloballyEnabled: Bool
        let isActive: Bool
        let capabilities: PluginHostCapabilities
        let category: String?
        let releaseChannel: String?
    }

    let rows: [Row]
    let mode: FeatureManagementTableMode
    let isReorderEnabled: Bool
    let contentWidth: CGFloat

    init(
        items: [FeatureManagementTableItem],
        mode: FeatureManagementTableMode,
        isReorderEnabled: Bool,
        contentWidth: CGFloat
    ) {
        self.rows = items.map {
            Row(
                id: $0.id,
                title: $0.title,
                description: $0.description,
                iconName: $0.iconName,
                hasSettings: $0.hasSettings,
                isGloballyEnabled: $0.isGloballyEnabled,
                isActive: $0.isActive,
                capabilities: $0.capabilities,
                category: $0.category,
                releaseChannel: $0.releaseChannel
            )
        }
        self.mode = mode
        self.isReorderEnabled = isReorderEnabled
        self.contentWidth = contentWidth.rounded(.toNearestOrAwayFromZero)
    }
}

#if DEBUG
enum FeatureManagementTableUpdatePolicy {
    static func needsUpdate(
        previousItems: [FeatureManagementTableItem],
        currentItems: [FeatureManagementTableItem],
        previousMode: FeatureManagementTableMode,
        currentMode: FeatureManagementTableMode,
        previousIsReorderEnabled: Bool,
        currentIsReorderEnabled: Bool,
        previousContentWidth: CGFloat,
        currentContentWidth: CGFloat
    ) -> Bool {
        FeatureManagementTableSignature(
            items: previousItems,
            mode: previousMode,
            isReorderEnabled: previousIsReorderEnabled,
            contentWidth: previousContentWidth
        ) != FeatureManagementTableSignature(
            items: currentItems,
            mode: currentMode,
            isReorderEnabled: currentIsReorderEnabled,
            contentWidth: currentContentWidth
        )
    }
}
#endif

private final class NonScrollingTableScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private final class LockedClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin = .zero
        return bounds
    }
}

@MainActor
private enum FeatureManagementDragPreview {
    static func image(
        for item: FeatureManagementTableItem,
        mode: FeatureManagementTableMode,
        width: CGFloat
    ) -> NSImage {
        let imageSize = NSSize(
            width: min(max(width, 320), 620),
            height: FeatureManagementTableView.rowHeight
        )
        let image = NSImage(size: imageSize)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high

        let bounds = NSRect(origin: .zero, size: imageSize)
        let contentBounds = bounds.insetBy(dx: 1, dy: 1)
        let backgroundPath = NSBezierPath(
            roundedRect: contentBounds,
            xRadius: 12,
            yRadius: 12
        )
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        backgroundPath.fill()
        NSColor.separatorColor.withAlphaComponent(0.28).setStroke()
        backgroundPath.lineWidth = 1
        backgroundPath.stroke()

        let tintColor = NSColor(item.iconTint)
        let iconBackgroundRect = NSRect(x: 9, y: 16, width: 30, height: 30)
        NSColor(item.iconTint.opacity(0.14)).setFill()
        NSBezierPath(roundedRect: iconBackgroundRect, xRadius: 10, yRadius: 10).fill()

        drawSymbol(
            item.iconName,
            in: NSRect(x: 16, y: 23, width: 16, height: 16),
            color: tintColor,
            pointSize: 16
        )

        let trailingWidth: CGFloat = 74
        let textX = iconBackgroundRect.maxX + 12
        let textWidth = max(imageSize.width - textX - trailingWidth - 12, 80)
        let titleRect = NSRect(x: textX, y: 34, width: textWidth, height: 18)
        let descriptionRect = NSRect(x: textX, y: 13, width: textWidth, height: 17)

        drawText(
            item.title,
            in: titleRect,
            font: .systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor
        )

        drawText(
            featureManagementDescription(for: item, mode: mode),
            in: descriptionRect,
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .secondaryLabelColor
        )

        if item.isActive {
            NSColor.systemGreen.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: imageSize.width - 72,
                    y: (imageSize.height - 8) / 2,
                    width: 8,
                    height: 8
                )
            )
            .fill()
        }

        drawEnablementCheckbox(
            isOn: item.isGloballyEnabled,
            in: NSRect(x: imageSize.width - 50, y: 24, width: 14, height: 14)
        )
        drawSymbol(
            "line.3.horizontal",
            in: NSRect(x: imageSize.width - 20, y: 23, width: 13, height: 13),
            color: .secondaryLabelColor,
            pointSize: 13
        )

        return image
    }

    private static func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor
    ) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        NSString(string: text).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    private static func drawSymbol(
        _ name: String,
        in rect: NSRect,
        color: NSColor,
        pointSize: CGFloat
    ) {
        guard
            let symbol = NSImage(
                systemSymbolName: name,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        else {
            return
        }

        let tintedSymbol = symbol.tinted(with: color)
        tintedSymbol.draw(in: rect)
    }

    private static func drawEnablementCheckbox(isOn: Bool, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)

        if isOn {
            NSColor.controlAccentColor.setFill()
            path.fill()

            let checkPath = NSBezierPath()
            checkPath.lineWidth = 1.5
            checkPath.lineCapStyle = .round
            checkPath.lineJoinStyle = .round
            checkPath.move(to: NSPoint(
                x: rect.minX + rect.width * 0.2,
                y: rect.midY
            ))
            checkPath.line(to: NSPoint(
                x: rect.minX + rect.width * 0.42,
                y: rect.minY + rect.height * 0.28
            ))
            checkPath.line(to: NSPoint(
                x: rect.maxX - rect.width * 0.18,
                y: rect.maxY - rect.height * 0.22
            ))
            NSColor.white.setStroke()
            checkPath.stroke()
        } else {
            NSColor.windowBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

private final class FeatureManagementIconActionButton: NSButton {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isHidden, isEnabled else {
            return
        }
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

private final class FeatureManagementTableCellView: NSTableCellView {
    private let containerView = NSView()
    private let iconBackgroundView = NSView()
    private let iconImageView = NSImageView()
    private let titleRowStackView = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let releaseChannelBadgeView = FeatureManagementReleaseChannelBadgeView()
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let activeDotView = NSView()
    private let iconActionButton = FeatureManagementIconActionButton(title: "", target: nil, action: nil)
    private let trailingControlView = NSView()
    private let enablementButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let handleImageView = NSImageView()
    private var stateChangeHandler: ((Bool) -> Void)?
    private var openSettingsHandler: (() -> Void)?
    private var hasSettings = false
    private var iconTintColor = NSColor.controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildViewHierarchy()
        configureStyles()
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        item: FeatureManagementTableItem,
        mode: FeatureManagementTableMode,
        showsHandle: Bool,
        onStateChange: @escaping (Bool) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        stateChangeHandler = onStateChange
        openSettingsHandler = onOpenSettings
        hasSettings = item.hasSettings

        titleLabel.stringValue = item.title
        configureReleaseChannelBadge(item.releaseChannel)
        descriptionLabel.stringValue = featureManagementDescription(for: item, mode: mode)
        iconImageView.image = NSImage(
            systemSymbolName: item.iconName,
            accessibilityDescription: item.title
        )
        iconTintColor = NSColor(item.iconTint)
        iconImageView.contentTintColor = iconTintColor
        setIconActionHovered(false)
        activeDotView.isHidden = !item.isActive || !item.isGloballyEnabled
        configureTrailingControl(item: item)
        handleImageView.isHidden = !showsHandle
        containerView.alphaValue = 1
        toolTip = item.title
        let controlHelp = featureManagementControlHelp()
        enablementButton.toolTip = controlHelp
        enablementButton.setAccessibilityLabel(item.title)
        enablementButton.setAccessibilityHelp(controlHelp)
        iconActionButton.toolTip = hasSettings
            ? AppL10n.pluginsFormat(
                "plugin.management.openSettingsForPlugin",
                defaultValue: "打开%@设置",
                item.title
            )
            : nil
        iconActionButton.setAccessibilityLabel(iconActionButton.toolTip ?? item.title)
        iconActionButton.setAccessibilityHelp(iconActionButton.toolTip ?? "")
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        containerView.wantsLayer = true
        iconBackgroundView.wantsLayer = true
        activeDotView.wantsLayer = true

        addSubview(containerView)
        containerView.addSubview(iconBackgroundView)
        iconBackgroundView.addSubview(iconImageView)
        iconBackgroundView.addSubview(iconActionButton)
        containerView.addSubview(titleRowStackView)
        titleRowStackView.addArrangedSubview(titleLabel)
        titleRowStackView.addArrangedSubview(releaseChannelBadgeView)
        containerView.addSubview(descriptionLabel)
        containerView.addSubview(activeDotView)
        containerView.addSubview(trailingControlView)
        trailingControlView.addSubview(enablementButton)
        containerView.addSubview(handleImageView)
    }

    private func configureStyles() {
        containerView.layer?.cornerRadius = 12
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        iconBackgroundView.layer?.cornerRadius = 10

        titleRowStackView.orientation = .horizontal
        titleRowStackView.alignment = .centerY
        titleRowStackView.spacing = 6
        titleRowStackView.distribution = .fill

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        releaseChannelBadgeView.setContentHuggingPriority(.required, for: .horizontal)
        releaseChannelBadgeView.setContentCompressionResistancePriority(.required, for: .horizontal)

        descriptionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.usesSingleLineMode = false

        activeDotView.layer?.cornerRadius = 4
        activeDotView.layer?.backgroundColor = NSColor.systemGreen.cgColor

        enablementButton.setButtonType(.switch)
        enablementButton.title = ""
        enablementButton.target = self
        enablementButton.action = #selector(handleEnablementToggle(_:))

        iconActionButton.isBordered = false
        iconActionButton.target = self
        iconActionButton.action = #selector(handleOpenSettings(_:))
        iconActionButton.onHoverChanged = { [weak self] isHovered in
            self?.setIconActionHovered(isHovered)
        }

        handleImageView.image = NSImage(
            systemSymbolName: "line.3.horizontal",
            accessibilityDescription: AppL10n.plugins(
                "plugin.management.reorderAccessibility",
                defaultValue: "拖拽调整顺序"
            )
        )
        handleImageView.contentTintColor = .secondaryLabelColor
        handleImageView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
    }

    private func configureLayout() {
        [
            containerView,
            iconBackgroundView,
            iconImageView,
            iconActionButton,
            titleRowStackView,
            descriptionLabel,
            activeDotView,
            trailingControlView,
            enablementButton,
            handleImageView
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconBackgroundView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            iconBackgroundView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 30),
            iconBackgroundView.heightAnchor.constraint(equalToConstant: 30),

            iconImageView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),

            iconActionButton.leadingAnchor.constraint(equalTo: iconBackgroundView.leadingAnchor),
            iconActionButton.trailingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor),
            iconActionButton.topAnchor.constraint(equalTo: iconBackgroundView.topAnchor),
            iconActionButton.bottomAnchor.constraint(equalTo: iconBackgroundView.bottomAnchor),

            titleRowStackView.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 12),
            titleRowStackView.trailingAnchor.constraint(lessThanOrEqualTo: activeDotView.leadingAnchor, constant: -10),
            titleRowStackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleRowStackView.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingControlView.leadingAnchor, constant: -12),
            descriptionLabel.topAnchor.constraint(equalTo: titleRowStackView.bottomAnchor, constant: 4),

            activeDotView.widthAnchor.constraint(equalToConstant: 8),
            activeDotView.heightAnchor.constraint(equalToConstant: 8),
            activeDotView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            activeDotView.trailingAnchor.constraint(equalTo: trailingControlView.leadingAnchor, constant: -14),

            trailingControlView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            trailingControlView.trailingAnchor.constraint(equalTo: handleImageView.leadingAnchor, constant: -12),
            trailingControlView.widthAnchor.constraint(equalToConstant: 22),
            trailingControlView.heightAnchor.constraint(equalToConstant: 22),

            enablementButton.centerXAnchor.constraint(equalTo: trailingControlView.centerXAnchor),
            enablementButton.centerYAnchor.constraint(equalTo: trailingControlView.centerYAnchor),

            handleImageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            handleImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            handleImageView.widthAnchor.constraint(equalToConstant: 16),
            handleImageView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    private func configureTrailingControl(
        item: FeatureManagementTableItem
    ) {
        enablementButton.isHidden = false
        enablementButton.state = item.isGloballyEnabled ? .on : .off
        iconActionButton.isHidden = !hasSettings
        window?.invalidateCursorRects(for: iconActionButton)
    }

    @objc
    private func handleEnablementToggle(_ sender: NSButton) {
        stateChangeHandler?(sender.state == .on)
    }

    @objc
    private func handleOpenSettings(_ sender: NSButton) {
        openSettingsHandler?()
    }

    private func setIconActionHovered(_ isHovered: Bool) {
        guard hasSettings else {
            iconBackgroundView.layer?.setAffineTransform(.identity)
            iconBackgroundView.layer?.backgroundColor = iconTintColor.withAlphaComponent(0.14).cgColor
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            iconBackgroundView.layer?.setAffineTransform(
                isHovered ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
            )
            iconBackgroundView.layer?.backgroundColor = iconTintColor
                .withAlphaComponent(isHovered ? 0.22 : 0.14)
                .cgColor
        }
    }

    private func configureReleaseChannelBadge(_ rawValue: String?) {
        releaseChannelBadgeView.configure(releaseChannel: PluginReleaseChannel(rawString: rawValue))
    }
}

private final class FeatureManagementReleaseChannelBadgeView: NSView {
    private let textField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildViewHierarchy()
        configureStyles()
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(releaseChannel: PluginReleaseChannel?) {
        guard let releaseChannel else {
            isHidden = true
            return
        }

        textField.stringValue = releaseChannel.displayName
        isHidden = false
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        addSubview(textField)
    }

    private func configureStyles() {
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor

        textField.font = .systemFont(ofSize: 10, weight: .semibold)
        textField.textColor = .systemOrange
        textField.alignment = .center
        textField.lineBreakMode = .byTruncatingTail

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureLayout() {
        textField.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        ])
    }
}

#if DEBUG
enum FeatureManagementTableCellInspection {
    @MainActor
    static func containsSwiftUIHostingViewAfterConfiguring(
        item: FeatureManagementTableItem,
        mode: FeatureManagementTableMode,
        showsHandle: Bool
    ) -> Bool {
        let cell = FeatureManagementTableCellView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: 480,
                height: FeatureManagementTableView.rowHeight
            )
        )
        cell.configure(
            item: item,
            mode: mode,
            showsHandle: showsHandle,
            onStateChange: { _ in },
            onOpenSettings: {}
        )
        return containsSwiftUIHostingView(in: cell)
    }

    @MainActor
    private static func containsSwiftUIHostingView(in view: NSView) -> Bool {
        if NSStringFromClass(type(of: view)).contains("NSHostingView") {
            return true
        }

        return view.subviews.contains { containsSwiftUIHostingView(in: $0) }
    }
}
#endif

func featureManagementDescription(
    for item: FeatureManagementTableItem,
    mode: FeatureManagementTableMode
) -> String {
    var details = [item.description]

    switch mode {
    case .installed:
        details.append(pluginCapabilitySummary(item.capabilities))
    case .surface:
        break
    }

    if item.isGloballyEnabled, item.isActive {
        details.append(AppL10n.plugins("plugin.management.active", defaultValue: "使用中"))
    }

    return details.joined(separator: " · ")
}

func pluginCapabilitySummary(_ capabilities: PluginHostCapabilities) -> String {
    switch (capabilities.supportsDashboard, capabilities.supportsFeaturePanel) {
    case (true, true):
        return AppL10n.plugins("plugin.capability.both", defaultValue: "仪表盘与功能面板")
    case (true, false):
        return AppL10n.plugins("plugin.capability.dashboard", defaultValue: "仪表盘")
    case (false, true):
        return AppL10n.plugins("plugin.capability.featurePanel", defaultValue: "功能面板")
    case (false, false):
        return AppL10n.plugins("plugin.capability.settingsOnly", defaultValue: "仅设置")
    }
}

func featureManagementControlHelp() -> String {
    AppL10n.plugins("plugin.management.globalToggle", defaultValue: "启用或停用插件")
}

private extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size)
        color.setFill()
        rect.fill()
        draw(in: rect, from: rect, operation: .destinationIn, fraction: 1)

        image.isTemplate = false
        return image
    }
}
