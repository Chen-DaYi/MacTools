import AppKit

enum AppAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    static let userDefaultsKey = "app.appearancePreference"
    static let didChangeNotification = Notification.Name("AppAppearancePreferenceDidChange")

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return AppL10n.settings("appearance.system", defaultValue: "自动")
        case .dark:
            return AppL10n.settings("appearance.dark", defaultValue: "深色")
        case .light:
            return AppL10n.settings("appearance.light", defaultValue: "浅色")
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    @MainActor
    func apply(to view: NSView?) {
        view?.appearance = nsAppearance
    }

    @MainActor
    func apply(to window: NSWindow?) {
        window?.appearance = nsAppearance
    }

    @MainActor
    func apply(to popover: NSPopover) {
        apply(to: popover.contentViewController?.view)
        apply(to: popover.contentViewController?.view.window)
    }

    @MainActor
    private var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .dark:
            return NSAppearance(named: .darkAqua)
        case .light:
            return NSAppearance(named: .aqua)
        }
    }

    static func stored(in userDefaults: UserDefaults = .standard) -> AppAppearancePreference {
        guard
            let rawValue = userDefaults.string(forKey: userDefaultsKey),
            let preference = AppAppearancePreference(rawValue: rawValue)
        else {
            return .system
        }

        return preference
    }

    @MainActor
    static func applyStoredPreference(userDefaults: UserDefaults = .standard) {
        stored(in: userDefaults).apply()
    }
}
