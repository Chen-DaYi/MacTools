import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// UI state for purge-root management (design §10.1 settings).
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

    // MARK: - Scope linkage

    /// Any root change must push the new scope to the section controller, or users may clean with stale results against a just-removed folder.
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

    /// Rejected additions leave the root set unchanged; do not fake a scope change or the UI will spuriously prompt to rescan.
    func testRejectedAdditionDoesNotNotifyScopeChange() {
        let model = makeModel(persisted: ["/code"])
        var observed: [[String]] = []
        model.onRootsChange = { observed.append($0) }

        model.add("/code")

        XCTAssertEqual(model.roots, ["/code"])
        XCTAssertTrue(observed.isEmpty)
    }

    // MARK: - Rejection feedback

    func testDuplicateAdditionSurfacesReason() {
        let model = makeModel(persisted: ["/code"])

        model.add("/code")

        XCTAssertEqual(model.rejections, [.duplicate(path: "/code")])
    }

    /// Ancestor adjudication keeps the ancestor and drops the descendant; the dropped path needs a readable reason.
    /// Silent discard makes users think they mis-clicked and try again.
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

    func testTooBroadRootSurfacesReasonWithoutChangingScope() {
        let model = makeModel(persisted: ["/code"])
        var observed: [[String]] = []
        model.onRootsChange = { observed.append($0) }

        model.add(NSHomeDirectory())

        XCTAssertEqual(model.roots, ["/code"])
        XCTAssertEqual(model.rejections, [.tooBroad(path: NSHomeDirectory())])
        XCTAssertTrue(observed.isEmpty)
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

    // MARK: - Persistence

    func testAdditionsAndRemovalsArePersisted() {
        let persistence = InMemoryPurgeRootsPersistence(roots: [])
        let model = makeModel(persistence: persistence)

        model.add("/code")
        model.add("/work")
        model.remove("/code")

        XCTAssertEqual(persistence.loadRoots(), ["/work"])
    }

    // MARK: - Helpers

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

/// In-memory persistence. Never touch `UserDefaults.standard` — that is the user's real config.
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
