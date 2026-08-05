import AppKit
import MacToolsPluginKit
import SwiftUI

struct ActionGridSettingsView: View {
    let plugin: ActionGridPlugin
    @ObservedObject var store: ActionGridStore
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            preview
            entriesSection
            if let error = store.loadError {
                Label(
                    plugin.localizedFormat("无法读取已保存的网格：%@", error),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .foregroundStyle(.red)
                    .font(PluginSettingsTheme.Typography.rowDescription)
            }
        }
        .alert(plugin.localized("重置操作网格？"), isPresented: $confirmingReset) {
            Button(plugin.localized("重置"), role: .destructive) {
                if store.reset(to: plugin.suggestedReferences()) {
                    plugin.notifyMutation()
                }
            }
            Button(plugin.localized("取消"), role: .cancel) {}
        } message: {
            Text(plugin.localized("这会替换当前条目，并使用一组安全的建议操作。"))
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label(plugin.localized("预览"), systemImage: "square.grid.3x3")
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: previewColumns, spacing: 8) {
                ForEach(store.entries) { entry in
                    let item = plugin.item(for: entry.reference)
                    VStack(spacing: 6) {
                        Image(systemName: item?.systemImage ?? "questionmark.square.dashed")
                            .font(.title2)
                        Text(entry.customTitle ?? item?.title ?? plugin.localized("不可用操作"))
                            .font(PluginSettingsTheme.Typography.rowTitle)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .foregroundStyle(item?.availability.isAvailable == true ? .primary : .secondary)
                    .background(PluginSettingsTheme.Palette.nativeCardBackground, in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card))
                }
            }
            if store.entries.isEmpty {
                ContentUnavailableView(
                    plugin.localized("网格为空"),
                    systemImage: "square.grid.3x3",
                    description: Text(plugin.localized("添加最多九个操作。"))
                )
                    .frame(maxWidth: .infinity, minHeight: 130)
                    .pluginSettingsCardBackground(.host)
            }
        }
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label(plugin.localized("条目"), systemImage: "list.bullet")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                addMenu
                Button(plugin.localized("重置")) { confirmingReset = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            List {
                ForEach(store.entries) { entry in
                    entryRow(entry)
                }
                .onMove { offsets, destination in
                    if store.move(fromOffsets: offsets, toOffset: destination) {
                        plugin.notifyMutation()
                    }
                }
            }
            .frame(minHeight: 230)
            .listStyle(.inset)
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(plugin.catalogItems()) { item in
                Button(item.subtitle.map { "\(item.title) — \($0)" } ?? item.title) {
                    if store.add(reference: item.reference) {
                        plugin.notifyMutation()
                    }
                }
            }
        } label: {
            Label(plugin.localized("添加操作"), systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(store.entries.count >= ActionGridStore.maximumEntryCount || plugin.catalogItems().isEmpty)
    }

    private func entryRow(_ entry: ActionGridEntry) -> some View {
        ActionGridEntryRow(plugin: plugin, store: store, entry: entry)
    }

    private var previewColumns: [GridItem] {
        let count = max(1, store.entries.count)
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count <= 6 ? 2 : 3)
    }
}

struct ActionGridEntryRow: View {
    let plugin: ActionGridPlugin
    @ObservedObject var store: ActionGridStore
    let entry: ActionGridEntry

