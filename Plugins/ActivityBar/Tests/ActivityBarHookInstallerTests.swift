import XCTest
@testable import ActivityBarPlugin

final class ActivityBarHookInstallerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityBarHookInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testInstallWritesScriptsAndToolConfigurations() throws {
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: temporaryDirectory,
            hookScriptsDirectory: temporaryDirectory.appendingPathComponent("hooks")
        )
        let installer = ActivityBarHookInstaller(paths: paths, socketPath: "/tmp/mactools-test.sock")

        let summary = try installer.install()

        XCTAssertEqual(summary.installedTools, ["Claude Code", "Cursor", "Codex"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.hookScriptsDirectory.path))

        let claudeScript = paths.hookScriptsDirectory.appendingPathComponent("mactools-activity-claude-hook.sh")
        let scriptText = try String(contentsOf: claudeScript, encoding: .utf8)
        XCTAssertTrue(scriptText.contains("/tmp/mactools-test.sock"))

        let permissions = try FileManager.default.attributesOfItem(atPath: claudeScript.path)[.posixPermissions] as? Int
        XCTAssertEqual((permissions ?? 0) & 0o111, 0o111)

        let claudeSettings = try readJSONObject(paths.claudeSettingsPath)
        let claudeHooks = try XCTUnwrap(claudeSettings["hooks"] as? [String: Any])
        XCTAssertNotNil(claudeHooks["UserPromptSubmit"])

        let cursorSettings = try readJSONObject(paths.cursorHooksPath)
        let cursorHooks = try XCTUnwrap(cursorSettings["hooks"] as? [String: Any])
        XCTAssertNotNil(cursorHooks["beforeSubmitPrompt"])

        let codexConfig = try String(contentsOf: paths.codexConfigPath, encoding: .utf8)
        XCTAssertTrue(codexConfig.contains("codex_hooks = true"))

        let codexSettings = try readJSONObject(paths.codexHooksPath)
        let codexHooks = try XCTUnwrap(codexSettings["hooks"] as? [String: Any])
        XCTAssertNotNil(codexHooks["PreToolUse"])
    }

    func testInstallIsIdempotentForClaudeHooks() throws {
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: temporaryDirectory,
            hookScriptsDirectory: temporaryDirectory.appendingPathComponent("hooks")
        )
        let installer = ActivityBarHookInstaller(paths: paths, socketPath: "/tmp/mactools-test.sock")

        _ = try installer.install()
        let first = try Data(contentsOf: paths.claudeSettingsPath)
        _ = try installer.install()
        let second = try Data(contentsOf: paths.claudeSettingsPath)

        XCTAssertEqual(first, second)
    }

    func testUninstallRemovesOnlyActivityBarHooks() throws {
        let paths = ActivityBarHookInstallerPaths(
            homeDirectory: temporaryDirectory,
            hookScriptsDirectory: temporaryDirectory.appendingPathComponent("hooks")
        )
        try writeJSONObject(
            [
                "hooks": [
                    "UserPromptSubmit": [
                        [
                            "matcher": "",
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": "/usr/bin/true",
                                ]
                            ],
                        ]
                    ],
                ],
            ],
            to: paths.claudeSettingsPath
        )
        try writeJSONObject(
            [
                "version": 1,
                "hooks": [
                    "beforeSubmitPrompt": [
                        [
                            "command": "/usr/bin/true",
                        ]
                    ],
                ],
            ],
            to: paths.cursorHooksPath
        )
        try writeJSONObject(
            [
                "hooks": [
                    "PreToolUse": [
                        [
                            "matcher": "",
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": "/usr/bin/true",
                                ]
                            ],
                        ]
                    ],
                ],
            ],
            to: paths.codexHooksPath
        )

        let installer = ActivityBarHookInstaller(paths: paths, socketPath: "/tmp/mactools-test.sock")

        _ = try installer.install()
        let summary = try installer.uninstall()

        XCTAssertEqual(summary.removedTools, ["Claude Code", "Cursor", "Codex"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.hookScriptsDirectory.path))

        let claudeObject = try readJSONObject(paths.claudeSettingsPath)
        let cursorObject = try readJSONObject(paths.cursorHooksPath)
        let codexObject = try readJSONObject(paths.codexHooksPath)
        let claudeSettings = try serializedJSONObject(claudeObject)
        let cursorSettings = try serializedJSONObject(cursorObject)
        let codexSettings = try serializedJSONObject(codexObject)

        XCTAssertFalse(claudeSettings.contains("mactools-activity"))
        XCTAssertFalse(cursorSettings.contains("mactools-activity"))
        XCTAssertFalse(codexSettings.contains("mactools-activity"))
        XCTAssertTrue(containsString("/usr/bin/true", in: claudeObject))
        XCTAssertTrue(containsString("/usr/bin/true", in: cursorObject))
        XCTAssertTrue(containsString("/usr/bin/true", in: codexObject))
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func serializedJSONObject(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    private func containsString(_ expected: String, in object: Any) -> Bool {
        if let value = object as? String {
            return value == expected
        }

        if let values = object as? [Any] {
            return values.contains { containsString(expected, in: $0) }
        }

        if let values = object as? [String: Any] {
            return values.values.contains { containsString(expected, in: $0) }
        }

        return false
    }
}
