import Foundation

/// Whether the left-click and right-click actions on the menu bar status item are swapped.
///
/// - `.standard`: left-click opens the dashboard (component panel);
///   the right-click action opens the feature panel. Option+left-click triggers
///   the right-click action on every supported macOS version.
/// - `.swapped`: left-click opens the feature panel; the right-click action
///   opens the dashboard.
enum MenuBarClickBehaviorPreference: String {
    case standard
    case swapped

    static let userDefaultsKey = "menuBar.clickBehaviorPreference"

    var isSwapped: Bool { self == .swapped }

    /// Reads the current preference from `UserDefaults` (defaults to `.standard`).
    static func current(_ userDefaults: UserDefaults = .standard) -> MenuBarClickBehaviorPreference {
        userDefaults.string(forKey: userDefaultsKey)
            .flatMap(MenuBarClickBehaviorPreference.init(rawValue:))
            ?? .standard
    }
}
