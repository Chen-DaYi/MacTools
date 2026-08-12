import XCTest
@testable import MacTools

@MainActor
final class AppInstanceCoordinatorTests: XCTestCase {
    func testShowSettingsCommandUsesTheCurrentProtocolVersion() {
        let command = AppInstanceCommand.showSettingsRequest()

        XCTAssertEqual(command.version, AppInstanceCommand.currentVersion)
        XCTAssertEqual(command.command, AppInstanceCommand.showSettings)
        XCTAssertTrue(command.isSupported)
    }

    func testCommandRejectsUnknownVersionAndCommand() {
        XCTAssertFalse(
            AppInstanceCommand(
                version: AppInstanceCommand.currentVersion + 1,
                command: AppInstanceCommand.showSettings,
                requestID: UUID()
            ).isSupported
        )
        XCTAssertFalse(
            AppInstanceCommand(
                version: AppInstanceCommand.currentVersion,
                command: "open-url",
                requestID: UUID()
            ).isSupported
        )
    }

    func testCommandPayloadRemainsWithinTheProtocolLimit() throws {
        let data = try JSONEncoder().encode(AppInstanceCommand.showSettingsRequest())

        XCTAssertLessThanOrEqual(data.count, AppInstanceCommand.maximumPayloadSize)
    }

    func testSecondaryForwardsSettingsRequestToThePrimary() {
        let bundleIdentifier = "com.example.mactools.instance-test.\(UUID().uuidString)"
        let primary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        var receivedRequestCount = 0
        primary.setCommandHandler {
            receivedRequestCount += 1
            return .accepted
        }
        defer { primary.invalidate() }

        XCTAssertEqual(primary.acquireOrForwardSettingsRequest(), .primary(recoveryRequested: false))

        let secondary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        XCTAssertEqual(
            secondary.acquireOrForwardSettingsRequest(),
            .secondary(.acknowledged)
        )
        XCTAssertEqual(receivedRequestCount, 1)
    }

    func testSecondaryRetriesUntilThePrimaryIsReady() {
        let bundleIdentifier = "com.example.mactools.instance-test.\(UUID().uuidString)"
        let primary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        var receivedRequestCount = 0
        primary.setCommandHandler {
            receivedRequestCount += 1
            return receivedRequestCount == 1 ? .notReady : .accepted
        }
        defer { primary.invalidate() }

        XCTAssertEqual(primary.acquireOrForwardSettingsRequest(), .primary(recoveryRequested: false))

        let secondary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        XCTAssertEqual(
            secondary.acquireOrForwardSettingsRequest(),
            .secondary(.acknowledged)
        )
        XCTAssertEqual(receivedRequestCount, 2)
    }

    func testAReplacementBecomesPrimaryAfterPortInvalidation() {
        let bundleIdentifier = "com.example.mactools.instance-test.\(UUID().uuidString)"
        let primary = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)

        XCTAssertEqual(primary.acquireOrForwardSettingsRequest(), .primary(recoveryRequested: false))
        primary.invalidate()

        let replacement = AppInstanceCoordinator(bundleIdentifier: bundleIdentifier)
        defer { replacement.invalidate() }
        XCTAssertEqual(replacement.acquireOrForwardSettingsRequest(), .primary(recoveryRequested: false))
    }
}
