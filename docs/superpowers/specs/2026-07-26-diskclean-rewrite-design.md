# DiskClean 插件重写 — 技术设计（2026-07-26，rev 4）

范围与决策见 [2026-07-26-diskclean-rewrite-scope.md](2026-07-26-diskclean-rewrite-scope.md)。本文是给实现者的技术设计，**自包含**（不依赖任何历史版本），按里程碑直接开工。

**rev 4 修订记录（回应设计评审 round 3，10 条）：**
1. 废纸篓模式同样走 identity-bound freeze（暂存改名后 trash 暂存对象），审计单独记录原路径用于恢复（§7.4）。
2. 路径解析全链改为 `O_NOFOLLOW_ANY`（拒绝任意一级符号链接）+ 打开后 `fstatfs` 校验设备（§3.2、§7.3）。
3. 暂存/回滚一律 `renameatx_np(RENAME_EXCL)`（绝不覆盖）；删除前非破坏性 fd prewalk；删除中途失败引入 `partiallyDeleted` 终态（§7.4、§7.5）。
4. 暂存对象崩溃恢复协议：rename 前 fsync journal、启动 reconciliation、SafetyPolicy 保护 staged 名称（§7.6）。
5. 回退 sizer 改为 fd-relative 慢速 walker（同等 no-follow/设备约束/完整性语义）；熔断后 **fail closed**——不再做任何 sizing，未定大小候选不可清理（§3.4、§3.5）。
6. 每个 target 必填 `reservedRootPaths`，与 provider 是否成功运行无关（§5.2）。
7. 根 opener 先无跟随打开再 `fstat` 分型：普通文件直接取大小，目录才进 walker，symlink 按链接本身计（§3.2）。
8. 本文自包含：完整映射表、P2/FDA/选择细节全部收录，删除对 rev 2/3 的引用。
9. `ValidatedPlan` 携带完整验证证据（排除路径 + 保留前缀），执行器 preflight 据此重跑断言（§6.1、§6.2）。
10. 过期门增加可注入 Clock 的时间驱动转换；confirming 铸造与执行 preflight 都复核 observedAt；确认窗口不得越过过期时刻（§4.4、§8.4）。

---

## 1. 背景与目标

现有 DiskClean 插件（v1.0.8，约 3200 行）基于 Mole 第一版规则移植。核心痛点：`sizeOfItem` 用 `FileManager.enumerator` 逐文件 `attributesOfItem` 递归求和、扫描全串行、进程检测每规则 spawn 一次 `pgrep`。重写参考 /Users/rk/work/ps/Burrow 的技术方案（其引擎为私有 submodule 不可得，搬方法不搬代码）。

**目标**
- 扫描性能：大目录求大小从分钟级降到秒级；并发化、流式出结果、可取消、协作式超时（边界见 §3.4）。
- 安全性升级：不可伪造删除计划、验证-冻结-删除原语、崩溃恢复、使用中锁定（双时点）、废纸篓默认、审计日志。现有 `DiskCleanSafetyPolicy`/白名单/二次校验保留（AGENTS.md 红线）。
- 规则体系升级：10 分类 + 风险排序 + 后果文案 + 动态规则补齐。
- 新增开发产物清扫、残留安装包两个清理域。
- FDA 检测与引导（插件本地实现）。

**非目标**
- 不改 PluginKit/PluginHost 共享代码（无 ABI 变更；依据：loader 对 `pluginKitVersion` 严格相等校验 `PluginPackageManifest.swift:121`，仓库惯例用可选协议回避 witness table 变更）。
- 不捆绑 CLI；不做树图/重复文件/卸载/优化；不迁移组件面板大视图。
- `appLeftovers`（已卸载应用孤儿目录）延期。

## 2. 模块结构

`Plugins/DiskClean/Sources/` 平铺（现有插件惯例）：

```
DiskCleanPlugin.swift            # MacToolsPlugin + PluginPrimaryPanel + PluginConfigurationPresenting
DiskCleanController.swift        # @MainActor 状态机（含 confirming）+ 权威选择状态 + 过期时钟
DiskCleanModels.swift            # Category/Candidate/事件/完整性/limitations 纯数据
DiskCleanRuleCatalog.swift       # v2 规则目录（target 级分类/风险/稳定 ID/保留根）
DiskCleanDynamicRules.swift      # simctl / 版本目录比较 providers
DiskCleanScanEngine.swift        # 扫描编排；产出 ScanArtifact
DiskCleanFastWalker.swift        # getattrlistbulk walker（fd 遍历/挂载防护/根身份）
DiskCleanSlowWalker.swift        # fd-relative readdir 回退 walker（同等约束）
DiskCleanWorkerPool.swift        # Thread 池：exactly-once 门、放弃预算、熔断
DiskCleanFileSystem.swift        # glob 展开、itemInfo（保留+扩展）
DiskCleanPlan.swift              # Planner + ValidatedPlan（fileprivate init，唯一铸造点）
DiskCleanSafetyPolicy.swift      # 保留 + staged 名称保护
DiskCleanWhitelistStore.swift    # 保留，存储格式不变
DiskCleanRunningAppLock.swift    # 运行应用/进程快照锁定（扫描与执行共用）
DiskCleanStagingJournal.swift    # 暂存事务 journal + 启动 reconciliation
DiskCleanAuditLog.swift          # 追加式删除日志（滚动）
DiskCleanExecutor.swift          # 只接受 ValidatedPlan；验证-冻结-删除原语
DiskCleanSelectionModel.swift    # 纯三态选择模型（Controller 持有）
DiskCleanPurgeScanner.swift      # P2 开发产物扫描
DiskCleanInstallerScanner.swift  # P2 残留安装包扫描
DiskCleanDetailView.swift        # 详情视图（重写）
```

删除：`DiskCleanScanner.swift`、旧 `sizeOfItem`。测试文件一一对应 `Plugins/DiskClean/Tests/<TypeName>Tests.swift`。

## 3. Sizing 子系统

### 3.1 完整性与身份模型

