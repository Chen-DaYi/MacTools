import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanPurgeScannerTests: XCTestCase {
    private var temporaryDirectory: DiskCleanTempDirectory!
    private var discovery: DiskCleanPurgeDiscovery!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try DiskCleanTempDirectory(name: "DiskCleanPurgeScannerTests")
        discovery = DiskCleanPurgeDiscovery()
    }

    override func tearDownWithError() throws {
        temporaryDirectory?.remove()
        temporaryDirectory = nil
        discovery = nil
        try super.tearDownWithError()
    }

    // MARK: - 工程标记判定矩阵

    func testFindsNodeModulesWithSiblingPackageManifest() throws {
        try temporaryDirectory.makeFile("root/app/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/app/node_modules")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.path), [path("root/app/node_modules")])
        XCTAssertEqual(items[0].kind, .nodeModules)
        XCTAssertEqual(items[0].projectMarker, "package.json")
        XCTAssertEqual(items[0].projectPath, path("root/app"))
    }

    /// 没有工程标记就不是工程产物：`~/Documents/build` 这类照片目录必须零命中。
    func testIgnoresBuildDirectoryWithoutProjectMarker() throws {
        try temporaryDirectory.makeFile("root/Documents/build/photo.jpg", bytes: 8)
        try temporaryDirectory.makeFile("root/Documents/dist/poster.png", bytes: 8)
        try temporaryDirectory.makeDirectory("root/Documents/node_modules")
        try temporaryDirectory.makeDirectory("root/Documents/target")

        let items = try discoverItems()

        XCTAssertTrue(items.isEmpty, "无标记目录不得命中，实际 \(items.map(\.path))")
    }

    func testMatchesEachKindWithItsMarker() throws {
        try temporaryDirectory.makeFile("root/rust/Cargo.toml", bytes: 10)
        try temporaryDirectory.makeDirectory("root/rust/target")
        try temporaryDirectory.makeFile("root/web/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/web/build")
        try temporaryDirectory.makeFile("root/py/setup.py", bytes: 10)
        try temporaryDirectory.makeDirectory("root/py/dist")
        try temporaryDirectory.makeFile("root/modern/pyproject.toml", bytes: 10)
        try temporaryDirectory.makeDirectory("root/modern/build")

        let items = try discoverItems()

        XCTAssertEqual(
            items.map { [$0.path, $0.kind.rawValue, $0.projectMarker ?? "-"] },
            [
                [path("root/modern/build"), "buildOutput", "pyproject.toml"],
                [path("root/py/dist"), "distOutput", "setup.py"],
                [path("root/rust/target"), "rustTarget", "Cargo.toml"],
                [path("root/web/build"), "buildOutput", "package.json"]
            ]
        )
    }

    /// `target` 只认 `Cargo.toml`：Xcode 工程里的 `target` 目录不该被当成 Rust 产物。
    func testTargetRequiresCargoManifest() throws {
        try temporaryDirectory.makeFile("root/xcode/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/xcode/target")

        let items = try discoverItems()

        XCTAssertTrue(items.isEmpty)
    }

    func testPythonCacheMatchesUnconditionally() throws {
        try temporaryDirectory.makeDirectory("root/scripts/__pycache__")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.path), [path("root/scripts/__pycache__")])
        XCTAssertEqual(items[0].kind, .pythonCache)
        XCTAssertNil(items[0].projectMarker, "无条件命中没有标记依据可展示")
    }

    /// 名为 `package.json` 的**目录**只是巧合，不能算工程根。
    func testMarkerMustNotBeADirectory() throws {
        try temporaryDirectory.makeDirectory("root/app/package.json")
        try temporaryDirectory.makeDirectory("root/app/node_modules")

        let items = try discoverItems()

        XCTAssertTrue(items.isEmpty)
    }

    /// monorepo 里 `package.json` 可能是指向共享清单的符号链接，仍算工程根。
    func testMarkerMayBeSymlink() throws {
        try temporaryDirectory.makeFile("root/shared.json", bytes: 10)
        try temporaryDirectory.makeSymlink("root/app/package.json", destination: "../shared.json")
        try temporaryDirectory.makeDirectory("root/app/node_modules")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.path), [path("root/app/node_modules")])
    }

    // MARK: - 剪枝与深度

    /// 命中即剪枝：`node_modules` 内部还有成百上千个嵌套依赖目录，报第二层起的任何一个都无意义。
    func testPrunesNestedCandidatesInsideAHit() throws {
        try temporaryDirectory.makeFile("root/app/package.json", bytes: 10)
        try temporaryDirectory.makeFile("root/app/node_modules/lib/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/app/node_modules/lib/node_modules")
        try temporaryDirectory.makeDirectory("root/app/node_modules/lib/__pycache__")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.path), [path("root/app/node_modules")])
    }

    /// 深度上限 6：根为 0，第 6 层仍参与判定，第 7 层不再枚举。
    func testHonorsDepthLimit() throws {
        try temporaryDirectory.makeFile("root/a/b/c/d/e/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/a/b/c/d/e/node_modules")
        try temporaryDirectory.makeFile("root/a/b/c/d/e/f/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/a/b/c/d/e/f/node_modules")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.path), [path("root/a/b/c/d/e/node_modules")])
    }

    func testDepthLimitIsConfigurable() throws {
        try temporaryDirectory.makeFile("root/a/b/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/a/b/node_modules")
        discovery = DiskCleanPurgeDiscovery(maximumDepth: 2)

        let items = try discoverItems()

        XCTAssertTrue(items.isEmpty, "深度 3 的候选在上限 2 下不该被发现")
    }

    // MARK: - 符号链接

    /// 目录符号链接一律不跟随：跟随会走出扫描根，把用户没授权的目录也扫进来。
    func testDoesNotFollowDirectorySymlink() throws {
        try temporaryDirectory.makeFile("outside/app/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("outside/app/node_modules")
        try temporaryDirectory.makeDirectory("root")
        try temporaryDirectory.makeSymlink("root/link", destination: "../outside")

        let items = try discoverItems()

        XCTAssertTrue(items.isEmpty)
    }

    /// 名为 `node_modules` 的符号链接不是候选：删它删掉的是链接，不是依赖目录。
    func testDoesNotReportSymlinkNamedLikeATarget() throws {
        try temporaryDirectory.makeFile("root/app/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("outside/real_modules")
        try temporaryDirectory.makeSymlink("root/app/node_modules", destination: "../../outside/real_modules")

        let items = try discoverItems()

        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - 根状态

    func testReportsUnreadableRootForMissingDirectory() {
        let report = discovery.discover(root: path("root"))

        XCTAssertEqual(report.status, .unreadable(reason: .walkError))
        XCTAssertTrue(report.items.isEmpty)
    }

    func testReportsPermissionDeniedRoot() throws {
        try temporaryDirectory.makeDirectory("root")
        try temporaryDirectory.denyAccess(to: "root")

        let report = discovery.discover(root: path("root"))

        XCTAssertEqual(report.status, .unreadable(reason: .permissionDenied))
    }

    func testReportsUnreadableWhenRootIsAFile() throws {
        try temporaryDirectory.makeFile("root", bytes: 4)

        let report = discovery.discover(root: path("root"))

        XCTAssertEqual(report.status, .unreadable(reason: .walkError))
    }

    /// 子树不可读只降级完整性，不影响其它子树的候选。
    func testUnreadableSubtreeDegradesCompleteness() throws {
        try temporaryDirectory.makeFile("root/app/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/app/node_modules")
        try temporaryDirectory.makeDirectory("root/locked/inner")
        try temporaryDirectory.denyAccess(to: "root/locked")

        let report = discovery.discover(root: path("root"))

        XCTAssertEqual(report.items.map(\.path), [path("root/app/node_modules")])
        XCTAssertEqual(report.status, .traversed(completeness: .partial(reasons: [.permissionDenied])))
    }

    /// 取消不能伪装成"扫完了"：结果必须带 timedOut。
    func testCancellationMarksResultIncomplete() throws {
        try temporaryDirectory.makeDirectory("root/a")

        let report = discovery.discover(root: path("root"), isCancelled: { true })

        XCTAssertEqual(report.status, .traversed(completeness: .partial(reasons: [.timedOut])))
        XCTAssertTrue(report.items.isEmpty)
    }

    // MARK: - 仓库归属

    func testAttributesCandidateToNearestRepository() throws {
        try temporaryDirectory.makeDirectory("root/repo/.git")
        try temporaryDirectory.makeFile("root/repo/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/repo/node_modules")
        try temporaryDirectory.makeDirectory("root/repo/vendor/inner/.git")
        try temporaryDirectory.makeFile("root/repo/vendor/inner/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/repo/vendor/inner/node_modules")

        let items = try discoverItems()

        XCTAssertEqual(
            items.map(\.repositoryPath),
            [path("root/repo"), path("root/repo/vendor/inner")]
        )
    }

    /// worktree / submodule 的 `.git` 是文件而不是目录，同样算仓库。
    func testTreatsGitFileAsRepository() throws {
        try temporaryDirectory.makeFile("root/repo/.git", bytes: 20)
        try temporaryDirectory.makeFile("root/repo/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/repo/node_modules")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.repositoryPath), [path("root/repo")])
    }

    func testRootItselfCanBeTheRepository() throws {
        try temporaryDirectory.makeDirectory("root/.git")
        try temporaryDirectory.makeFile("root/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/node_modules")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.repositoryPath), [path("root")])
    }

    func testReportsNoRepositoryWhenGitIsAboveTheRoot() throws {
        try temporaryDirectory.makeDirectory(".git")
        try temporaryDirectory.makeFile("root/app/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/app/node_modules")

        let items = try discoverItems()

        XCTAssertEqual(items.map(\.repositoryPath), [nil])
    }

    // MARK: - git 三态

    func testMarksRepositoryCleanWhenBothChecksAreEmpty() async throws {
        try makeSingleRepositoryLayout()
        let runner = ScriptedDiskCleanSubprocessRunner()

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(candidate.gitState, .clean(repositoryPath: path("root/repo")))
        XCTAssertTrue(candidate.isSelectedByDefault)
        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(
            runner.invocations[0],
            ["-C", path("root/repo"), "status", "--porcelain", "-unormal"]
        )
        XCTAssertEqual(
            runner.invocations[1],
            ["-C", path("root/repo"), "log", "--branches", "--not", "--remotes", "-n", "1"]
        )
    }

    func testMarksRepositoryDirtyOnUncommittedChanges() async throws {
        try makeSingleRepositoryLayout()
        let runner = ScriptedDiskCleanSubprocessRunner(statusOutput: " M src/main.rs\n")

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(
            candidate.gitState,
            .dirty(repositoryPath: path("root/repo"), reason: .uncommittedChanges)
        )
        XCTAssertFalse(candidate.isSelectedByDefault)
        XCTAssertEqual(runner.invocations.count, 1, "status 已判定为脏，不必再查未推送提交")
    }

    func testMarksRepositoryDirtyOnUnpushedCommits() async throws {
        try makeSingleRepositoryLayout()
        let runner = ScriptedDiskCleanSubprocessRunner(logOutput: "9f1c2ab\n")

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(
            candidate.gitState,
            .dirty(repositoryPath: path("root/repo"), reason: .unpushedCommits)
        )
        XCTAssertFalse(candidate.isSelectedByDefault)
    }

    /// 超时按有改动处理（fail-safe）：查不出来时误判为"干净"可能让用户删掉还需要的东西。
    func testTimeoutIsTreatedAsDirty() async throws {
        try makeSingleRepositoryLayout()
        let runner = ScriptedDiskCleanSubprocessRunner(
            error: DiskCleanSubprocessError.timedOut(path: DiskCleanGitStatusInspector.executablePath)
        )

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(
            candidate.gitState,
            .dirty(repositoryPath: path("root/repo"), reason: .inspectionFailed("git 检查超时"))
        )
        XCTAssertFalse(candidate.isSelectedByDefault)
    }

    func testMissingGitExecutableIsTreatedAsDirty() async throws {
        try makeSingleRepositoryLayout()
        let runner = ScriptedDiskCleanSubprocessRunner(
            error: DiskCleanSubprocessError.executableUnavailable(path: "/usr/bin/git")
        )

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(
            candidate.gitState,
            .dirty(repositoryPath: path("root/repo"), reason: .inspectionFailed("未找到 git"))
        )
    }

    func testNonZeroExitIsTreatedAsDirty() async throws {
        try makeSingleRepositoryLayout()
        let runner = ScriptedDiskCleanSubprocessRunner(statusExitCode: 128)

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(
            candidate.gitState,
            .dirty(repositoryPath: path("root/repo"), reason: .inspectionFailed("status 退出码 128"))
        )
    }

    /// 不在仓库里的候选不该 spawn 任何子进程。
    func testSkipsGitInspectionOutsideRepositories() async throws {
        try temporaryDirectory.makeFile("root/app/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/app/node_modules")
        let runner = ScriptedDiskCleanSubprocessRunner()

        let candidate = try await scanSingleCandidate(runner: runner)

        XCTAssertEqual(candidate.gitState, .notInRepository)
        XCTAssertTrue(candidate.isSelectedByDefault)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    /// 一个仓库下常有几十个 `node_modules`，逐个查会把 2 秒超时乘上几十倍。
    func testInspectsEachRepositoryOnlyOnce() async throws {
        try temporaryDirectory.makeDirectory("root/repo/.git")
        try temporaryDirectory.makeFile("root/repo/a/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/repo/a/node_modules")
        try temporaryDirectory.makeFile("root/repo/b/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/repo/b/node_modules")
        let runner = ScriptedDiskCleanSubprocessRunner()

        let result = await makeScanner(runner: runner).scan(roots: [path("root")])

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(runner.invocations.count, 2, "两条命令各一次，与候选数无关")
    }

    // MARK: - 扫描器汇总

    func testReportsUnreadableRootsSeparatelyFromEmptyResults() async throws {
        try temporaryDirectory.makeDirectory("present")
        let runner = ScriptedDiskCleanSubprocessRunner()

        let result = await makeScanner(runner: runner).scan(
            roots: [path("present"), path("missing")]
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.unreadableRoots, [path("missing")])
    }

    // MARK: - 挂载防护

    /// 子目录 devid 与根不同（= 该位置挂载了别的卷）→ 不下潜、不命中、完整性记 crossedMountPoint。
    /// 真实文件系统上无法 mount，只能靠注入条目源（与 DirectoryTreeWalker 同套路）。
    ///
    /// 真实 FS 上 `Mounted/` 下故意放可命中的 `node_modules`：脚本源不会读到它，
    /// 所以断言靠 `createdSourceCount`——错误下潜会多一次 `makeSource`。
    func testDoesNotDescendIntoDirectoryOnAnotherDevice() throws {
        // 真实目录必须存在：脚本源只控制"看到什么"，下潜仍走真实 openat。
        // `Mounted` 下故意放可命中的 node_modules——若错误下潜，会在真实 FS 上被发现。
        let root = try temporaryDirectory.makeDirectory("root")
        try temporaryDirectory.makeFile("root/Mounted/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/Mounted/node_modules")
        try temporaryDirectory.makeDirectory("root/local")
        let rootDevice = try deviceID(of: root.path)

        let factory = ScriptedPurgeSourceFactory(scripts: [
            [[
                .resolved(entry(
                    name: "Mounted",
                    type: .directory,
                    devid: rootDevice &+ 1,
                    fileID: 77
                )),
                .resolved(entry(
                    name: "local",
                    type: .directory,
                    devid: rootDevice,
                    fileID: 78
                )),
            ]],
            // 仅当同设备的 `local` 被下潜时才会创建第二个 source。
            [[
                .resolved(entry(
                    name: "__pycache__",
                    type: .directory,
                    devid: rootDevice,
                    fileID: 79
                )),
            ]],
        ])
        discovery = DiskCleanPurgeDiscovery(sourceFactory: factory)

        let report = discovery.discover(root: root.path)

        guard case let .traversed(completeness) = report.status else {
            return XCTFail("expected traversed, got \(report.status)")
        }
        XCTAssertEqual(completeness, .partial(reasons: [.crossedMountPoint]))
        XCTAssertEqual(report.items.map(\.path), [root.path + "/local/__pycache__"])
        XCTAssertFalse(
            report.items.contains { $0.path.contains("/Mounted/") },
            "跨设备子树内的候选不得被发现"
        )
        XCTAssertEqual(factory.createdSourceCount, 2, "跨设备目录不得被 openat 下潜")
    }

    // MARK: - 夹具

    private func path(_ relativePath: String) -> String {
        temporaryDirectory.resolve(relativePath).path
    }

    private func discoverItems() throws -> [DiskCleanPurgeDiscoveredItem] {
        discovery.discover(root: path("root")).items
    }

    private func makeSingleRepositoryLayout() throws {
        try temporaryDirectory.makeDirectory("root/repo/.git")
        try temporaryDirectory.makeFile("root/repo/package.json", bytes: 10)
        try temporaryDirectory.makeDirectory("root/repo/node_modules")
    }

    private func makeScanner(runner: ScriptedDiskCleanSubprocessRunner) -> DiskCleanPurgeScanner {
        DiskCleanPurgeScanner(
            discovery: discovery,
            inspector: DiskCleanGitStatusInspector(runner: runner)
        )
    }

    private func scanSingleCandidate(
        runner: ScriptedDiskCleanSubprocessRunner
    ) async throws -> DiskCleanPurgeCandidate {
        let result = await makeScanner(runner: runner).scan(roots: [path("root")])
        return try XCTUnwrap(result.candidates.first)
    }

    private func deviceID(of path: String) throws -> UInt64 {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return UInt64(UInt32(bitPattern: status.st_dev))
    }

    private func entry(
        name: String,
        type: DiskCleanRootIdentity.FileType,
        devid: UInt64,
        fileID: UInt64,
        linkCount: UInt32 = 1,
        dataLength: Int64 = 0
    ) -> DiskCleanResolvedEntry {
        DiskCleanResolvedEntry(
            nameBytes: Array(name.utf8).map { CChar(bitPattern: $0) } + [0],
            fileType: type,
            devid: devid,
            fileID: fileID,
            linkCount: linkCount,
            dataLength: dataLength
        )
    }
}

