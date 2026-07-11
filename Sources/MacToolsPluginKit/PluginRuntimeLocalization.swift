import Combine
import Foundation

/// The single runtime locale source shared by the host and dynamic plugins.
/// Views observe `revision`; string lookup always reads the same snapshot.
public final class PluginRuntimeLocaleSource: ObservableObject, @unchecked Sendable {
    public static let preferenceUserDefaultsKey = "app.languagePreference"
    public static let shared = PluginRuntimeLocaleSource()

    @Published public private(set) var revision = 0

    private let lock = NSLock()
    private var storedPreference: String?
    private var storedPreferredLanguages: [String]
    private var localeChangeObserver: NSObjectProtocol?

    public var preferredLanguages: [String] {
        lock.withLock { storedPreferredLanguages }
    }

    public var locale: Locale {
        Locale(identifier: preferredLanguages.first ?? Locale.current.identifier)
    }

    private init(userDefaults: UserDefaults = .standard) {
        let preference = userDefaults.string(forKey: Self.preferenceUserDefaultsKey)
        self.storedPreference = preference
        self.storedPreferredLanguages = Self.preferredLanguages(for: preference)
        localeChangeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSystemLocaleIfNeeded()
        }
    }

    deinit {
        if let localeChangeObserver {
            NotificationCenter.default.removeObserver(localeChangeObserver)
        }
    }

    /// Updates the language snapshot and notifies all app and plugin surfaces.
    /// Call this whenever the app-language preference is saved.
    public func setPreference(_ preference: String?) {
        let languages = Self.preferredLanguages(for: preference)
        let changed = lock.withLock {
            guard storedPreference != preference || storedPreferredLanguages != languages else {
                return false
            }

            storedPreference = preference
            storedPreferredLanguages = languages
            return true
        }

        guard changed else {
            return
        }

        revision &+= 1
    }

    public func refreshFromUserDefaults(_ userDefaults: UserDefaults = .standard) {
        setPreference(userDefaults.string(forKey: Self.preferenceUserDefaultsKey))
    }

    private func refreshSystemLocaleIfNeeded() {
        guard lock.withLock({ storedPreference == nil || storedPreference == "system" }) else {
            return
        }

        setPreference(storedPreference)
    }

    private static func preferredLanguages(for preference: String?) -> [String] {
        guard let preference, preference != "system" else {
            return Locale.preferredLanguages
        }

        return [preference]
    }
}

/// Resolves localized resources against `PluginRuntimeLocaleSource.shared`.
/// `Bundle.localizedString` only consults the process language list, so every
/// lookup explicitly selects an `.lproj` resource bundle instead.
public enum PluginRuntimeLocalization {
    public static let preferenceUserDefaultsKey = PluginRuntimeLocaleSource.preferenceUserDefaultsKey
    public static let source = PluginRuntimeLocaleSource.shared
    public static let baseLanguage = "en"

    public static var preferredLanguages: [String] {
        source.preferredLanguages
    }

    public static var locale: Locale {
        source.locale
    }

    public static func string(
        _ key: String,
        defaultValue: String,
        table: String? = nil,
        bundle: Bundle
    ) -> String {
        for localizedBundle in localizedBundles(in: bundle) {
            let value = localizedBundle.localizedString(forKey: key, value: nil, table: table)
            if value != key {
                return value
            }
        }

        return defaultValue
    }

    public static func localizedBundle(in bundle: Bundle) -> Bundle? {
        localizedBundles(in: bundle).first
    }

    public static func localizedBundles(in bundle: Bundle) -> [Bundle] {
        var bundles: [Bundle] = []
        for language in preferredLanguages + [baseLanguage] {
            for candidate in candidateLanguageIdentifiers(for: language) {
                guard let path = bundle.path(forResource: candidate, ofType: "lproj"),
                      let localizedBundle = Bundle(path: path)
                else {
                    continue
                }

                if !bundles.contains(where: { $0.bundleURL == localizedBundle.bundleURL }) {
                    bundles.append(localizedBundle)
                }
                break
            }
        }

        return bundles
    }

    public static func candidateLanguageIdentifiers(for language: String) -> [String] {
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        var candidates = [normalized]
        let components = normalized.split(separator: "-").map(String.init)

        if let languageCode = components.first {
            if languageCode == "zh" {
                candidates.append(
                    components.contains(where: { ["Hant", "HK", "MO", "TW"].contains($0) })
                        ? "zh-Hant"
                        : "zh-Hans"
                )
            }
            candidates.append(languageCode)
        }

        return candidates.reduce(into: []) { result, candidate in
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
    }
}
