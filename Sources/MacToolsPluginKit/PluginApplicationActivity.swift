import Foundation

/// Host-level activity relevant to nonessential plugin background work.
///
/// Safety-critical plugins may keep their own sleep/wake handling. Telemetry,
/// scans, and other deferrable work should run only while this state is
/// `interactive`.
public enum PluginApplicationActivityState: Equatable, Sendable {
    case interactive
    case sessionInactive
    case displayAsleep
    case systemSleeping
    case waking

    public var allowsBackgroundWork: Bool {
        self == .interactive
    }
}

/// Optional lifecycle hook that preserves compatibility with installed plugins
/// built against an older `MacToolsPlugin` protocol.
@MainActor
public protocol PluginApplicationActivityStateHandling: AnyObject {
    func applicationActivityStateDidChange(_ state: PluginApplicationActivityState)
}
