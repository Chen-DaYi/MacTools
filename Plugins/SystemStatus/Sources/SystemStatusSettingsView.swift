import AppKit
import SwiftUI
import MacToolsPluginKit

struct SystemStatusSettingsView: View {
    @ObservedObject var controller: SystemStatusSettingsController
    let localization: PluginLocalization

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            panelSection
            menuBarSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var panelSection: some View {
        metricSection(
            systemName: "square.grid.2x2",
            title: localization.string("settings.panel.title", defaultValue: "组件面板"),
            description: localization.string(
                "settings.panel.description",
                defaultValue: "选择组件面板显示的内容，并拖拽调整顺序。"
            ),
            items: panelItems,
            listID: "panel",
            onVisibilityChange: controller.setPanelMetric(_:visible:),
            onMove: controller.movePanelMetric(_:toOffset:)
        )
    }

    private var menuBarSection: some View {
        metricSection(
            systemName: "menubar.rectangle",
            title: localization.string("settings.menuBar.title", defaultValue: "菜单栏指标"),
            description: localization.string(
                "settings.menuBar.description",
                defaultValue: "选择要显示在菜单栏里的指标。"
            ),
            items: menuBarItems,
            listID: "menu-bar",
            onVisibilityChange: controller.setMenuBarMetric(_:visible:),
            onMove: controller.moveMenuBarMetric(_:toOffset:)
        )
    }

    private func metricSection(
        systemName: String,
        title: String,
        description: String,
        items: [SystemStatusMetricPreferenceTableItem],
        listID: String,
        onVisibilityChange: @escaping (SystemStatusMetricKind, Bool) -> Void,
        onMove: @escaping (SystemStatusMetricKind, Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemName)
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)

                Text(description)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            SystemStatusMetricPreferenceTableView(
                items: items,
                listID: listID,
                onVisibilityChange: onVisibilityChange,
                onMove: onMove
            )
            .frame(height: SystemStatusMetricPreferenceTableView.preferredHeight(for: items.count))
            .pluginSettingsCardBackground(.plugin)
        }
    }

    private var panelItems: [SystemStatusMetricPreferenceTableItem] {
        controller.configuration.panelItems.map {
            tableItem(
                preference: $0,
                description: panelDescription(for: $0.kind)
            )
        }
    }

    private var menuBarItems: [SystemStatusMetricPreferenceTableItem] {
        controller.configuration.menuBarItems.map {
            tableItem(
                preference: $0,
                description: menuBarDescription(for: $0.kind)
            )
        }
    }

    private func tableItem(
        preference: SystemStatusMetricPreference,
        description: String
    ) -> SystemStatusMetricPreferenceTableItem {
        let title = preference.kind.title(localization: localization)
        let visibilityActionTitle = preference.isVisible
            ? localization.format(
                "settings.metric.visibility.hide",
                defaultValue: "隐藏%@",
                title
            )
            : localization.format(
                "settings.metric.visibility.show",
                defaultValue: "显示%@",
                title
            )

        return SystemStatusMetricPreferenceTableItem(
            kind: preference.kind,
            title: title,
            description: description,
            iconName: preference.kind.symbolName,
            iconTint: tint(for: preference.kind),
            isVisible: preference.isVisible,
            visibilityActionTitle: visibilityActionTitle,
            visibilityStateTitle: preference.isVisible
                ? localization.string("settings.metric.visibility.visible", defaultValue: "已显示")
                : localization.string("settings.metric.visibility.hidden", defaultValue: "已隐藏")
        )
    }

    private func panelDescription(for kind: SystemStatusMetricKind) -> String {
        switch kind {
        case .cpu:
            return localization.string("settings.metric.cpu.panelDescription", defaultValue: "使用率、温度和功率")
        case .gpu:
            return localization.string("settings.metric.gpu.panelDescription", defaultValue: "使用率、温度和型号")
        case .network:
            return localization.string("settings.metric.network.panelDescription", defaultValue: "上传、下载和地址")
        case .disk:
            return localization.string("settings.metric.disk.panelDescription", defaultValue: "容量和读写速率")
        case .memory:
            return localization.string("settings.metric.memory.panelDescription", defaultValue: "内存和交换空间")
        case .battery:
            return localization.string("settings.metric.battery.panelDescription", defaultValue: "电量、健康度和温度")
        case .topProcesses:
            return localization.string("settings.metric.topProcesses.panelDescription", defaultValue: "CPU 占用最高的进程")
        }
    }

    private func menuBarDescription(for kind: SystemStatusMetricKind) -> String {
        switch kind {
        case .cpu:
            return localization.string("settings.metric.cpu.menuBarDescription", defaultValue: "显示 CPU 使用率")
        case .gpu:
            return localization.string("settings.metric.gpu.menuBarDescription", defaultValue: "显示 GPU 使用率")
        case .network:
            return localization.string("settings.metric.network.menuBarDescription", defaultValue: "显示上下行速率")
        case .disk:
            return localization.string("settings.metric.disk.menuBarDescription", defaultValue: "显示磁盘使用率")
        case .memory:
            return localization.string("settings.metric.memory.menuBarDescription", defaultValue: "显示内存使用率")
        case .battery:
            return localization.string("settings.metric.battery.menuBarDescription", defaultValue: "显示电量")
        case .topProcesses:
            return localization.string("settings.metric.topProcesses.menuBarDescription", defaultValue: "不支持菜单栏显示")
        }
    }

    private func tint(for kind: SystemStatusMetricKind) -> Color {
        switch kind {
        case .cpu:
            return Color(nsColor: .systemGreen)
        case .gpu:
            return Color(nsColor: .systemPurple)
        case .network:
            return Color(nsColor: .systemCyan)
        case .disk:
            return Color(nsColor: .systemBlue)
        case .memory:
            return Color(nsColor: .systemOrange)
        case .battery:
            return Color(nsColor: .systemMint)
        case .topProcesses:
            return Color(nsColor: .systemGray)
        }
    }
}

