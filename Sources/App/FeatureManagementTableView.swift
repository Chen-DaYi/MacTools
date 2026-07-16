import AppKit
import SwiftUI
import MacToolsPluginKit

enum FeatureManagementTableMode: Equatable {
    case surface(PluginDisplaySurface)

    var supportsReordering: Bool {
        true
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
    let isVisible: Bool
    let isActive: Bool
    let canUninstall: Bool
    let hasSettings: Bool
    let category: String?
    let releaseChannel: String?

    init(surfaceItem item: PluginSurfaceLayoutItem, hasSettings: Bool = false) {
        id = item.id
        title = item.title
        description = item.description
        iconName = item.iconName
        iconTint = item.iconTint
        capabilities = item.capabilities
        isVisible = item.isVisible
        isActive = item.isActive
        canUninstall = item.canUninstall
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
    var onMove: (String, Int) -> Void = { _, _ in }
    var onSetVisible: (String, Bool) -> Void = { _, _ in }
    var onOpenSettings: (String) -> Void = { _ in }
    var onOpenMarketplace: () -> Void = {}
    var onRequestUninstall: (String) -> Void = { _ in }

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

        let tableView = PluginSettingsReorderTableView(dragType: Self.dragType)
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: Self.rowSpacing)

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
                onSetVisible: { [weak self] isVisible in
                    self?.parent.onSetVisible(item.id, isVisible)
                },
                onOpenSettings: { [weak self] in
                    self?.parent.onOpenSettings(item.id)
                },
                onOpenMarketplace: { [weak self] in
                    self?.parent.onOpenMarketplace()
                },
                onRequestUninstall: { [weak self] in
                    self?.parent.onRequestUninstall(item.id)
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
        let isVisible: Bool
        let isActive: Bool
        let canUninstall: Bool
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
                isVisible: $0.isVisible,
                isActive: $0.isActive,
                canUninstall: $0.canUninstall,
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

        let trailingWidth: CGFloat = 30
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
                    x: imageSize.width - 48,
                    y: (imageSize.height - 8) / 2,
                    width: 8,
                    height: 8
                )
            )
            .fill()
        }

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

enum FeatureManagementVisibilityPresentation {
    static func symbolName(isVisible: Bool) -> String {
        isVisible ? "eye" : "eye.slash"
    }

    static func tintColor(isVisible: Bool) -> NSColor {
        isVisible ? .systemBlue : .tertiaryLabelColor
    }
}

enum FeatureManagementVisibilityToggleState {
    static func nextValue(currentValue: inout Bool) -> Bool {
        currentValue.toggle()
        return currentValue
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
    private let visibilityButton = FeatureManagementIconActionButton(title: "", target: nil, action: nil)
    private let handleImageView = NSImageView()
    private var openSettingsHandler: (() -> Void)?
    private var setVisibleHandler: ((Bool) -> Void)?
    private var openMarketplaceHandler: (() -> Void)?
    private var requestUninstallHandler: (() -> Void)?
    private var hasSettings = false
    private var canUninstall = false
    private var isVisible = true
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
        onSetVisible: @escaping (Bool) -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenMarketplace: @escaping () -> Void,
        onRequestUninstall: @escaping () -> Void
    ) {
        openSettingsHandler = onOpenSettings
        setVisibleHandler = onSetVisible
        openMarketplaceHandler = onOpenMarketplace
        requestUninstallHandler = onRequestUninstall
        hasSettings = item.hasSettings
        canUninstall = item.canUninstall
        isVisible = item.isVisible

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
        activeDotView.isHidden = !item.isActive
        configureVisibilityAction(item: item, mode: mode)
        configureActions()
        handleImageView.isHidden = !showsHandle
        containerView.alphaValue = 1
        toolTip = item.title
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
        containerView.addSubview(visibilityButton)
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

        iconActionButton.isBordered = false
        iconActionButton.target = self
        iconActionButton.action = #selector(handleOpenSettings(_:))
        iconActionButton.onHoverChanged = { [weak self] isHovered in
            self?.setIconActionHovered(isHovered)
        }

        visibilityButton.isBordered = false
        visibilityButton.target = self
        visibilityButton.action = #selector(handleVisibilityAction(_:))
        visibilityButton.contentTintColor = .secondaryLabelColor
        visibilityButton.symbolConfiguration = .init(pointSize: 14, weight: .medium)

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
            visibilityButton,
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
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: visibilityButton.leadingAnchor, constant: -12),
            descriptionLabel.topAnchor.constraint(equalTo: titleRowStackView.bottomAnchor, constant: 4),

            activeDotView.widthAnchor.constraint(equalToConstant: 8),
            activeDotView.heightAnchor.constraint(equalToConstant: 8),
            activeDotView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            activeDotView.trailingAnchor.constraint(equalTo: visibilityButton.leadingAnchor, constant: -12),

            visibilityButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            visibilityButton.trailingAnchor.constraint(equalTo: handleImageView.leadingAnchor, constant: -12),
            visibilityButton.widthAnchor.constraint(equalToConstant: 22),
            visibilityButton.heightAnchor.constraint(equalToConstant: 22),

            handleImageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            handleImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            handleImageView.widthAnchor.constraint(equalToConstant: 16),
            handleImageView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    private func configureActions() {
        iconActionButton.isHidden = !hasSettings
        window?.invalidateCursorRects(for: iconActionButton)
        window?.invalidateCursorRects(for: visibilityButton)
    }