```swift
enum DiskCleanScanCompleteness: Equatable, Sendable {
    case complete
    case partial(reasons: Set<PartialReason>)

    enum PartialReason: Equatable, Sendable, Hashable {
        case timedOut             // 协作式 deadline 到期
        case permissionDenied     // EPERM/EACCES 子树跳过
        case unsupportedVolume    // 非本地卷 / 黑名单卷 / 熔断后未 sizing
        case crossedMountPoint    // 子树内发现挂载点，未下潜
        case walkError            // 属性异常且逐条回退失败
    }
}

struct DiskCleanRootIdentity: Equatable, Sendable {
    let devid: UInt64
    let fileID: UInt64
    let mtime: Date
    let fileType: FileType        // .directory / .regularFile / .symlink
}

struct DiskCleanSizeResult: Equatable, Sendable {
    let estimatedBytes: Int64     // 估算逻辑大小（st_size 求和、硬链接按 (devid,fileID) 去重）。
                                  // ≠ 实际可释放空间（APFS clone/稀疏/目录外硬链接）。UI 统一"约 X GB"。
    let fileCount: Int
    let completeness: DiskCleanScanCompleteness
    let rootIdentity: DiskCleanRootIdentity   // 从打开的根 fd 上 fstat 取得
    let observedAt: Date                      // 真实观测时刻（缓存命中 = 缓存条目的观测时刻）
}
```

**核心不变量：`completeness != .complete` 或含 `crossedMountPoint` 的候选不可清理**——选择模型拒绝（§8.1）、Planner 排除（§6.1）、执行器复核拒绝（§7.2），三重防线。

### 3.2 根 opener（评审 r3-#2、r3-#7）

所有 sizing 与执行的入口统一经根 opener：

1. `open(path, O_RDONLY | O_NOFOLLOW_ANY)`——**O_NOFOLLOW_ANY 拒绝路径任意一级的符号链接**（不是只保护末级；防"中间目录被换成指向 Documents 的 symlink"）。macOS 12+ 可用，部署目标 14.0。
2. `fstatfs(fd)`：校验 `MNT_LOCAL`、记录 `f_fsid`；与后续 entry 的 devid 交叉校验。
3. `fstat(fd)` 分型：
   - **目录** → 进 walker（§3.3）。
   - **普通文件**（安装包 .dmg/.iso/.xip/.zip、日志文件等）→ 直接从 fstat 取 `st_size`，complete，rootIdentity 从同一 fd 取得。
   - **symlink**：O_NOFOLLOW_ANY 下 open 会失败（ELOOP）→ 改 `lstat` 路径取链接本身大小与身份，标记 fileType .symlink（执行时按链接本身删除，绝不跟随）。
4. 打开失败 EPERM/EACCES → `partial([.permissionDenied])`；ELOOP 之外的错误 → `partial([.walkError])`。

### 3.3 FastWalker（getattrlistbulk）

- 根 fd 由 §3.2 提供；`getattrlistbulk(2)` 批量读（64KB/批），请求 `ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE | ATTR_CMN_DEVID | ATTR_CMN_FILEID | ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH`。逐项按 RETURNED_ATTRS 位图解析（非 APFS 卷会缺属性，不得假设固定布局）；**单条缺关键属性 → 该条目 `fstatat(dirFd, name, AT_SYMLINK_NOFOLLOW)` 回退**，再失败 → completeness 加 `walkError`。
- 迭代式 DFS（显式栈），子目录 `openat(parentFd, name, O_DIRECTORY | O_NOFOLLOW)` 下潜——全程 fd 相对寻址（相对单级组件，O_NOFOLLOW 足够）。
- **挂载防护**：entry `DEVID != rootIdentity.devid` → 不下潜不计数，加 `crossedMountPoint`。
- **硬链接去重**：`LINKCOUNT > 1` 记 `(devid, fileID)` 入 Set，重复只计一次（devid 必须参与键，跨挂载 fileID 不唯一）。
- symlink entry 计链接本身，不跟随。EPERM 子树 → `permissionDenied`。
- 每批之间检查 isCancelled 与 deadline；到期 → `partial([.timedOut])`。

### 3.4 WorkerPool 与超时（真实原语）

Swift task 取消不能中断阻塞 syscall，GCD 并发队列没有"放弃并补充某条线程"的接口。因此：

- **插件持有的 `Thread` 池**：最多 3 条常驻线程，从锁保护队列取活；任务 = 一次 walker 调用。
- **exactly-once resume 门**：每任务一个 `OSAllocatedUnfairLock` 状态机 `pending → resumed(result | timeout)`。超时计时（引擎侧 task）与 worker 完成谁先到谁 resume checked continuation；后到者只置弃标志，不 resume、不触碰对方内存（worker 结果自持有）。双向竞争单测。
- **放弃与预算**：超时后 worker 未返回 → 线程标记 abandoned（滞留 syscall），池补新线程。**预算 = 进程级常量 3（跨扫描累计）**。
- **熔断（fail closed，评审 r3-#5）**：预算耗尽 → **本进程不再执行任何 sizing**（Fast/Slow 一律停）。已 abandoned 走线的 devid 入黑名单。后续扫描仍可枚举候选，但全部 `partial([.unsupportedVolume])` → 不可清理；UI 显示"扫描引擎已降级，重启应用恢复"。不自动恢复——病态文件系统重试只会烧预算；也不换回退 sizer 续跑——同样会阻塞，与"泄漏上限 3"矛盾。
- 超时语义对外表述为**协作式**："本地健康卷可靠；病态卷降级为跳过+熔断"。不使用"硬超时"。

### 3.5 SlowWalker（回退，评审 r3-#5）

getattrlistbulk 对个别卷（部分 FUSE）返回错误时的回退不再是 `FileManager`——那会丢掉 no-follow/设备约束并可能跨挂载点仍报 complete。回退为 **fd-relative 慢速 walker**：`fdopendir`/`readdir` + 逐条 `fstatat(AT_SYMLINK_NOFOLLOW)`，复用 §3.3 的全部约束（挂载防护、硬链接去重、EPERM 跳过、deadline/isCancelled、rootIdentity）。同样跑在 WorkerPool 内、受同一预算管辖。

## 4. 扫描引擎

### 4.1 事件流

```swift
enum DiskCleanScanEvent: Sendable {
    case log(DiskCleanScanLogMessage)
    case candidateFound(DiskCleanCandidate)              // 大小未知，不可勾选
    case candidateSized(id: String, DiskCleanSizeResult)
    case categoryFinished(DiskCleanCategoryID)
    case finished(DiskCleanScanSummary)                  // 含 limitations 与 ScanArtifact
}

protocol DiskCleanScanning: Sendable {
    func scan(categories: Set<DiskCleanCategoryID>, forceRefresh: Bool)
        -> AsyncThrowingStream<DiskCleanScanEvent, Error>
}
```

