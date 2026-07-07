import Foundation
import NaturalLanguage

protocol LanguageDetecting: Sendable {
    func detect(_ text: String) -> TranslatorLanguage?
}

struct LanguageDetector: LanguageDetecting {
    func detect(_ text: String) -> TranslatorLanguage? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            return nil
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmedText)

        if let language = recognizer.dominantLanguage,
           let translatorLanguage = Self.map(language) {
            return translatorLanguage
        }

        return Self.detectByScript(trimmedText)
    }

    private static func map(_ language: NLLanguage) -> TranslatorLanguage? {
        switch language {
        case .simplifiedChinese:
            return .simplifiedChinese
        case .traditionalChinese:
            return .traditionalChinese
        case .english:
            return .english
        case .japanese:
            return .japanese
        case .korean:
            return .korean
        case .french:
            return .french
        case .german:
            return .german
        case .spanish:
            return .spanish
        case .portuguese:
            return .portuguese
        case .italian:
            return .italian
        case .russian:
            return .russian
        default:
            return nil
        }
    }

    private static func detectByScript(_ text: String) -> TranslatorLanguage? {
        var hasLatinLetter = false

        for scalar in text.unicodeScalars {
            if Self.isJapaneseScript(scalar) {
                return .japanese
            }

            if Self.isKoreanScript(scalar) {
                return .korean
            }

            if Self.isCJKScript(scalar) {
                return .simplifiedChinese
            }

            if Self.isLatinLetter(scalar) {
                hasLatinLetter = true
            }
        }

        return hasLatinLetter ? .english : nil
    }

    private static func isJapaneseScript(_ scalar: UnicodeScalar) -> Bool {
        (0x3040...0x309F).contains(Int(scalar.value)) ||
            (0x30A0...0x30FF).contains(Int(scalar.value))
    }

    private static func isKoreanScript(_ scalar: UnicodeScalar) -> Bool {
        (0xAC00...0xD7AF).contains(Int(scalar.value)) ||
            (0x1100...0x11FF).contains(Int(scalar.value)) ||
            (0x3130...0x318F).contains(Int(scalar.value))
    }

    private static func isCJKScript(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
    }

    private static func isLatinLetter(_ scalar: UnicodeScalar) -> Bool {
        (0x0041...0x005A).contains(Int(scalar.value)) ||
            (0x0061...0x007A).contains(Int(scalar.value))
    }
}
