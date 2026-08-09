import XCTest
@testable import MacTools

@MainActor
final class DevelopmentInstanceGuardTests: XCTestCase {
    func testFirstDevelopmentInstanceClaimsLock() {
        let lock = DevelopmentInstanceLockStub(result: .acquired)
        let guardUnderTest = DevelopmentInstanceGuard(
            lock: lock,
            environment: [:],
            processIdentifier: 41,
            activateExistingInstance: { _, _ in
                XCTFail("The first instance should not activate another app")
            }
        )

        XCTAssertTrue(guardUnderTest.claim(bundleIdentifier: "com.example.mactools.dev"))
        XCTAssertTrue(guardUnderTest.ownsInstance)
        XCTAssertEqual(lock.claimedIdentifiers, ["com.example.mactools.dev"])

        guardUnderTest.release()
        XCTAssertFalse(guardUnderTest.ownsInstance)
        XCTAssertEqual(lock.releaseCount, 1)
    }

    func testDuplicateDevelopmentInstanceActivatesOwnerAndStopsLaunch() {
        let lock = DevelopmentInstanceLockStub(result: .ownedByOtherProcess)
        var activatedBundleIdentifier: String?
        var activatingProcessIdentifier: pid_t?
        let guardUnderTest = DevelopmentInstanceGuard(
            lock: lock,
            environment: [:],
            processIdentifier: 42,
            activateExistingInstance: { bundleIdentifier, processIdentifier in
                activatedBundleIdentifier = bundleIdentifier
                activatingProcessIdentifier = processIdentifier
            }
        )

        XCTAssertFalse(guardUnderTest.claim(bundleIdentifier: "com.example.mactools.dev"))
        XCTAssertFalse(guardUnderTest.ownsInstance)
        XCTAssertEqual(activatedBundleIdentifier, "com.example.mactools.dev")
        XCTAssertEqual(activatingProcessIdentifier, 42)
    }

    func testXCTestAndExplicitOverrideBypassSingletonLock() {
        for environment in [
            ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"],
            ["XCTestSessionIdentifier": "session"],
            ["XCODE_RUNNING_FOR_PREVIEWS": "1"],
            [DevelopmentInstanceGuard.allowMultipleInstancesEnvironmentKey: "1"],
        ] {
            let lock = DevelopmentInstanceLockStub(result: .ownedByOtherProcess)
            let guardUnderTest = DevelopmentInstanceGuard(
                lock: lock,
                environment: environment,
                activateExistingInstance: { _, _ in
                    XCTFail("Bypassed environments should not activate another app")
                }
            )

            XCTAssertTrue(guardUnderTest.claim(bundleIdentifier: "com.example.mactools.dev"))
            XCTAssertTrue(lock.claimedIdentifiers.isEmpty)
            guardUnderTest.release()
            XCTAssertEqual(lock.releaseCount, 0)
        }
    }

    func testUnavailableLockFailsOpenWithoutPretendingToHoldIt() {
        let lock = DevelopmentInstanceLockStub(result: .unavailable)
        let guardUnderTest = DevelopmentInstanceGuard(
            lock: lock,
            environment: [:],
            activateExistingInstance: { _, _ in
                XCTFail("An unavailable lock does not prove another app owns it")
            }
        )

        XCTAssertTrue(guardUnderTest.claim(bundleIdentifier: "com.example.mactools.dev"))
        guardUnderTest.release()
        XCTAssertEqual(lock.releaseCount, 0)
    }
}

private final class DevelopmentInstanceLockStub: DevelopmentInstanceLocking {
    private let result: DevelopmentInstanceLockResult
    private(set) var claimedIdentifiers: [String] = []
    private(set) var releaseCount = 0

    init(result: DevelopmentInstanceLockResult) {
        self.result = result
    }

    func tryAcquire(identifier: String) -> DevelopmentInstanceLockResult {
        claimedIdentifiers.append(identifier)
        return result
    }

    func release() {
        releaseCount += 1
    }
}