Stream 必须设置 `onTermination`：消费方取消 → 引擎根任务取消 → 不再派生 sizing 任务。

### 4.2 编排

1. **展开阶段**（串行，快）：按分类遍历 target → glob 展开（`DiskCleanFileSystem`，保留现有 glob/父子去重工具）→ 所有权归属与祖先分解（§5.3）→ SafetyPolicy + 锁定判定 → 发 `candidateFound`。用户 1-2 秒内看到条目。被跳过的 target（FDA、动态失败）记入 limitations 且其 `reservedRootPaths` 进 ScanArtifact 保留集。
2. **求大小阶段**：`withThrowingTaskGroup` 限 3 并发，任务体经 WorkerPool；完成即发 `candidateSized`，可回收估算实时累加。
3. **单项 deadline 20s**（超时 partial，UI 提供"重试此项"用更长 deadline 单项重扫）；**全局 300s**。
4. **进程/应用锁定快照**：扫描开始时 `NSWorkspace.runningApplications` + 一次批量 `pgrep`（覆盖非 App 进程，替换现在每规则一次）。

### 4.3 大小缓存

- 键 = 路径；**命中条件 = 根身份三元组 `(devid, fileID, mtime)` 全等**（防"替换目录保留 mtime"复用旧结果）。
- 值含 observedAt（真实观测时刻，传导给过期门）。**只缓存 complete**。
- TTL **240s**（严格 < 过期门 300s）。容量 ~500 条。
- **`forceRefresh: true` 绕过缓存**——过期门触发后的重扫必须走此路径，杜绝"过期→重扫→命中旧缓存→仍过期"死循环。

### 4.4 结果过期门（误操作防护 + 时间驱动，评审 r3-#10）

- 门限：`min(所有选中项 observedAt) + 300s`。超过 → `canClean == false`。
- **时间驱动转换**：Controller 持可注入 `Clock` 的 deadline task，在门限时刻触发 `onStateChange?()`——菜单栏按钮与详情页同步变灰并提示重扫，不依赖用户操作才发现过期。选中集变化时重置 deadline task。
- confirming 与执行 preflight 均复核此门（§6.1、§7.1、§8.4）。
- **定位声明**：此门是误操作防护（防"扫完放半天再点清理"），**不构成 TOCTOU 防护**——执行时防线在 §7。文档、注释、用户文案三处不得声称此门"防止删除未审查内容"。

### 4.5 扫描级 limitations

```swift
enum DiskCleanScanLimitation: Equatable, Sendable {
    case fdaRestricted(skippedTargetIDs: [String])
    case dynamicRuleFailed(targetID: String, reason: String)
    case volumeSkipped(path: String)
    case walkerCircuitBroken
    case threadsAbandoned(count: Int)
}
```

菜单栏"（受限）"后缀与详情页横幅一律从 `summary.limitations` 派生——不依赖"恰好存在 permissionDenied 候选"。动态 provider 失败静默返回空（不阻塞扫描），但必须上报 limitation + 保留前缀，完整性不被无声吞掉。

## 5. 规则体系 v2

### 5.1 分类

```swift
enum DiskCleanCategoryID: String, CaseIterable, Sendable {
    case userEssentials, appCaches, systemCaches, logs, developer,
         browsers, cloudOffice, communication, aiTools, virtualization
}
```

每类携带 `risk`（展示排序低→高）、`consequence` 一句诚实后果文案（浏览器→"首次访问网站会稍慢"；开发者→"首次构建会变慢"）、SF Symbol。

### 5.2 target 级规则模型（评审 r2-#9、r3-#6）

```swift
struct DiskCleanRuleTarget: Sendable {
    let id: String                    // 稳定 target ID，如 "cache.user-essentials.caches"
    let legacyRuleID: String          // v1 规则 id（审计/迁移/快照测试）
    let category: DiskCleanCategoryID
    let risk: DiskCleanRisk           // target 级
    let kind: Kind                    // .path(glob: String) / .dynamic(DiskCleanDynamicRuleProviding)
    let reservedRootPaths: [String]   // 必填：规范化绝对保留根。无论 target 是否成功运行，
                                      // 被跳过/失败时 Planner 用它做祖先保护（§6.1）。
                                      // path 类由 glob 固定前缀推导后写死；dynamic 类由作者显式给出
                                      // （如 ~/Library/Developer/CoreSimulator/Devices）。
    let requiresFullDiskAccess: Bool
    let lockedByBundleIDs: [String]
    let skipWhenProcessIsRunning: [String]
}
```

候选携带 `targetID + legacyRuleID`。

### 5.3 所有权归属与祖先分解

1. **路径所有权**：同一路径被多 target 命中 → 归属最特定 target（glob 固定前缀最长者；并列取更高风险，宁严勿宽）。
2. **祖先分解**：候选 A 路径是候选 B 路径的祖先 → A 分解为直接子项（继承 A 的 target 归属与风险），递归至不含任何其它候选；B 保持独立身份（自己的风险/锁定/默认勾选）。
3. 祖先断言在 Planner 铸造与执行 preflight 执行（§6.1、§7.1）。

### 5.4 v1 → v2 权威映射表（快照测试 fixture 依据）

| v1 规则 id | v2 target(s) | 分类 | 风险 | 备注 |
|---|---|---|---|---|
| cache.user-essentials | `.caches` / `.logs` 两个 target | userEssentials / logs | low | 按 Caches、Logs 目标拆分 |
| cache.macos-app-state | 同名 | systemCaches | medium | |
| cache.apple-sandboxed-apps | 同名 | appCaches | low | |
| cache.cloud-storage | 同名 | cloudOffice | low | |
| cache.office-apps | 同名 | cloudOffice | low | |
| cache.virtualization | 同名 | virtualization | medium | 默认不勾选 |
| cache.communication | 同名 | communication | low | |
| cache.ai-assistants | 同名 | aiTools | low | |
| cache.creative-tools | 同名 | appCaches | low | |
| cache.productivity-media | 同名 | appCaches | low | |
| cache.utilities | 同名 | appCaches | low | |
| cache.games-notes-remote | 同名 | appCaches | low | |
| cache.launchers-system-utils | 同名 | appCaches | low | |
| developer.xcode-derived-data | 同名 | developer | low | |
| developer.xcode-user-caches | 同名 | developer | low | |
| developer.simulator-unavailable | 同名 | developer | medium | 动态实装（simctl） |
| developer.simulator-caches | 同名 | developer | low | |
| developer.package-manager-dynamic-caches | 同名 | developer | low | |
| developer.javascript-caches | 同名 | developer | low | |
| developer.python-caches | 同名 | developer | low | |
| developer.rust-go-docker | `.rust-go` / `.docker` 两个 target | developer | low / medium | docker 单独 medium、默认不勾选 |
| developer.mobile-caches | 同名 | developer | low | |
| developer.jvm-caches | 同名 | developer | low | |
| developer.jetbrains-toolbox-old-versions | 同名 | developer | medium | 动态实装 |
| developer.ai-agent-old-versions | 同名 | aiTools | medium | 动态实装 |
| developer.editor-caches | 同名 | developer | low | |
| developer.cloud-devops-caches | 同名 | developer | low | |
| developer.language-caches | 同名 | developer | low | |
| developer.database-api-caches | 同名 | developer | low | |
| developer.misc-caches | 同名 | developer | low | |
| developer.shell-network-caches | 同名 | developer | low | |
| developer.homebrew | 同名 | developer | low | |
| browser.safari / chrome / edge / arc-dia / brave / helium-yandex | 同名（Service Worker 目标单独 target） | browsers | low（SW 目标 medium） | |
| （新）browser.old-versions | 新增 | browsers | medium | 动态规则 |

