import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 扫描根管理的界面状态（设计 §10.1 设置区）。
@MainActor
final class DiskCleanPurgeRootsModelTests: XCTestCase {
    func testLoadsPersistedRootsOnInit() {
        let model = makeModel(persisted: ["/code", "/work"])

        XCTAssertEqual(model.roots, ["/code", "/work"])
        XCTAssertEqual(model.scope, .developerArtifacts(roots: ["/code", "/work"]))
        XCTAssertFalse(model.isEmpty)
    }

    func testStartsEmptyByDefault() {
        let model = makeModel()

        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.scope, .developerArtifacts(roots: []))
    }

    // MARK: - 范围联动

    /// 根一变就得把新范围推给分段 Controller，否则用户会拿着旧结果去清理刚移除的文件夹。
    func testAddingRootNotifiesScopeChange() {
        let model = makeModel()
        var observed: [[String]] = []
        model.onRootsChange = { observed.append($0) }

        model.add("/code")

        XCTAssertEqual(model.roots, ["/code"])
        XCTAssertEqual(observed, [["/code"]])
    }

    func testRemovingRootNotifiesScopeChange() {
        let model = makeModel(persisted: ["/code", "/work"])
        var observed: [[String]] = []
        model.onRootsChange = { observed.append($0) }

        model.remove("/code")

        XCTAssertEqual(model.roots, ["/work"])
        XCTAssertEqual(observed, [["/work"]])
    }

    /// 被拒收时根集合没变，不该假装范围变了——否则界面会白白提示一次"请重新扫描"。
    func testRejectedAdditionDoesNotNotifyScopeChange() {
        let model = makeModel(persisted: ["/code"])
        var observed: [[String]] = []
        model.onRootsChange = { observed.append($0) }

        model.add("/code")

        XCTAssertEqual(model.roots, ["/code"])
        XCTAssertTrue(observed.isEmpty)
    }

    // MARK: - 拒收反馈

    func testDuplicateAdditionSurfacesReason() {
        let model = makeModel(persisted: ["/code"])

        model.add("/code")

        XCTAssertEqual(model.rejections, [.duplicate(path: "/code")])
    }

    /// 祖先裁决保留祖先、弃后代——被弃的那一条必须给出可读理由，
    /// 静默丢弃会让用户以为自己点错了然后再选一次。
    func testDescendantAdditionSurfacesCoveringAncestor() {
        let model = makeModel(persisted: ["/code"])

        model.add("/code/app")

        XCTAssertEqual(model.roots, ["/code"])
        XCTAssertEqual(model.rejections, [.coveredByAncestor(path: "/code/app", ancestor: "/code")])
    }

    func testUnresolvablePathSurfacesReason() {
        let model = makeModel(resolvePhysicalPath: { _ in nil })

        model.add("/nowhere")

        XCTAssertTrue(model.roots.isEmpty)
        XCTAssertEqual(model.rejections, [.unresolvable(path: "/nowhere")])
    }

    func testSuccessfulAdditionClearsPreviousRejections() {
        let model = makeModel(persisted: ["/code"])
        model.add("/code")
        XCTAssertFalse(model.rejections.isEmpty)

        model.add("/work")

        XCTAssertTrue(model.rejections.isEmpty)
        XCTAssertEqual(model.roots, ["/code", "/work"])
    }

    func testDismissClearsRejections() {
        let model = makeModel(persisted: ["/code"])
        model.add("/code")

        model.dismissRejections()

        XCTAssertTrue(model.rejections.isEmpty)
    }

    // MARK: - 持久化

    func testAdditionsAndRemovalsArePersisted() {
        let persistence = InMemoryPurgeRootsPersistence(roots: [])
        let model = makeModel(persistence: persistence)

        model.add("/code")
        model.add("/work")
        model.remove("/code")

        XCTAssertEqual(persistence.loadRoots(), ["/work"])
    }

    // MARK: - 辅助

    private func makeModel(
        persisted: [String] = [],
        resolvePhysicalPath: @escaping @Sendable (String) -> String? = { $0 }
    ) -> DiskCleanPurgeRootsModel {
        makeModel(
            persistence: InMemoryPurgeRootsPersistence(roots: persisted),
            resolvePhysicalPath: resolvePhysicalPath
        )
    }

    private func makeModel(
        persistence: InMemoryPurgeRootsPersistence,
        resolvePhysicalPath: @escaping @Sendable (String) -> String? = { $0 }
    ) -> DiskCleanPurgeRootsModel {
        DiskCleanPurgeRootsModel(
            store: DiskCleanPurgeRootsStore(
                persistence: persistence,
                resolvePhysicalPath: resolvePhysicalPath
            )
        )
    }
}

/// 内存持久化。绝不碰 `UserDefaults.standard`——那是用户的真实配置。
private final class InMemoryPurgeRootsPersistence: DiskCleanPurgeRootsPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRoots: [String]

    init(roots: [String]) {
        self.storedRoots = roots
    }

    func loadRoots() -> [String] {
        lock.withLock { storedRoots }
    }

    func saveRoots(_ roots: [String]) {
        lock.withLock { storedRoots = roots }
    }
}
