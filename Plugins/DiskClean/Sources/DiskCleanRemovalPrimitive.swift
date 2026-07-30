import Darwin
import Foundation

// MARK: - 终态

/// 单项处置的终态（设计 §7.5）。
///
/// 每个 case 都是**如实**记录：删除中途失败不假装成功，回滚被挡不假装回滚。
enum DiskCleanRemovalDisposition: Equatable, Sendable {
    /// 永久删除完成，暂存对象已不存在。
    case removed
    /// 已移入废纸篓。放回时会落在暂存名下，故一并回传（设计 §7.4 的取舍）。
    case trashed(stagedName: String)
    /// 身份复核不符：对象在扫描后被替换或改动过。原对象**未被触碰**。
    case changedSinceScan
    /// 冻结之前失败，或冻结后失败且已成功回滚。原路径对象完好。
    case failed(reason: String)
    /// 删除中途 I/O 失败，树已半删。回滚无意义，残骸留在暂存名下。
    case partiallyDeleted(stagedName: String, reason: String)
    /// 冻结后处置失败且回滚被挡（原路径已被重建）。暂存对象保留，交 reconciliation。
    case rollbackBlocked(stagedName: String, reason: String)
}

/// 验证-冻结-删除原语的接缝。执行器只依赖本协议，测试据此注入 fake。
protocol DiskCleanPlanItemRemoving: Sendable {
    func remove(
        _ item: DiskCleanValidatedPlan.PlanItem,
        mode: DiskCleanRemovalMode
    ) -> DiskCleanRemovalDisposition
}

// MARK: - 注入接缝

/// 废纸篓接缝。
///
/// 独立成协议不只是为了可测：真实实现会把对象放进用户的废纸篓，而仓库硬性要求
/// "文件系统测试绝不触碰真实用户目录"，测试必须能拦下这一步。
protocol DiskCleanTrashing: Sendable {
    func trashItem(atPath path: String) throws
}

struct DiskCleanSystemTrash: DiskCleanTrashing {
    func trashItem(atPath path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }
}

/// prewalk 的条目设备号来源（设计 §7.4 的"全体 devid 一致性"）。
///
/// 挂载穿越无法在真实文件系统的临时目录里构造——挂载需要 root。因此设备号判定必须留一个
/// 注入点，否则这条安全分支只能靠代码审读，永远测不到。与 M1 给 walker 留 entry source
/// 接缝是同一个理由。
protocol DiskCleanStagedEntryDeviceResolving: Sendable {
    func deviceID(ofEntry nameBytes: [CChar], statResult: stat) -> UInt64
}

struct DiskCleanRealStagedEntryDeviceResolver: DiskCleanStagedEntryDeviceResolving {
    func deviceID(ofEntry nameBytes: [CChar], statResult: stat) -> UInt64 {
        UInt64(UInt32(bitPattern: statResult.st_dev))
    }
}

// MARK: - 原语

/// 验证-冻结-删除原语（设计 §7.3、§7.4）。安全核心。
///
/// 顺序不可调换，每一步都在关一扇窗：
/// 1. 父目录 `O_NOFOLLOW_ANY` 打开 + `fstatfs` 校验本地卷——路径任意一级被换成符号链接都会失败。
/// 2. `fstatat(AT_SYMLINK_NOFOLLOW)` 复核 `(devid, fileID, fileType, mtime)`（普通文件另比对
///    大小）——扫描后被替换的对象在这里被拦下，绝不误删。
/// 3. journal 落盘并 **fsync 成功之后**才 rename——反过来会留下"无记录的暂存对象"，
///    SafetyPolicy 会保护它不被扫描收走，但没人知道它的原名，用户数据事实上失踪。
/// 4. `renameatx_np(RENAME_EXCL)` 原子改名到暂存名——此后对象脱离原路径，
///    路径替换窗口关闭；`RENAME_EXCL` 保证绝不覆盖任何既有对象。
/// 5. 处置（trash / 递归删除）一律作用于**暂存路径**。
///
/// 残余风险（设计 §7.7）：删除目录即删除其**执行时刻**的全部内容。根身份一致 ≠ 深层内容与
/// 扫描时一致——根 mtime 只反映直接子项的增删。对缓存目录这是可接受语义。
struct DiskCleanRemovalPrimitive: DiskCleanPlanItemRemoving {
    /// 暂存名前缀。SafetyPolicy 据此保护暂存对象不被任何扫描收进候选（§7.6）。
    static let stagedNamePrefix = ".mactools-staged-"
    /// prewalk 与递归删除的深度上限：每层持有一个目录 fd，无上限会撞 EMFILE 或爆栈。
    /// 触顶按失败处理（fail closed），不冒险继续。
    static let maximumTreeDepth = 128

