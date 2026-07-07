import Foundation

/// Shared page-snap animation constants. The edge-turner dwell/cooldown
/// invariants are asserted against these in tests, so changing the spring here
/// trips the same red light — keep spring parameters and the settle estimate in
/// this one place.
enum LaunchpadPageAnimation {
    static let snapResponse: Double = 0.34
    static let snapDamping: Double = 0.86
    /// Conservative perceptual settle time for the snap spring (≈1.9× response
    /// at ζ≈0.86). Dwell and repeat-cooldown must never undercut this.
    static let snapVisualSettle: TimeInterval = 0.65
}
