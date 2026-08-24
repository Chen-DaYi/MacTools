import XCTest
@testable import MacTools

final class CLIStartupDeadlineTests: XCTestCase {
    func testRemainingDurationIsCappedByOperationBudget() {
        let start = ContinuousClock.now
        let deadline = CLIStartupDeadline(timeout: .seconds(10), now: start)

        XCTAssertEqual(
            deadline.cappedInstant(
                upTo: .seconds(1),
                now: start.advanced(by: .seconds(2))
            ),
            start.advanced(by: .seconds(3))
        )
    }

    func testRemainingDurationShrinksAtOverallDeadline() {
        let start = ContinuousClock.now
        let deadline = CLIStartupDeadline(timeout: .seconds(10), now: start)

        XCTAssertEqual(
            deadline.cappedInstant(
                upTo: .seconds(1),
                now: start.advanced(by: .milliseconds(9_500))
            ),
            deadline.instant
        )
        XCTAssertNil(
            deadline.cappedInstant(
                upTo: .milliseconds(200),
                now: start.advanced(by: .seconds(10))
            )
        )
    }

    func testNearExpiryResponseWaitRetainsOriginalDoctorDeadline() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = CLIStartupDeadline(timeout: .milliseconds(100), now: start)
        try await clock.sleep(until: start.advanced(by: .milliseconds(80)))

        let responseDeadline = try XCTUnwrap(
            deadline.cappedInstant(upTo: .seconds(10), now: clock.now)
        )

        XCTAssertEqual(responseDeadline, deadline.instant)
        try await clock.sleep(until: responseDeadline)
        XCTAssertGreaterThan(
            clock.now.duration(to: start.advanced(by: .milliseconds(200))),
            .zero
        )
    }
}