    private let journal: DiskCleanStagingJournal
    private let trash: any DiskCleanTrashing
    private let deviceResolver: any DiskCleanStagedEntryDeviceResolving
    private let stagedNameFactory: @Sendable () -> String
    private let now: @Sendable () -> Date

    init(
        journal: DiskCleanStagingJournal,
        trash: any DiskCleanTrashing = DiskCleanSystemTrash(),
        deviceResolver: any DiskCleanStagedEntryDeviceResolving = DiskCleanRealStagedEntryDeviceResolver(),
        stagedNameFactory: @escaping @Sendable () -> String = {
            DiskCleanRemovalPrimitive.stagedNamePrefix + UUID().uuidString
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.journal = journal
        self.trash = trash
        self.deviceResolver = deviceResolver
        self.stagedNameFactory = stagedNameFactory
        self.now = now
    }

    func remove(
        _ item: DiskCleanValidatedPlan.PlanItem,
        mode: DiskCleanRemovalMode
    ) -> DiskCleanRemovalDisposition {
        guard let location = ParentAnchoredPath(path: item.path) else {
            return .failed(reason: "无法解析父目录：\(item.path)")
        }

        // 全链拒符号链接：中间任意一级被换成指向别处的链接都会在这里失败。
        let parentDescriptor = Darwin.open(
            location.parentPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_NONBLOCK
        )
        guard parentDescriptor >= 0 else {
            let code = errno
            // 父目录不见了 → 对象也不可能还在原处，按"已变化"处理而不是失败。
            return code == ENOENT ? .changedSinceScan : .failed(reason: Self.describe(code, doing: "打开父目录"))
        }
        defer { close(parentDescriptor) }

        guard Self.isLocalVolume(fileDescriptor: parentDescriptor) else {
            return .failed(reason: "父目录不在本地卷上")
        }

        switch verifyIdentity(parentDescriptor: parentDescriptor, name: location.name, item: item) {
        case .mismatch:
            return .changedSinceScan
        case let .failure(reason):
            return .failed(reason: reason)
        case .match:
            break
        }

        let staged: StagedObject
        switch stage(parentDescriptor: parentDescriptor, location: location, mode: mode) {
        case let .failure(disposition):
            return disposition
        case let .success(object):
            staged = object
        }

        // 冻结后复核：暂存名下必须仍是同一个对象。RENAME_EXCL 之下这一步理论上不会失败，
        // 但"理论上不会"正是安全代码需要显式验证的那一类断言。
        guard identityMatches(parentDescriptor: parentDescriptor, name: staged.name, expected: item.rootIdentity) else {
            return rollback(
                parentDescriptor: parentDescriptor,
                staged: staged,
                originalName: location.name,
                reason: "暂存后身份复核不符",
                dispositionAfterRollback: .changedSinceScan
            )
        }

        switch mode {
        case .trash:
            return moveToTrash(
                parentDescriptor: parentDescriptor,
                staged: staged,
                location: location
            )
        case .permanent:
            return deletePermanently(
                parentDescriptor: parentDescriptor,
                staged: staged,
                location: location,
                item: item
            )
        }
    }

    // MARK: - 身份验证（§7.3）

    private enum IdentityOutcome {
        case match
        case mismatch
        case failure(reason: String)
    }

    private func verifyIdentity(
        parentDescriptor: Int32,
        name: String,
        item: DiskCleanValidatedPlan.PlanItem
    ) -> IdentityOutcome {
        var status = stat()
        guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            return code == ENOENT ? .mismatch : .failure(reason: Self.describe(code, doing: "复核对象身份"))
        }

        // (devid, fileID, fileType) 全等 + mtime 比对。被替换成同名新目录或符号链接
        // 都会在这里出现 fileID 或 fileType 差异。
        guard DiskCleanRootIdentity(stat: status) == item.rootIdentity else {
            return .mismatch
        }
        // 普通文件另比对大小：内容被改写而 mtime 恰好被保留时，大小是第二道证据。
        if item.rootIdentity.fileType == .regularFile, status.st_size != item.estimatedBytes {
            return .mismatch
        }
        return .match
    }