/// 按脚本回放条目批次的伪造 source 工厂。第 n 个被创建的 source 使用 scripts[n]。
/// 与 `DiskCleanDirectoryTreeWalkerTests` 同套路，刻意不共享——两边各测各的约束。
private final class ScriptedPurgeSourceFactory: DiskCleanDirectoryEntrySourceFactory, @unchecked Sendable {
    private let scripts: [[[DiskCleanWalkEntry]]]
    private let lock = NSLock()
    private var sources: [ScriptedPurgeSource] = []

    init(scripts: [[[DiskCleanWalkEntry]]]) {
        self.scripts = scripts
    }

    var createdSourceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sources.count
    }

    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        lock.lock()
        let index = sources.count
        lock.unlock()

        let source = ScriptedPurgeSource(
            fileDescriptor: fileDescriptor,
            batches: index < scripts.count ? scripts[index] : []
        )
        lock.lock()
        sources.append(source)
        lock.unlock()
        return source
    }
}

private final class ScriptedPurgeSource: DiskCleanDirectoryEntrySource {
    let directoryFileDescriptor: Int32
    private var batches: [[DiskCleanWalkEntry]]
    private(set) var isClosed = false

    init(fileDescriptor: Int32, batches: [[DiskCleanWalkEntry]]) {
        self.directoryFileDescriptor = fileDescriptor
        self.batches = batches
    }

