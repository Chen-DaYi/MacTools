import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanRunningAppLockTests: XCTestCase {
    // MARK: - 判定矩阵

    func testBundleIDMatchIsCaseInsensitive() {
        let snapshot = DiskCleanRunningAppSnapshot(runningBundleIDs: ["COM.Google.Chrome"])
        let target = DiskCleanRuleTarget.test(id: "browser.chrome", lockedByBundleIDs: ["com.google.chrome"])

        XCTAssertEqual(snapshot.lockingProcessName(for: target), "com.google.chrome")
    }

    func testProcessNameMatchIsCaseSensitive() {
        let snapshot = DiskCleanRunningAppSnapshot(runningProcessNames: ["Docker"])

        XCTAssertEqual(
            snapshot.lockingProcessName(for: .test(id: "a", skipWhenProcessIsRunning: ["Docker"])),
            "Docker"
        )
        XCTAssertNil(
            snapshot.lockingProcessName(for: .test(id: "b", skipWhenProcessIsRunning: ["docker"])),
            "进程名是精确匹配，不做大小写归一"
        )
    }

    func testUnlockedTargetReturnsNil() {
        let snapshot = DiskCleanRunningAppSnapshot(
            runningBundleIDs: ["com.apple.finder"],
            runningProcessNames: ["Xcode"]
        )
        let target = DiskCleanRuleTarget.test(
            id: "a",
            lockedByBundleIDs: ["com.google.Chrome"],
            skipWhenProcessIsRunning: ["Docker"]
        )

        XCTAssertNil(snapshot.lockingProcessName(for: target))
    }

    func testBundleIDTakesPrecedenceOverProcessName() {
        let snapshot = DiskCleanRunningAppSnapshot(
            runningBundleIDs: ["com.vivaldi.vivaldi"],
            runningProcessNames: ["Vivaldi"]
        )
        let target = DiskCleanRuleTarget.test(
            id: "a",
            lockedByBundleIDs: ["com.vivaldi.Vivaldi"],
            skipWhenProcessIsRunning: ["Vivaldi"]
        )

        XCTAssertEqual(snapshot.lockingProcessName(for: target), "com.vivaldi.Vivaldi")
    }

    func testProcessNamesCollectionIsDeduplicatedAndOrdered() {
        let names = DiskCleanRunningAppSnapshot.processNames(in: [
            .test(id: "a", skipWhenProcessIsRunning: ["Docker", "Xcode"]),
            .test(id: "b", skipWhenProcessIsRunning: ["Xcode", "Simulator"]),
            .test(id: "c")
        ])

        XCTAssertEqual(names, ["Docker", "Xcode", "Simulator"])
    }

    // MARK: - 批量 pgrep

    func testQueriesAllProcessNamesInASingleSubprocess() async {
        let runner = FakeDiskCleanSubprocessRunner(exitCode: 0, standardOutput: "421 Docker\n99 Xcode\n")
        let lock = DiskCleanRunningAppLock(subprocessRunner: runner)

        let snapshot = await lock.makeSnapshot(processNames: ["Docker", "Xcode", "Simulator"])

        XCTAssertEqual(runner.invocations.count, 1, "一次子进程查全部名字，替换 v1 的每规则一次 pgrep")
        XCTAssertEqual(
            runner.invocations.first?.arguments,
            ["-x", "-l", "(Docker|Xcode|Simulator)"]
        )
        XCTAssertEqual(snapshot.runningProcessNames, ["Docker", "Xcode"])
    }

    func testSkipsSubprocessWhenNoTargetDeclaresProcessNames() async {
        let runner = FakeDiskCleanSubprocessRunner(exitCode: 0)
        let lock = DiskCleanRunningAppLock(subprocessRunner: runner)

        let snapshot = await lock.makeSnapshot(processNames: [])

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(snapshot.runningProcessNames.isEmpty)
    }

    func testTreatsExitCodeOneAsNoMatchRatherThanFailure() async {
        let runner = FakeDiskCleanSubprocessRunner(exitCode: 1, standardOutput: "")
        let lock = DiskCleanRunningAppLock(subprocessRunner: runner)

        let snapshot = await lock.makeSnapshot(processNames: ["Docker"])

        XCTAssertTrue(snapshot.runningProcessNames.isEmpty)
    }

    func testSubprocessFailureDegradesToEmptyProcessSet() async {
        let runner = FakeDiskCleanSubprocessRunner(
            error: DiskCleanSubprocessError.timedOut(path: "/usr/bin/pgrep")
        )
        let lock = DiskCleanRunningAppLock(subprocessRunner: runner)

        let snapshot = await lock.makeSnapshot(processNames: ["Docker"])

        XCTAssertTrue(
            snapshot.runningProcessNames.isEmpty,
            "pgrep 失败只会漏报锁定，执行侧的双时点复核兜底；绝不因此中断扫描"
        )
    }

    func testIgnoresProcessNamesOutsideTheRequestedSet() async {
        let runner = FakeDiskCleanSubprocessRunner(
            exitCode: 0,
            standardOutput: "1 Docker\n2 SomethingElse\n"
        )
        let lock = DiskCleanRunningAppLock(subprocessRunner: runner)

        let snapshot = await lock.makeSnapshot(processNames: ["Docker"])

        XCTAssertEqual(snapshot.runningProcessNames, ["Docker"])
    }

    // MARK: - 解析与转义

    func testEscapesRegexMetacharactersInProcessNames() {
        XCTAssertEqual(
            DiskCleanRunningAppLock.pattern(for: ["com.docker.backend", "Sublime Text (Safe Mode)"]),
            "(com\\.docker\\.backend|Sublime Text \\(Safe Mode\\))"
        )
    }

    func testParsesProcessNamesContainingSpaces() {
        let names = DiskCleanRunningAppLock.processNames(
            fromPgrepOutput: Data("1234 Google Chrome\n5678 Code Helper (Renderer)\n".utf8)
        )

        XCTAssertEqual(names, ["Google Chrome", "Code Helper (Renderer)"])
    }

    func testIgnoresMalformedPgrepLines() {
        let names = DiskCleanRunningAppLock.processNames(fromPgrepOutput: Data("garbage\n42 \n7 Real\n".utf8))

        XCTAssertEqual(names, ["Real"])
    }
}