    private func identityMatches(
        parentDescriptor: Int32,
        name: String,
        expected: DiskCleanRootIdentity
    ) -> Bool {
        var status = stat()
        guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
        return DiskCleanRootIdentity(stat: status) == expected
    }

    // MARK: - 冻结（§7.4 第 1、2 步）

    private struct StagedObject {
        let entryID: String
        let name: String
    }

    private enum StageOutcome {
        case success(StagedObject)
        case failure(DiskCleanRemovalDisposition)
    }

    private func stage(
        parentDescriptor: Int32,
        location: ParentAnchoredPath,
        mode: DiskCleanRemovalMode
    ) -> StageOutcome {
        // uuid 碰撞概率可忽略，但 RENAME_EXCL 的 EEXIST 也可能来自别的进程恰好占用了这个名字，
        // 故换名重试一次；仍冲突就放弃，不无限重试。
        for attempt in 0..<2 {
            let stagedName = stagedNameFactory()
            let entry = DiskCleanStagingJournal.Entry(
                id: UUID().uuidString,
                timestamp: now(),
                parentPath: location.parentPath,
                originalName: location.name,
                stagedName: stagedName,
                mode: mode.rawValue
            )

            // 顺序铁律：begin + fsync 成功返回之后才允许 rename。写不进 journal 就不动文件。
            do {
                try journal.begin(entry)
            } catch {
                return .failure(.failed(reason: "无法写入暂存日志：\(error.localizedDescription)"))
            }

            let status = renameatx_np(
                parentDescriptor,
                location.name,
                parentDescriptor,
                stagedName,
                UInt32(RENAME_EXCL)
            )
            if status == 0 {
                return .success(StagedObject(entryID: entry.id, name: stagedName))
            }

            let code = errno
            // rename 未发生 → 没有暂存对象，条目立即销账，不留给 reconciliation 空转。
            journal.complete(entryID: entry.id, status: "abortedBeforeRename", at: now())

            if code == EEXIST, attempt == 0 {
                continue
            }
            if code == ENOENT {
                return .failure(.changedSinceScan)
            }
            return .failure(.failed(reason: Self.describe(code, doing: "暂存改名")))
        }
        return .failure(.failed(reason: "暂存名连续冲突"))
    }

    /// 回滚：`RENAME_EXCL` 改回原名。
    ///
    /// **原路径被重建是缓存进程的常见行为**（应用一边跑一边重建自己的缓存目录），
    /// 此时绝不覆盖：保留暂存对象并返回 `rollbackBlocked`，journal 条目**保持未完成**，
    /// 交由启动 reconciliation 或用户处理。
    private func rollback(
        parentDescriptor: Int32,
        staged: StagedObject,
        originalName: String,
        reason: String,
        dispositionAfterRollback: DiskCleanRemovalDisposition
    ) -> DiskCleanRemovalDisposition {
        let status = renameatx_np(
            parentDescriptor,
            staged.name,
            parentDescriptor,
            originalName,
            UInt32(RENAME_EXCL)
        )
        guard status == 0 else {
            let code = errno
            return .rollbackBlocked(
                stagedName: staged.name,
                reason: "\(reason)；回滚失败：\(Self.describe(code, doing: "改回原名"))"
            )
        }
        journal.complete(entryID: staged.entryID, status: "rolledBack", at: now())
        return dispositionAfterRollback
    }

