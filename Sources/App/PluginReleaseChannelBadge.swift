import SwiftUI
import MacToolsPluginKit

struct PluginReleaseChannelBadge: View {
    let releaseChannel: String?

    var body: some View {
        if let channel = PluginReleaseChannel(rawString: releaseChannel) {
            Text(channel.displayName)
                .font(PluginSettingsTheme.Typography.statusBadge.weight(.semibold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.orange.opacity(0.14))
                )
        }
    }
}
