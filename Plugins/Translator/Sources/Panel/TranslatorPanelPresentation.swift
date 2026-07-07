import Foundation
import MacToolsPluginKit

struct TranslatorPanelPresentation: Equatable {
    struct Tip: Equatable {
        var title: String
        var message: String
        var actionTitle: String
        var systemImage: String
    }

    struct ProviderRow: Equatable, Identifiable {
        var id: String
        var title: String
        var symbolName: String
        var bodyText: String
        var isExpanded: Bool
        var isLoading: Bool
        var isError: Bool
        var canCopy: Bool
    }

    var sourceText: String
    var usesSourceCaretPlaceholder: Bool
    var sourceLanguageTitle: String
    var targetLanguageTitle: String
    var tip: Tip?
    var providerRows: [ProviderRow]

    init(
        snapshot: TranslatorPanelSnapshot,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        let trimmedSource = snapshot.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sourceText = trimmedSource
        usesSourceCaretPlaceholder = trimmedSource.isEmpty
        sourceLanguageTitle = snapshot.languageSelection?.sourceDisplayName(localization: localization)
            ?? localization.string("language.automatic", defaultValue: "自动检测")
        targetLanguageTitle = snapshot.languageSelection?.target.displayName(localization: localization)
            ?? localization.string("language.automaticTarget", defaultValue: "自动选择")
        tip = Self.tip(for: snapshot, localization: localization)

        let results = Self.providerResults(for: snapshot, localization: localization)
        let expandedProviderID = Self.expandedProviderID(in: results)
        providerRows = results.map { result in
            let text = Self.providerBodyText(result, localization: localization)
            let translatedText = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ProviderRow(
                id: result.id,
                title: result.providerTitle,
                symbolName: Self.symbolName(forProviderTitle: result.providerTitle),
                bodyText: text,
                isExpanded: result.id == expandedProviderID,
                isLoading: result.phase == .translating || result.phase == .waiting,
                isError: result.phase == .error,
                canCopy: !translatedText.isEmpty
            )
        }
    }

    private static func providerResults(
        for snapshot: TranslatorPanelSnapshot,
        localization: PluginLocalization
    ) -> [TranslatorProviderResult] {
        if !snapshot.providerResults.isEmpty {
            return snapshot.providerResults
        }

        let providerTitle = snapshot.translation?.providerTitle
            ?? localization.string("openAIClient.providerTitle", defaultValue: "OpenAI 翻译")
        return [
            TranslatorProviderResult(
                id: "placeholder",
                providerTitle: providerTitle,
                phase: placeholderProviderPhase(for: snapshot.phase),
                translation: snapshot.translation,
                errorMessage: snapshot.errorMessage
            ),
        ]
    }

    private static func placeholderProviderPhase(for phase: TranslatorPanelPhase) -> TranslatorProviderResultPhase {
        switch phase {
        case .translating:
            return .translating
        case .success:
            return .success
        case .error:
            return .error
        case .idle, .capturing:
            return .waiting
        }
    }

    private static func expandedProviderID(in results: [TranslatorProviderResult]) -> String? {
        results.first { result in
            let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !text.isEmpty || result.phase == .error
        }?.id
    }

    private static func tip(
        for snapshot: TranslatorPanelSnapshot,
        localization: PluginLocalization
    ) -> Tip? {
        guard case let .error(error) = snapshot.phase else {
            return nil
        }

        let title = localization.string("panel.tip.title", defaultValue: "提示")
        let actionTitle = localization.string("panel.tip.actionTitle", defaultValue: "如何解决")
        let message: String
        switch error {
        case .missingSelection:
            message = localization.string(
                "panel.tip.missingSelection",
                defaultValue: "划词翻译没有获取到文本"
            )
        default:
            message = snapshot.errorMessage ?? error.message(localization: localization)
        }

        return Tip(
            title: title,
            message: message,
            actionTitle: actionTitle,
            systemImage: "lightbulb"
        )
    }

    private static func providerBodyText(
        _ result: TranslatorProviderResult,
        localization: PluginLocalization
    ) -> String {
        let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            return text
        }

        switch result.phase {
        case .translating:
            return localization.string("panel.resultPlaceholder.translating", defaultValue: "正在翻译...")
        case .error:
            return result.errorMessage
                ?? localization.string("openAIClient.error.requestFailed", defaultValue: "请求失败，请稍后重试")
        case .waiting:
            return localization.string("panel.resultPlaceholder.idle", defaultValue: "等待翻译")
        case .success:
            return localization.string("panel.resultPlaceholder.emptyResponse", defaultValue: "响应为空")
        }
    }

    private static func symbolName(forProviderTitle title: String) -> String {
        let normalized = title.lowercased()
        if normalized.contains("deepseek") {
            return "sparkle.magnifyingglass"
        }
        if normalized.contains("fireworks") {
            return "sparkles"
        }
        if normalized.contains("openai") {
            return "circle.hexagongrid"
        }
        return "bubble.left.and.text.bubble.right"
    }
}
