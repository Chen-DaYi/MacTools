import Foundation
import XCTest

final class AppInstanceCoordinatorProcessTests: XCTestCase {
    func testTenConcurrentProcessesElectOnePrimary() throws {
        let namespace = uniqueNamespace()
        let processes = try (0..<10).map { _ in try launchProbe(namespace: namespace) }
        defer { processes.forEach(terminateIfRunning) }

        XCTAssertTrue(waitUntil(timeout: 4) {
            processes.filter(\.isRunning).count == 1
                && processes.filter { !$0.isRunning }.count == 9
        })

        let primary = try XCTUnwrap(processes.first(where: \.isRunning))
        let secondaries = processes.filter { !$0.isRunning }
        XCTAssertEqual(secondaries.filter { $0.terminationStatus == 0 }.count, 9)
        XCTAssertEqual(try secondaries.filter { try output(of: $0) == "secondary-acknowledged" }.count, 9)

        terminateIfRunning(primary)
        let primaryLines = try output(of: primary).split(separator: "\n")
        XCTAssertEqual(primaryLines.filter { $0 == "command-accepted" }.count, 9)
    }

    func testOwnerCrashAllowsPromotion() throws {
        let namespace = uniqueNamespace()
        let owner = try launchProbe(namespace: namespace)
        defer { terminateIfRunning(owner) }
        try waitForOutput("primary", from: owner)

        owner.terminate()
        owner.waitUntilExit()

        let replacement = try launchProbe(namespace: namespace)
        defer { terminateIfRunning(replacement) }
        try waitForOutput("primary", from: replacement)
        XCTAssertTrue(replacement.isRunning)
    }

    func testUnresponsiveOwnerTimesOutWithoutSecondPrimary() throws {
        let namespace = uniqueNamespace()
        let owner = try launchProbe(namespace: namespace, mode: "unresponsive")
        defer { terminateIfRunning(owner) }
        try waitForOutput("primary", from: owner)

        let startedAt = Date()
        let secondary = try launchProbe(namespace: namespace)
        secondary.waitUntilExit()

        XCTAssertEqual(secondary.terminationStatus, 0)
        XCTAssertEqual(try output(of: secondary), "secondary-timed-out")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        XCTAssertTrue(owner.isRunning)
    }

    func testDifferentNamespacesElectIndependentPrimaries() throws {
        let first = try launchProbe(namespace: uniqueNamespace())
        let second = try launchProbe(namespace: uniqueNamespace())
        defer {
            terminateIfRunning(first)
            terminateIfRunning(second)
        }
        try waitForOutput("primary", from: first)
        try waitForOutput("primary", from: second)

        XCTAssertTrue(first.isRunning)
        XCTAssertTrue(second.isRunning)
    }

    private func launchProbe(namespace: String, mode: String = "ready") throws -> Process {
        let process = Process()
        process.executableURL = probeURL
        process.arguments = [namespace, mode]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private var probeURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("AppInstanceProbe")
    }

    private func uniqueNamespace() -> String {
        "com.example.mactools.process-test.\(UUID().uuidString)"
    }

    private func output(of process: Process) throws -> String {
        let pipe = try XCTUnwrap(process.standardOutput as? Pipe)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitForOutput(
        _ expectedOutput: String,
        from process: Process,
        timeout: TimeInterval = 2
    ) throws {
        let pipe = try XCTUnwrap(process.standardOutput as? Pipe)
        let collector = ProcessOutputCollector(expectedOutput: expectedOutput)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }

        XCTAssertEqual(collector.wait(timeout: timeout), .success)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func terminateIfRunning(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let expectedData: Data
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var data = Data()
    private var didSignal = false

    init(expectedOutput: String) {
        expectedData = Data(expectedOutput.utf8)
    }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(newData)
        guard !didSignal, data.range(of: expectedData) != nil else { return }
        didSignal = true
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + timeout)
    }
}