快照测试：全体 target 的 legacyRuleID 去重集合 == v1 规则 id 集合；每条 v1 glob 在 v2 中恰有一个归属 target。规则 glob 本身不变（白名单与用户认知依赖）。

### 5.5 动态规则（`DiskCleanDynamicRules`）

```swift
protocol DiskCleanDynamicRuleProviding: Sendable {
    func expand() async throws -> [DiskCleanFileItem]
}
```

- `unavailableSimulators`：`xcrun simctl list devices -j` 解析 `isAvailable == false` 设备目录。simctl 不存在（未装 Xcode）→ 空。
- `jetbrainsToolboxOldVersions` / `oldBrowserVersions` / `aiAgentOldVersions`：版本目录排序比较，保留最新，旧版本为候选。
- 子进程统一 2s 超时；失败 → 返回空 + `dynamicRuleFailed` limitation + `reservedRootPaths` 进保留集，绝不阻塞扫描。
- 全部 `risk >= .medium`，默认不勾选。每个 provider 独立测试（fake 子进程输出 / 临时目录版本布局）。

## 6. 删除计划（Planner，唯一铸造点）

### 6.1 `DiskCleanPlan.swift`

`DiskCleanValidatedPlan.init` 为 **fileprivate**——除同文件 `DiskCleanPlanner.makePlan` 外无法构造（ticket-mint 模式；仓库外参照 Burrow `RunTicket`/`MoActions.decide`）。执行器只接受 ValidatedPlan。

```swift
struct DiskCleanValidatedPlan: Sendable {
    struct PlanItem: Sendable {
        let path: String
        let rootIdentity: DiskCleanRootIdentity
        let observedAt: Date
        let targetID: String
        let legacyRuleID: String
        let category: DiskCleanCategoryID
        let estimatedBytes: Int64
    }
    let items: [PlanItem]
    let mode: DiskCleanRemovalMode        // 冻结
    let totalEstimatedBytes: Int64        // 冻结
    let minObservedAt: Date               // 冻结，供执行 preflight 复核过期
    // 验证证据（评审 r3-#9）：执行器 preflight 重跑断言的依据
    let exclusionPaths: [String]          // 全体未入计划候选 + 锁定/保护/白名单/partial 路径
    let reservedPrefixes: [String]        // 被跳过/失败 target 的保留根
    fileprivate init(...)
}

@MainActor
enum DiskCleanPlanner {
    static func makePlan(
        artifact: DiskCleanScanArtifact,          // ScanEngine 产出的不可变工件
        selectedIDs: Set<DiskCleanCandidate.ID>,
        mode: DiskCleanRemovalMode,
        now: Date
    ) throws -> DiskCleanValidatedPlan
}
```

`makePlan` 校验（任一失败 `throw` → 不产出计划 = 零删除）：
1. `selectedIDs ⊆` artifact 可清理候选（complete、未锁定、非白名单/保护、大小已知、无挂载点）。
2. 排除集与保留前缀从 **artifact** 推导（Controller 只能递 selectedIDs 做减法，无法伪造/漏传）。
3. **祖先断言**：任何计划路径不得是任何排除路径或保留前缀的祖先。
4. 过期校验：`min(observedAt) + 300s > now`。

## 7. 执行器（安全核心）

### 7.1 计划级 preflight（删除任何一项之前）

1. 过期复核：`plan.minObservedAt + 300s > now`（评审 r3-#10：299s 铸造 + 60s 确认窗口不得越过门限）。
2. 重新获取运行应用/进程快照；对全体计划项做锁定/SafetyPolicy 预检。
3. 用 plan 携带的 `exclusionPaths + reservedPrefixes` **重跑祖先断言**（证据在计划内，可独立复核——防 Planner 缺陷，纯内存廉价）。

**任一失败：整次执行中止，零删除**，报告失败原因。

### 7.2 逐项复核链（任一失败跳过该项）

completeness == complete → 锁定复核（每项删除前重查快照）→ SafetyPolicy 二次校验 → §7.3 身份验证 → §7.4 冻结与删除 → 审计。

### 7.3 身份验证（fd 锚定）

1. 父目录 `open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY)`（全链拒 symlink）+ `fstatfs` 校验设备。
2. `fstatat(parentFd, name, AT_SYMLINK_NOFOLLOW)`：`(devid, fileID, fileType)` 必须 == 计划 rootIdentity；目录/文件还比对 mtime（文件另比对 size）→ 不符 `skipped(.changedSinceScan)`，UI 归类"内容已变化，请重扫"。

### 7.4 冻结与删除原语（评审 r3-#1、r3-#3）

**两种模式共用 freeze**（废纸篓不再走绝对路径 trash——`FileManager.trashItem` 会重新按路径解析，存在替换竞态）：

