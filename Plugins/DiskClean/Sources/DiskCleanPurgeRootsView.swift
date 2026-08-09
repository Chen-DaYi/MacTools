import AppKit
import SwiftUI
import MacToolsPluginKit

/// Developer-artifact scan-root management (design §10.1 settings area).
///
/// Empty by default; only scans directories the user explicitly names—never whole-disk scanning
/// is a product premise, not a performance optimization.
///
/// Adding uses `NSOpenPanel`, not a text field: paths are handed to removal primitives; hand-typed
/// strings are error-prone and cannot obtain the system’s user-intent authorization for directories
/// like Documents / Desktop (panel selection is itself that authorization).
struct DiskCleanPurgeRootsView: View {
    @ObservedObject var model: DiskCleanPurgeRootsModel
    let localization: PluginLocalization

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.roots.isEmpty {
                PluginSettingsListDivider()
                rootRows
            }
            if !model.rejections.isEmpty {
                PluginSettingsListDivider()
                rejectionRow
            }
        }
        .pluginSettingsCardBackground(.plugin)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(localization.string("detail.purgeRoots.title", defaultValue: "扫描文件夹"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
                Text(
                    localization.string(
                        "detail.purgeRoots.description",
                        defaultValue: "只扫描这些文件夹，最多向下 6 层。请添加具体工程目录，不要选择个人文件夹或系统目录。"
                    )
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Button(action: chooseFolder) {
                Label(
                    localization.string("detail.purgeRoots.add", defaultValue: "添加文件夹"),
                    systemImage: "plus"
                )
                .font(PluginSettingsTheme.Typography.controlLabel)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var rootRows: some View {
        VStack(spacing: 0) {
            ForEach(model.roots, id: \.self) { root in
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Image(systemName: "folder")
                        .pluginSettingsRowIconStyle()

                    Text(root)
                        .font(PluginSettingsTheme.Typography.monospacedValue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

                    Button {
                        model.remove(root)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(PluginSettingsTheme.Typography.rowIcon)
                    }
                    .buttonStyle(.borderless)
                    .help(localization.string("detail.purgeRoots.remove", defaultValue: "移除此文件夹"))
                }
                .pluginSettingsListRowPadding()

                if root != model.roots.last {
                    PluginSettingsListDivider()
                }
            }
        }
    }

    /// Show rejection reasons one by one. Silently dropping a just-chosen folder is the worst
    /// outcome—users think they mis-clicked and choose again.
    private var rejectionRow: some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                ForEach(Array(model.rejections.enumerated()), id: \.offset) { _, rejection in
                    Text(Self.rejectionText(rejection, localization: localization))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)

            Button {
                model.dismissRejections()
            } label: {
                Text(localization.string("detail.purgeRoots.dismiss", defaultValue: "知道了"))
                    .font(PluginSettingsTheme.Typography.controlLabel)
            }
            .buttonStyle(.borderless)
        }
        .pluginSettingsListRowPadding()
    }

    static func rejectionText(
        _ rejection: DiskCleanPurgeRootRejection,
        localization: PluginLocalization
    ) -> String {
        switch rejection {
        case let .unresolvable(path):
            return localization.format(
                "detail.purgeRoots.rejected.unresolvable",
                defaultValue: "%@ 无法解析，可能已被移除或没有访问权限。",
                path
            )
        case let .duplicate(path):
            return localization.format(
                "detail.purgeRoots.rejected.duplicate",
                defaultValue: "%@ 已经在列表里了。",
                path
            )
        case let .coveredByAncestor(path, ancestor):
            return localization.format(
                "detail.purgeRoots.rejected.covered",
                defaultValue: "%@ 已包含在 %@ 之内，无需重复添加。",
                path,
                ancestor
            )
        case let .tooBroad(path):
            return localization.format(
                "detail.purgeRoots.rejected.tooBroad",
                defaultValue: "%@ 范围过大，请选择具体的工程目录。",
                path
            )
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = localization.string("detail.purgeRoots.choose", defaultValue: "选择")
        panel.message = localization.string(
            "detail.purgeRoots.chooseMessage",
            defaultValue: "选择具体的工程文件夹（不要选个人文件夹或系统目录）"
        )
        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.add(url.path)
        }
    }
}
