import SwiftUI

struct PanelPluginEmptyState: View {
    let title: String
    let systemImage: String
    let iconTint: Color
    let onInstall: () -> Void
    let onEnable: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconTint.opacity(0.14))

                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            .frame(width: 42, height: 42)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))

                actionLinks
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var actionLinks: some View {
        HStack(spacing: 4) {
            Button(AppL10n.plugins("plugin.empty.install", defaultValue: "安装"), action: onInstall)
                .buttonStyle(.link)
                .help(AppL10n.plugins("plugin.empty.openMarketplace", defaultValue: "打开插件市场"))

            Text(AppL10n.plugins("plugin.empty.or", defaultValue: "或"))
                .foregroundStyle(.secondary)

            Button(AppL10n.plugins("plugin.empty.enable", defaultValue: "启用"), action: onEnable)
                .buttonStyle(.link)
                .help(AppL10n.plugins("plugin.empty.openInstalled", defaultValue: "打开已安装插件"))

            Text(AppL10n.plugins("plugin.empty.pluginSuffix", defaultValue: "插件"))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }
}