1. **journal 先行**（§7.6）：追加 `{stagedName, originalPath, mode, ts}` 并 `fsync`，然后才 rename。
2. **冻结**：`renameatx_np(parentFd, name, parentFd, ".mactools-staged-<uuid>", RENAME_EXCL)`——同父原子改名，RENAME_EXCL 保证不覆盖既有对象（uuid 冲突即失败重试新 uuid）。改名后 `fstatat` 暂存名复核身份。此后对象脱离原路径，路径替换窗口关闭。
3. **删除**：
   - `mode == .trash`：`FileManager.trashItem` 作用于**暂存路径**。放回原处会落在暂存名——审计与"清理历史"记录 `originalPath ↔ stagedName` 映射，历史界面提供原路径展示与恢复指引。这是"防错删"与"放回体验"之间的取舍：安全优先。
   - `mode == .permanent`：**非破坏性 prewalk**（fd 遍历暂存树：全体 devid 一致性、无异常）→ 通过后 fd 递归删除（`openat`/`fdopendir`/`unlinkat(AT_REMOVEDIR)` 全程 fd 相对）。prewalk 发现跨设备 → 回滚（见下）。删除中途 I/O 错误 → **`partiallyDeleted` 终态**：不回滚（树已半删，回滚无意义），journal 保留条目，审计如实记录，历史界面明示。
4. **回滚**（冻结后、删除前的失败）：`renameatx_np(parentFd, staged, parentFd, name, RENAME_EXCL)`——**原路径已被重建（缓存进程常见行为）→ 绝不覆盖**：保留 staged 对象、记 `failed(.rollbackBlocked)`、journal 保留，交 reconciliation/用户处理。
5. 普通文件候选：同一原语，删除步骤为单次 `unlinkat`，无 prewalk。symlink 候选：`unlinkat` 链接本身。

### 7.5 执行结果终态

`removed / trashed / skipped(reason) / failed(reason) / partiallyDeleted`。全部进审计与 UI 汇总；`partiallyDeleted` 与 `rollbackBlocked` 在历史界面置顶提示。

### 7.6 暂存 journal 与崩溃恢复（评审 r3-#4）

- `DiskCleanStagingJournal`：JSONL，位于 runtimeContext 插件支持目录。**写入顺序铁律：journal append + fsync → rename**；完成后追加 completion 记录。
- **启动 reconciliation**（插件 `activate` 时）：扫 journal 未完成条目——staged 对象仍存在 → 尝试 `RENAME_EXCL` 回滚；原路径被占 → 保留并在"清理历史"置顶提示"上次清理有未完成项"。
- **SafetyPolicy 保护 staged 名称**：末级组件匹配 `.mactools-staged-*` → `.protected("staging in progress")`——宽 glob 扫描永远不会把孤儿暂存对象当普通缓存收进候选；唯一允许触碰它们的是 reconciliation。

### 7.7 残余风险声明（写入代码注释与帮助文案）

- 删除目录即删除其执行时刻的全部内容；根身份一致 ≠ 深层内容与扫描时一致（根 mtime 只反映直接子项增删）。对缓存目录这是可接受语义。
- 估算字节 ≠ 实际释放（clone/稀疏/外部硬链接）；trash 完成文案"已移到废纸篓约 X GB"，不写"已释放"。

### 7.8 审计日志

JSONL 追加，插件支持目录：

```json
{"ts":"...","action":"trash|delete","targetID":"...","legacyRuleID":"...","category":"...",
 "path":"...","stagedName":"...?","estimatedBytes":0,
 "status":"ok|skipped|failed|partiallyDeleted","skipReason":"...?","error":"...?"}
```

另记扫描级事件（熔断、线程放弃计数、reconciliation 结果）。滚动：单文件 5MB，轮转 `.1`，保留 2 代。日志路径受 SafetyPolicy"cleanup tool state"分支保护。

## 8. 选择状态、状态机与 UI

### 8.1 SelectionModel（Controller 持有，权威）

- 纯逻辑类型，Controller 独占持有；详情视图与菜单栏只读 snapshot 投影、经 Controller 命令修改。
- **不可勾选（toggle 拒绝，非仅 UI 禁用）**：锁定（使用中）、白名单、保护、非 complete、未 sized、含挂载点。
- 默认勾选：`risk == .low` 且可勾选；medium/high 与动态规则产物默认不勾选。
- **流式候选 × 用户显式覆盖**：分类记录显式三态操作。无显式操作 → 新候选按默认策略；显式"全不选" → 不选；显式"全选" → 仅 low 且可勾选者加入——**"全选"语义 = "选中本类所有低风险项"**，UI 文案如此表述，medium/high 永不被全选带入。
- 派生：选中项数、估算字节，驱动按钮与副标题。

### 8.2 菜单栏面板

- 扫描 / 清理 / 打开详情 三个 actionRow。"清理"提交 Controller 选中集（不是全部 cleanable），按钮带"N 项 · 约 X GB"，0 或过期时禁用。
- "打开详情"：实现 `PluginConfigurationPresenting`，调用宿主注入的 `requestConfigurationPresentation?()`（现实现是空操作，需接线）。
- 扫描中副标题实时估算字节（~250ms 节流，AGENTS.md 高频源例外条款）；完成后 `summary.limitations` 非空 → 追加"（受限）"。

### 8.3 详情视图（自定义 configuration 视图）

`PluginSettingsSection` 声明式模型只支持状态/说明/按钮（不支持 switch/picker），故设置全部放自定义视图（DiskClean 本就自定义，符合"复杂交互"使用条件），`settingsSections` 不使用。布局（遵循 `PluginSettingsTheme`，FanControl 基线）：

1. FDA 状态卡（未授权时，§9）。
2. 受限横幅（由 limitations 派生）。
3. 分类卡片列表（风险升序）：图标 + 分类名 + 后果文案 + 约字节 + 三态勾选；展开逐项 路径/大小/徽标（使用中、白名单、部分-原因、内容已变化、挂载点）。
4. 开发产物 / 残留安装包 分段（§10）。
5. 设置区：删除方式 picker（废纸篓/永久）、开发产物根目录管理、清理历史（含 reconciliation 提示）。

### 8.4 状态机与确认（评审 r2-#7、r3-#10）

`idle / scanning / scanned / confirming / cleaning / completed`。

- `scanned --清理--> confirming`：**进入时即 `Planner.makePlan` 铸造计划**——mode/项数/字节原子冻结，确认界面展示冻结值。
- `confirming --> scanned` 的作废条件：用户取消；任何选择或删除方式变更；**确认窗口到期 = `min(进入后 60s, 过期门剩余时间)`**——确认窗口不得越过过期时刻；Controller 的 Clock deadline task 同样驱动此转换。
- 废纸篓模式 = 单步（按钮即"移到废纸篓 · N 项 · 约 X GB"；freeze 原语保证安全，可恢复故不设二次确认）。**永久模式 = 双步**：菜单栏显示确认对（"确认永久清理 N 项 · 约 X GB" + "取消"），详情视图 `confirmationDialog`；两入口共享同一 confirming 状态与冻结计划。
- 执行前 preflight 复核过期（§7.1），即使确认在门限边缘落下也不会越线。

