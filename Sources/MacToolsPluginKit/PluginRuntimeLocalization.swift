import Combine
import Foundation

/// The single runtime locale source shared by the host and dynamic plugins.
/// Views observe `revision`; string lookup always reads the same snapshot.
public final class PluginRuntimeLocaleSource: ObservableObject, @unchecked Sendable {
    public static let preferenceUserDefaultsKey = "app.languagePreference"
    public static let shared = PluginRuntimeLocaleSource()

    @Published public private(set) var revision = 0

    private let lock = NSLock()
    private let systemPreferredLanguages: () -> [String]
    private let currentLocale: () -> Locale
    private var storedPreference: String?
    private var storedPreferredLanguages: [String]
    private var storedLocale: Locale
    private var localeChangeObserver: NSObjectProtocol?

    public var preferredLanguages: [String] {
        lock.withLock { storedPreferredLanguages }
    }

    public var locale: Locale {
        lock.withLock { storedLocale }
    }

    init(
        userDefaults: UserDefaults = .standard,
        systemPreferredLanguages: @escaping () -> [String] = PluginRuntimeLocaleSource.systemPreferredLanguages,
        currentLocale: @escaping () -> Locale = { .current }
    ) {
        let initialSystemLanguages = systemPreferredLanguages()
        let initialLocale = currentLocale()
        self.systemPreferredLanguages = systemPreferredLanguages
        self.currentLocale = currentLocale
        let preference = userDefaults.string(forKey: Self.preferenceUserDefaultsKey)
        self.storedPreference = preference
        if let preference, preference != "system" {
            self.storedPreferredLanguages = [preference]
            self.storedLocale = LocalizedBundleResolver.locale(
                for: preference,
                currentLocale: initialLocale
            )
        } else {
            self.storedPreferredLanguages = initialSystemLanguages
            self.storedLocale = initialLocale
        }
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
        let languages = preferredLanguages(for: preference)
        let locale = locale(for: preference)
        let changed = lock.withLock {
            guard storedPreference != preference
                || storedPreferredLanguages != languages
                || storedLocale.identifier != locale.identifier
            else {
                return false
            }

            storedPreference = preference
            storedPreferredLanguages = languages
            storedLocale = locale
            return true
        }

        guard changed else {
            return
        }

        publishRevision()
    }

    private func refreshSystemLocaleIfNeeded() {
        let snapshot = lock.withLock { () -> (shouldRefresh: Bool, preference: String?) in
            (
                storedPreference == nil || storedPreference == "system",
                storedPreference
            )
        }
        guard snapshot.shouldRefresh else {
            return
        }

        setPreference(snapshot.preference)
    }

    private func preferredLanguages(for preference: String?) -> [String] {
        guard let preference, preference != "system" else {
            return systemPreferredLanguages()
        }

        return [preference]
    }

    private func locale(for preference: String?) -> Locale {
        guard let preference, preference != "system" else {
            return currentLocale()
        }

        return LocalizedBundleResolver.locale(for: preference, currentLocale: currentLocale())
    }

    private func publishRevision() {
        if Thread.isMainThread {
            revision &+= 1
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.revision &+= 1
        }
    }

    private static func systemPreferredLanguages() -> [String] {
        let globalDomain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        if let languages = globalDomain?["AppleLanguages"] as? [String], !languages.isEmpty {
            return languages
        }

        return Locale.preferredLanguages
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
        // The selected language falls back to English, then to the caller's
        // source-language default when neither resource contains the key.
        let missingValue = "\u{F8FF}.mactools.localization.missing.\u{F8FF}"
        for localizedBundle in localizedBundles(in: bundle) {
            let value = localizedBundle.localizedString(
                forKey: key,
                value: missingValue,
                table: table
            )
            if value != missingValue {
                return value
            }
        }

        return defaultValue
    }

    public static func localizedBundle(in bundle: Bundle) -> Bundle? {
        localizedBundles(in: bundle).first
    }

    public static func localizedBundles(in bundle: Bundle) -> [Bundle] {
        LocalizedBundleResolver.localizedBundles(
            in: bundle,
            preferredLanguages: preferredLanguages,
            baseLanguage: baseLanguage
        )
    }

    public static func candidateLanguageIdentifiers(for language: String) -> [String] {
        LocalizedBundleResolver.candidateLanguageIdentifiers(for: language)
    }
}
