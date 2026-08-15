import AppKit
import SwiftUI
import MacToolsPluginKit

enum ActionRunLinkClipboard {
    static func copy(_ value: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

struct ActionRunLinkControl: View {
    @ObservedObject var pluginHost: PluginHost
    let reference: ActionReference
    var displaysUnavailableReason = true

    @State private var isExpanded = false
    @State private var copiedValue: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            switch pluginHost.actionRunLinkPresentation(for: reference) {
            case let .available(representation, _):
                availableContent(representation)
            case .needsPreset:
                Button {
                    switch pluginHost.createActionRunLink(for: reference) {
                    case let .success(representation):
                        copy(representation.url)
                    case let .failure(error):
                        errorMessage = message(for: error)
                    }
                } label: {
                    Label(FeatureL10n.string("复制运行链接"), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case let .unavailable(reason):
                if displaysUnavailableReason {
                    Label(reason, systemImage: "link.badge.plus")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityIdentifier("mactools.run-link.\(reference.key.id)")
    }

    private func availableContent(_ representation: ActionRunLinkRepresentation) -> some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            Button {
                isExpanded.toggle()
            } label: {
                Label(FeatureL10n.string("运行链接"), systemImage: isExpanded ? "chevron.down" : "chevron.right")
                    .font(PluginSettingsTheme.Typography.rowDescription)
            }
            .buttonStyle(.plain)

            if isExpanded {
                runLinkValueRow(
                    title: FeatureL10n.string("运行链接"),
                    value: representation.url
                )
                runLinkValueRow(
                    title: FeatureL10n.string("终端命令"),
                    value: representation.terminalCommand
                )
            }
        }
    }

    private func runLinkValueRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(PluginSettingsTheme.Typography.monospacedValue)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                copy(value)
            } label: {
                Image(systemName: copiedValue == value ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(FeatureL10n.format("复制%@", title))
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.field)
                .fill(PluginSettingsTheme.Palette.fieldBackground)
        )
    }

    private func copy(_ value: String) {
        ActionRunLinkClipboard.copy(value)
        copiedValue = value
        errorMessage = nil
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copiedValue == value {
                copiedValue = nil
            }
        }
    }

    private func message(for error: ActionInvocationPresetError) -> String {
        switch error {
        case .unknownAction:
            FeatureL10n.string("找不到对应操作。")
        case .parameterlessAction:
            FeatureL10n.string("此操作可直接使用运行链接。")
        case .externalInvocationUnavailable:
            FeatureL10n.string("此操作不能通过运行链接调用。")
        case .sensitiveParametersUnsupported:
            FeatureL10n.string("包含敏感参数的操作不能创建运行链接。")
        case .maximumPresetCountReached:
            FeatureL10n.string("运行链接预设数量已达上限。")
        case .persistenceFailed:
            FeatureL10n.string("无法保存运行链接预设。")
        case .unavailablePreset:
            FeatureL10n.string("运行链接预设不可用。")
        }
    }
}

struct ActionRunLinkCopyButton: View {
    @ObservedObject var pluginHost: PluginHost
    let reference: ActionReference
    @State private var didCopy = false

    var body: some View {
        switch pluginHost.actionRunLinkPresentation(for: reference) {
        case let .available(representation, _):
            Menu {
                Button(FeatureL10n.string("复制运行链接")) { copy(representation.url) }
                Button(FeatureL10n.string("复制终端命令")) { copy(representation.terminalCommand) }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "link")
            } primaryAction: {
                copy(representation.url)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(representation.url)
            .accessibilityLabel(FeatureL10n.string("复制运行链接"))
        case .needsPreset:
            Button {
                if case let .success(representation) = pluginHost.createActionRunLink(
                    for: reference
                ) {
                    copy(representation.url)
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "link")
            }
            .buttonStyle(.plain)
            .help(FeatureL10n.string("复制运行链接"))
            .accessibilityLabel(FeatureL10n.string("复制运行链接"))
        case let .unavailable(reason):
            Image(systemName: "link.badge.plus")
                .foregroundStyle(.tertiary)
                .help(reason)
                .accessibilityLabel(reason)
        }
    }

    private func copy(_ value: String) {
        ActionRunLinkClipboard.copy(value)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}