## 9. FDA（插件本地，零共享代码）

- **探测**：能力探针——`FileHandle(forReadingAtPath:)` 依次试 `~/Library/Application Support/com.apple.TCC/TCC.db`、`~/Library/Safari/Bookmarks.plist`，开即关不读字节，失败静默（探测本身绝不触发弹窗）。
- **展示**：详情页 FDA 状态卡："完全磁盘访问未开启——部分系统缓存将被跳过" + "前往授权"（`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`）+ footnote"授权后请退出并重新打开 MacTools"（FDA 绑定进程启动）。
- **受限扫描**：`requiresFullDiskAccess` 的 target 在未授权时**直接跳过**（不逐目录触发 TCC 弹窗轰炸）→ 上报 `fdaRestricted` limitation + `reservedRootPaths` 进保留集（未扫描子树被视为存在，覆盖其祖先的候选被分解或排除，绝不顺带删除）。
- **未来路径（本期不做，仅记录）**：PluginKit v4 时统一处理 `PluginPermissionKind.fullDiskAccess` + loader 版本区间兼容 + 旧插件兼容测试 + app/plugin 双 changelog；届时迁移到宿主权限卡。

## 10. P2 清理域

### 10.1 开发产物清扫（`DiskCleanPurgeScanner`）

- **扫描根目录由用户配置**（详情页设置区管理，持久化插件 storage；默认空 + "添加文件夹"），不全盘扫描。
- 目标与工程标记（防误报，如 `~/Documents/build` 照片目录）：`node_modules/`（同级 `package.json`）、`target/`（同级 `Cargo.toml`）、`build/`、`dist/`（同级 `package.json`/`setup.py`/`pyproject.toml` 等）、`__pycache__/`（无条件）。
- 深度上限 6 层；命中即剪枝（不进 node_modules 内部找嵌套）。
- **git 警示**：候选所在仓库（向上找 `.git`）`git status --porcelain -unormal` + 未推送检查；有改动 → 徽标"仓库有未提交改动"，默认不勾选；git 失败/超时（2s）→ 视为有改动（fail-safe）。
- 展示为详情页独立分段，候选走统一管线（sizing/完整性/选择/Planner/执行原语全部适用）。

### 10.2 残留安装包（`DiskCleanInstallerScanner`）

- `~/Downloads` 顶层（不递归）：`.dmg/.pkg/.iso/.xip` 且 mtime > 7 天默认勾选；`.zip` 单独提示（可能非安装包）默认不勾选。
- 先探测 Downloads TCC 可达性再扫，不可达显示引导。普通文件 sizing 走 §3.2 分型路径。同样走统一管线。

## 11. 测试策略

| 对象 | 方式 |
|---|---|
| 属性解析 | RETURNED_ATTRS 缺失组合矩阵；单条缺属性 → fstatat 回退断言 |
| 根 opener | 分型（目录/文件/symlink）；O_NOFOLLOW_ANY 中间级 symlink 拒绝（临时目录构造链式布局）；fstatfs 设备校验 |
| Fast/SlowWalker | 已知树（硬链接跨目录、symlink、EPERM、深层）；devid 注入 fake 测挂载不下潜；两 walker 交叉验证 |
| WorkerPool | exactly-once 双向竞争；预算耗尽 → 熔断 fail closed（后续零 sizing）+ devid 黑名单 |
| ScanEngine | fake sizer 延迟/挂起：并发上限、超时 partial、取消不派生、onTermination；limitations 上报全枚举 |
| 缓存 | 身份三元组不符不命中（含"替换目录保留 mtime"）；TTL 240s；forceRefresh 绕过；partial 不入缓存；observedAt 传导 |
| Planner | 铸造校验矩阵：越权选择/祖先冲突/保留前缀冲突/过期 → throw；证据字段完整性 |
| Executor preflight | 过期/锁定/断言任一失败 → 零删除 |
| 执行原语 | 路径交换（fstatat 后替换 symlink/同名新目录 → changedSinceScan）；RENAME_EXCL 暂存冲突重试；回滚遇原路径被占 → 保留 staged + rollbackBlocked；prewalk 跨设备 → 回滚；删除中途注入 I/O 错误 → partiallyDeleted；trash 作用于暂存路径 |
| Journal/reconciliation | 崩溃点矩阵（journal 后 rename 前 / rename 后完成前）→ 启动回滚或置顶提示；SafetyPolicy 拒收 staged 名称 |
| Controller | confirming 冻结/作废矩阵（选择变更/模式变更/60s/过期边缘）；注入 Clock 的过期转换触发 onStateChange |
| SelectionModel | 三态语义、不可勾选拒绝、流式 × 显式覆盖矩阵 |
| 动态规则 | fake 子进程；超时降级 + limitation + 保留前缀 |
| PurgeScanner | 工程标记、剪枝、git fail-safe |
| 规则映射 | 快照：legacyRuleID 集合 == v1 id 集合；每条 v1 glob 恰有一个 v2 target；reservedRootPaths 非空 |
| 审计日志 | 字段完整性；5MB 轮转保留 2 代 |

临时目录 only（AGENTS.md：文件系统测试绝不触碰真实用户目录）。验证：`xcodebuild ... -only-testing:MacToolsTests/<ClassName>`。

## 12. 里程碑（每步独立构建+测试）

1. **M1 Sizing 子系统**：属性解析器 → 根 opener（分型/O_NOFOLLOW_ANY）→ FastWalker → SlowWalker → WorkerPool（exactly-once/预算/熔断 fail closed）。纯新增。
2. **M2 ScanEngine + Controller**：事件流 + 缓存 + limitations + 过期时钟 + Controller 消费/节流；删除旧 Scanner；面板等价迁移。`make build`。
3. **M3 规则 v2**：target 级模型（含 reservedRootPaths）+ §5.4 映射落地 + 动态 providers + 快照测试。
4. **M4 计划与执行（安全关键）**：Planner/ValidatedPlan（含证据）+ Executor preflight + 验证-冻结-删除原语（RENAME_EXCL/prewalk/partiallyDeleted）+ StagingJournal/reconciliation + SafetyPolicy staged 保护 + 双时点锁 + confirming 状态 + 审计日志。测试覆盖 §11 对应全部行。
5. **M5 UI**：SelectionModel 接线 + DetailView 重写 + `PluginConfigurationPresenting` + 确认交互 + 本地化 key（中文默认值）。`make build`。
6. **M6 FDA**：探测/状态卡/跳过 + 保留前缀 + limitation。
7. **M7 P2 域**：PurgeScanner + InstallerScanner + 根目录管理。
8. **收尾**：plugin.json 2.0.0（pluginKitVersion 3、minHostVersion 1.1.3）、README、一条 plugin changelog fragment（`release: plugin`, `type: changed`；无宿主改动故无 app fragment）。

