import AppKit
import Combine
import SwiftUI
import MacToolsPluginKit

enum UnifiedSearchPaletteLayout {
    static let maximumWidth: CGFloat = 672
    static let minimumWidth: CGFloat = 560
    static let outerHorizontalPadding: CGFloat = 48
    static let maximumResultListHeight: CGFloat = 420
    static let minimumResultListHeight: CGFloat = 260
    static let verticalChromeHeight: CGFloat = 202

    static func width(for availableWidth: CGFloat) -> CGFloat {
        min(
            maximumWidth,
            max(minimumWidth, availableWidth - outerHorizontalPadding)
        )
    }

    static func resultListHeight(for availableHeight: CGFloat) -> CGFloat {
        min(
            maximumResultListHeight,
            max(minimumResultListHeight, availableHeight - verticalChromeHeight)
        )
    }
}

@MainActor
final class UnifiedSearchPaletteModel: ObservableObject {
    @Published private(set) var results: [MacToolsSearchResult]

    private let pluginHost: PluginHost
    private var index: MacToolsSearchIndex
    private var query = ""
    private var pluginHostCancellable: AnyCancellable?
    private var rebuildTask: Task<Void, Never>?

    init(pluginHost: PluginHost) {
        self.pluginHost = pluginHost
        let index = MacToolsSearchIndexBuilder.build(pluginHost: pluginHost)
        self.index = index
        self.results = MacToolsSearchPresentation.orderedResults(
            index.results(matching: "")
        )
        pluginHostCancellable = pluginHost.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleIndexRebuild()
            }
        }
    }

    func updateQuery(_ query: String) {
        guard self.query != query else {
            return
        }

        self.query = query
        updateResults()
    }

    private func scheduleIndexRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else {
                return
            }

            index = MacToolsSearchIndexBuilder.build(pluginHost: pluginHost)
            updateResults()
        }
    }

    private func updateResults() {
        results = MacToolsSearchPresentation.orderedResults(
            index.results(matching: query)
        )
    }
}

struct UnifiedSearchTextField: NSViewRepresentable {
    enum Command: Equatable {
        case moveSelection(Int)
        case submit
        case cancel
    }

    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let focusRequestID: UInt
    let onCommand: (Command) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.setAccessibilityIdentifier("mactools.unified-search.field")
        context.coordinator.focus(field, for: focusRequestID)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        if field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.focus(field, for: focusRequestID)
    }

    static func command(
        for selector: Selector,
        hasMarkedText: Bool
    ) -> Command? {
        guard !hasMarkedText else {
            return nil
        }

        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            return .moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            return .moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            return .submit
        case #selector(NSResponder.cancelOperation(_:)):
            return .cancel
        default:
            return nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: UnifiedSearchTextField
        private var lastFocusRequestID: UInt?

        init(parent: UnifiedSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }

            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            guard let command = UnifiedSearchTextField.command(
                for: selector,
                hasMarkedText: textView.hasMarkedText()
            ) else {
                return false
            }

            parent.onCommand(command)
            return true
        }

        func focus(_ field: NSTextField, for requestID: UInt) {
            guard lastFocusRequestID != requestID else {
                return
            }

            lastFocusRequestID = requestID
            DispatchQueue.main.async { [weak field] in
                field?.window?.makeFirstResponder(field)
            }
        }
    }
}

struct UnifiedSearchPresentationView: View {
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency
    let pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(accessibilityReduceTransparency ? 0.30 : 0.24)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        navigationCoordinator.dismissUnifiedSearch()
                    }
                    .accessibilityHidden(true)

                UnifiedSearchPaletteView(
                    pluginHost: pluginHost,
                    navigationCoordinator: navigationCoordinator,
                    availableSize: geometry.size
                )
                .padding(24)
            }
        }
    }
}

struct UnifiedSearchPaletteView: View {
    private enum Layout {
        static let rowCornerRadius: CGFloat = 8
    }

    let pluginHost: PluginHost
    @ObservedObject var navigationCoordinator: SettingsNavigationCoordinator
    let availableSize: CGSize
    @StateObject private var model: UnifiedSearchPaletteModel
    @State private var query = ""
    @State private var selectedResultID: String?
    @State private var pendingConfirmation: MacToolsSearchResult?

    init(
        pluginHost: PluginHost,
        navigationCoordinator: SettingsNavigationCoordinator,
        availableSize: CGSize
    ) {
        self.pluginHost = pluginHost
        self.navigationCoordinator = navigationCoordinator
        self.availableSize = availableSize
        _model = StateObject(
            wrappedValue: UnifiedSearchPaletteModel(pluginHost: pluginHost)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            metadataRow

            resultList

            footer
        }
        .padding(16)
        .frame(width: UnifiedSearchPaletteLayout.width(for: availableSize.width))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        .onAppear {
            syncSelection()
            handleQuickSelectionRequest(
                navigationCoordinator.unifiedSearchQuickSelectionRequest
            )
        }
        .onChange(of: query) {
            model.updateQuery(query)
            syncSelection()
        }
        .onChange(of: resultIDs) {
            syncSelection()
        }
        .onChange(of: navigationCoordinator.unifiedSearchQuickSelectionRequest) { _, request in
            handleQuickSelectionRequest(request)
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

            UnifiedSearchTextField(
                text: $query,
                placeholder: AppL10n.search(
                    "search.prompt",
                    defaultValue: "搜索插件、设置和命令"
                ),
                accessibilityLabel: AppL10n.search(
                    "search.title",
                    defaultValue: "搜索 MacTools"
                ),
                focusRequestID: navigationCoordinator.unifiedSearchFocusRequestID,
                onCommand: handleSearchFieldCommand
            )
            .frame(maxWidth: .infinity, minHeight: 22)

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
            .frame(
                height: UnifiedSearchPaletteLayout.resultListHeight(
                    for: availableSize.height
                )
            )
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

    private var results: [MacToolsSearchResult] {
        model.results
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
        AppL10n.searchPluralFormat(
            "search.resultCountFormat",
            defaultValue: "%d 个结果",
            count: results.count
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
        let result = availableResults[nextIndex]
        selectedResultID = result.id
        announceSelection(result)
    }

    private func announceSelection(_ result: MacToolsSearchResult) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: result.accessibilityLabel,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    private func activateSelectedResult() {
        guard let selectedResult else {
            return
        }

        activate(selectedResult)
    }

    private func handleSearchFieldCommand(
        _ command: UnifiedSearchTextField.Command
    ) {
        switch command {
        case let .moveSelection(offset):
            moveSelection(by: offset)
        case .submit:
            activateSelectedResult()
        case .cancel:
            navigationCoordinator.dismissUnifiedSearch()
        }
    }

    private func handleQuickSelectionRequest(
        _ request: UnifiedSearchQuickSelectionRequest?
    ) {
        guard
            let request,
            navigationCoordinator.consumeUnifiedSearchQuickSelectionRequest(request)
        else {
            return
        }

        guard results.indices.contains(request.number - 1) else {
            return
        }

        let result = results[request.number - 1]
        selectedResultID = result.id
        activate(result)
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

}
