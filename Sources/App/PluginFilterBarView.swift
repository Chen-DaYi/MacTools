import SwiftUI
import MacToolsPluginKit

struct PluginFilterBarView: View {
    @Binding var searchText: String
    @Binding var selectedFilter: PluginCategoryFilter
    let countsByFilter: [PluginCategoryFilter: Int]
    var searchPrompt: String = AppL10n.plugins("plugin.filter.searchPrompt", defaultValue: "搜索插件名称或简介")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField

            if visibleFilters.count > 1 {
                chipsRow
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

            TextField(searchPrompt, text: $searchText)
                .textFieldStyle(.plain)
                .font(PluginSettingsTheme.Typography.rowTitle)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(AppL10n.plugins("plugin.filter.clearSearch", defaultValue: "清除搜索"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
    }

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(visibleFilters) { filter in
                    PluginFilterChip(
                        filter: filter,
                        count: countsByFilter[filter] ?? 0,
                        isSelected: selectedFilter == filter,
                        action: { selectedFilter = filter }
                    )
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var visibleFilters: [PluginCategoryFilter] {
        var filters: [PluginCategoryFilter] = [.all]

        for category in PluginCategory.orderedCases {
            let filter = PluginCategoryFilter.category(category)
            if (countsByFilter[filter] ?? 0) > 0 || filter == selectedFilter {
                filters.append(filter)
            }
        }

        return filters
    }
}

private struct PluginFilterChip: View {
    let filter: PluginCategoryFilter
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: filter.iconName)
                    .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.semibold))
                    .foregroundStyle(iconColor)

                Text(filter.displayName)
                    .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.medium))
                    .foregroundStyle(textColor)

                Text("\(count)")
                    .font(PluginSettingsTheme.Typography.statusBadge.weight(.semibold))
                    .foregroundStyle(countTextColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(countBackground)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(chipBackground)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(filter.displayName)
    }

    private var iconColor: Color {
        isSelected ? .white : filter.iconTint
    }

    private var textColor: Color {
        isSelected ? .white : .primary
    }

    private var countTextColor: Color {
        isSelected ? .white : .secondary
    }

    private var countBackground: Color {
        if isSelected {
            return Color.white.opacity(0.22)
        }

        return Color(nsColor: .quaternaryLabelColor).opacity(0.7)
    }

    private var chipBackground: Color {
        if isSelected {
            return Color.accentColor
        }

        if isHovered {
            return Color(nsColor: .controlBackgroundColor)
        }

        return Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }
}
