import AppKit
import SwiftUI
import MacToolsPluginKit

struct FeatureManagementTableView: NSViewRepresentable {
    static let rowHeight: CGFloat = 62
    static let rowSpacing: CGFloat = 6
    static let verticalContentInset: CGFloat = 6
    private static let dragType = NSPasteboard.PasteboardType("com.ggbond.mactools.feature-management-item")

    let items: [PluginFeatureManagementItem]
    var isReorderEnabled: Bool = true
    let onVisibilityChange: (String, Bool) -> Void
    let onMove: (String, Int) -> Void

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

            let item = parent.items[row]
            view.configure(
                item: item,
                showsHandle: parent.isReorderEnabled,
                onVisibilityChange: { [weak self] isVisible in
                    self?.parent.onVisibilityChange(item.id, isVisible)
                }
            )
            return view
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.isReorderEnabled else {
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
            tableView.reloadData()
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
            guard parent.isReorderEnabled else {
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
            guard parent.isReorderEnabled else {
                return false
            }

            guard
                let draggedID = info.draggingPasteboard.string(forType: FeatureManagementTableView.dragType)
            else {
                return false
            }

            let targetRow = min(max(row, 0), parent.items.count)
            parent.onMove(draggedID, targetRow)
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
        let isVisible: Bool
        let isActive: Bool
        let presentation: PluginFeaturePresentation
        let category: String?
        let releaseChannel: String?
    }

    let rows: [Row]
    let isReorderEnabled: Bool
    let contentWidth: CGFloat

    init(
        items: [PluginFeatureManagementItem],
        isReorderEnabled: Bool,
        contentWidth: CGFloat
    ) {
        self.rows = items.map {
            Row(
                id: $0.id,
                title: $0.title,
                description: $0.description,
                iconName: $0.iconName,
                isVisible: $0.isVisible,
                isActive: $0.isActive,
                presentation: $0.presentation,
                category: $0.category,
                releaseChannel: $0.releaseChannel
            )
        }
        self.isReorderEnabled = isReorderEnabled
        self.contentWidth = contentWidth.rounded(.toNearestOrAwayFromZero)
    }
}

#if DEBUG
enum FeatureManagementTableUpdatePolicy {
    static func needsUpdate(
        previousItems: [PluginFeatureManagementItem],
        currentItems: [PluginFeatureManagementItem],
        previousIsReorderEnabled: Bool,
        currentIsReorderEnabled: Bool,
        previousContentWidth: CGFloat,
        currentContentWidth: CGFloat
    ) -> Bool {
        FeatureManagementTableSignature(
            items: previousItems,
            isReorderEnabled: previousIsReorderEnabled,
            contentWidth: previousContentWidth
        ) != FeatureManagementTableSignature(
            items: currentItems,
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
    static func image(for item: PluginFeatureManagementItem, width: CGFloat) -> NSImage {
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
            "\(item.description) · \(featureManagementPresentationText(for: item.presentation))",
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

        drawVisibilityCheckbox(
            isOn: item.isVisible,
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

    private static func drawVisibilityCheckbox(isOn: Bool, in rect: NSRect) {
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

private final class FeatureManagementTableCellView: NSTableCellView {
    private let containerView = NSView()
    private let iconBackgroundView = NSView()
    private let iconImageView = NSImageView()
    private let titleRowStackView = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let releaseChannelBadgeView = NSHostingView(rootView: PluginReleaseChannelBadge(releaseChannel: nil))
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let activeDotView = NSView()
    private let visibilityButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let handleImageView = NSImageView()
    private var visibilityHandler: ((Bool) -> Void)?

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
        item: PluginFeatureManagementItem,
        showsHandle: Bool,
        onVisibilityChange: @escaping (Bool) -> Void
    ) {
        visibilityHandler = onVisibilityChange

        titleLabel.stringValue = item.title
        configureReleaseChannelBadge(item.releaseChannel)
        descriptionLabel.stringValue = "\(item.description) · \(featureManagementPresentationText(for: item.presentation))"
        iconImageView.image = NSImage(
            systemSymbolName: item.iconName,
            accessibilityDescription: item.title
        )
        iconImageView.contentTintColor = NSColor(item.iconTint)
        iconBackgroundView.layer?.backgroundColor = NSColor(item.iconTint.opacity(0.14)).cgColor
        activeDotView.isHidden = !item.isActive
        visibilityButton.state = item.isVisible ? .on : .off
        handleImageView.isHidden = !showsHandle
        toolTip = item.title
        visibilityButton.toolTip = item.title
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        containerView.wantsLayer = true
        iconBackgroundView.wantsLayer = true
        activeDotView.wantsLayer = true

        addSubview(containerView)
        containerView.addSubview(iconBackgroundView)
        iconBackgroundView.addSubview(iconImageView)
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

        visibilityButton.setButtonType(.switch)
        visibilityButton.title = ""
        visibilityButton.target = self
        visibilityButton.action = #selector(handleVisibilityToggle(_:))

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

            titleRowStackView.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 12),
            titleRowStackView.trailingAnchor.constraint(lessThanOrEqualTo: activeDotView.leadingAnchor, constant: -10),
            titleRowStackView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleRowStackView.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: visibilityButton.leadingAnchor, constant: -12),
            descriptionLabel.topAnchor.constraint(equalTo: titleRowStackView.bottomAnchor, constant: 4),

            activeDotView.widthAnchor.constraint(equalToConstant: 8),
            activeDotView.heightAnchor.constraint(equalToConstant: 8),
            activeDotView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            activeDotView.trailingAnchor.constraint(equalTo: visibilityButton.leadingAnchor, constant: -14),

            visibilityButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            visibilityButton.trailingAnchor.constraint(equalTo: handleImageView.leadingAnchor, constant: -12),

            handleImageView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            handleImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            handleImageView.widthAnchor.constraint(equalToConstant: 16),
            handleImageView.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    @objc
    private func handleVisibilityToggle(_ sender: NSButton) {
        visibilityHandler?(sender.state == .on)
    }

    private func configureReleaseChannelBadge(_ rawValue: String?) {
        releaseChannelBadgeView.rootView = PluginReleaseChannelBadge(releaseChannel: rawValue)
        releaseChannelBadgeView.isHidden = PluginReleaseChannel(rawString: rawValue) == nil
    }
}

private func featureManagementPresentationText(for presentation: PluginFeaturePresentation) -> String {
    switch presentation {
    case .featurePanel:
        return AppL10n.plugins("plugin.presentation.featurePanel", defaultValue: "操作面板")
    case .componentPanel:
        return AppL10n.plugins("plugin.presentation.componentPanel", defaultValue: "组件")
    case .featureAndComponentPanel:
        return AppL10n.plugins("plugin.presentation.featureAndComponentPanel", defaultValue: "操作面板与组件")
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
