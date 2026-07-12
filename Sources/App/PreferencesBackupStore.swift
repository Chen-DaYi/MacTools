import Foundation

@MainActor
final class PreferencesBackupStore: PreferencesBackupApplicationStoring {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func applicationPreferences() -> PreferencesBackup.ApplicationPreferences {
        PreferencesBackup.ApplicationPreferences(
            appearancePreference: AppAppearancePreference.stored(in: userDefaults).rawValue,
            languagePreference: AppLanguagePreference.stored(in: userDefaults).rawValue,
            menuBarClickBehavior: MenuBarClickBehaviorPreference.current(userDefaults).rawValue
        )
    }

    func apply(_ preferences: PreferencesBackup.ApplicationPreferences) {
        guard let appearance = AppAppearancePreference(rawValue: preferences.appearancePreference),
              let language = AppLanguagePreference(rawValue: preferences.languagePreference),
              let clickBehavior = MenuBarClickBehaviorPreference(rawValue: preferences.menuBarClickBehavior)
        else {
            return
        }

        userDefaults.set(appearance.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
        appearance.apply()
        language.store(in: userDefaults)
        userDefaults.set(clickBehavior.rawValue, forKey: MenuBarClickBehaviorPreference.userDefaultsKey)
    }
}
