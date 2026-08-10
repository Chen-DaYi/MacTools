import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

// MARK: - Manager View

struct AppHotkeyManagerView: View {
    @ObservedObject var store: AppHotkeyStore
    let localization: PluginLocalization
    let onUpdate: () -> Void

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyView
            } else {
                entryList
            }
        }
    }

    private var emptyView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: PluginSettingsTheme.Size.emptyStateIcon))
                    .foregroundStyle(.secondary)
                Text(localization.string("settings.empty", defaultValue: "点击「添加」选择应用并绑定快捷键"))
                    .font(PluginSettingsTheme.Typography.pageDescription)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
            Spacer()
        }
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            ForEach(store.entries) { entry in
                AppShortcutEntryRow(
                    entry: entry,
                    localization: localization,
                    onDelete: {
                        store.deleteEntry(id: entry.id)
                        onUpdate()
                    }
                )
                if entry.id != store.entries.last?.id {
                    PluginSettingsListDivider()
                }
            }
        }
    }

    // MARK: Actions

    static func addApp(
        store: AppHotkeyStore,
        localization: PluginLocalization,
        onUpdate: () -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = localization.string("openPanel.title", defaultValue: "选择应用")
        panel.message = localization.string("openPanel.message", defaultValue: "选择要绑定快捷键的应用")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Bundle(url: url) != nil else { return }

        let displayName = url.deletingPathExtension().lastPathComponent
        let entry = AppShortcutEntry(bundleURL: url, displayName: displayName)
        store.addEntry(entry)
        onUpdate()
    }
}

// MARK: - Entry Row

private struct AppShortcutEntryRow: View {
    private enum Layout {
        static let summaryMinWidth: CGFloat = 220
    }

    let entry: AppShortcutEntry
    let localization: PluginLocalization
    let onDelete: () -> Void

    private var appIcon: NSImage {
        guard let url = entry.bundleURL else {
            return NSWorkspace.shared.icon(forFile: "/Applications")
        }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }

    private var subtitle: String {
        guard let url = entry.bundleURL else {
            return localization.string("settings.pathUnavailable", defaultValue: "应用路径不可用")
        }

        return url.path(percentEncoded: false)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                appSummary
                    .frame(minWidth: Layout.summaryMinWidth)
                rowActions
            }

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                appSummary
                rowActions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .pluginSettingsListRowPadding()
    }

    private var appSummary: some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: PluginSettingsTheme.Size.rowIcon, height: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(entry.displayName)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(subtitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowActions: some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.controlCluster) {
            Text(localization.string("settings.configureInActions", defaultValue: "前往“操作与快捷键”设置"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .pluginSettingsRowIconStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(localization.string("settings.deleteBinding", defaultValue: "删除此绑定"))
        }
    }
}