    private func configureVisibilityAction(
        item: FeatureManagementTableItem,
        mode: FeatureManagementTableMode
    ) {
        let title = visibilityActionTitle(for: item, mode: mode)
        visibilityButton.image = NSImage(
            systemSymbolName: FeatureManagementVisibilityPresentation.symbolName(isVisible: item.isVisible),
            accessibilityDescription: title
        )
        visibilityButton.contentTintColor = FeatureManagementVisibilityPresentation.tintColor(isVisible: item.isVisible)
        visibilityButton.toolTip = title
        visibilityButton.setAccessibilityLabel(title)
        visibilityButton.setAccessibilityHelp(title)
    }

    @objc
    private func handleOpenSettings(_ sender: NSButton) {
        openSettingsHandler?()
    }

    @objc
    private func handleVisibilityAction(_ sender: NSButton) {
        let nextValue = FeatureManagementVisibilityToggleState.nextValue(currentValue: &isVisible)
        visibilityButton.image = NSImage(
            systemSymbolName: FeatureManagementVisibilityPresentation.symbolName(isVisible: nextValue),
            accessibilityDescription: nil
        )
        visibilityButton.contentTintColor = FeatureManagementVisibilityPresentation.tintColor(
            isVisible: nextValue
        )
        setVisibleHandler?(nextValue)
    }

    @objc
    private func handleOpenMarketplace(_ sender: NSMenuItem) {
        openMarketplaceHandler?()
    }

    @objc
    private func handleRequestUninstall(_ sender: NSMenuItem) {
        requestUninstallHandler?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        actionsMenu()
    }

    private func actionsMenu() -> NSMenu? {
        guard canUninstall else {
            return nil
        }

        let menu = NSMenu()
        if hasSettings {
            let openSettings = NSMenuItem(
                title: AppL10n.plugins("plugin.management.openSettings", defaultValue: "打开插件设置"),
                action: #selector(handleOpenSettingsMenuItem(_:)),
                keyEquivalent: ""
            )
            openSettings.target = self
            menu.addItem(openSettings)
        }

        let marketplace = NSMenuItem(
            title: AppL10n.plugins("plugin.management.viewMarketplace", defaultValue: "在市场中查看"),
            action: #selector(handleOpenMarketplace(_:)),
            keyEquivalent: ""
        )
        marketplace.target = self
        menu.addItem(marketplace)

        if canUninstall {
            menu.addItem(.separator())
            let uninstall = NSMenuItem(
                title: AppL10n.plugins("plugin.marketplace.uninstall", defaultValue: "卸载"),
                action: #selector(handleRequestUninstall(_:)),
                keyEquivalent: ""
            )
            uninstall.target = self
            menu.addItem(uninstall)
        }

        return menu
    }

    @objc
    private func handleOpenSettingsMenuItem(_ sender: NSMenuItem) {
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

    private func visibilityActionTitle(
        for item: FeatureManagementTableItem,
        mode: FeatureManagementTableMode
    ) -> String {
        switch (mode, item.isVisible) {
        case (.surface(.dashboard), true):
            return AppL10n.pluginsFormat(
                "plugin.management.hideFromDashboardFormat",
                defaultValue: "从仪表盘隐藏%@",
                item.title
            )
        case (.surface(.dashboard), false):
            return AppL10n.pluginsFormat(
                "plugin.management.showOnDashboardFormat",
                defaultValue: "在仪表盘显示%@",
                item.title
            )
        case (.surface(.featurePanel), true):
            return AppL10n.pluginsFormat(
                "plugin.management.hideFromFeaturePanelFormat",
                defaultValue: "从功能面板隐藏%@",
                item.title
            )
        case (.surface(.featurePanel), false):
            return AppL10n.pluginsFormat(
                "plugin.management.showInFeaturePanelFormat",
                defaultValue: "在功能面板显示%@",
                item.title
            )
        }
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
        let cell = configuredCell(
            item: item,
            mode: mode,
            showsHandle: showsHandle
        )
        return containsSwiftUIHostingView(in: cell)
    }

    @MainActor
    static func inlineActionButtonCountAfterConfiguring(
        item: FeatureManagementTableItem,
        mode: FeatureManagementTableMode,
        showsHandle: Bool
    ) -> Int {
        let cell = configuredCell(
            item: item,
            mode: mode,
            showsHandle: showsHandle
        )
        return actionButtons(in: cell).count
    }

    @MainActor
    private static func configuredCell(
        item: FeatureManagementTableItem,
        mode: FeatureManagementTableMode,
        showsHandle: Bool
    ) -> FeatureManagementTableCellView {
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
            onSetVisible: { _ in },
            onOpenSettings: {},
            onOpenMarketplace: {},
            onRequestUninstall: {}
        )
        return cell
    }

    @MainActor
    private static func containsSwiftUIHostingView(in view: NSView) -> Bool {
        if NSStringFromClass(type(of: view)).contains("NSHostingView") {
            return true
        }

        return view.subviews.contains { containsSwiftUIHostingView(in: $0) }
    }

    @MainActor
    private static func actionButtons(in view: NSView) -> [FeatureManagementIconActionButton] {
        let ownButton = (view as? FeatureManagementIconActionButton).map { [$0] } ?? []
        return ownButton + view.subviews.flatMap { actionButtons(in: $0) }
    }
}
#endif

func featureManagementDescription(
    for item: FeatureManagementTableItem,
    mode: FeatureManagementTableMode
) -> String {
    var details = [item.description]

    if item.isActive {
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
