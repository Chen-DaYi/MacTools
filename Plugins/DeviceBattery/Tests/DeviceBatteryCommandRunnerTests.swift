import XCTest
@testable import DeviceBatteryPlugin

final class DeviceBatteryCommandRunnerTests: XCTestCase {
    func testReturnsCompleteOutput() async {
        let output = await DeviceBatteryCommandRunner.run(
            path: "/usr/bin/printf",
            arguments: ["battery-output"],
            timeout: 1
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "battery-output", completion: .completed)
        )
    }

    func testShortCommandsCompleteWithoutPipeGraceDelay() async {
        let clock = ContinuousClock()
        let start = clock.now
        var results: [DeviceBatteryCommandResult?] = []

        for _ in 0..<3 {
            results.append(await DeviceBatteryCommandRunner.run(
                path: "/usr/bin/printf",
                arguments: ["done"],
                timeout: 1
            ))
        }

        XCTAssertEqual(results, Array(repeating: DeviceBatteryCommandResult(
            output: "done",
            completion: .completed
        ), count: 3))
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(600))
    }

    func testFiltersOutputWhileDrainingPipe() async {
        let output = await DeviceBatteryCommandRunner.run(
            path: "/usr/bin/printf",
            arguments: ["keep\nskip\nkeep-again\n"],
            timeout: 1,
            outputLineFilter: { $0.hasPrefix("keep") }
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "keep\nkeep-again\n", completion: .completed)
        )
    }

    func testTimeoutTerminatesCommandWithoutPollingDelay() async {
        let clock = ContinuousClock()
        let start = clock.now
        let output = await DeviceBatteryCommandRunner.run(
            path: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.05
        )

        XCTAssertEqual(output?.completion, .timedOut)
        XCTAssertEqual(output?.output, "")
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testTimeoutReturnsFilteredPartialOutputWithoutWaitingForDescendantPipe() async {
        let clock = ContinuousClock()
        let start = clock.now
        let output = await DeviceBatteryCommandRunner.run(
            path: "/bin/sh",
            arguments: ["-c", "printf 'keep\\nskip\\n'; sleep 5"],
            timeout: 0.05,
            outputLineFilter: { $0 == "keep" }
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "keep\n", completion: .timedOut)
        )
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testCompletedParentDoesNotWaitForDescendantHoldingPipe() async {
        let clock = ContinuousClock()
        let start = clock.now
        let output = await DeviceBatteryCommandRunner.run(
            path: "/bin/sh",
            arguments: ["-c", "sleep 5 & printf done"],
            timeout: 2
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "done", completion: .completed)
        )
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testLargeOutputIsDrainedInOrder() async {
        let output = await DeviceBatteryCommandRunner.run(
            path: "/usr/bin/jot",
            arguments: ["-", "1", "20000"],
            timeout: 2
        )
        let lines = output?.output.split(separator: "\n") ?? []

        XCTAssertEqual(output?.completion, .completed)
        XCTAssertEqual(lines.count, 20_000)
        XCTAssertEqual(lines.first, "1")
        XCTAssertEqual(lines.last, "20000")
    }

    func testPreservesUTF8CharacterSplitAcrossPipeReads() async {
        let output = await DeviceBatteryCommandRunner.run(
            path: "/bin/sh",
            arguments: [
                "-c",
                "printf '\\344\\270'; sleep 0.05; printf '\\255\\n'"
            ],
            timeout: 1
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "中\n", completion: .completed)
        )
    }

    func testFiltersUTF8LineSplitAcrossPipeReads() async {
        let output = await DeviceBatteryCommandRunner.run(
            path: "/bin/sh",
            arguments: [
                "-c",
                "printf 'keep \\360\\237'; sleep 0.05; printf '\\221\\213\\nskip\\n'"
            ],
            timeout: 1,
            outputLineFilter: { $0.hasPrefix("keep") }
        )

        XCTAssertEqual(
            output,
            DeviceBatteryCommandResult(output: "keep 👋\n", completion: .completed)
        )
    }

    func testTaskCancellationTerminatesCommand() async {
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task {
            await DeviceBatteryCommandRunner.run(
                path: "/bin/sh",
                arguments: ["-c", "sleep 5"],
                timeout: 10
            )
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let output = await task.value
        XCTAssertNil(output)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }
}
