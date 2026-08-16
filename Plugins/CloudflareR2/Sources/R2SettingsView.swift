import MacToolsPluginKit
import SwiftUI

struct R2SettingsView: View {
    @ObservedObject var plugin: CloudflareR2Plugin
    @ObservedObject private var store: R2ConfigurationStore

    init(plugin: CloudflareR2Plugin) {
        self.plugin = plugin
        store = plugin.configurationStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            sectionHeader("R2 凭据", icon: "key.fill")
            VStack(spacing: 0) {
                fieldRow("Account ID", text: $store.accountID, prompt: "Cloudflare Account ID")
                PluginSettingsListDivider()
                fieldRow("Bucket", text: $store.bucket, prompt: "Bucket 名称")
                PluginSettingsListDivider()
                fieldRow("Access Key ID", text: $store.accessKeyID, prompt: "R2 API Token Access Key ID")
                PluginSettingsListDivider()
                secureFieldRow
            }
            .pluginSettingsCardBackground(.standard)

            sectionHeader("上传选项", icon: "slider.horizontal.3")
            VStack(spacing: 0) {
                fieldRow("对象前缀", text: $store.objectPrefix, prompt: "例如 uploads/2026（可选）")
                if let validation = store.objectPrefixValidationMessage {
                    Text(validation)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                        .padding(.bottom, PluginSettingsTheme.Spacing.rowVertical)
                }
                PluginSettingsListDivider()
                fieldRow("公开访问地址", text: $store.publicBaseURL, prompt: "https://cdn.example.com（可选）")
                if let validation = store.publicBaseURLValidationMessage {
                    Text(validation)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
                        .padding(.bottom, PluginSettingsTheme.Spacing.rowVertical)
                }
                PluginSettingsListDivider()
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                        Text("保留原文件名").font(PluginSettingsTheme.Typography.rowTitle)
                        Text("开启后，同名对象可能被覆盖；关闭时自动追加唯一后缀。")
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $store.preservesFileName).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .pluginSettingsListRowPadding(interactive: true)
            }
            .pluginSettingsCardBackground(.standard)

            if let message = store.errorMessage {
                Text(message).font(PluginSettingsTheme.Typography.rowDescription).foregroundStyle(.red)
            }

            HStack {
                Text("Secret Access Key 仅保存在 macOS 钥匙串中。")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存配置") { store.save() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if plugin.status.isUploading {
                    Button("取消上传") { plugin.cancelUpload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("选择文件并上传") { plugin.chooseAndUpload() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }

    private var secureFieldRow: some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text("Secret Access Key").font(PluginSettingsTheme.Typography.rowTitle)
                Text(store.hasStoredSecret ? "已保存；留空不会覆盖" : "尚未保存")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SecureField("输入 Secret Access Key", text: $store.secretAccessKey)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func fieldRow(_ title: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Text(title).font(PluginSettingsTheme.Typography.rowTitle)
            Spacer()
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 340)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(PluginSettingsTheme.Typography.sectionTitle)
            .foregroundStyle(.secondary)
    }
}