    // MARK: - 废纸篓（§7.4 第 3 步）

    private func moveToTrash(
        parentDescriptor: Int32,
        staged: StagedObject,
        location: ParentAnchoredPath
    ) -> DiskCleanRemovalDisposition {
        // 作用于**暂存路径**：`trashItem` 会按路径重新解析，对原路径调用它等于把
        // §7.3 刚关上的替换窗口重新打开。
        let stagedPath = Self.join(location.parentPath, staged.name)
        do {
            try trash.trashItem(atPath: stagedPath)
        } catch {
            let reason = "移入废纸篓失败：\(error.localizedDescription)"
            return rollback(
                parentDescriptor: parentDescriptor,
                staged: staged,
                originalName: location.name,
                reason: reason,
                dispositionAfterRollback: .failed(reason: reason)
            )
        }
        journal.complete(entryID: staged.entryID, status: "trashed", at: now())
        return .trashed(stagedName: staged.name)
    }

    // MARK: - 永久删除（§7.4 第 3 步）

    private func deletePermanently(
        parentDescriptor: Int32,
        staged: StagedObject,
        location: ParentAnchoredPath,
        item: DiskCleanValidatedPlan.PlanItem
    ) -> DiskCleanRemovalDisposition {
        // 非目录：单次 unlinkat，无需 prewalk。symlink 删链接本身，绝不跟随。
        guard item.rootIdentity.fileType == .directory else {
            guard unlinkat(parentDescriptor, staged.name, 0) == 0 else {
                let reason = Self.describe(errno, doing: "删除对象")
                return rollback(
                    parentDescriptor: parentDescriptor,
                    staged: staged,
                    originalName: location.name,
                    reason: reason,
                    dispositionAfterRollback: .failed(reason: reason)
                )
            }
            journal.complete(entryID: staged.entryID, status: "removed", at: now())
            return .removed
        }

        // 非破坏性 prewalk：整棵树先只读走一遍，确认没有挂载穿越、没有异常条目。
        // 通不过就回滚——半路才发现问题时树已经缺了一块，那时回滚已经没有意义。
        switch prewalk(
            parentDescriptor: parentDescriptor,
            name: staged.name,
            expectedDevice: item.rootIdentity.devid,
            depth: 0
        ) {
        case .ok:
            break
        case .crossedMountPoint:
            let reason = "暂存树内发现挂载点，已放弃删除"
            return rollback(
                parentDescriptor: parentDescriptor,
                staged: staged,
                originalName: location.name,
                reason: reason,
                dispositionAfterRollback: .failed(reason: reason)
            )
        case let .failure(walkReason):
            let reason = "删除前检查失败：\(walkReason)"
            return rollback(
                parentDescriptor: parentDescriptor,
                staged: staged,
                originalName: location.name,
                reason: reason,
                dispositionAfterRollback: .failed(reason: reason)
            )
        }

        if let reason = deleteTree(parentDescriptor: parentDescriptor, name: staged.name, depth: 0) {
            // **设计偏离**：§7.4 写"partiallyDeleted 时 journal 保留条目"，这里改为显式销账。
            // 保留条目会让下次启动的 reconciliation 把这棵**半删的损坏树**改名回原路径——
            // 应用会当它是完好的缓存继续使用。残骸留在暂存名下由审计与清理历史显式呈现，
            // 比自动"恢复"一个坏掉的目录诚实得多。
            journal.complete(entryID: staged.entryID, status: "partiallyDeleted", at: now())
            return .partiallyDeleted(stagedName: staged.name, reason: reason)
        }
        journal.complete(entryID: staged.entryID, status: "removed", at: now())
        return .removed
    }

