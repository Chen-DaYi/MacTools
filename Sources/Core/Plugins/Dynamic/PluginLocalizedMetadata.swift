import Foundation

struct PluginLocalizedMetadata: Codable, Equatable {
    let displayName: String?
    let summary: String?

    init(displayName: String? = nil, summary: String? = nil) {
        self.displayName = displayName
        self.summary = summary
    }
}

enum PluginLocalizationMatcher {
    private static let appleLanguagesKey = "AppleLanguages"

    static func localizedMetadata(
        from metadataByLanguage: [String: PluginLocalizedMetadata],
        preferredLanguages: [String]? = nil,
        userDefaults: UserDefaults = .standard
    ) -> PluginLocalizedMetadata? {
        guard !metadataByLanguage.isEmpty else {
            return nil
        }

        for language in preferredLanguages ?? effectivePreferredLanguages(in: userDefaults) {
            let candidates = candidateLanguageIdentifiers(for: language)
            for candidate in candidates {
                if let exact = metadataByLanguage[candidate] {
                    return exact
                }

                if let caseInsensitive = metadataByLanguage.first(where: {
                    $0.key.caseInsensitiveCompare(candidate) == .orderedSame
                })?.value {
                    return caseInsensitive
                }
            }
        }

        return metadataByLanguage["en"]
            ?? metadataByLanguage["zh-Hans"]
            ?? metadataByLanguage.values.first
    }

    private static func effectivePreferredLanguages(in userDefaults: UserDefaults) -> [String] {
        if let appleLanguages = userDefaults.stringArray(forKey: appleLanguagesKey),
           !appleLanguages.isEmpty {
            return appleLanguages
        }

        return Locale.preferredLanguages
    }

    private static func candidateLanguageIdentifiers(for language: String) -> [String] {
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        var candidates = [normalized]

        let components = normalized.split(separator: "-").map(String.init)
        if let languageCode = components.first {
            if languageCode == "zh" {
                if components.contains(where: { ["Hant", "HK", "MO", "TW"].contains($0) }) {
                    candidates.append("zh-Hant")
                } else {
                    candidates.append("zh-Hans")
                }
            }

            candidates.append(languageCode)
        }

        var unique: [String] = []
        for candidate in candidates where !unique.contains(candidate) {
            unique.append(candidate)
        }
        return unique
    }
}