    var body: some View {
        let item = plugin.item(for: entry.reference)
        let title = entry.customTitle ?? item?.title ?? plugin.localized("不可用操作")
        let owner = item?.ownerTitle ?? plugin.localized("提供者缺失")
        let availability = item.map {
            $0.availability.isAvailable
                ? plugin.localized("可用")
                : ($0.availability.reason ?? plugin.localized("不可用"))
        } ?? plugin.localized("重新安装后会自动恢复")
        let accessibility = ActionGridEntryAccessibility(
            title: title,
            owner: owner,
            availability: availability,
            copy: plugin.accessibilityCopy
        )
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: item?.systemImage ?? "questionmark.square.dashed")
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text("\(owner) · \(availability)")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(item?.availability.isAvailable == true ? Color.secondary : Color.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibility.summaryLabel)
            ActionGridEntryControlsView(
                settingsAction: item?.canOpenOwner == true ? {
                    _ = plugin.openOwner(for: entry.reference)
                } : nil,
                replacementOptions: plugin.catalogItems(excluding: entry.id).map {
                    ActionGridReplacementOption(title: $0.title, reference: $0.reference)
                },
                replaceAction: { replacement in
                    if store.replace(id: entry.id, reference: replacement) {
                        plugin.notifyMutation()
                    }
                },
                removeAction: {
                    if store.remove(id: entry.id) { plugin.notifyMutation() }
                },
                accessibility: accessibility,
                identifierPrefix: "mactools.action-grid.entry.\(entry.id.uuidString)"
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct ActionGridReplacementOption: Equatable {
    let title: String
    let reference: ActionReference
}

struct ActionGridEntryControlsView: NSViewRepresentable {
    let settingsAction: (() -> Void)?
    let replacementOptions: [ActionGridReplacementOption]
    let replaceAction: (ActionReference) -> Void
    let removeAction: () -> Void
    let accessibility: ActionGridEntryAccessibility
    let identifierPrefix: String

    func makeNSView(context: Context) -> NativeView {
        NativeView()
    }

    func updateNSView(_ nsView: NativeView, context: Context) {
        nsView.update(
            settingsAction: settingsAction,
            replacementOptions: replacementOptions,
            replaceAction: replaceAction,
            removeAction: removeAction,
            accessibility: accessibility,
            identifierPrefix: identifierPrefix
        )
    }

    final class NativeView: NSStackView {
        let settingsButton: NSButton
        let replacementButton: NSPopUpButton
        let removeButton: NSButton
        var settingsAction: (() -> Void)?
        var replaceAction: ((ActionReference) -> Void)?
        var removeAction: (() -> Void)?
        var replacementOptions: [ActionGridReplacementOption] = []

        override init(frame frameRect: NSRect) {
            settingsButton = NSButton(title: "", target: nil, action: nil)
            replacementButton = NSPopUpButton(frame: .zero, pullsDown: true)
            removeButton = NSButton(
                image: NSImage(
                    systemSymbolName: "trash",
                    accessibilityDescription: nil
                ) ?? NSImage(),
                target: nil,
                action: nil
            )
            super.init(frame: frameRect)

            settingsButton.target = self
            settingsButton.action = #selector(openSettings)
            settingsButton.bezelStyle = .rounded
            settingsButton.controlSize = .small

            replacementButton.bezelStyle = .rounded
            replacementButton.controlSize = .small

            removeButton.target = self
            removeButton.action = #selector(remove)
            removeButton.bezelStyle = .inline
            removeButton.isBordered = false
            removeButton.controlSize = .small
            removeButton.contentTintColor = .systemRed

            setViews([settingsButton, replacementButton, removeButton], in: .leading)
            orientation = .horizontal
            alignment = .centerY
            spacing = PluginSettingsTheme.Spacing.rowContentControl
            setHuggingPriority(.required, for: .horizontal)
            setAccessibilityElement(false)
        }

        convenience init() {
            self.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            settingsAction: (() -> Void)?,
            replacementOptions: [ActionGridReplacementOption],
            replaceAction: @escaping (ActionReference) -> Void,
            removeAction: @escaping () -> Void,
            accessibility: ActionGridEntryAccessibility,
            identifierPrefix: String
        ) {
            self.settingsAction = settingsAction
            self.replaceAction = replaceAction
            self.removeAction = removeAction
            self.replacementOptions = replacementOptions

            settingsButton.isHidden = settingsAction == nil
            settingsButton.title = accessibility.copy.settingsButtonTitle
            configure(
                settingsButton,
                role: .button,
                label: accessibility.settingsLabel,
                help: accessibility.copy.settingsHelp,
                identifier: "\(identifierPrefix).settings"
            )
            configure(
                replacementButton,
                role: .menuButton,
                label: accessibility.replaceLabel,
                help: accessibility.copy.replaceHelp,
                identifier: "\(identifierPrefix).replace"
            )
            configure(
                removeButton,
                role: .button,
                label: accessibility.removeLabel,
                help: accessibility.copy.removeHelp,
                identifier: "\(identifierPrefix).remove"
            )

            let menu = NSMenu()
            menu.addItem(
                withTitle: accessibility.copy.replacementMenuTitle,
                action: nil,
                keyEquivalent: ""
            )
            for (index, option) in replacementOptions.enumerated() {
                let item = NSMenuItem(
                    title: option.title,
                    action: #selector(replace(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
            replacementButton.menu = menu
            replacementButton.isEnabled = !replacementOptions.isEmpty
            setAccessibilityChildren(
                [settingsButton, replacementButton, removeButton].filter { !$0.isHidden }
            )
        }

        private func configure(
            _ element: NSView,
            role: NSAccessibility.Role,
            label: String,
            help: String,
            identifier: String
        ) {
            element.setAccessibilityElement(true)
            element.setAccessibilityRole(role)
            element.setAccessibilityLabel(label)
            element.setAccessibilityHelp(help)
            element.setAccessibilityIdentifier(identifier)
        }

        @objc func openSettings() {
            settingsAction?()
        }

        @objc func replace(_ sender: NSMenuItem) {
            guard replacementOptions.indices.contains(sender.tag) else { return }
            replaceAction?(replacementOptions[sender.tag].reference)
        }

        @objc func remove() {
            removeAction?()
        }
    }
}

struct ActionGridEntryAccessibility: Equatable {
    let title: String
    let owner: String
    let availability: String
    let copy: ActionGridAccessibilityCopy

    init(
        title: String,
        owner: String,
        availability: String,
        copy: ActionGridAccessibilityCopy = .source
    ) {
        self.title = title
        self.owner = owner
        self.availability = availability
        self.copy = copy
    }

    var summaryLabel: String {
        String(format: copy.summaryFormat, title, owner, availability)
    }
    var settingsLabel: String { String(format: copy.settingsLabelFormat, title) }
    var replaceLabel: String { String(format: copy.replaceLabelFormat, title) }
    var removeLabel: String { String(format: copy.removeLabelFormat, title) }
}

struct ActionGridAccessibilityCopy: Equatable {
    let summaryFormat: String
    let settingsLabelFormat: String
    let replaceLabelFormat: String
    let removeLabelFormat: String
    let settingsButtonTitle: String
    let replacementMenuTitle: String
    let settingsHelp: String
    let replaceHelp: String
    let removeHelp: String

    static let source = ActionGridAccessibilityCopy(
        summaryFormat: "%@，%@，%@",
        settingsLabelFormat: "设置“%@”",
        replaceLabelFormat: "替换“%@”",
        removeLabelFormat: "移除“%@”",
        settingsButtonTitle: "设置",
        replacementMenuTitle: "替换",
        settingsHelp: "打开操作提供者设置",
        replaceHelp: "选择其他操作替换此条目",
        removeHelp: "从操作网格移除此条目"
    )
}
