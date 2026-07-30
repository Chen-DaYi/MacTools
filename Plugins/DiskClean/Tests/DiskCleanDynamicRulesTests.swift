import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 动态规则 provider 测试（设计 §5.5、§11"动态规则"行）。
/// 文件系统一律使用临时目录，绝不触碰真实用户目录。
final class DiskCleanDynamicRulesTests: XCTestCase {
    private var root: URL!

    /// **夹具根一律取 `realpath(3)` 物理路径**：`NSTemporaryDirectory()` 在 `/var/folders/...` 下，
    /// 而 `/var` 是指向 `private/var` 的符号链接。`resolvingSymlinksInPath()` 修不了这件事
    /// （它倾向剥掉 `/private` 而不是补上），只有 realpath 能给出稳定可比对的路径。
    /// 复用 `DiskCleanTempDirectory.physicalPath(of:)`，避免两份 realpath 逻辑各自漂移。
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

    // MARK: - 版本号解析

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

    // MARK: - 版本目录 provider

    func testVersionProviderKeepsNewestAndReturnsOlderVersions() async throws {
        let container = try makeDirectory("versions")
        try makeDirectories(["2.1.9", "2.1.10", "2.1.215", "2.2.0"], in: container)

        let items = try await expand(containerGlobs: [container.path])

        XCTAssertEqual(names(of: items), ["2.1.215", "2.1.10", "2.1.9"])
        // 候选路径必须落在容器物理路径下：全路径比对是 realpath 规范化真正兜住的场景。
        for item in items {
            XCTAssertTrue(item.path.hasPrefix(container.path + "/"), "候选逃出容器：\(item.path)")
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

    /// `Current -> <version>` 指向的版本视为在用，即使它不是最新版也不能作为候选。
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

    /// 名字像版本号的符号链接本身永不作为候选——删链接不释放空间，还可能破坏调用方期望。
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

    func testVersionProviderReturnsEmptyForMissingContainer() async throws {
        let items = try await expand(containerGlobs: [root.appendingPathComponent("absent").path])

        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - 不可用模拟器 provider

    func testUnavailableSimulatorProviderReturnsOnlyUnavailableExistingDeviceDirectories() async throws {
        let devices = try makeDirectory("Devices")
        let unavailable = "3A6B1C2D-0000-4000-8000-000000000001"
        let available = "3A6B1C2D-0000-4000-8000-000000000002"
        // 第三个设备在 JSON 里不可用，但目录已被用户手动删除，不应出现在候选中。
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

    func testUnavailableSimulatorProviderThrowsOnMalformedOutput() async throws {
        let devices = try makeDirectory("Devices")

        for payload in ["not json at all", "{}", #"{"devices":42}"#] {
            do {
                _ = try await expandSimulators(devicesRoot: devices, outcome: .success(Data(payload.utf8)))
                XCTFail("畸形输出应抛错：\(payload)")
            } catch let error as DiskCleanDynamicRuleError {
                XCTAssertEqual(error, .malformedOutput(command: "simctl list devices -j"))
            }
        }
    }

    func testUnavailableSimulatorProviderPropagatesTimeout() async throws {
        let devices = try makeDirectory("Devices")

        do {
            _ = try await expandSimulators(
                devicesRoot: devices,
                outcome: .failure(.timedOut(path: "/usr/bin/xcrun"))
            )
            XCTFail("超时应抛错")
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

    // MARK: - 真实子进程执行器

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
            XCTFail("缺失可执行文件应抛错")
        } catch let error as DiskCleanSubprocessError {
            guard case .executableUnavailable = error else {
                return XCTFail("错误类型不符：\(error)")
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
            XCTFail("超时应抛错")
        } catch let error as DiskCleanSubprocessError {
            guard case .timedOut = error else {
                return XCTFail("错误类型不符：\(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// 输出超过管道缓冲区（64KB）时不能死锁：读取与等待退出必须并行。
    func testLocalSubprocessRunnerHandlesOutputLargerThanPipeBuffer() async throws {
        let result = try await LocalDiskCleanSubprocessRunner().run(
            executablePath: "/usr/bin/head",
            arguments: ["-c", "400000", "/dev/zero"],
            timeout: .seconds(10)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.count, 400_000)
    }

    // MARK: - 辅助

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
