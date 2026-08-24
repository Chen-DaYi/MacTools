import XCTest
import MacToolsCLIProtocol
@testable import MacTools

final class CLIHostBridgeCallbackRelayTests: XCTestCase {
    func testReconnectCallbackCanEnterFromDetachedTaskAndRunsOnMainActor() async {
        let reconnected = expectation(description: "Reconnect callback ran")
        let relay = CLIHostBridgeCallbackRelay {
            XCTAssertTrue(Thread.isMainThread)
            reconnected.fulfill()
        }

        await Task.detached {
            relay.makeReconnectHandler()()
        }.value

        await fulfillment(of: [reconnected], timeout: 1)
    }

    func testErrorCallbackCanEnterFromDetachedTaskAndRunsOnMainActor() async {
        let reconnected = expectation(description: "Reconnect callback ran")
        let relay = CLIHostBridgeCallbackRelay {
            XCTAssertTrue(Thread.isMainThread)
            reconnected.fulfill()
        }

        await Task.detached {
            relay.makeReconnectErrorHandler()(CallbackError.expected)
        }.value

        await fulfillment(of: [reconnected], timeout: 1)
    }

    func testAuthenticatedIncompatibleHostRegistrationDoesNotReconnect() async throws {
        let reconnected = expectation(description: "Reconnect callback did not run")
        reconnected.isInverted = true
        let relay = CLIHostBridgeCallbackRelay(
            reconnect: { reconnected.fulfill() },
            connectionIsBroker: { _ in true }
        )
        let connection = NSXPCConnection(serviceName: "test.invalid")
        let response = try CLIProtocolCodec.encodeResponse(CLIHandshakeResponse(
            selectedProtocolVersion: nil,
            brokerVersion: "1",
            brokerBuild: "1",
            hostVersion: "2",
            hostBuild: "2",
            hostReady: false,
            message: "No compatible host protocol version."
        ))

        relay.makeRegistrationReplyHandler(for: connection)(response)

        await fulfillment(of: [reconnected], timeout: 0.1)
    }
}

private enum CallbackError: Error {
    case expected
}