struct SystemStatusMetricPreferenceTableItem: Equatable, Identifiable {
    let kind: SystemStatusMetricKind
    let title: String
    let description: String
    let iconName: String
    let iconTint: Color
    let isVisible: Bool
    let visibilityActionTitle: String
    let visibilityStateTitle: String

    var id: String { kind.rawValue }

    static func == (lhs: SystemStatusMetricPreferenceTableItem, rhs: SystemStatusMetricPreferenceTableItem) -> Bool {
        lhs.kind == rhs.kind
            && lhs.title == rhs.title
            && lhs.description == rhs.description
            && lhs.iconName == rhs.iconName
            && lhs.isVisible == rhs.isVisible
            && lhs.visibilityActionTitle == rhs.visibilityActionTitle
            && lhs.visibilityStateTitle == rhs.visibilityStateTitle
    }
}

struct SystemStatusMetricPreferenceTableView: NSViewRepresentable {
    static let rowHeight: CGFloat = 58
    static let rowSpacing: CGFloat = 6
    static let verticalContentInset: CGFloat = 6
    private static let dragType = NSPasteboard.PasteboardType("com.ggbond.mactools.system-status.metric-preference")

    let items: [SystemStatusMetricPreferenceTableItem]
    let listID: String
    let onVisibilityChange: (SystemStatusMetricKind, Bool) -> Void
    let onMove: (SystemStatusMetricKind, Int) -> Void

    static func preferredHeight(for itemCount: Int) -> CGFloat {
        let visibleItemCount = max(itemCount, 1)
        let spacing = CGFloat(max(itemCount - 1, 0)) * rowSpacing
        return CGFloat(visibleItemCount) * rowHeight + spacing + verticalContentInset * 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SystemStatusMetricPreferenceScrollView()
        scrollView.contentView = SystemStatusMetricPreferenceClipView()
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
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsEmptySelection = true
        tableView.allowsTypeSelect = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.verticalMotionCanBeginDrag = true
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.registerForDraggedTypes([Self.dragType])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metric"))
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
        guard let tableView = coordinator.tableView, !coordinator.isDragging else {
            return
        }

        let contentHeight = Self.preferredHeight(for: items.count)
        let contentWidth = max(scrollView.contentSize.width, 1)
        let signature = SystemStatusMetricPreferenceTableSignature(
            items: items,
            listID: listID,
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
        var parent: SystemStatusMetricPreferenceTableView
        weak var tableView: NSTableView?
        fileprivate var lastSignature: SystemStatusMetricPreferenceTableSignature?
        fileprivate var isDragging = false

        init(parent: SystemStatusMetricPreferenceTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            SystemStatusMetricPreferenceTableView.rowHeight
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("SystemStatusMetricPreferenceCell")
            let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SystemStatusMetricPreferenceCellView)
                ?? SystemStatusMetricPreferenceCellView(frame: .zero)
            view.identifier = identifier

            let item = parent.items[row]
            view.configure(
                item: item,
                onVisibilityChange: { [weak self] isVisible in
                    self?.parent.onVisibilityChange(item.kind, isVisible)
                }
            )
            return view
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(
                "\(parent.listID):\(parent.items[row].kind.rawValue)",
                forType: SystemStatusMetricPreferenceTableView.dragType
            )
            return pasteboardItem
        }

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

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard draggedKind(from: info.draggingPasteboard) != nil else {
                return []
            }

            tableView.setDropRow(min(max(row, 0), parent.items.count), dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let kind = draggedKind(from: info.draggingPasteboard) else {
                return false
            }

            parent.onMove(kind, min(max(row, 0), parent.items.count))
            return true
        }

        private func draggedKind(from pasteboard: NSPasteboard) -> SystemStatusMetricKind? {
            guard
                let payload = pasteboard.string(forType: SystemStatusMetricPreferenceTableView.dragType),
                payload.hasPrefix("\(parent.listID):")
            else {
                return nil
            }

            let rawValue = String(payload.dropFirst(parent.listID.count + 1))
            let kind = SystemStatusMetricKind(rawValue: rawValue)
            guard let kind, parent.items.contains(where: { $0.kind == kind }) else {
                return nil
            }
            return kind
        }
    }
}

