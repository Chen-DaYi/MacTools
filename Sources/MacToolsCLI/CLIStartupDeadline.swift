import Foundation

struct CLIStartupDeadline {
    let instant: ContinuousClock.Instant

    init(
        timeout: Duration,
        now: ContinuousClock.Instant = .now
    ) {
        instant = now.advanced(by: timeout)
    }

    func cappedInstant(
        upTo maximum: Duration,
        now: ContinuousClock.Instant = .now
    ) -> ContinuousClock.Instant? {
        guard now < instant else { return nil }
        return min(instant, now.advanced(by: maximum))
    }
}
