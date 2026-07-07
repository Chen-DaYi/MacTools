import Foundation

/// A single launchable application discovered by `LaunchpadAppScanner`.
struct LaunchpadAppItem: Identifiable, Hashable, Sendable {
    /// Resolved absolute path of the `.app` bundle — stable and unique, used as identity.
    let id: String
    /// User-facing localized name (without the `.app` suffix).
    let name: String
    let url: URL
}
