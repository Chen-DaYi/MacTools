import Darwin
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Dynamic rule provider tests (design §5.5, §11 "dynamic rules" row).
/// Always use temporary directories; never touch real user directories.
final class DiskCleanDynamicRulesTests: XCTestCase {
    private var root: URL!

    /// **Fixture roots always use `realpath(3)` physical paths**: `NSTemporaryDirectory()` lives under `/var/folders/...`,
    /// and `/var` is a symlink to `private/var`. `resolvingSymlinksInPath()` does not fix this
    /// (it tends to strip `/private` rather than add it); only realpath yields stable comparable paths.
    /// Reuse `DiskCleanTempDirectory.physicalPath(of:)` so two realpath implementations cannot drift.
    override func setUpWithError() throws {
        try super.setUpWithError()
        let created = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DiskCleanDynamicRulesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: DiskCleanTempDirectory.physicalPath(of: created.path), isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let root, FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Version parsing

    func testVersionNumberAcceptsNumericDottedNamesOnly() {
        XCTAssertEqual(DiskCleanVersionNumber("152.0.7933.0")?.components, [152, 0, 7933, 0])
        XCTAssertEqual(DiskCleanVersionNumber("2.1.215")?.components, [2, 1, 215])
        XCTAssertEqual(DiskCleanVersionNumber("223")?.components, [223])
        XCTAssertEqual(DiskCleanVersionNumber("1.0.0-beta.2")?.components, [1, 0, 0, 2])

        XCTAssertNil(DiskCleanVersionNumber("Current"))
        XCTAssertNil(DiskCleanVersionNumber("ch-0"))
        XCTAssertNil(DiskCleanVersionNumber("crx_cache"))
        XCTAssertNil(DiskCleanVersionNumber("prefs.json"))
        XCTAssertNil(DiskCleanVersionNumber("updater.log.old"))
        XCTAssertNil(DiskCleanVersionNumber(""))
    }

    func testVersionNumberComparesNumericallyNotLexically() throws {
        XCTAssertLessThan(
            try XCTUnwrap(DiskCleanVersionNumber("2.1.9")),
            try XCTUnwrap(DiskCleanVersionNumber("2.1.10"))
        )
        XCTAssertLessThan(
            try XCTUnwrap(DiskCleanVersionNumber("2.1")),
            try XCTUnwrap(DiskCleanVersionNumber("2.1.1"))
        )
    }

    // MARK: - Version directory provider

    func testVersionProviderKeepsNewestAndReturnsOlderVersions() async throws {
        let container = try makeDirectory("versions")
        try makeDirectories(["2.1.9", "2.1.10", "2.1.215", "2.2.0"], in: container)

        let items = try await expand(containerGlobs: [container.path])

        XCTAssertEqual(names(of: items), ["2.1.215", "2.1.10", "2.1.9"])
        // Candidate paths must stay under the container physical path: full-path compare is where realpath normalization matters.
        for item in items {
            XCTAssertTrue(item.path.hasPrefix(container.path + "/"), "candidate escaped container: \(item.path)")
        }
    }

    func testVersionProviderHonoursKeepNewestCount() async throws {
        let container = try makeDirectory("versions")
        try makeDirectories(["1.0.0", "1.1.0", "1.2.0", "1.3.0"], in: container)

        let items = try await expand(containerGlobs: [container.path], keepNewestCount: 2)

        XCTAssertEqual(names(of: items), ["1.1.0", "1.0.0"])
    }

    func testVersionProviderReturnsNothingWhenOnlyKeptVersionsExist() async throws {
        let container = try makeDirectory("versions")
        try makeDirectories(["3.0.0"], in: container)

        let items = try await expand(containerGlobs: [container.path])

        XCTAssertTrue(items.isEmpty)
    }

    func testVersionProviderIgnoresNonVersionEntriesAndFiles() async throws {
        let container = try makeDirectory("GoogleUpdater")
        try makeDirectories(["149.0.7814.0", "152.0.7933.0", "crx_cache"], in: container)
        try Data("{}".utf8).write(to: container.appendingPathComponent("prefs.json"))
        try Data("log".utf8).write(to: container.appendingPathComponent("updater.log"))

        let items = try await expand(containerGlobs: [container.path])

        XCTAssertEqual(names(of: items), ["149.0.7814.0"])
    }

    /// The version pointed to by `Current -> <version>` is in use and must not be a candidate even if it is not the newest.
    func testVersionProviderNeverReturnsVersionPinnedBySiblingSymlink() async throws {
        let container = try makeDirectory("GoogleUpdater")
        try makeDirectories(["149.0.7814.0", "150.0.7863.0", "151.0.7910.0"], in: container)
        try FileManager.default.createSymbolicLink(
            atPath: container.appendingPathComponent("Current").path,
            withDestinationPath: "149.0.7814.0"
        )

        let items = try await expand(containerGlobs: [container.path])

        XCTAssertEqual(names(of: items), ["150.0.7863.0"])
    }

    /// Symlinks whose names look like versions are never candidates — deleting the link frees no space and may break callers.
    func testVersionProviderIgnoresSymlinkedVersionDirectories() async throws {
        let container = try makeDirectory("versions")
        try makeDirectories(["1.0.0", "1.1.0", "1.2.0", "shared"], in: container)
        try FileManager.default.createSymbolicLink(
            atPath: container.appendingPathComponent("0.9.0").path,
            withDestinationPath: "shared"
        )

        let items = try await expand(containerGlobs: [container.path])

        XCTAssertEqual(names(of: items), ["1.1.0", "1.0.0"])
    }

    func testVersionProviderExpandsWildcardContainerGlobs() async throws {
        let apps = try makeDirectory("apps")
        for ide in ["IntelliJ", "GoLand"] {
            let channel = apps.appendingPathComponent("\(ide)/ch-0", isDirectory: true)
            try FileManager.default.createDirectory(at: channel, withIntermediateDirectories: true)
            try makeDirectories(["223.8836.35", "241.14494.240"], in: channel)
        }

        let items = try await expand(containerGlobs: [apps.path + "/*/ch-*"])

        XCTAssertEqual(Set(names(of: items)), ["223.8836.35"])
        XCTAssertEqual(items.count, 2)
    }

    func testUnavailableSimulatorProviderReturnsOnlyUnavailableExistingDeviceDirectories() async throws {
        let devices = try makeDirectory("Devices")
        let unavailable = "3A6B1C2D-0000-4000-8000-000000000001"
        let available = "3A6B1C2D-0000-4000-8000-000000000002"
        // Third device is unavailable in JSON, and its directory was already deleted by the user; it must not appear as a candidate.
        let missing = "3A6B1C2D-0000-4000-8000-000000000003"
        try makeDirectories([unavailable, available], in: devices)

        let json = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[
          {"udid":"\(unavailable)","isAvailable":false,"name":"iPhone 15"},
          {"udid":"\(available)","isAvailable":true,"name":"iPhone 16"},
          {"udid":"\(missing)","isAvailable":false,"name":"deleted"}
        ]}}
        """

        let items = try await expandSimulators(devicesRoot: devices, outcome: .success(Data(json.utf8)))

        XCTAssertEqual(names(of: items), [unavailable])
    }

    func testUnavailableSimulatorProviderRejectsNonUUIDIdentifiers() async throws {
        let devices = try makeDirectory("Devices")
        try makeDirectories(["passwd"], in: devices)

        let json = """
        {"devices":{"runtime":[{"udid":"../passwd","isAvailable":false}]}}
        """

        let items = try await expandSimulators(devicesRoot: devices, outcome: .success(Data(json.utf8)))

        XCTAssertTrue(items.isEmpty)
    }

    func testUnavailableSimulatorProviderPropagatesTimeout() async throws {
        let devices = try makeDirectory("Devices")

        do {
            _ = try await expandSimulators(
                devicesRoot: devices,
                outcome: .failure(.timedOut(path: "/usr/bin/xcrun"))
            )
            XCTFail("timeout should throw")
        } catch let error as DiskCleanSubprocessError {
            XCTAssertEqual(error, .timedOut(path: "/usr/bin/xcrun"))
        }
    }

    func testUnavailableSimulatorProviderReturnsEmptyWhenSimctlUnavailable() async throws {
        let devices = try makeDirectory("Devices")

        let missingExecutable = try await expandSimulators(
            devicesRoot: devices,
            outcome: .failure(.executableUnavailable(path: "/usr/bin/xcrun"))
        )
        XCTAssertTrue(missingExecutable.isEmpty)

        let nonZeroExit = try await expandSimulators(
            devicesRoot: devices,
            outcome: .exit(code: 72, output: Data())
        )
        XCTAssertTrue(nonZeroExit.isEmpty)
    }

    // MARK: - Real subprocess executor

    func testLocalSubprocessRunnerCapturesStandardOutput() async throws {
        let result = try await LocalDiskCleanSubprocessRunner().run(
            executablePath: "/bin/echo",
            arguments: ["diskclean"],
            timeout: .seconds(5)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "diskclean\n")
    }

    func testLocalSubprocessRunnerReportsMissingExecutable() async throws {
        do {
            _ = try await LocalDiskCleanSubprocessRunner().run(
                executablePath: root.appendingPathComponent("nope").path,
                arguments: [],
                timeout: .seconds(1)
            )
            XCTFail("missing executable should throw")
        } catch let error as DiskCleanSubprocessError {
            guard case .executableUnavailable = error else {
                return XCTFail("unexpected error type: \(error)")
            }
        }
    }

    func testLocalSubprocessRunnerTimesOutAndTerminatesChild() async throws {
        let started = Date()
        do {
            _ = try await LocalDiskCleanSubprocessRunner().run(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                timeout: .milliseconds(300)
            )
            XCTFail("timeout should throw")
        } catch let error as DiskCleanSubprocessError {
            guard case .timedOut = error else {
                return XCTFail("unexpected error type: \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testLocalSubprocessRunnerKillsTermIgnoringDescendantHoldingOutputPipe() async throws {
        let started = Date()
        do {
            _ = try await LocalDiskCleanSubprocessRunner().run(
                executablePath: "/bin/sh",
                arguments: ["-c", #"(trap '' TERM; sleep 30) & exit 0"#],
                timeout: .milliseconds(300)
            )
            XCTFail("descendant-held pipe should reach the bounded timeout")
        } catch let error as DiskCleanSubprocessError {
            guard case .timedOut = error else {
                return XCTFail("unexpected error type: \(error)")
            }
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            3,
            "SIGKILL escalation must close inherited pipe writers promptly"
        )
    }

    func testLocalSubprocessRunnerCancelsAfterOutputDrainAndTerminatesGroup() async throws {
        let script = root.appendingPathComponent("close-output-and-wait.sh")
        let pidFile = root.appendingPathComponent("processes.txt")
        let source = """
        trap '' TERM
        (
          trap '' TERM
          exec 1>&-
          sleep 30
        ) &
        child=$!
        printf '%s %s\n' "$$" "$child" > "$1"
        exec 1>&-
        wait "$child"
        """
        try Data(source.utf8).write(to: script)
        let drain = DiskCleanOutputDrainRecorder()
        let runner = LocalDiskCleanSubprocessRunner {
            drain.record()
        }
        let task = Task {
            try await runner.run(
                executablePath: "/bin/sh",
                arguments: [script.path, pidFile.path],
                timeout: .seconds(2)
            )
        }
        defer { task.cancel() }

        for _ in 0..<200 where !drain.didDrain {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(drain.didDrain, "subprocess stdout should reach EOF before cancellation")
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let processIDs = pidText.split(separator: " ").compactMap {
            pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(processIDs.count, 2)
        let started = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled subprocess should throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        for processID in processIDs {
            for _ in 0..<200 where kill(processID, 0) == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(kill(processID, 0), -1, "process \(processID) should be terminated")
        }
    }

    func testSubprocessLifecycleNaturalCompletionWinsLateTimeout() {
        let lifecycle = DiskCleanSubprocessLifecycle()

        lifecycle.recordLeaderExited()
        lifecycle.recordDrainFinished()

        XCTAssertEqual(lifecycle.outcome, .completed)
        XCTAssertFalse(lifecycle.claimTimeout())
        XCTAssertFalse(lifecycle.claimCancellation())
        XCTAssertEqual(lifecycle.outcome, .completed)
    }

    func testSubprocessLifecycleTimeoutWinsWhileDescendantStillHoldsPipe() {
        let lifecycle = DiskCleanSubprocessLifecycle()

        lifecycle.recordLeaderExited()

        XCTAssertTrue(lifecycle.claimTimeout())
        XCTAssertFalse(lifecycle.claimTimeout())
        XCTAssertFalse(lifecycle.claimCancellation())
        lifecycle.recordDrainFinished()
        XCTAssertEqual(lifecycle.outcome, .timedOut)
    }

    func testProcessGroupEscalationFinishesBeforeOwnershipRelease() async {
        let events = DiskCleanProcessEventRecorder()
        let lifecycle = DiskCleanSubprocessLifecycle()
        lifecycle.recordLeaderExited()
        lifecycle.recordDrainFinished()
        let processGroup = DiskCleanProcessGroupBox(
            processID: 42,
            lifecycle: lifecycle,
            signalGroup: { _, signal in
                events.append(signal == SIGTERM ? .term : .kill)
            },
            waitForGrace: {
                events.append(.grace)
            }
        )

        await processGroup.finishAndTerminateRemainingDescendants()
        events.append(.reap)
        processGroup.releaseOwnership()
        let eventsAtRelease = events.snapshot
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        XCTAssertEqual(eventsAtRelease, [.term, .grace, .kill, .reap])
        XCTAssertEqual(events.snapshot, eventsAtRelease)
    }

    func testFailedExitObservationRevokesAllProcessGroupSignals() async {
        let events = DiskCleanProcessEventRecorder()
        let lifecycle = DiskCleanSubprocessLifecycle()
        let processGroup = DiskCleanProcessGroupBox(
            processID: 42,
            lifecycle: lifecycle,
            signalGroup: { _, signal in
                events.append(signal == SIGTERM ? .term : .kill)
            },
            waitForGrace: {
                events.append(.grace)
            }
        )

        processGroup.revokeGroupSignalOwnership()
        processGroup.requestCancellation()
        await processGroup.finishAndTerminateRemainingDescendants()
        events.append(.reap)
        processGroup.releaseOwnership()

        XCTAssertEqual(events.snapshot, [.grace, .reap])
    }

    func testRunnerFailsWhenLeaderExitCannotBeSafelyObserved() async {
        let runner = LocalDiskCleanSubprocessRunner(
            waitForLeaderExitWithoutReaping: { _ in false }
        )

        do {
            _ = try await runner.run(
                executablePath: "/usr/bin/true",
                arguments: [],
                timeout: .seconds(1)
            )
            XCTFail("unsafe leader-exit observation should fail")
        } catch let error as DiskCleanSubprocessError {
            guard case let .launchFailed(path, message) = error else {
                return XCTFail("expected launchFailed, got \(error)")
            }
            XCTAssertEqual(path, "/usr/bin/true")
            XCTAssertEqual(message, "Unable to observe subprocess exit safely.")
        } catch {
            XCTFail("expected DiskCleanSubprocessError, got \(error)")
        }
    }

    // MARK: - Helpers

    private struct FakeSubprocessRunner: DiskCleanSubprocessRunning {
        enum Outcome: Sendable {
            case success(Data)
            case exit(code: Int32, output: Data)
            case failure(DiskCleanSubprocessError)
        }

        let outcome: Outcome

        func run(
            executablePath: String,
            arguments: [String],
            timeout: Duration
        ) async throws -> DiskCleanSubprocessResult {
            switch outcome {
            case let .success(output):
                return DiskCleanSubprocessResult(exitCode: 0, standardOutput: output)
            case let .exit(code, output):
                return DiskCleanSubprocessResult(exitCode: code, standardOutput: output)
            case let .failure(error):
                throw error
            }
        }
    }

    private func expand(
        containerGlobs: [String],
        keepNewestCount: Int = 1
    ) async throws -> [DiskCleanFileItem] {
        let provider = DiskCleanVersionDirectoryRuleProvider(
            containerGlobs: containerGlobs,
            keepNewestCount: keepNewestCount
        )
        return try await provider.expand()
    }

    private func expandSimulators(
        devicesRoot: URL,
        outcome: FakeSubprocessRunner.Outcome
    ) async throws -> [DiskCleanFileItem] {
        let provider = DiskCleanUnavailableSimulatorRuleProvider(
            devicesRootPath: devicesRoot.path,
            executablePath: "/usr/bin/xcrun",
            timeout: .seconds(2),
            subprocessRunner: FakeSubprocessRunner(outcome: outcome)
        )
        return try await provider.expand()
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDirectories(_ names: [String], in parent: URL) throws {
        for name in names where !name.isEmpty {
            try FileManager.default.createDirectory(
                at: parent.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func names(of items: [DiskCleanFileItem]) -> [String] {
        items.map { ($0.path as NSString).lastPathComponent }
    }
}

private final class DiskCleanProcessEventRecorder: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case term
        case grace
        case kill
        case reap
    }

    private let lock = NSLock()
    private var events: [Event] = []

    var snapshot: [Event] {
        lock.withLock { events }
    }

    func append(_ event: Event) {
        lock.withLock { events.append(event) }
    }
}

private final class DiskCleanOutputDrainRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var drained = false

    var didDrain: Bool {
        lock.withLock { drained }
    }

    func record() {
        lock.withLock { drained = true }
    }
}
