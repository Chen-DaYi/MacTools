import XCTest
import MacToolsPluginKit
@testable import MacTools
@testable import LaunchControlPlugin

final class LaunchControlScanStatusTests: XCTestCase {
    func testParseLaunchctlListMapsPIDAndStatus() throws {
        let output = """
        PID\tStatus\tLabel
        1270\t0\tcom.apple.cloudphotod
        -\t-9\tcom.apple.progressd
        -\t0\tcom.apple.enhancedloggingd
        """
        let map = LaunchControlScanner.parseLaunchctlList(output)
        XCTAssertEqual(map.count, 3)

        let running = try XCTUnwrap(map["com.apple.cloudphotod"])
        XCTAssertEqual(running.pid, 1270)
        XCTAssertEqual(running.lastExitStatus, 0)

        let failed = try XCTUnwrap(map["com.apple.progressd"])
        XCTAssertNil(failed.pid)              // "-" → nil
        XCTAssertEqual(failed.lastExitStatus, -9)

        let idle = try XCTUnwrap(map["com.apple.enhancedloggingd"])
        XCTAssertNil(idle.pid)
        XCTAssertEqual(idle.lastExitStatus, 0)
    }

    func testParseLaunchctlListSkipsHeaderAndBlankLines() {
        XCTAssertTrue(LaunchControlScanner.parseLaunchctlList("PID\tStatus\tLabel\n").isEmpty)
        XCTAssertTrue(LaunchControlScanner.parseLaunchctlList("").isEmpty)
    }

    func testStatusFromListPresentIsLoaded() {
        let map: [String: (pid: Int?, lastExitStatus: Int?)] = ["x": (pid: 42, lastExitStatus: 0)]
        let status = LaunchControlScanner.status(from: map, label: "x")
        XCTAssertEqual(status.exitCode, 0)   // present in list → loaded
        XCTAssertEqual(status.pid, 42)
        XCTAssertEqual(status.lastExitStatus, 0)
    }

    func testStatusFromListAbsentIsNotLoaded() {
        let status = LaunchControlScanner.status(from: [:], label: "missing")
        XCTAssertEqual(status.exitCode, 1)   // absent → not loaded (matches non-zero `launchctl print`)
        XCTAssertNil(status.pid)
        XCTAssertNil(status.lastExitStatus)
    }

    func testStatusFromListPreservesFailedJob() {
        // pid "-" + non-zero status: equivalent to a job that exited with an error.
        let map: [String: (pid: Int?, lastExitStatus: Int?)] = ["y": (pid: nil, lastExitStatus: -9)]
        let status = LaunchControlScanner.status(from: map, label: "y")
        XCTAssertEqual(status.exitCode, 0)
        XCTAssertNil(status.pid)
        XCTAssertEqual(status.lastExitStatus, -9)
    }
}
