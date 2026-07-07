import Foundation
import MacToolsPluginKit

struct TranslatorLanguageSelection: Equatable, Sendable {
    var source: TranslatorLanguage?
    var target: TranslatorLanguage

    var sourceIsAutomatic: Bool {
        source == nil
    }

    var sourceDisplayName: String {
        sourceDisplayName()
    }

    func sourceDisplayName(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        source?.displayName(localization: localization)
            ?? localization.string("language.automatic", defaultValue: "自动检测")
    }
}

struct AutomaticLanguageSelector: Sendable {
    private let detector: any LanguageDetecting
    private let preferredPair: TranslatorLanguagePair

    init(
        detector: any LanguageDetecting = LanguageDetector(),
        preferredPair: TranslatorLanguagePair
    ) {
        self.detector = detector
        self.preferredPair = preferredPair
    }

    func select(text: String) -> TranslatorLanguageSelection {
        guard let source = detector.detect(text) else {
            return TranslatorLanguageSelection(source: nil, target: preferredPair.first)
        }

        if source == preferredPair.first {
            return TranslatorLanguageSelection(source: source, target: preferredPair.second)
        }

        return TranslatorLanguageSelection(source: source, target: preferredPair.first)
    }

    func select(for text: String) -> TranslatorLanguageSelection {
        select(text: text)
    }
}
