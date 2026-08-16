import SwiftUI
import MacToolsPluginKit

struct PluginFilterBarView: View {
    @Binding var searchText: String
    @Binding var selectedFilter: PluginCategoryFilter
    @FocusState.Binding var isSearchFocused: Bool
    let countsByFilter: [PluginCategoryFilter: Int]
    var searchPrompt: String = AppL10n.plugins("plugin.filter.searchPrompt", defaultValue: "搜索插件名称或简介")

    var body: some View {
        SettingsSearchFilterBar(
            searchText: $searchText,
            isSearchFocused: $isSearchFocused,
            searchPrompt: searchPrompt,
            clearSearchHelp: AppL10n.plugins(
                "plugin.filter.clearSearch",
                defaultValue: "清除搜索"
            )
        ) {
            if visibleFilters.count > 1 {
                SettingsFilterChipsRow(
                    accessibilityLabel: FeatureL10n.string("筛选")
                ) {
                    ForEach(visibleFilters) { filter in
                        SettingsFilterChip(
                            title: filter.displayName,
                            systemImage: filter.iconName,
                            iconTint: filter.iconTint,
                            count: countsByFilter[filter] ?? 0,
                            isSelected: selectedFilter == filter,
                            action: { selectedFilter = filter }
                        )
                    }
                }
            }
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

struct SettingsSearchFilterBar<Filters: View>: View {
    @Binding private var searchText: String
    @FocusState.Binding private var isSearchFocused: Bool
    private let searchPrompt: String
    private let clearSearchHelp: String
    private let searchAccessibilityIdentifier: String?
    private let filters: Filters

    init(
        searchText: Binding<String>,
        isSearchFocused: FocusState<Bool>.Binding,
        searchPrompt: String,
        clearSearchHelp: String,
        searchAccessibilityIdentifier: String? = nil,
        @ViewBuilder filters: () -> Filters
    ) {
        _searchText = searchText
        _isSearchFocused = isSearchFocused
        self.searchPrompt = searchPrompt
        self.clearSearchHelp = clearSearchHelp
        self.searchAccessibilityIdentifier = searchAccessibilityIdentifier
        self.filters = filters()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            filters
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

            searchTextField

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(clearSearchHelp)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsStyle.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var searchTextField: some View {
        let field = TextField(searchPrompt, text: $searchText)
            .textFieldStyle(.plain)
            .font(PluginSettingsTheme.Typography.rowTitle)
            .focused($isSearchFocused)

        if let searchAccessibilityIdentifier {
            field.accessibilityIdentifier(searchAccessibilityIdentifier)
        } else {
            field
        }
    }
}

struct SettingsFilterChipsRow<Chips: View>: View {
    let accessibilityLabel: String
    private let chips: Chips

    init(
        accessibilityLabel: String,
        @ViewBuilder chips: () -> Chips
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.chips = chips()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chips
            }
            .padding(.vertical, 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SettingsFilterChip: View {
    let title: String
    let systemImage: String
    let iconTint: Color
    let count: Int
    let isSelected: Bool
    var accessibilityIdentifier: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: PluginSystemImage.resolvedName(systemImage))
                    .font(PluginSettingsTheme.Typography.secondaryLabel.weight(.semibold))
                    .foregroundStyle(iconColor)

                Text(title)
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
        .help(title)
        .modifier(OptionalAccessibilityIdentifier(identifier: accessibilityIdentifier))
    }

    private var iconColor: Color {
        isSelected ? .white : iconTint
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
            return SettingsStyle.recessedControlBackground.opacity(0.72)
        }

        return SettingsStyle.recessedControlBackground.opacity(0.42)
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
