import Foundation
import MacToolsPluginKit

enum TranslatorLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case russian = "ru"

    var id: String { rawValue }

    var displayName: String {
        displayName()
    }

    func displayName(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .simplifiedChinese:
            return localization.string("language.simplifiedChinese", defaultValue: "简体中文")
        case .traditionalChinese:
            return localization.string("language.traditionalChinese", defaultValue: "繁體中文")
        case .english:
            return localization.string("language.english", defaultValue: "英语")
        case .japanese:
            return localization.string("language.japanese", defaultValue: "日语")
        case .korean:
            return localization.string("language.korean", defaultValue: "韩语")
        case .french:
            return localization.string("language.french", defaultValue: "法语")
        case .german:
            return localization.string("language.german", defaultValue: "德语")
        case .spanish:
            return localization.string("language.spanish", defaultValue: "西班牙语")
        case .portuguese:
            return localization.string("language.portuguese", defaultValue: "葡萄牙语")
        case .italian:
            return localization.string("language.italian", defaultValue: "意大利语")
        case .russian:
            return localization.string("language.russian", defaultValue: "俄语")
        }
    }

    var promptName: String {
        switch self {
        case .simplifiedChinese:
            return "Simplified Chinese"
        case .traditionalChinese:
            return "Traditional Chinese"
        case .english:
            return "English"
        case .japanese:
            return "Japanese"
        case .korean:
            return "Korean"
        case .french:
            return "French"
        case .german:
            return "German"
        case .spanish:
            return "Spanish"
        case .portuguese:
            return "Portuguese"
        case .italian:
            return "Italian"
        case .russian:
            return "Russian"
        }
    }

    /// BCP-47 voice locale used by `AVSpeechSynthesisVoice(language:)` for speech playback.
    var speechLanguageCode: String {
        switch self {
        case .simplifiedChinese:
            return "zh-CN"
        case .traditionalChinese:
            return "zh-TW"
        case .english:
            return "en-US"
        case .japanese:
            return "ja-JP"
        case .korean:
            return "ko-KR"
        case .french:
            return "fr-FR"
        case .german:
            return "de-DE"
        case .spanish:
            return "es-ES"
        case .portuguese:
            return "pt-BR"
        case .italian:
            return "it-IT"
        case .russian:
            return "ru-RU"
        }
    }

    var flag: String {
        switch self {
        case .simplifiedChinese:
            return "🇨🇳"
        case .traditionalChinese:
            return "🇨🇳"
        case .english:
            return "🇬🇧"
        case .japanese:
            return "🇯🇵"
        case .korean:
            return "🇰🇷"
        case .french:
            return "🇫🇷"
        case .german:
            return "🇩🇪"
        case .spanish:
            return "🇪🇸"
        case .portuguese:
            return "🇵🇹"
        case .italian:
            return "🇮🇹"
        case .russian:
            return "🇷🇺"
        }
    }

    static func from(localeIdentifier: String) -> TranslatorLanguage? {
        let normalized = localeIdentifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if normalized == "zh-hant" ||
            normalized.hasPrefix("zh-hant-") ||
            normalized == "zh-tw" ||
            normalized.hasPrefix("zh-tw-") ||
            normalized == "zh-hk" ||
            normalized.hasPrefix("zh-hk-") {
            return .traditionalChinese
        }

        if normalized == "zh" || normalized.hasPrefix("zh-") {
            return .simplifiedChinese
        }

        return allCases.first { language in
            normalized == language.rawValue.lowercased() ||
                normalized.hasPrefix("\(language.rawValue.lowercased())-")
        }
    }
}

struct TranslatorLanguagePair: Equatable, Codable, Sendable {
    var first: TranslatorLanguage
    var second: TranslatorLanguage
}
