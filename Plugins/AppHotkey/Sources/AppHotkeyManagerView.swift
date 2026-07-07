import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

// MARK: - Manager View

struct AppHotkeyManagerView: View {
    @ObservedObject var store: AppHotkeyStore
    let localization: PluginLocalization
    let onUpdate: () -> Void
    var onBeginRecording: ((UUID) -> Void)? = nil
    var onEndRecording: ((UUID) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            bindingSection
        }
    }

    // MARK: Binding Section

    private var bindingSection: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack {
                Label(localization.string("settings.section.bindings", defaultValue: "应用绑定"), systemImage: "keyboard")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: addApp) {
                    Label(localization.string("settings.add", defaultValue: "添加"), systemImage: "plus")
                        .font(PluginSettingsTheme.Typography.controlLabel)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

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
        .pluginSettingsCardBackground(.host)
    }

    private var entryList: some View {
        VStack(spacing: 0) {
            ForEach(store.entries) { entry in
                AppShortcutEntryRow(
                    entry: entry,
                    localization: localization,
                    onClearShortcut: {
                        store.updateShortcut(id: entry.id, shortcut: nil)
                        onUpdate()
                    },
                    onDelete: {
                        store.deleteEntry(id: entry.id)
                        onUpdate()
                    },
                    onBeginRecording: { onBeginRecording?(entry.id) },
                    onEndRecording: { onEndRecording?(entry.id) },
                    onRecord: { binding in
                        if let conflict = store.conflictEntry(for: binding, excludingID: entry.id) {
                            return .rejected(localization.format(
                                "settings.shortcutConflictFormat",
                                defaultValue: "与「%@」冲突",
                                conflict.displayName
                            ))
                        }
                        store.updateShortcut(id: entry.id, shortcut: binding)
                        onUpdate()
                        return .accepted
                    }
                )
                if entry.id != store.entries.last?.id {
                    PluginSettingsListDivider()
                }
            }
        }
        .pluginSettingsCardBackground(.host)
    }

    // MARK: Actions

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = localization.string("openPanel.title", defaultValue: "选择应用")
        panel.message = localization.string("openPanel.message", defaultValue: "选择要绑定快捷键的应用")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

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
    let entry: AppShortcutEntry
    let localization: PluginLocalization
    let onClearShortcut: () -> Void
    let onDelete: () -> Void
    let onBeginRecording: () -> Void
    let onEndRecording: () -> Void
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult

    private var appIcon: NSImage {
        guard let url = entry.bundleURL else {
            return NSWorkspace.shared.icon(forFile: "/Applications")
        }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }

    private var shortcutText: String {
        ShortcutFormatter.displayString(for: entry.shortcut)
            .replacingOccurrences(
                of: "None",
                with: localization.string("settings.shortcutUnset", defaultValue: "未设置")
            )
    }

    private var subtitle: String {
        guard let url = entry.bundleURL else {
            return localization.string("settings.pathUnavailable", defaultValue: "应用路径不可用")
        }

        return url.path(percentEncoded: false)
    }

    var body: some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: PluginSettingsTheme.Size.rowIcon, height: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(entry.displayName)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .lineLimit(1)

                Text(subtitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PluginShortcutRecorder(
                title: localization.format(
                    "settings.shortcutRecorderTitleFormat",
                    defaultValue: "%@ 快捷键",
                    entry.displayName
                ),
                displayText: shortcutText,
                onRecord: onRecord,
                onBeginRecording: onBeginRecording,
                onEndRecording: onEndRecording
            )

            if entry.shortcut != nil {
                Button(action: onClearShortcut) {
                    Image(systemName: "xmark.circle.fill")
                        .pluginSettingsRowIconStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(localization.string("settings.clearShortcut", defaultValue: "清除快捷键"))
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .pluginSettingsRowIconStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help(localization.string("settings.deleteBinding", defaultValue: "删除此绑定"))
        }
        .pluginSettingsListRowPadding()
    }
}
