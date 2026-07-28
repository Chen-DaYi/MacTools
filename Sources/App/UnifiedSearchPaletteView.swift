import SwiftUI
import MacToolsPluginKit

struct UnifiedSearchPresentationView: View {
    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    navigationCoordinator.dismissUnifiedSearch()
                }
                .accessibilityHidden(true)

            UnifiedSearchPaletteView(
                pluginHost: pluginHost,
                navigationCoordinator: navigationCoordinator
            )
            .padding(24)
        }
    }
}

struct UnifiedSearchPaletteView: View {
    private enum Layout {
        static let width: CGFloat = 640
        static let resultListHeight: CGFloat = 390
        static let rowCornerRadius: CGFloat = 8
    }

    @ObservedObject var pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    @State private var query = ""
    @State private var selectedResultID: String?
    @State private var pendingConfirmation: MacToolsSearchResult?
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            metadataRow

            resultList

            footer
        }
        .padding(16)
        .frame(width: Layout.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background {
            quickSelectionShortcutButtons
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        .onAppear {
            syncSelection()
            focusQuery()
        }
        .onChange(of: query) {
            syncSelection()
        }
        .onChange(of: resultIDs) {
            syncSelection()
        }
        .onChange(of: navigationCoordinator.unifiedSearchFocusRequestID) {
            focusQuery()
        }
        .onExitCommand {
            navigationCoordinator.dismissUnifiedSearch()
        }
        .alert(item: $pendingConfirmation) { result in
            let confirmation = result.confirmation
            return Alert(
                title: Text(confirmation?.title ?? result.title),
                message: Text(confirmation?.message ?? result.detail),
                primaryButton: .destructive(
                    Text(
                        confirmation?.confirmButtonTitle
                            ?? AppL10n.search("search.action.run", defaultValue: "执行")
                    )
                ) {
                    execute(result)
                },
                secondaryButton: .cancel()
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppL10n.search("search.title", defaultValue: "搜索 MacTools")
        )
        .accessibilityIdentifier("mactools.unified-search.palette")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField(
                AppL10n.search(
                    "search.prompt",
                    defaultValue: "搜索插件、设置和命令"
                ),
                text: $query
            )
            .textFieldStyle(.plain)
            .font(PluginSettingsTheme.Typography.rowTitle)
            .focused($isQueryFocused)
            .onSubmit {
                activateSelectedResult()
            }
            .onKeyPress(.downArrow) {
                moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveSelection(by: -1)
                return .handled
            }
            .accessibilityLabel(
                AppL10n.search("search.title", defaultValue: "搜索 MacTools")
            )
            .accessibilityIdentifier("mactools.unified-search.field")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(AppL10n.search("search.clear", defaultValue: "清除搜索"))
                .accessibilityLabel(
                    AppL10n.search("search.clear", defaultValue: "清除搜索")
                )
            }

            Text("⌘K")
                .font(PluginSettingsTheme.Typography.statusBadge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
                )
                .accessibilityHidden(true)

            Button {
                navigationCoordinator.dismissUnifiedSearch()
            } label: {
                Text("Esc")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(AppL10n.search("search.close", defaultValue: "关闭搜索"))
            .accessibilityLabel(
                AppL10n.search("search.close", defaultValue: "关闭搜索")
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
    }

    private var metadataRow: some View {
        HStack {
            Text(originText)
            Spacer()
            Text(resultCountText)
        }
        .font(PluginSettingsTheme.Typography.secondaryLabel)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(originText)，\(resultCountText)")
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if results.isEmpty {
                    ContentUnavailableView(
                        AppL10n.search("search.empty.title", defaultValue: "未找到结果"),
                        systemImage: "magnifyingglass",
                        description: Text(
                            AppL10n.search(
                                "search.empty.description",
                                defaultValue: "尝试插件名称、设置、功能或命令。"
                            )
                        )
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(MacToolsSearchResultKind.allCases, id: \.self) { kind in
                            let group = results.filter { $0.kind == kind }
                            if !group.isEmpty {
                                Text(kind.title)
                                    .font(PluginSettingsTheme.Typography.secondaryLabel)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.top, 4)

                                ForEach(group) { result in
                                    resultRow(
                                        result,
                                        quickSelectionNumber: quickSelectionNumber(for: result)
                                    )
                                        .id(result.id)
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: Layout.resultListHeight)
            .onChange(of: selectedResultID) { _, resultID in
                guard let resultID else {
                    return
                }

                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(resultID, anchor: .center)
                }
            }
        }
    }

    private func resultRow(
        _ result: MacToolsSearchResult,
        quickSelectionNumber: Int?
    ) -> some View {
        let isSelected = result.id == selectedResultID

        return Button {
            selectedResultID = result.id
            activate(result)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: result.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(PluginSettingsTheme.Typography.rowTitle)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)

                    Text(result.subtitle)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let quickSelectionNumber {
                    Text("⌘\(quickSelectionNumber)")
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
                        .accessibilityHidden(true)
                }

                Text(result.kind.actionTitle)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                isSelected
                                    ? Color.white.opacity(0.16)
                                    : Color.accentColor.opacity(0.1)
                            )
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Layout.rowCornerRadius, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(result.accessibilityLabel)
        .accessibilityHint(accessibilityHint(for: result, number: quickSelectionNumber))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("mactools.unified-search.result.\(result.id)")
    }

    private var footer: some View {
        HStack {
            if let selectedResult {
                Text(
                    AppL10n.searchFormat(
                        "search.footer.actionFormat",
                        defaultValue: "%@“%@”",
                        selectedResult.kind.actionTitle,
                        selectedResult.title
                    )
                )
                    .lineLimit(1)
            } else {
                Text(
                    AppL10n.search(
                        "search.footer.tryAnotherQuery",
                        defaultValue: "尝试其他关键词"
                    )
                )
            }

            Spacer()

            Text(
                AppL10n.search(
                    "search.footer.keyboard",
                    defaultValue: "↑↓ 选择　↩ 打开　⌘1–9 快速打开"
                )
            )
        }
        .font(PluginSettingsTheme.Typography.secondaryLabel)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var index: MacToolsSearchIndex {
        MacToolsSearchIndexBuilder.build(pluginHost: pluginHost)
    }

    private var results: [MacToolsSearchResult] {
        MacToolsSearchPresentation.orderedResults(
            index.results(matching: query)
        )
    }

    private var resultIDs: [String] {
        results.map(\.id)
    }

    private var selectedResult: MacToolsSearchResult? {
        guard let selectedResultID else {
            return nil
        }

        return results.first { $0.id == selectedResultID }
    }

    private var resultCountText: String {
        AppL10n.searchFormat(
            "search.resultCountFormat",
            defaultValue: "%d 个结果",
            results.count
        )
    }

    private var originText: String {
        switch navigationCoordinator.unifiedSearchPresentationOrigin {
        case .pluginSidebar:
            return AppL10n.search(
                "search.origin.pluginSidebar",
                defaultValue: "来自插件导航"
            )
        case .keyboard:
            return AppL10n.search(
                "search.origin.keyboard",
                defaultValue: "全局快捷键 ⌘K"
            )
        case nil:
            return AppL10n.search(
                "search.title",
                defaultValue: "搜索 MacTools"
            )
        }
    }

    private var quickSelectionShortcutButtons: some View {
        HStack(spacing: 0) {
            ForEach(
                Array(results.prefix(MacToolsSearchPresentation.quickSelectionLimit).enumerated()),
                id: \.element.id
            ) { index, result in
                Button("") {
                    selectedResultID = result.id
                    activate(result)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(index + 1))),
                    modifiers: [.command]
                )
                .focusable(false)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func quickSelectionNumber(
        for result: MacToolsSearchResult
    ) -> Int? {
        MacToolsSearchPresentation.quickSelectionNumber(
            for: result.id,
            in: results
        )
    }

    private func accessibilityHint(
        for result: MacToolsSearchResult,
        number: Int?
    ) -> String {
        guard let number else {
            return result.detail
        }

        return "⌘\(number). \(result.detail)"
    }

    private func syncSelection() {
        let availableResults = results
        if let selectedResultID,
           availableResults.contains(where: { $0.id == selectedResultID }) {
            return
        }

        selectedResultID = availableResults.first?.id
    }

    private func moveSelection(by offset: Int) {
        let availableResults = results
        guard !availableResults.isEmpty else {
            return
        }

        let currentIndex = selectedResultID.flatMap { selectedID in
            availableResults.firstIndex { $0.id == selectedID }
        } ?? 0
        let nextIndex = (currentIndex + offset + availableResults.count) % availableResults.count
        selectedResultID = availableResults[nextIndex].id
    }

    private func activateSelectedResult() {
        guard let selectedResult else {
            return
        }

        activate(selectedResult)
    }

    private func activate(_ result: MacToolsSearchResult) {
        if result.confirmation != nil {
            pendingConfirmation = result
        } else {
            execute(result)
        }
    }

    private func execute(_ result: MacToolsSearchResult) {
        switch result.action {
        case let .navigate(destination, target):
            navigationCoordinator.navigateFromSearch(to: destination, target: target)
        case let .pluginCommand(pluginID, commandID):
            navigationCoordinator.dismissUnifiedSearch()
            pluginHost.performCommand(pluginID: pluginID, commandID: commandID)
        case let .appCommand(action):
            navigationCoordinator.dismissUnifiedSearch()
            pluginHost.performAppCommand(action)
        }
    }

    private func focusQuery() {
        DispatchQueue.main.async {
            isQueryFocused = true
        }
    }
}
