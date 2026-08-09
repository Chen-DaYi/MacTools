import MacToolsPluginKit
import SwiftUI

struct PanelPluginEmptyState: View {
    let title: String
    let systemImage: String
    let iconTint: Color
    let onInstall: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconTint.opacity(0.14))

                Image(systemName: PluginSystemImage.resolvedName(systemImage))
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
        Button(AppL10n.plugins("plugin.empty.install", defaultValue: "安装插件"), action: onInstall)
            .buttonStyle(.link)
            .help(AppL10n.plugins("plugin.empty.openMarketplace", defaultValue: "打开插件市场"))
        .font(.system(size: 12, weight: .medium))
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }
}