## 13. 实现修正记录（里程碑完成后追加，后续里程碑以此为准）

**M1（Sizing 子系统，已完成，79 测试全绿）——对 §2/§3 的修正：**
1. **不请求 `ATTR_CMN_ERROR`**（修正 §3.3）：内核实测发现 returned 位为 0 时 ERROR 仍占 4 字节（与 `ATTR_FILE_*` 的真缺席语义不同），朴素位图解析会错位读出错误大小。以 NAME 的 `attr_dataoffset` 复核固定段边界，不符 → `hasLayoutMismatch` → 强制 fstatat 回退。逐条错误发现由 fstatat 回退覆盖。
2. **`DiskCleanSizeResult.rootIdentity` 为可选**（修正 §3.1）：根 open 失败与熔断拦截路径无身份可取。不变量：`rootIdentity == nil ⟺ completeness != .complete`（必然不可清理）。M2/M4 按可选消费。
3. **ELOOP 分支用父目录 fd 锚定**（修正 §3.2）：朴素 `lstat` 会跟随中间级 symlink。先 `O_NOFOLLOW_ANY` 开父目录，再 `fstatat(AT_SYMLINK_NOFOLLOW)` 确认末级。
4. **新增共用文件 `DiskCleanDirectoryTreeWalker.swift`**（修正 §2）：两 walker 共用 DFS 骨架 + 注入条目来源，防约束实现漂移；该接缝也是挂载穿越的测试注入点。
5. 其它已固化决策：`open` 一律加 `O_NONBLOCK`（防 FIFO 挂死烧预算），`FileType` 增加 `.other`；`ResumeGate` 拆 `claim()/deliver()`（放弃预算先于 resume 记账）；条目名保存原始字节 `[CChar]`（非法 UTF-8 文件名不丢字节）。
6. **路径约束（M2+ 全体适用）**：`O_NOFOLLOW_ANY` 拒绝任意一级 symlink，`/var`、`/tmp` 本身是 symlink——一切喂给 sizing/执行的路径必须是物理路径（`/private/var/...`）；规范化只能用 `realpath(3)`，`resolvingSymlinksInPath()` 语义相反。
7. M2 接线点：`DiskCleanWorkerPool.shared` 暴露 `isCircuitBroken` / `abandonedThreads`，供派生 `walkerCircuitBroken` / `threadsAbandoned` limitation。

**M4（计划与执行，已完成，314 测试全绿）——对 §6/§7/§8.4 的修正：**
1. **partiallyDeleted 时 journal 显式销账**（修正 §7.4"保留条目"）：保留条目会让下次 reconciliation 把半删的损坏树改名回原路径，应用会当它是完好缓存继续用。staged 残骸留在暂存名下，经审计/历史界面显式呈现。
2. **staged 名称保护放宽到路径任意一级**（修正 §7.6"末级组件"）：末级判定挡不住暂存树内部路径；误伤代价只是少清理一个目录，fail-safe 方向。
3. **`changedSinceScan` 与 `rollbackBlocked` 是独立执行终态**（修正 §7.5 归类）：塞进 `skipped(SafetyStatus)`/`failed` 会让 UI 无法区分"请重扫"与"路径非法"/普通失败；`rollbackBlocked` 需在历史置顶，用户动作不同。
4. 其它已固化：Controller/Planner 注入 `catalog`（默认 `.current`）；快照协议增加 `refreshingBundleIDs(in:)`（逐项刷 bundle ID、pgrep 沿用 preflight 一次）；递归删除与 prewalk 深度上限 128（每层持一个 fd，防 EMFILE/爆栈，触顶按失败处理）；DetailView 已带确认对（样式留 M5）。
5. **开放问题（M5 实测后裁决）**：目录 mtime 比对（§7.3）会让运行中应用的缓存频繁 `changedSinceScan`——若实测高频，考虑目录只比对 `(devid, fileID, fileType)`。
6. M5 接线点：`DiskCleanExecutionResult.attentionResults`（partiallyDeleted/rollbackBlocked 置顶展示）；reconciliation 结果需"清理历史置顶提示"UI；`DiskCleanScanArtifact.exclusionPaths` 已无调用方，M5 顺手清理其 TODO 注释。

**M5（UI 重写，已完成，348 测试全绿）——对 §8 的修正：**
1. **选择模型是无状态派生**（强化 §8.1）：模型只存"用户做过什么"（逐项覆盖 + 分类显式操作），选中与否由 `(候选事实, 覆盖, 分类操作)` 现算——流式新增候选无需补登记，跨事件窗口无脱节可能；`isSelectable` 直接复用 `DiskCleanCandidate.isCleanable`，不复写六条条件（两份必然漂移）。
2. **分类三态实为四态**：增加 `unavailable`（本类无任何可勾选项），与"有可勾选但没选"区分；类型刻意不命名 `none`（字典值位置会被解读为 `Optional.none` 删除键）。分类勾选框语义：有选中 → 全不选；零选中 → 全选低风险（含 medium 的类停在 partiallySelected 是预期，非 bug）。
3. **过期门保持"全体可清理候选最早 observedAt"**（未改 §4.4 的"选中项"口径）：全体是严格更早或相等的界，只会更早过期，fail-safe；执行侧权威门仍是 Planner 按真实选中项算的 `minObservedAt`。
4. 其它已固化：UI 拆出 `DiskCleanCategoryListView`/`DiskCleanCleanupHistoryView` 两文件；详情页保留扫描范围选择与默认收起的扫描日志；`ScanArtifact.exclusionPaths` 保留（ScanEngineTests 在用）并重写注释；删除无调用方的 `protectedCount`；`categoryFinished` 事件暂不消费（留 P2 分段）；`cleanSelected(candidateIDs:)` 改为无参 `clean()`，`canClean` 要求选中集非空。
5. **待办**：真机视觉验收（`make run` 看设置页）；§13-M4-5 的目录 mtime 裁决仍悬空，需真机跑通后定；新增 122 条 key 仅 zh-Hans，其余语言待翻译流程。

