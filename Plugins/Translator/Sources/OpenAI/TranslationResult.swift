import Foundation

struct TranslationResult: Equatable, Sendable {
    var providerTitle: String
    var text: String
    var sourceText: String
    var languageSelection: TranslatorLanguageSelection
}
