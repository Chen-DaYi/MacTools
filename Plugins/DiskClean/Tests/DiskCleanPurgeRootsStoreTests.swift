import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanPurgeRootsStoreTests: XCTestCase {
    private var temporaryDirectory: DiskCleanTempDirectory!
    private var persistence: InMemoryDiskCleanPurgeRootsPersistence!
    private var store: DiskCleanPurgeRootsStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try DiskCleanTempDirectory(name: "DiskCleanPurgeRootsStoreTests")
        persistence = InMemoryDiskCleanPurgeRootsPersistence()
        store = DiskCleanPurgeRootsStore(persistence: persistence)
    }

    override func tearDownWithError() throws {
        temporaryDirectory?.remove()
        temporaryDirectory = nil
        persistence = nil
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - 规范化

    /// 用户可能选中一个符号链接文件夹；存进去的必须是物理路径，否则 `O_NOFOLLOW_ANY` 会拒绝整棵树。
    func testStoresPhysicalPathForSymlinkedRoot() throws {
        let real = try temporaryDirectory.makeDirectory("Projects")
        let link = try temporaryDirectory.makeSymlink("ProjectsLink", destination: "Projects")

        let update = store.add(link.path)

        XCTAssertEqual(update.roots, [real.path])
        XCTAssertEqual(persistence.storedRoots, [real.path])
    }

    /// 同一目录的两种写法只保留一条。
    func testRejectsDuplicateAfterNormalization() throws {
        let real = try temporaryDirectory.makeDirectory("Code")
        try temporaryDirectory.makeSymlink("CodeLink", destination: "Code")

        store.add(real.path)
        let update = store.add(temporaryDirectory.resolve("CodeLink").path)

        XCTAssertEqual(update.roots, [real.path])
        XCTAssertEqual(update.rejections.count, 1)
        guard case .duplicate = update.rejections[0] else {
            return XCTFail("重复根应报 duplicate，实际 \(update.rejections[0])")
        }
    }

    /// 尾部斜杠不该制造出第二条根。
    func testTrailingSlashIsNotADistinctRoot() throws {
        let real = try temporaryDirectory.makeDirectory("Work")

        store.add(real.path)
        let update = store.add(real.path + "/")

        XCTAssertEqual(update.roots, [real.path])
    }

    // MARK: - 祖先裁决

    func testDropsDescendantWhenAncestorIsAdded() throws {
        let ancestor = try temporaryDirectory.makeDirectory("Repos")
        let descendant = try temporaryDirectory.makeDirectory("Repos/app")

        let update = store.replaceAll(with: [ancestor.path, descendant.path])

        XCTAssertEqual(update.roots, [ancestor.path])
        XCTAssertEqual(update.rejections, [.coveredByAncestor(path: descendant.path, ancestor: ancestor.path)])
    }

    /// 裁决与添加顺序无关：先加后代再加祖先，同样是留祖先。缩小用户明确要求的范围才是更糟的失效。
    func testDropsDescendantEvenWhenItWasAddedFirst() throws {
        let ancestor = try temporaryDirectory.makeDirectory("Repos")
        let descendant = try temporaryDirectory.makeDirectory("Repos/app")

        store.add(descendant.path)
        let update = store.add(ancestor.path)

        XCTAssertEqual(update.roots, [ancestor.path])
        XCTAssertEqual(persistence.storedRoots, [ancestor.path])
    }

    /// 前缀相同但不是祖先：`/tmp/x/Repos` 不覆盖 `/tmp/x/ReposBackup`。
    func testKeepsSiblingWithSharedPrefix() throws {
        let first = try temporaryDirectory.makeDirectory("Repos")
        let second = try temporaryDirectory.makeDirectory("ReposBackup")

        let update = store.replaceAll(with: [first.path, second.path])

        XCTAssertEqual(update.roots, [first.path, second.path])
        XCTAssertTrue(update.rejections.isEmpty)
    }

    func testAncestorCheckIgnoresSelf() {
        XCTAssertFalse(DiskCleanPurgeRootNormalizer.isStrictAncestor("/a/b", of: "/a/b"))
        XCTAssertTrue(DiskCleanPurgeRootNormalizer.isStrictAncestor("/a/b", of: "/a/b/c"))
        XCTAssertFalse(DiskCleanPurgeRootNormalizer.isStrictAncestor("/a/b", of: "/a/bc"))
        XCTAssertTrue(DiskCleanPurgeRootNormalizer.isStrictAncestor("/", of: "/a"))
    }

    // MARK: - 不可解析

    func testRejectsMissingPath() {
        let missing = temporaryDirectory.resolve("NotThere").path

        let update = store.add(missing)

        XCTAssertTrue(update.roots.isEmpty)
        XCTAssertEqual(update.rejections, [.unresolvable(path: missing)])
    }

    /// 相对路径会被 `realpath` 按当前工作目录解析成一个用户根本没选的目录，必须直接拒收。
    func testRejectsRelativePath() {
        let update = store.add("Documents/Code")

        XCTAssertTrue(update.roots.isEmpty)
        XCTAssertEqual(update.rejections, [.unresolvable(path: "Documents/Code")])
    }

    func testExpandsTildePrefix() throws {
        let resolved = DiskCleanPurgeRootNormalizer.normalize(["~/Anywhere"]) { path in
            path.hasPrefix(NSHomeDirectory() + "/") ? path : nil
        }

        XCTAssertEqual(resolved.roots, [NSHomeDirectory() + "/Anywhere"])
    }

    // MARK: - 增删

    func testRemoveMatchesOriginalSpellingWhenPathIsGone() throws {
        let directory = try temporaryDirectory.makeDirectory("Gone")
        store.add(directory.path)
        try FileManager.default.removeItem(at: directory)

        let remaining = store.remove(directory.path)

        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(persistence.storedRoots.isEmpty)
    }

    func testRemoveMatchesPhysicalPathForSymlinkedSpelling() throws {
        let real = try temporaryDirectory.makeDirectory("Live")
        let link = try temporaryDirectory.makeSymlink("LiveLink", destination: "Live")
        store.add(real.path)

        let remaining = store.remove(link.path)

        XCTAssertTrue(remaining.isEmpty)
    }

    func testRootsReturnsStoredValuesUnchanged() {
        persistence.storedRoots = ["/tmp/one", "/tmp/two"]

        XCTAssertEqual(store.roots(), ["/tmp/one", "/tmp/two"])
    }

    // MARK: - UserDefaults 实现

    func testUserDefaultsPersistenceRoundTrip() throws {
        let suiteName = "DiskCleanPurgeRootsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = UserDefaultsDiskCleanPurgeRootsPersistence(defaults: defaults)

        XCTAssertTrue(persistence.loadRoots().isEmpty)
        persistence.saveRoots(["/tmp/a", "/tmp/b"])

        XCTAssertEqual(persistence.loadRoots(), ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(
            defaults.stringArray(forKey: UserDefaultsDiskCleanPurgeRootsPersistence.defaultsKey),
            ["/tmp/a", "/tmp/b"]
        )
    }
}

/// 内存持久化：扫描根测试绝不触碰 `UserDefaults.standard`。
final class InMemoryDiskCleanPurgeRootsPersistence: DiskCleanPurgeRootsPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [String] = []

    var storedRoots: [String] {
        get { lock.withLock { roots } }
        set { lock.withLock { roots = newValue } }
    }

    func loadRoots() -> [String] {
        storedRoots
    }

    func saveRoots(_ roots: [String]) {
        storedRoots = roots
    }
}