**M7 一阶段（scanner 核心，已完成，57 测试全绿）——对 §10 的修正：**
1. 发现遍历复用 SlowWalker 的条目源工厂（挂载防护/fd 契约/no-follow 与 walker 一致）；深度语义：根为 0，第 6 层参与判定、第 7 层不枚举；取消如实表现为 `partial([.timedOut])`。
2. **用户配置的 purge 根目录自身永远不会成为候选**（即使它本身名叫 node_modules）——设计未写明，现固化为契约。
3. `InstallerCandidate.byteSize` 只是 `st_size` 预览值，**不得**直接当 `estimatedBytes` 铸计划（须走统一 sizing）；`.denied` 不得退化为空列表（授权引导入口依赖它）。
4. **待补**：purge 发现遍历的跨设备分支无测试覆盖（需注入 fake 条目源伪造 devid），随二阶段集成补齐。

**M6（FDA，已完成）——对 §9 的修正：**
1. **标记口径**：`target` 的**每条** path glob 都落在 TCC 保护前缀内才置 `requiresFullDiskAccess`。混合 target 一律拆成两个（保持同一 `legacyRuleID`，v1 映射快照不受影响），绝不整体标记——否则会连可清理路径一起跳过。
2. **最终标 true 的 5 个 target**：`browser.safari`、`cache.apple-sandboxed-apps.containers`、`cache.office-apps.containers`、`cache.productivity-media.containers`、`cache.macos-app-state.protected`。快照测试 `testFullDiskAccessTargetSnapshot` + 前缀表反向推导测试双向锁死。
3. **不标记**：`~/Library/Caches` 本身、`Saved Application State`、`com.apple.helpd`、`GeoServices`、`DiagnosticReports`、`Autosave Information`、`IdentityCaches`——读得到的路径标记只会白白少清理；证据不足按不保护处理（猜错代价是降级成 `permissionDenied`）。
4. **探测**：`FileHandle(forReadingAtPath:)` 开-关不读字节，依次试 `~/Library/Application Support/com.apple.TCC/TCC.db` → `~/Library/Safari/Bookmarks.plist`；结果进程内缓存（FDA 绑定进程启动，UI 脚注"退出重开"）。
5. **引擎**：未授权时 `requiresFullDiskAccess` target 整体跳过（绝不触发逐目录 TCC 弹窗），产出 `fdaRestricted(skippedTargetIDs)` limitation，其 `reservedRootPaths` 进工件保留集。
6. **UI**：DetailView 顶部状态卡 + 前往授权按钮（`x-apple.systempreferences:...?Privacy_AllFiles`）+ 退出重开脚注；插件本地实现，零 PluginKit 改动。

**M7 二阶段（P2 集成，已完成）——对 §10/§8 的修正：**
1. **没有为 P2 写第二套状态机**：`DiskCleanScanScope`（`.rules(choices:)` / `.developerArtifacts(roots:)` / `.installers`），Controller 泛化后原样实例化三份——过期时钟、confirming、节流、operationID 世代零复制。
2. **合成 target**：`purge.<目录名>` 5 条 + `installer.<扩展名>` 5 条，`Kind.external`（引擎不展开）。按种类拆而非合并——`targetID` 原样写进审计日志。legacyRuleID 前缀不匹配任何 `DiskCleanChoice`，与引擎 scope 过滤形成双保险。
3. **风险映射**：合成 target 兜底 `.medium`；展开来源按候选事实覆盖成 `.low`。方向 fail-safe——漏给覆盖只导致不默认勾选。仓库脏 / 检查失败 / `.zip` / 近 7 天下载停在 medium，永不被"全选低风险"带入。`DiskCleanCandidate.notes` 纯展示，不参与可清理性。
4. **保留根**：purge 合成 target 静态 `reservedRootPaths` 为空（唯一例外）——改由展开时把**全体已配置根**无条件放进工件保留集；installer 的 `~/Downloads` 写死在合成 target 上。祖先断言拒绝以根为后代的计划路径，根内部候选不受影响。
5. **根级 partial 不下沉为候选级 partial**：候选自身完整性由统一 sizing 独立判定；根级 partial 是漏报不是误删面。只记 warning 日志。根**完全**不可读才上报 limitation。
6. **一切删除仍只有一条路**：P2 候选经统一 sizing → 完整性 → 工件 → `Planner.makePlan` → 执行器原语。合成 target 必须真实存在于目录，否则 `makePlan` 抛 `unknownTarget`。
7. **接口偏离**：`scan(choices:)` → `scan(scope:)`（保留 choices 便捷扩展）；`ScanArtifact/ScanResult.choices` → `scope`；`selectedChoices` 变计算属性；`DiskCleanCategoryID` 新增 `.developerArtifacts` / `.installers`（`.installers` 分类风险 `.medium`——安装包是用户文件，删错只能重下）。
8. **跨设备测试已补齐**（修正 M7 一阶段 §13 待补）：`DiskCleanPurgeScannerTests.testDoesNotDescendIntoDirectoryOnAnotherDevice` 注入伪 devid，断言不下潜 + `.crossedMountPoint`。
9. **验收基线**：独立复跑 35 测试类 **475 全绿**，`make build` 零警告。本地化审计测试仍红（130 个 key 仅 zh-Hans，M5 遗留 101 + M6/M7 新增 29，留给翻译流程，不编造译文）。

**M8（收尾）——版本与文档：**
1. `plugin.json` version → `2.0.0`（pluginKitVersion 保持 3，minHostVersion 保持 1.1.3）。
2. README / README.zh-CN 功能描述更新为覆盖开发产物扫描与残留安装包。
3. `changes/unreleased/` 一条 plugin fragment（`release: plugin`, `type: changed`）。

## 14. 风险与残余声明汇总

- 协作式超时：本地健康卷可靠；病态卷 → 跳过 + 熔断（fail closed，重启恢复）。abandoned 线程滞留有界（≤3）。
- 目录删除语义：根身份一致 ≠ 深层内容未变；缓存目录接受此语义。
- 废纸篓"放回"落在暂存名：安全（freeze 防错删）优先于放回体验；历史界面提供原路径与恢复指引。
- 估算字节 ≠ 实际释放：全文案用"约"。
- `partiallyDeleted` / `rollbackBlocked` 是诚实终态：删除中途失败不假装成功也不假装回滚。