    // MARK: - fd 相对的树遍历

    private enum TreeOutcome {
        case ok
        case crossedMountPoint
        case failure(reason: String)
    }

    /// 只读 prewalk：全程 fd 相对寻址，逐条 `fstatat(AT_SYMLINK_NOFOLLOW)` 校验设备号。
    private func prewalk(
        parentDescriptor: Int32,
        name: String,
        expectedDevice: UInt64,
        depth: Int
    ) -> TreeOutcome {
        guard depth < Self.maximumTreeDepth else {
            return .failure(reason: "目录层级超过 \(Self.maximumTreeDepth) 层")
        }
        guard let directory = OpenDirectory(parentDescriptor: parentDescriptor, name: name) else {
            let code = errno
            return .failure(reason: Self.describe(code, doing: "打开暂存目录"))
        }
        defer { directory.close() }

        var childDirectories: [[CChar]] = []
        while let entry = directory.next() {
            var status = stat()
            let statResult = entry.nameBytes.withUnsafeBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return fstatat(directory.descriptor, base, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else {
                return .failure(reason: Self.describe(errno, doing: "读取条目属性"))
            }
            guard deviceResolver.deviceID(ofEntry: entry.nameBytes, statResult: status) == expectedDevice else {
                return .crossedMountPoint
            }
            if DiskCleanRootIdentity.FileType(mode: status.st_mode) == .directory {
                childDirectories.append(entry.nameBytes)
            }
        }
        if let code = directory.readError {
            return .failure(reason: Self.describe(code, doing: "枚举暂存目录"))
        }

        for childName in childDirectories {
            let outcome = childName.withUnsafeBufferPointer { buffer -> TreeOutcome in
                guard let base = buffer.baseAddress else {
                    return .failure(reason: "条目名为空")
                }
                return prewalk(
                    parentDescriptor: directory.descriptor,
                    name: String(cString: base),
                    expectedDevice: expectedDevice,
                    depth: depth + 1
                )
            }
            guard case .ok = outcome else { return outcome }
        }
        return .ok
    }

    /// fd 递归删除。返回 nil 表示整棵树已删干净，否则返回首个失败原因。
    ///
    /// 条目名一路保存为原始 `[CChar]` 字节、不经 `String` 往返：非法 UTF-8 的文件名转成
    /// String 再转回去会丢字节，删除时就会指向另一个（或不存在的）对象。
    private func deleteTree(parentDescriptor: Int32, name: String, depth: Int) -> String? {
        guard depth < Self.maximumTreeDepth else {
            return "目录层级超过 \(Self.maximumTreeDepth) 层"
        }
        guard let directory = OpenDirectory(parentDescriptor: parentDescriptor, name: name) else {
            return Self.describe(errno, doing: "打开暂存目录")
        }

        // 先读完整个目录再删：边 readdir 边 unlink 会让目录流的位置语义变得依赖实现。
        var entries: [(nameBytes: [CChar], isDirectory: Bool)] = []
        while let entry = directory.next() {
            var status = stat()
            let statResult = entry.nameBytes.withUnsafeBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return fstatat(directory.descriptor, base, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else {
                directory.close()
                return Self.describe(errno, doing: "读取条目属性")
            }
            entries.append((entry.nameBytes, DiskCleanRootIdentity.FileType(mode: status.st_mode) == .directory))
        }
        if let code = directory.readError {
            directory.close()
            return Self.describe(code, doing: "枚举暂存目录")
        }

        var failureReason: String?
        for entry in entries where failureReason == nil {
            if entry.isDirectory {
                let childName = entry.nameBytes.withUnsafeBufferPointer { buffer -> String? in
                    buffer.baseAddress.map { String(cString: $0) }
                }
                guard let childName else {
                    failureReason = "条目名为空"
                    continue
                }
                failureReason = deleteTree(
                    parentDescriptor: directory.descriptor,
                    name: childName,
                    depth: depth + 1
                )
            } else {
                let result = entry.nameBytes.withUnsafeBufferPointer { buffer -> Int32 in
                    guard let base = buffer.baseAddress else { return -1 }
                    return unlinkat(directory.descriptor, base, 0)
                }
                if result != 0, errno != ENOENT {
                    failureReason = Self.describe(errno, doing: "删除文件")
                }
            }
        }

        // 目录 fd 必须先释放再 rmdir 自身，否则 unlinkat 在忙碌的挂载点上会更容易失败。
        directory.close()
        if let failureReason {
            return failureReason
        }
        if unlinkat(parentDescriptor, name, AT_REMOVEDIR) != 0, errno != ENOENT {
            return Self.describe(errno, doing: "删除目录")
        }
        return nil
    }

    // MARK: - 工具

    private static func isLocalVolume(fileDescriptor: Int32) -> Bool {
        var fileSystem = statfs()
        guard fstatfs(fileDescriptor, &fileSystem) == 0 else { return false }
        return fileSystem.f_flags & UInt32(MNT_LOCAL) != 0
    }

    static func join(_ parentPath: String, _ name: String) -> String {
        parentPath == "/" ? "/" + name : parentPath + "/" + name
    }

    private static func describe(_ code: Int32, doing action: String) -> String {
        "\(action)失败（\(String(cString: strerror(code)))）"
    }
}

// MARK: - 目录流

/// `openat` + `fdopendir` 的 RAII 包装。
///
/// `closedir` 会连带关闭底层 fd，因此 fd 的所有权全程只有一个归属：本类型。
private final class OpenDirectory {
    struct Entry {
        /// NUL 结尾的原始字节名，直接回传给 `fstatat` / `unlinkat`。
        let nameBytes: [CChar]
    }

    let descriptor: Int32
    private let stream: UnsafeMutablePointer<DIR>
    private var isClosed = false
    /// `readdir` 的错误码。nil 表示正常枚举到结尾。
    private(set) var readError: Int32?

    init?(parentDescriptor: Int32, name: String) {
        // 单级组件 + 父目录已由 fd 锚定，故 O_NOFOLLOW 足够；符号链接一律不跟随。
        let descriptor = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        guard let stream = fdopendir(descriptor) else {
            let code = errno
            // 本类型自己有 close()，不加模块限定会解析成实例方法。
            Darwin.close(descriptor)
            errno = code
            return nil
        }
        self.descriptor = descriptor
        self.stream = stream
    }

    deinit {
        close()
    }

    func next() -> Entry? {
        guard !isClosed else { return nil }
        while true {
            errno = 0
            guard let directoryEntry = readdir(stream) else {
                let code = errno
                if code != 0 {
                    readError = code
                }
                return nil
            }
            guard let nameBytes = Self.nameBytes(of: directoryEntry), !Self.isDotEntry(nameBytes) else {
                continue
            }
            return Entry(nameBytes: nameBytes)
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        closedir(stream)
    }

    private static func nameBytes(of entry: UnsafeMutablePointer<dirent>) -> [CChar]? {
        let length = Int(entry.pointee.d_namlen)
        guard length > 0 else { return nil }
        return withUnsafePointer(to: entry.pointee.d_name) { tuplePointer in
            let characters = UnsafeRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
            var bytes = Array(UnsafeBufferPointer(start: characters, count: length))
            bytes.append(0)
            return bytes
        }
    }

    private static func isDotEntry(_ nameBytes: [CChar]) -> Bool {
        let dot = CChar(UInt8(ascii: "."))
        switch nameBytes.count {
        case 2: return nameBytes[0] == dot
        case 3: return nameBytes[0] == dot && nameBytes[1] == dot
        default: return false
        }
    }
}