    func nextBatch() throws -> [DiskCleanWalkEntry]? {
        guard !batches.isEmpty else { return nil }
        return batches.removeFirst()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(directoryFileDescriptor)
    }
}

/// 可按命令分别编程的子进程 fake。既有的 `FakeDiskCleanSubprocessRunner` 对所有调用返回同一
/// 结果，无法覆盖"status 干净但 log 有输出"这一格。
final class ScriptedDiskCleanSubprocessRunner: DiskCleanSubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let statusResult: Result<DiskCleanSubprocessResult, Error>
    private let logResult: Result<DiskCleanSubprocessResult, Error>

    init(
        statusOutput: String = "",
        statusExitCode: Int32 = 0,
        logOutput: String = "",
        logExitCode: Int32 = 0
    ) {
        self.statusResult = .success(
            DiskCleanSubprocessResult(exitCode: statusExitCode, standardOutput: Data(statusOutput.utf8))
        )
        self.logResult = .success(
            DiskCleanSubprocessResult(exitCode: logExitCode, standardOutput: Data(logOutput.utf8))
        )
    }

    init(error: Error) {
        self.statusResult = .failure(error)
        self.logResult = .failure(error)
    }

    var invocations: [[String]] { lock.withLock { recorded } }

    func run(
        executablePath: String,
        arguments: [String],
        timeout: Duration
    ) async throws -> DiskCleanSubprocessResult {
        lock.withLock { recorded.append(arguments) }
        XCTAssertEqual(executablePath, DiskCleanGitStatusInspector.executablePath)
        XCTAssertEqual(timeout, .seconds(2))
        return try (arguments.contains("status") ? statusResult : logResult).get()
    }
}
