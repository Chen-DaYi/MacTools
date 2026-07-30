import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// Behavior contract for the verify-freeze-delete primitive (design §7.3, §7.4).
///
/// **All real syscalls and temp directories**: correctness rests on real `renameatx_np` / `fstatat` /
/// `unlinkat` semantics; a fake filesystem would test nothing. The only injections are trash
/// (must not touch the user's real Trash) and entry device IDs (mount crossing cannot be fabricated in a temp dir).
@MainActor
final class DiskCleanRemovalPrimitiveTests: XCTestCase {
    private var temporary: DiskCleanTempDirectory!
    private var storage: DiskCleanTempDirectory!
    private var journal: DiskCleanStagingJournal!
    /// Directories made read-only must have permissions restored before teardown or cleanup fails.
    private var restrictedDirectories: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporary = try DiskCleanTempDirectory(name: "diskclean-primitive")
        storage = try DiskCleanTempDirectory(name: "diskclean-primitive-state")
        journal = DiskCleanStagingJournal(directory: storage.url)
    }

    override func tearDown() {
        for path in restrictedDirectories {
            chmod(path, 0o755)
        }
        restrictedDirectories.removeAll()
        temporary?.remove()
        storage?.remove()
        temporary = nil
        storage = nil
        journal = nil
        super.tearDown()
    }

    // MARK: - Permanent delete

    func testPermanentModeDeletesDirectoryTreeAndLeavesNoStagedRemnant() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        try temporary.makeFile("Cache/Nested/b.bin", bytes: 20)
        try temporary.makeDirectory("Cache/Empty")
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .removed)
        assertPathDoesNotExist(target)
        XCTAssertEqual(stagedNames(in: temporary.path), [], "successful delete must leave no staged remnants")
        XCTAssertTrue(journal.incompleteEntries().isEmpty, "successful disposition must clear the journal")
    }

    func testPermanentModeDeletesRegularFileWithoutPrewalk() throws {
        try temporary.makeFile("installer.dmg", bytes: 512)
        let target = temporary.resolve("installer.dmg").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .removed)
        assertPathDoesNotExist(target)
    }

    /// Symlink candidates remove the link itself and never follow.
    func testSymlinkCandidateRemovesLinkItselfAndKeepsTarget() throws {
        try temporary.makeFile("Outside/precious.bin", bytes: 4_096)
        try temporary.makeSymlink("Link/toOutside", destination: "../Outside")
        let target = temporary.resolve("Link/toOutside").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .removed)
        assertPathDoesNotExist(target)
        assertPathExists(temporary.resolve("Outside/precious.bin").path, "must not follow the link and delete the target")
    }

    // MARK: - Path swap (core race in §7.3)

    /// After identity is recorded, replace the target with a symlink elsewhere → refuse; link and target stay intact.
    func testTargetReplacedWithSymlinkAfterPlanIsRefused() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        try temporary.makeFile("Precious/data.bin", bytes: 8_192)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        // After plan minting, before execution: target swapped for a symlink into user data.
        try FileManager.default.removeItem(atPath: target)
        try FileManager.default.createSymbolicLink(
            atPath: target,
            withDestinationPath: temporary.resolve("Precious").path
        )

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .changedSinceScan)
        assertPathExists(target, "the replacement symlink itself must not be touched")
        assertPathExists(temporary.resolve("Precious/data.bin").path, "user data behind the link must remain intact")
        XCTAssertTrue(journal.incompleteEntries().isEmpty, "identity mismatch must not rename")
    }

    /// After identity is recorded, replace with a same-name directory (different fileID) → refuse; new contents intact.
    func testTargetReplacedWithSameNameDirectoryIsRefused() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        try FileManager.default.removeItem(atPath: target)
        try temporary.makeFile("Cache/brand-new.bin", bytes: 20)

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .changedSinceScan)
        assertPathExists(temporary.resolve("Cache/brand-new.bin").path, "contents of the same-name replacement must stay intact")
    }

    /// Middle path component swapped for a symlink → `O_NOFOLLOW_ANY` fails when opening the parent; never delete through the link.
    func testMiddleComponentReplacedWithSymlinkIsRefused() throws {
        try temporary.makeDirectory("Parent")
        try temporary.makeFile("Parent/Cache/a.bin", bytes: 10)
        try temporary.makeFile("Elsewhere/Cache/precious.bin", bytes: 8_192)
        let target = temporary.resolve("Parent/Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        try FileManager.default.removeItem(atPath: temporary.resolve("Parent").path)
        try FileManager.default.createSymbolicLink(
            atPath: temporary.resolve("Parent").path,
            withDestinationPath: temporary.resolve("Elsewhere").path
        )

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        guard case .failed = disposition else {
            return XCTFail("middle-component symlink must fail, got: \(disposition)")
        }
        assertPathExists(temporary.resolve("Elsewhere/Cache/precious.bin").path, "data behind the link must stay intact")
    }

    /// Directory contents change after scan (root mtime changes) → refuse and force a rescan.
    func testDirectoryModifiedAfterPlanIsRefused() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        try temporary.makeFile("Cache/added-later.bin", bytes: 5)

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .changedSinceScan)
        assertPathExists(temporary.resolve("Cache/added-later.bin").path)
    }

    /// Regular-file size mismatches the plan → refuse (second evidence when mtime is preserved).
    func testRegularFileWithDifferentSizeIsRefused() throws {
        try temporary.makeFile("log.txt", bytes: 100)
        let target = temporary.resolve("log.txt").path
        // Size mismatches while other identity fields match — only size comparison can catch this.
        let candidate = DiskCleanPlanFactory.candidate(
            path: target,
            identity: try XCTUnwrap(DiskCleanPlanFactory.currentIdentity(ofItemAt: target)),
            bytes: 999
        )
        let plan = try DiskCleanPlanner.makePlan(
            artifact: DiskCleanPlanFactory.artifact(candidates: [candidate]),
            selectedIDs: [candidate.id],
            mode: .permanent,
            now: DiskCleanPlanFactory.observedAt,
            catalog: DiskCleanPlanFactory.catalog()
        )

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .changedSinceScan)
        assertPathExists(target)
    }

    // MARK: - Freeze semantics

    /// After freeze, anything appearing at the original path is unrelated — the object has left that name.
    func testStagedObjectIsDetachedFromOriginalPath() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target], mode: .trash)
        let recreatedMarker = temporary.resolve("Cache/recreated.bin").path

        // During disposition, another "process" recreates the cache directory at the original path.
        let trash = FakeDiskCleanTrash(duringTrash: {
            try? FileManager.default.createDirectory(
                atPath: target,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: recreatedMarker, contents: Data([0x41]))
        })

        let disposition = makePrimitive(trash: trash).remove(plan.items[0], mode: .trash)

        guard case let .trashed(stagedName) = disposition else {
            return XCTFail("expected trashed, got: \(disposition)")
        }
        XCTAssertEqual(
            trash.trashedPaths,
            [DiskCleanRemovalPrimitive.join(temporary.path, stagedName)],
            "trash must operate on the staged path, not the re-resolvable original path"
        )
        assertPathExists(recreatedMarker, "object recreated at the original path is unrelated and must stay intact")
    }

    func testTrashOperatesOnStagedNameWithProtectedPrefix() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let plan = try DiskCleanPlanFactory.makePlan(paths: [temporary.resolve("Cache").path], mode: .trash)
        let trash = FakeDiskCleanTrash()

        let disposition = makePrimitive(trash: trash).remove(plan.items[0], mode: .trash)

        guard case let .trashed(stagedName) = disposition else {
            return XCTFail("expected trashed, got: \(disposition)")
        }
        XCTAssertTrue(stagedName.hasPrefix(DiskCleanRemovalPrimitive.stagedNamePrefix))
        XCTAssertTrue(journal.incompleteEntries().isEmpty)
    }

    /// Staged-name collision → retry once with a new uuid and never overwrite the placeholder (RENAME_EXCL).
    func testStagedNameCollisionRetriesWithNewNameAndNeverOverwrites() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let collidingName = DiskCleanRemovalPrimitive.stagedNamePrefix + "collision"
        try temporary.makeFile(collidingName, bytes: 7)
        let plan = try DiskCleanPlanFactory.makePlan(paths: [temporary.resolve("Cache").path])

        let names = NameSequence(names: [collidingName, DiskCleanRemovalPrimitive.stagedNamePrefix + "fresh"])
        let disposition = makePrimitive(stagedNameFactory: { names.next() }).remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .removed)
        assertPathExists(
            temporary.resolve(collidingName).path,
            "RENAME_EXCL must guarantee the placeholder is not overwritten"
        )
        XCTAssertEqual(DiskCleanPlanFactory.currentSize(ofItemAt: temporary.resolve(collidingName).path), 7)
    }

    /// If the journal cannot be written, never rename — reverse check of the ordering invariant.
    func testRenameNeverHappensWhenJournalCannotBeWritten() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        // Occupy the journal directory path with a regular file so createDirectory and writes fail.
        let blocked = try DiskCleanTempDirectory(name: "diskclean-blocked-journal")
        defer { blocked.remove() }
        try blocked.makeFile("state", bytes: 1)
        let unwritableJournal = DiskCleanStagingJournal(directory: blocked.resolve("state"))

        let disposition = DiskCleanRemovalPrimitive(journal: unwritableJournal, trash: FakeDiskCleanTrash())
            .remove(plan.items[0], mode: .permanent)

        guard case .failed = disposition else {
            return XCTFail("unwritable journal must fail, got: \(disposition)")
        }
        assertPathExists(target, "object must be untouched when journal write fails")
        XCTAssertEqual(stagedNames(in: temporary.path), [])
    }

    // MARK: - Rollback

    func testTrashFailureRollsBackToOriginalPath() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target], mode: .trash)

        let disposition = makePrimitive(trash: FakeDiskCleanTrash(shouldFail: true))
            .remove(plan.items[0], mode: .trash)

        guard case .failed = disposition else {
            return XCTFail("expected failed, got: \(disposition)")
        }
        assertPathExists(temporary.resolve("Cache/a.bin").path, "original path must be intact after rollback")
        XCTAssertEqual(stagedNames(in: temporary.path), [])
        XCTAssertTrue(journal.incompleteEntries().isEmpty, "successful rollback clears the journal")
    }

    /// On rollback the original path was recreated → never overwrite: keep the staged object; leave the journal entry for reconciliation.
    func testRollbackBlockedWhenOriginalPathWasRecreated() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target], mode: .trash)
        let recreatedMarker = temporary.resolve("Cache/recreated.bin").path

        let trash = FakeDiskCleanTrash(shouldFail: true, duringTrash: {
            try? FileManager.default.createDirectory(
                atPath: target,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: recreatedMarker, contents: Data([0x41]))
        })

        let disposition = makePrimitive(trash: trash).remove(plan.items[0], mode: .trash)

        guard case let .rollbackBlocked(stagedName, _) = disposition else {
            return XCTFail("expected rollbackBlocked, got: \(disposition)")
        }
        assertPathExists(recreatedMarker, "recreated original path must never be overwritten")
        assertPathExists(
            DiskCleanRemovalPrimitive.join(temporary.path, stagedName),
            "staged object must be retained for reconciliation"
        )
        XCTAssertEqual(
            journal.incompleteEntries().map(\.stagedName),
            [stagedName],
            "journal entry stays incomplete when rollback is blocked"
        )
    }

    /// Prewalk finds mount crossing → delete nothing; rename the whole tree back to the original path.
    func testPrewalkCrossingMountPointRollsBackWithoutDeleting() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        try temporary.makeFile("Cache/Nested/b.bin", bytes: 20)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        let primitive = makePrimitive(
            deviceResolver: FakeDiskCleanStagedEntryDeviceResolver(crossedMountEntryNames: ["Nested"])
        )
        let disposition = primitive.remove(plan.items[0], mode: .permanent)

        guard case let .failed(reason) = disposition else {
            return XCTFail("expected failed, got: \(disposition)")
        }
        XCTAssertTrue(reason.contains("挂载点"), "failure reason should mention mount crossing, got: \(reason)")
        assertPathExists(temporary.resolve("Cache/a.bin").path, "prewalk is non-destructive; whole tree must be intact after rollback")
        assertPathExists(temporary.resolve("Cache/Nested/b.bin").path)
        XCTAssertEqual(stagedNames(in: temporary.path), [])
    }

    // MARK: - partiallyDeleted

    /// Mid-delete unwritable subdirectory → honestly report partiallyDeleted; remnants stay under the staged name.
    ///
    /// **Deviation from design §7.4**: the journal entry is explicitly cleared rather than retained. Retention would let
    /// next-launch reconciliation rename the half-deleted broken tree back, and the app would treat it as a healthy cache.
    func testPartiallyDeletedWhenSubdirectoryIsNotWritable() throws {
        try temporary.makeFile("Cache/top.bin", bytes: 10)
        try temporary.makeFile("Cache/Locked/inner.bin", bytes: 20)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        // r-x: readable/enterable (prewalk succeeds) but not writable (unlinkat of children fails).
        let lockedPath = temporary.resolve("Cache/Locked").path
        restrictedDirectories.append(lockedPath)
        XCTAssertEqual(chmod(lockedPath, 0o555), 0)

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        guard case let .partiallyDeleted(stagedName, _) = disposition else {
            return XCTFail("expected partiallyDeleted, got: \(disposition)")
        }
        assertPathDoesNotExist(target, "object has left the original path and is not pretend-restored")
        XCTAssertEqual(
            stagedNames(in: temporary.path),
            [stagedName],
            "half-deleted remnants stay under the staged name for audit and clean history"
        )
        XCTAssertTrue(
            journal.incompleteEntries().isEmpty,
            "partiallyDeleted must clear the journal or next launch renames the broken tree back"
        )
        // Restore permissions so teardown can delete the tree.
        chmod(DiskCleanRemovalPrimitive.join(temporary.path, stagedName) + "/Locked", 0o755)
    }

    // MARK: - Fixtures

    private func makePrimitive(
        trash: any DiskCleanTrashing = FakeDiskCleanTrash(),
        deviceResolver: any DiskCleanStagedEntryDeviceResolving = DiskCleanRealStagedEntryDeviceResolver(),
        stagedNameFactory: (@Sendable () -> String)? = nil
    ) -> DiskCleanRemovalPrimitive {
        if let stagedNameFactory {
            return DiskCleanRemovalPrimitive(
                journal: journal,
                trash: trash,
                deviceResolver: deviceResolver,
                stagedNameFactory: stagedNameFactory
            )
        }
        return DiskCleanRemovalPrimitive(journal: journal, trash: trash, deviceResolver: deviceResolver)
    }
}

/// Sequential staged-name factory for constructing RENAME_EXCL collisions.
private final class NameSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String]

    init(names: [String]) {
        self.names = names
    }

    func next() -> String {
        lock.withLock {
            guard !names.isEmpty else { return DiskCleanRemovalPrimitive.stagedNamePrefix + UUID().uuidString }
            return names.removeFirst()
        }
    }
}
