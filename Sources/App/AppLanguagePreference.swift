import Foundation

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case es
    case fr
    case ru
    case pt
    case de
    case ja
    case ko
    case ar

    static let userDefaultsKey = "app.languagePreference"
    static let didChangeNotification = Notification.Name("AppLanguagePreferenceDidChange")

    private static let appleLanguagesKey = "AppleLanguages"
    private static let rightClickFinderSyncBundleSuffix = ".right-click.finder-sync"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return AppL10n.settings("language.system", defaultValue: "跟随系统")
        case .zhHans:
            return AppL10n.settings("language.zh-Hans", defaultValue: "简体中文")
        case .zhHant:
            return AppL10n.settings("language.zh-Hant", defaultValue: "繁體中文")
        case .en:
            return AppL10n.settings("language.en", defaultValue: "English")
        case .es:
            return AppL10n.settings("language.es", defaultValue: "Español")
        case .fr:
            return AppL10n.settings("language.fr", defaultValue: "Français")
        case .ru:
            return AppL10n.settings("language.ru", defaultValue: "Русский")
        case .pt:
            return AppL10n.settings("language.pt", defaultValue: "Português")
        case .de:
            return AppL10n.settings("language.de", defaultValue: "Deutsch")
        case .ja:
            return AppL10n.settings("language.ja", defaultValue: "日本語")
        case .ko:
            return AppL10n.settings("language.ko", defaultValue: "한국어")
        case .ar:
            return AppL10n.settings("language.ar", defaultValue: "العربية")
        }
    }

    var appleLanguagesOverride: [String]? {
        switch self {
        case .system:
            return nil
        case .zhHans:
            return ["zh-Hans"]
        case .zhHant:
            return ["zh-Hant"]
        case .en:
            return ["en"]
        case .es:
            return ["es"]
        case .fr:
            return ["fr"]
        case .ru:
            return ["ru"]
        case .pt:
            return ["pt"]
        case .de:
            return ["de"]
        case .ja:
            return ["ja"]
        case .ko:
            return ["ko"]
        case .ar:
            return ["ar"]
        }
    }

    func store(in userDefaults: UserDefaults = .standard) {
        userDefaults.set(rawValue, forKey: Self.userDefaultsKey)
        applyAppleLanguagesOverride(in: userDefaults)
        userDefaults.synchronize()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func applyAppleLanguagesOverride(in userDefaults: UserDefaults = .standard) {
        if let appleLanguagesOverride {
            userDefaults.set(appleLanguagesOverride, forKey: Self.appleLanguagesKey)
        } else {
            userDefaults.removeObject(forKey: Self.appleLanguagesKey)
        }

        if let extensionBundleIdentifier = Self.rightClickFinderSyncBundleIdentifier() {
            Self.applyAppleLanguagesOverride(
                appleLanguagesOverride,
                toBundleIdentifier: extensionBundleIdentifier
            )
        }
        Self.applyRightClickFinderSyncLanguageOverride(appleLanguagesOverride)
    }

    static func stored(in userDefaults: UserDefaults = .standard) -> AppLanguagePreference {
        guard
            let rawValue = userDefaults.string(forKey: userDefaultsKey),
            let preference = AppLanguagePreference(rawValue: rawValue)
        else {
            return .system
        }

        return preference
    }

    static func applyStoredPreference(userDefaults: UserDefaults = .standard) {
        stored(in: userDefaults).applyAppleLanguagesOverride(in: userDefaults)
    }

    private static func rightClickFinderSyncBundleIdentifier(bundle: Bundle = .main) -> String? {
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            return nil
        }

        return bundleIdentifier + rightClickFinderSyncBundleSuffix
    }

    private static func applyAppleLanguagesOverride(
        _ appleLanguagesOverride: [String]?,
        toBundleIdentifier bundleIdentifier: String
    ) {
        let key = appleLanguagesKey as CFString
        let applicationID = bundleIdentifier as CFString
        let value = appleLanguagesOverride.map { $0 as CFArray }
        CFPreferencesSetValue(
            key,
            value,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesAppSynchronize(applicationID)
    }

    private static func applyRightClickFinderSyncLanguageOverride(_ appleLanguagesOverride: [String]?) {
        var configuration = RightClickConfigurationStore.load()
        guard configuration.preferredLanguages != appleLanguagesOverride else {
            return
        }

        configuration.preferredLanguages = appleLanguagesOverride
        RightClickConfigurationStore.save(configuration)
    }
}
