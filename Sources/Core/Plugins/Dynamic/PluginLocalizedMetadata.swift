import Foundation
import MacToolsPluginKit

struct PluginLocalizedMetadata: Codable, Equatable {
    let displayName: String?
    let summary: String?

    init(displayName: String? = nil, summary: String? = nil) {
        self.displayName = displayName
        self.summary = summary
    }
}

enum PluginLocalizationMatcher {
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
        if userDefaults === UserDefaults.standard {
            return PluginRuntimeLocalization.preferredLanguages
        }

        if let preference = userDefaults.string(forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey),
           preference != "system" {
            return [preference]
        }

        // Keep this fallback for manifest decoding in isolated stores and
        // backwards-compatible callers that explicitly provide AppleLanguages.
        if let appleLanguages = userDefaults.stringArray(forKey: "AppleLanguages"),
           !appleLanguages.isEmpty {
            return appleLanguages
        }

        return Locale.preferredLanguages
    }

    private static func candidateLanguageIdentifiers(for language: String) -> [String] {
        PluginRuntimeLocalization.candidateLanguageIdentifiers(for: language)
    }
}
