import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 验证-冻结-删除原语的行为契约（设计 §7.3、§7.4）。
///
/// **全部使用真实 syscall 与临时目录**：这段代码的正确性完全落在 `renameatx_np` / `fstatat` /
/// `unlinkat` 的真实语义上，用 fake 文件系统测它等于什么都没测。唯二注入的是废纸篓
/// （不能碰用户真实废纸篓）与条目设备号（挂载穿越在临时目录里造不出来）。
@MainActor
final class DiskCleanRemovalPrimitiveTests: XCTestCase {
    private var temporary: DiskCleanTempDirectory!
    private var storage: DiskCleanTempDirectory!
    private var journal: DiskCleanStagingJournal!
    /// 被改成只读的目录，teardown 前必须恢复权限，否则删不掉会留垃圾。
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

    // MARK: - 永久删除

    func testPermanentModeDeletesDirectoryTreeAndLeavesNoStagedRemnant() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        try temporary.makeFile("Cache/Nested/b.bin", bytes: 20)
        try temporary.makeDirectory("Cache/Empty")
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .removed)
        assertPathDoesNotExist(target)
        XCTAssertEqual(stagedNames(in: temporary.path), [], "删干净后不应留下任何暂存残骸")
        XCTAssertTrue(journal.incompleteEntries().isEmpty, "成功处置必须销账")
    }

    func testPermanentModeDeletesRegularFileWithoutPrewalk() throws {
        try temporary.makeFile("installer.dmg", bytes: 512)
        let target = temporary.resolve("installer.dmg").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .removed)
        assertPathDoesNotExist(target)
    }

    /// symlink 候选删链接本身，绝不跟随。
    func testSymlinkCandidateRemovesLinkItselfAndKeepsTarget() throws {
        try temporary.makeFile("Outside/precious.bin", bytes: 4_096)
        try temporary.makeSymlink("Link/toOutside", destination: "../Outside")
        let target = temporary.resolve("Link/toOutside").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .removed)
        assertPathDoesNotExist(target)
        assertPathExists(temporary.resolve("Outside/precious.bin").path, "绝不能跟随链接删掉目标")
    }

    // MARK: - 路径交换（§7.3 的核心竞态）

    /// 记录身份后把目标换成指向别处的符号链接 → 拒绝，且链接与其目标都无损。
    func testTargetReplacedWithSymlinkAfterPlanIsRefused() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        try temporary.makeFile("Precious/data.bin", bytes: 8_192)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        // 计划铸造之后、执行之前：目标被换成指向用户数据的符号链接。
        try FileManager.default.removeItem(atPath: target)
        try FileManager.default.createSymbolicLink(
            atPath: target,
            withDestinationPath: temporary.resolve("Precious").path
        )

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .changedSinceScan)
        assertPathExists(target, "被换上的符号链接本身不该被触碰")
        assertPathExists(temporary.resolve("Precious/data.bin").path, "链接指向的用户数据必须无损")
        XCTAssertTrue(journal.incompleteEntries().isEmpty, "身份不符时根本没有发生改名")
    }

    /// 记录身份后换成同名新目录（fileID 不同）→ 拒绝，新目录内容无损。
    func testTargetReplacedWithSameNameDirectoryIsRefused() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        try FileManager.default.removeItem(atPath: target)
        try temporary.makeFile("Cache/brand-new.bin", bytes: 20)

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .changedSinceScan)
        assertPathExists(temporary.resolve("Cache/brand-new.bin").path, "同名新目录的内容必须无损")
    }

    /// 中间一级被换成符号链接 → `O_NOFOLLOW_ANY` 在打开父目录时就失败，绝不顺着链接删。
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
            return XCTFail("中间级 symlink 必须以失败告终，实际：\(disposition)")
        }
        assertPathExists(temporary.resolve("Elsewhere/Cache/precious.bin").path, "链接背后的数据必须无损")
    }

    /// 目录内容在扫描后发生变化（根 mtime 改变）→ 拒绝并引导重扫。
    func testDirectoryModifiedAfterPlanIsRefused() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        try temporary.makeFile("Cache/added-later.bin", bytes: 5)

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        XCTAssertEqual(disposition, .changedSinceScan)
        assertPathExists(temporary.resolve("Cache/added-later.bin").path)
    }

    /// 普通文件的大小与计划不符 → 拒绝（mtime 被保留时的第二道证据）。
    func testRegularFileWithDifferentSizeIsRefused() throws {
        try temporary.makeFile("log.txt", bytes: 100)
        let target = temporary.resolve("log.txt").path
        // 大小对不上，其余身份字段全等——只有 size 比对能拦下它。
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

    // MARK: - 冻结语义

    /// 冻结之后，原路径上出现什么都与本次处置无关——对象已经脱离那个名字。
    func testStagedObjectIsDetachedFromOriginalPath() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target], mode: .trash)
        let recreatedMarker = temporary.resolve("Cache/recreated.bin").path

        // 处置进行中，另一个"进程"在原路径上重建了缓存目录。
        let trash = FakeDiskCleanTrash(duringTrash: {
            try? FileManager.default.createDirectory(
                atPath: target,
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: recreatedMarker, contents: Data([0x41]))
        })

        let disposition = makePrimitive(trash: trash).remove(plan.items[0], mode: .trash)

        guard case let .trashed(stagedName) = disposition else {
            return XCTFail("期望 trashed，实际：\(disposition)")
        }
        XCTAssertEqual(
            trash.trashedPaths,
            [DiskCleanRemovalPrimitive.join(temporary.path, stagedName)],
            "废纸篓必须作用于暂存路径，而不是会被重新解析的原路径"
        )
        assertPathExists(recreatedMarker, "重建在原路径上的新对象与本次处置无关，必须无损")
    }

    func testTrashOperatesOnStagedNameWithProtectedPrefix() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let plan = try DiskCleanPlanFactory.makePlan(paths: [temporary.resolve("Cache").path], mode: .trash)
        let trash = FakeDiskCleanTrash()

        let disposition = makePrimitive(trash: trash).remove(plan.items[0], mode: .trash)

        guard case let .trashed(stagedName) = disposition else {
            return XCTFail("期望 trashed，实际：\(disposition)")
        }
        XCTAssertTrue(stagedName.hasPrefix(DiskCleanRemovalPrimitive.stagedNamePrefix))
        XCTAssertTrue(journal.incompleteEntries().isEmpty)
    }

    /// 暂存名冲突 → 换一个 uuid 重试一次，且绝不覆盖占位对象（RENAME_EXCL）。
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
            "RENAME_EXCL 必须保证占位对象不被覆盖"
        )
        XCTAssertEqual(DiskCleanPlanFactory.currentSize(ofItemAt: temporary.resolve(collidingName).path), 7)
    }

    /// journal 写不进去就绝不改名——顺序铁律的反向验证。
    func testRenameNeverHappensWhenJournalCannotBeWritten() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        // 把 journal 目录的位置占成一个普通文件：createDirectory 与写入都会失败。
        let blocked = try DiskCleanTempDirectory(name: "diskclean-blocked-journal")
        defer { blocked.remove() }
        try blocked.makeFile("state", bytes: 1)
        let unwritableJournal = DiskCleanStagingJournal(directory: blocked.resolve("state"))

        let disposition = DiskCleanRemovalPrimitive(journal: unwritableJournal, trash: FakeDiskCleanTrash())
            .remove(plan.items[0], mode: .permanent)

        guard case .failed = disposition else {
            return XCTFail("journal 不可写必须失败，实际：\(disposition)")
        }
        assertPathExists(target, "journal 写不进去时对象必须原封不动")
        XCTAssertEqual(stagedNames(in: temporary.path), [])
    }

    // MARK: - 回滚

    func testTrashFailureRollsBackToOriginalPath() throws {
        try temporary.makeFile("Cache/a.bin", bytes: 10)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target], mode: .trash)

        let disposition = makePrimitive(trash: FakeDiskCleanTrash(shouldFail: true))
            .remove(plan.items[0], mode: .trash)

        guard case .failed = disposition else {
            return XCTFail("期望 failed，实际：\(disposition)")
        }
        assertPathExists(temporary.resolve("Cache/a.bin").path, "回滚后原路径必须完好")
        XCTAssertEqual(stagedNames(in: temporary.path), [])
        XCTAssertTrue(journal.incompleteEntries().isEmpty, "回滚成功即销账")
    }

    /// 回滚时原路径已被重建 → 绝不覆盖：保留暂存对象，条目留给 reconciliation。
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
            return XCTFail("期望 rollbackBlocked，实际：\(disposition)")
        }
        assertPathExists(recreatedMarker, "重建的原路径绝不能被覆盖")
        assertPathExists(
            DiskCleanRemovalPrimitive.join(temporary.path, stagedName),
            "暂存对象必须保留，交 reconciliation 处理"
        )
        XCTAssertEqual(
            journal.incompleteEntries().map(\.stagedName),
            [stagedName],
            "回滚被挡时 journal 条目保持未完成"
        )
    }

    /// prewalk 发现挂载穿越 → 一个文件都不删，整棵树改回原路径。
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
            return XCTFail("期望 failed，实际：\(disposition)")
        }
        XCTAssertTrue(reason.contains("挂载点"), "失败原因应说明是挂载穿越，实际：\(reason)")
        assertPathExists(temporary.resolve("Cache/a.bin").path, "prewalk 是非破坏性的，回滚后整棵树必须完好")
        assertPathExists(temporary.resolve("Cache/Nested/b.bin").path)
        XCTAssertEqual(stagedNames(in: temporary.path), [])
    }

    // MARK: - partiallyDeleted

    /// 删除中途遇到不可写的子目录 → 诚实报 partiallyDeleted，残骸留在暂存名下。
    ///
    /// **与设计 §7.4 的偏离**：此处 journal 条目显式销账而非保留。保留会让下次启动的
    /// reconciliation 把这棵半删的损坏树改名回原路径，应用会当它是完好缓存继续使用。
    func testPartiallyDeletedWhenSubdirectoryIsNotWritable() throws {
        try temporary.makeFile("Cache/top.bin", bytes: 10)
        try temporary.makeFile("Cache/Locked/inner.bin", bytes: 20)
        let target = temporary.resolve("Cache").path
        let plan = try DiskCleanPlanFactory.makePlan(paths: [target])

        // r-x：可读可进入（prewalk 通得过），但不可写（unlinkat 子项失败）。
        let lockedPath = temporary.resolve("Cache/Locked").path
        restrictedDirectories.append(lockedPath)
        XCTAssertEqual(chmod(lockedPath, 0o555), 0)

        let disposition = makePrimitive().remove(plan.items[0], mode: .permanent)

        guard case let .partiallyDeleted(stagedName, _) = disposition else {
            return XCTFail("期望 partiallyDeleted，实际：\(disposition)")
        }
        assertPathDoesNotExist(target, "对象已经离开原路径，不会被假装恢复")
        XCTAssertEqual(
            stagedNames(in: temporary.path),
            [stagedName],
            "半删的残骸留在暂存名下，由审计与清理历史显式呈现"
        )
        XCTAssertTrue(
            journal.incompleteEntries().isEmpty,
            "partiallyDeleted 必须销账，否则下次启动会把损坏的树改名回原路径"
        )
        // 恢复权限，让 teardown 能删掉整棵树。
        chmod(DiskCleanRemovalPrimitive.join(temporary.path, stagedName) + "/Locked", 0o755)
    }

    // MARK: - 夹具

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

/// 按顺序发名字的暂存名工厂，用于构造 RENAME_EXCL 冲突。
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