private struct SystemStatusMetricPreferenceTableSignature: Equatable {
    let rows: [SystemStatusMetricPreferenceTableItem]
    let listID: String
    let contentWidth: CGFloat

    init(
        items: [SystemStatusMetricPreferenceTableItem],
        listID: String,
        contentWidth: CGFloat
    ) {
        self.rows = items
        self.listID = listID
        self.contentWidth = contentWidth.rounded(.toNearestOrAwayFromZero)
    }
}

private final class SystemStatusMetricPreferenceScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private final class SystemStatusMetricPreferenceClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin = .zero
        return bounds
    }
}

private final class SystemStatusMetricPreferenceCellView: NSTableCellView {
    private let containerView = NSView()
    private let iconBackgroundView = NSView()
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private let visibilityButton = NSButton(title: "", target: nil, action: nil)
    private let handleImageView = NSImageView()
    private var visibilityHandler: ((Bool) -> Void)?
    private var isVisible = false

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
        item: SystemStatusMetricPreferenceTableItem,
        onVisibilityChange: @escaping (Bool) -> Void
    ) {
        visibilityHandler = onVisibilityChange
        titleLabel.stringValue = item.title
        descriptionLabel.stringValue = item.description
        iconImageView.image = NSImage(
            systemSymbolName: item.iconName,
            accessibilityDescription: item.title
        )
        iconImageView.contentTintColor = NSColor(item.iconTint)
        iconBackgroundView.layer?.backgroundColor = NSColor(item.iconTint.opacity(0.14)).cgColor
        isVisible = item.isVisible
        visibilityButton.image = NSImage(
            systemSymbolName: isVisible ? "eye" : "eye.slash",
            accessibilityDescription: nil
        )
        visibilityButton.contentTintColor = isVisible ? .controlAccentColor : .secondaryLabelColor
        toolTip = item.title
        visibilityButton.toolTip = item.visibilityActionTitle
        visibilityButton.setAccessibilityLabel(item.title)
        visibilityButton.setAccessibilityValue(item.visibilityStateTitle)
        visibilityButton.setAccessibilityHelp(item.visibilityActionTitle)
    }

    private func buildViewHierarchy() {
        wantsLayer = true
        containerView.wantsLayer = true
        iconBackgroundView.wantsLayer = true

        addSubview(containerView)
        containerView.addSubview(iconBackgroundView)
        iconBackgroundView.addSubview(iconImageView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(descriptionLabel)
        containerView.addSubview(visibilityButton)
        containerView.addSubview(handleImageView)
    }

    private func configureStyles() {
        containerView.layer?.cornerRadius = 12
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        iconBackgroundView.layer?.cornerRadius = 10

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1

        descriptionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.maximumNumberOfLines = 1

        visibilityButton.setButtonType(.momentaryPushIn)
        visibilityButton.title = ""
        visibilityButton.imagePosition = .imageOnly
        visibilityButton.bezelStyle = .inline
        visibilityButton.isBordered = false
        visibilityButton.target = self
        visibilityButton.action = #selector(handleVisibilityToggle(_:))

        handleImageView.image = NSImage(
            systemSymbolName: "line.3.horizontal",
            accessibilityDescription: "拖拽调整顺序"
        )
        handleImageView.contentTintColor = .secondaryLabelColor
        handleImageView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
    }

    private func configureLayout() {
        [
            containerView,
            iconBackgroundView,
            iconImageView,
            titleLabel,
            descriptionLabel,
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

            titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: visibilityButton.leadingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: visibilityButton.leadingAnchor, constant: -12),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

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

    @objc
    private func handleVisibilityToggle(_ sender: NSButton) {
        visibilityHandler?(!isVisible)
    }
}
