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
                Label("无法读取已保存的网格：\(error)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(PluginSettingsTheme.Typography.rowDescription)
            }
        }
        .alert("重置操作网格？", isPresented: $confirmingReset) {
            Button("重置", role: .destructive) {
                if store.reset(to: plugin.suggestedReferences()) {
                    plugin.notifyMutation()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会替换当前条目，并使用一组安全的建议操作。")
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            Label("预览", systemImage: "square.grid.3x3")
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: previewColumns, spacing: 8) {
                ForEach(store.entries) { entry in
                    let item = plugin.item(for: entry.reference)
                    VStack(spacing: 6) {
                        Image(systemName: item?.systemImage ?? "questionmark.square.dashed")
                            .font(.title2)
                        Text(entry.customTitle ?? item?.title ?? "不可用操作")
                            .font(PluginSettingsTheme.Typography.rowTitle)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .foregroundStyle(item?.availability.isAvailable == true ? .primary : .secondary)
                    .background(PluginSettingsTheme.Palette.nativeCardBackground, in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card))
                }
            }
            if store.entries.isEmpty {
                ContentUnavailableView("网格为空", systemImage: "square.grid.3x3", description: Text("添加最多九个操作。"))
                    .frame(maxWidth: .infinity, minHeight: 130)
                    .pluginSettingsCardBackground(.host)
            }
        }
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label("条目", systemImage: "list.bullet")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                addMenu
                Button("重置") { confirmingReset = true }
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
            Label("添加操作", systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(store.entries.count >= ActionGridStore.maximumEntryCount || plugin.catalogItems().isEmpty)
    }

    private func entryRow(_ entry: ActionGridEntry) -> some View {
        let item = plugin.item(for: entry.reference)
        return HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: item?.systemImage ?? "questionmark.square.dashed")
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.customTitle ?? item?.title ?? "不可用操作")
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text(item.map { "\($0.ownerTitle) · \($0.availability.isAvailable ? "可用" : ($0.availability.reason ?? "不可用"))" } ?? "提供者缺失；重新安装后会自动恢复")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(item?.availability.isAvailable == true ? Color.secondary : Color.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item?.canOpenOwner == true {
                Button("设置") {
                    plugin.openOwner(for: entry.reference)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Menu("替换") {
                ForEach(plugin.catalogItems(excluding: entry.id)) { replacement in
                    Button(replacement.title) {
                        if store.replace(id: entry.id, reference: replacement.reference) {
                            plugin.notifyMutation()
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            Button(role: .destructive) {
                if store.remove(id: entry.id) { plugin.notifyMutation() }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.customTitle ?? item?.title ?? "不可用操作")，\(item?.ownerTitle ?? "提供者缺失")，\(item?.availability.reason ?? "可用")")
    }

    private var previewColumns: [GridItem] {
        let count = max(1, store.entries.count)
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count <= 6 ? 2 : 3)
    }
}
