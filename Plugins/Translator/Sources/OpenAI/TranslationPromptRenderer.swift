import Foundation
import MacToolsPluginKit

struct TranslationPromptRenderer: Sendable {
    let template: String

    init(template: String) {
        self.template = template
    }

    func render(
        text: String,
        sourceLanguageName: String,
        targetLanguageName: String
    ) throws -> String {
        guard template.contains("{{text}}") else {
            throw TranslationPromptRendererError.missingTextPlaceholder
        }

        return template
            .replacingOccurrences(of: "{{source_language}}", with: sourceLanguageName)
            .replacingOccurrences(of: "{{target_language}}", with: targetLanguageName)
            .replacingOccurrences(of: "{{text}}", with: text)
    }
}

enum TranslationPromptRendererError: Error, Equatable, Sendable {
    case missingTextPlaceholder
}

extension TranslationPromptRendererError: LocalizedError {
    var errorDescription: String? {
        errorDescription()
    }

    func errorDescription(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .missingTextPlaceholder:
            return localization.string(
                "translationPrompt.error.missingTextPlaceholder",
                defaultValue: "提示词必须包含 {{text}}。"
            )
        }
    }
}
