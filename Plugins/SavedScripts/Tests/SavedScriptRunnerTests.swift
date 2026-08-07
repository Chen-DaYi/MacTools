import Foundation
import XCTest
@testable import SavedScriptsPlugin

final class SavedScriptRunnerTests: XCTestCase {
    func testZshCapturesStandardOutputStandardErrorAndExitCode() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let runner = ProcessSavedScriptRunner(temporaryDirectory: temporaryDirectory)
        let script = SavedScript(
            name: "Output",
            kind: .zsh,
            source: "printf 'hello'; printf 'warning' >&2; exit 7"
        )

        let result = try await runner.run(script)

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.standardOutput, "hello")
        XCTAssertEqual(result.standardError, "warning")
        XCTAssertFalse(result.outputWasTruncated)
    }

    func testWorkingDirectoryWithSpacesIsPassedWithoutShellInterpolation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let workingDirectory = root.appendingPathComponent("Folder With Spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessSavedScriptRunner(temporaryDirectory: root)
        let script = SavedScript(
            name: "Directory",
            kind: .sh,
            source: "pwd",
            workingDirectory: workingDirectory.path
        )

        let result = try await runner.run(script)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            URL(fileURLWithPath: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
                .resolvingSymlinksInPath().path,
            workingDirectory.resolvingSymlinksInPath().path
        )
    }

    func testInvalidWorkingDirectoryFailsBeforeLaunching() async {
        let runner = ProcessSavedScriptRunner()
        let script = SavedScript(
            name: "Missing",
            kind: .zsh,
            source: "echo unreachable",
            workingDirectory: "/private/mactools-path-that-does-not-exist"
        )

        do {
            _ = try await runner.run(script)
            XCTFail("Expected invalid working directory")
        } catch {
            XCTAssertEqual(error as? SavedScriptProcessError, .invalidWorkingDirectory)
        }
    }

    func testTimeoutTerminatesLongRunningScript() async {
        let runner = ProcessSavedScriptRunner()
        let script = SavedScript(
            name: "Timeout",
            kind: .sh,
            source: "sleep 10",
            timeoutSeconds: 1
        )

        let started = Date()
        do {
            _ = try await runner.run(script)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? SavedScriptProcessError, .timedOut)
            XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        }
    }

    func testCapturedOutputIsBounded() async throws {
        let runner = ProcessSavedScriptRunner()
        let script = SavedScript(
            name: "Large Output",
            kind: .zsh,
            source: "printf '%*s' 70000 '' | tr ' ' x"
        )

        let result = try await runner.run(script)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.utf8.count, ProcessSavedScriptRunner.maximumCapturedByteCount)
        XCTAssertTrue(result.outputWasTruncated)
    }
}
