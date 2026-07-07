# 启动台跨页拖动重构设计（TODO §1）—— 2026-06-10

> 终审合成稿。输入：摸底简报（/tmp/launchpad-spike/crosspage-brief.md，22 条硬约束 + D1-D9 + 10 缺口）、两份独立设计（A-incremental / B-session）及各自 3 镜头对抗审查（constraints / races / tests）。
> 决策点全部落在简报倾向上：D1-A（externalDrag 幻影模型升格）/ D2-A（lift 即浮窗）/ D3-A+C（handoff 在注册点，page-indexed 注册表）/ D4 修订版（frame 停泊，禁 isHidden）/ D5-A / D6-A（驻留连翻）/ D7-A（coordinator 持页几何 + 显式算术——两份草稿各自偏离了 D7-A 的机制本义，均被审查否决，终稿回归倾向）/ D8-A（虚拟尾页）/ D9-A（identity 豁免）。无倾向违反硬约束，无需偏离。

---

## 0. 结论速览

**一句话**：把根页页内直拖升格为已验证的 eject 幻影模型（被拖项不属于任何容器 + coordinator 浮窗 + 每页容器只做让位/merge 分类），coordinator 升格为跨页 carry 会话 owner；**数据在 mouseUp 同步落库、settle 动画纯视觉**——这一条时序裁决一次性消解了六组审查中的 4 个 blocker。

**章节裁决表**（骨架 = 该章以哪份设计为主体；嫁接 = 从另一份并入的更优局部）：

| 章 | 骨架 | 嫁接与修正 |
|---|---|---|
| §1 会话模型 | B（显式状态机 + 表驱动完备性测试） | commit 时序改 A（mouseUp 同步提交，token 仅视觉通道）；数据通路按审查改为注入 storeApplier，彻底离开 View 层 |
| §2 锚 cell | B（anchorCell 不占用 draggedCell——结构性绕开两家审查共同命中的 :606 互斥 guard 雷） | A 的 seedGap 恒等布局、grab-offset 保持、夹 cell cacheDisplay 快照 |
| §3 handoff | 合成：A 的 page-indexed 全量注册表 + 两家都独立发现的 apply 注册死锁修复 | 驱动改单一 currentPage 漏斗（A-tests 修正）；兜底改容器身份比较的 reattachIfNeeded（修 A 的死代码兜底） |
| §4 边缘翻页 | B（page-local 判定 + 状态×输入全定义转移表） | A 的 Timer 驱动细节；动画常量互锁按 B-tests 修正 |
| §5 页几何 | 两家皆被否（A 的 convert 标定、B 的 convert+补偿都偏离 D7-A），终稿回归 D7-A 本义：纯推送 + 显式算术，热路径零 convert | A 的「几何突变即 cancel」fail-safe；运行时探针降级为交叉校验 |
| §6 虚拟尾页 | A 的消费点审计清单 | B 的「有意分歧」声明；落点语义按 AR-7 重写为「全局落尾 + 动画回落」 |
| §7 settle | A（数据先行 + park/reveal 协议 + 超时兜底） | B 的 resolveExternalDrop 纯 peek 与 FloatingIconPresenting 抽象；park 谓词按 AC-3 扩为三元 |
| §8 豁免 | 两家一致 | gate 键从 carryActive 升级为 session != nil（覆盖 settling 期） |
| §9 生命周期 | 两家矩阵取并集 | 审查新增行：右键、scroll 残留、settling 重入、commit 已落库声明 |
| §10 测试 | 两家并集 | 注入缝按 BT-5/AT-3 补全；纯函数化使 commit 路由可单测 |
| §11 落地顺序 | A 的步进粒度 | B 的「eject 先迁会话骨架」次序；BT-7 的过渡 clamp 说明 |
| §12 不做什么 | 并集 | — |

**五个关键合成裁决**（每个都对应一簇 blocker/major）：

1. **commit 在 mouseUp 同步落库**（废弃 B 的 settle-后-commit）：解析→纯函数→注入 storeApplier 直写 store，`commitToken` 退化为纯视觉通道（relocateSelection/关夹/清快照），视图拆除时丢失无害。消解 BC-1/BR-1/BT-1/BT-2/AC-7/BR-2，且现有 eject 测试的同步 token 断言天然保绿。
2. **锚 cell 走 anchorCell 新字段，不设 draggedCell**：`beginExternalDrag` 的互斥 guard（LaunchpadDragGrid.swift:606）原样保留，硬约束 9 的「与本地拖互斥」语义零重新协商。消解 AC-B1/AR-M1/AT-B1。
3. **页几何纯推送，热路径零 convert**：GridView 经 GeometryReader 推送 viewport 的 window 空间 frame，coordinator 纯算术换 page-local 点喂容器新入口 `updateExternalDrag(atContainerPoint:)`。消解 AC-4/BC-3/AC-5/BT-3，并独立修掉 page>0 出夹落点 bug。
4. **handoff 双驱**：单一 `.onChange(of: currentPage)` 漏斗（覆盖一切翻页入口，含未来新增）+ 注册表按容器身份的 `reattachIfNeeded` 兜迟到 mount。消解 AT-2/AT-4/AR-10。
5. **settling 是显式状态**：mouseUp 后浮窗飞行期间事件全定义（重入 lift = force-complete、cancel = 快进 reveal、注册不触发 handoff、手动翻页被 session != nil gate），settle 回调带 generation token。消解 AR-6/BR-3/BR-4。

**新类型总览**：

| 新类型 | 位置 | 职责 |
|---|---|---|
| `LaunchpadCarrySession`（@MainActor class，coordinator 持有） | 新文件 LaunchpadCarrySession.swift | 会话身份（itemID/origin/isApp/frozenVisibleOrder/editableAtBegin）、状态机、turner、dwell timer、浮窗抽象、last 点 |
| `LaunchpadEdgePageTurner`（internal struct，纯状态机） | 新文件 LaunchpadEdgePageTurner.swift | dwell/cooldown/驻留连翻判定，时间与几何全参数注入 |
| `LaunchpadPageGeometry` + `LaunchpadCarrySpace`（纯值） | 新文件 LaunchpadCarrySpace.swift | 推送几何快照；window 点 ↔ page-local 点 ↔ screen 的全部显式算术 |
| `LaunchpadFloatingIconPresenting`（protocol + 生产实现 + 工厂注入） | LaunchpadDragCoordinator.swift 旁 | 浮窗建/移/settle(to:completion:)/dismiss；测试换 spy |
| `LaunchpadCarryCommit` + `CarryStoreAction` + `resolveCarryCommit`（纯函数） | coordinator | 落点解析与 store 动作映射（含 isNoOp/落尾），可直驱单测 |
| `LaunchpadFlipRequest { token, targetPage }` | coordinator @Published | 翻页请求通道（约束 2） |
| `LaunchpadPageAnimation { snapResponse, snapDamping, snapVisualSettle }` | 共享常量文件 | pageSnap 弹簧参数与视觉沉降估值互锁（BT-4） |

现有名字演化：`ejectActive` → `carryActive`（任意 carry）+ `folderEjectActive`（仅 folder origin，驱动关夹 onChange 与夹缩略图过滤）；`ejectToken`/`pendingEject` → `commitToken`/`pendingVisualCommit`；`registerRootContainer` → `registerPageContainer(_:page:)`；`beginEject/moveEject/commitOut/cancelEject` 保留为薄 shim 供现有 7 个 eject 测试，内部转 `beginCarry/carryMoved/carryReleased/cancelCarry`。

---

## 1. 统一 carry 会话模型

### 1.1 会话类型与归属

```swift
@MainActor
final class LaunchpadCarrySession {
    enum Origin: Equatable {
        case rootPage                        // 根页 lift 即 carry（D2-A）
        case folder(sourceFolderID: String)  // 夹内直拖越界后升格（现 eject）
    }
    enum State: Equatable {
        case carrying(Mode)                  // 浮窗跟手，mouse 仍按着
        case settling(generation: Int)       // mouseUp 已收、数据已落库，浮窗飞行中（纯视觉）
    }
    enum Mode: Equatable {
        case tracking                            // 喂分类 + 喂 turner
        case awaitingHandoff(targetPage: Int)    // flip 已发布，等新容器接管；分类挂起
    }
}
```

终态不设 `.ended` 枚举值——会话结束即 `coordinator.carrySession = nil`，「ended 全忽略」由所有入口的 `guard let session` 表达，杜绝僵尸会话引用（B 的 .ended 终态在 BC-1 场景下恰好成了「永停 committing」事故的载体，去掉它结构上更安全）。

**三层各持有什么**（D3-A：几何与让位留容器级）：

- **coordinator（唯一跨页幸存者，约束 4）**：`carrySession?`、page-indexed 弱引用注册表 `pages: [Int: Weak<LaunchpadGridContainerView>]`、`weak var currentTargetContainer` + `currentTargetPage`、`LaunchpadPageGeometry`（普通存储，不 @Published——值写零成本，约束 22）、注入的 `storeApplier: (CarryStoreAction) -> Void`（OverlayController 构造时注入，见 §1.3）、`floatingPresenterFactory`（测试缝）、`@Published carryActive` / `folderEjectActive` / `flipRequest` / `commitToken`、非 published 的 `pendingVisualCommit`、`settlingItemID` + `settleGeneration`、`endReason`、`isCarryAllowed`（GridView 推送的编辑性 gate）。
- **session 持有**：itemID、origin、isApp（merge 资格）、`frozenVisibleOrder: [LaunchpadDisplayCell]`（onDragBegan 冻结快照随会话走——快照归属单点化，AR-11/AT-5）、editableAtBegin、`LaunchpadEdgePageTurner`、dwell Timer（注入驱动）、lastScreen/lastWindow/lastLocal 点、浮窗 `LaunchpadFloatingIconPresenting`。
- **容器（不动）**：`externalGapIndex`、`stackTargetCell`、±6 粘滞滞回、mergeRect 死区、`layoutCellsWithGap`、`isDragging → pendingGrid` 延迟 apply（约束 9）、新增的 `anchorCell` 停泊（§2）。**gap 状态归容器（gap1 裁决）；不变式：任意时刻至多一个容器 externalDragActive，由 §3 的 handoff 单点保证。**
- **SwiftUI GridView**：currentPage/selectedIndex/pageDragTranslation/searchText 原样；新增 `.onChange(flipRequest)`、`.onChange(commitToken)`（仅视觉）、`.onChange(of: currentPage)` 推送漏斗、`displayPageCount`、geometry 推送。

### 1.2 事件全集与转移表（状态 × 事件全定义）

事件：`lift(origin)`｜`moved(screen, window)`｜`tick(now)`｜`containerRegistered(container, page)`｜`released(window)`｜`cancel(reason)`｜`settleFinished(gen)`/`settleTimeout(gen)`。
cancel reason：`.overlayClosed` / `.anchorUnmounted` / `.searchActivated` / `.geometryChanged` / `.shutdown`。

| 状态 \ 事件 | lift | moved | tick | containerRegistered | released | cancel | settleFinished/Timeout |
|---|---|---|---|---|---|---|---|
| **idle**（session == nil） | gate 链（§9.2）通过 → 建会话 → carrying(.tracking)；**gate 失败返回 false，容器不得改动任何自身状态**（BR-4：gate 提到容器侧步骤 0） | 忽略 | 忽略 | 仅更新注册表 | 忽略 | 忽略（nil-safe，约束 1 调用点不变） | gen 不匹配 → 忽略（杜绝 stale 回调，AR-6） |
| **carrying(.tracking)** | 拒绝（guard session == nil） | 移浮窗（保 grab-offset）；CarrySpace → local 喂 `currentTargetContainer.updateExternalDrag(atContainerPoint:)`；记 last 点；turner.update → 若 `.flip(d)` 且目标页 ∈ 合法区间（§4.4）→ 发布 flipRequest → `.awaitingHandoff(target)` | turner.update(lastLocal)（光标静止时唯一驱动，约束 3） | `reattachIfNeeded`（容器身份比较，§3.3） | §1.4 released 序 → settling(gen+1) | §9 全同步收尾 → idle | 忽略 |
| **carrying(.awaitingHandoff)** | 拒绝 | 只移浮窗、记 last 点；**不喂分类**（滑出画面干净） | turner.update（推进 cooldown；fire 被 cooldown 结构性压制） | 若 page == target 且容器非当前 → handoff → `.tracking` → 立即重喂 last 点（gap 不等下次 mouse 事件即开） | **先撤销 flipRequest = nil**（AR-5/BR-3a），再走 released 序（从当前已注册容器解析；容器 nil → 兜底，§1.4-2） → settling | 同左（含撤销 flipRequest）→ idle | 忽略 |
| **settling** | **force-complete 当前 settle**（立即 reveal + 拆浮窗 + session=nil），再按 idle.lift 开新会话——iOS 允许立刻再抓（AR-6/BR-4） | 忽略（鼠标已抬，防御性吞掉） | 忽略（timer 已停） | 仅更新注册表，**不触发 handoff**（session 非 carrying；BR-3c/d 消解：gap 会话已在 released 序同步收口，注册表换走无副作用） | 忽略 | force-complete（reveal + 拆浮窗）→ idle；**数据已在 mouseUp 落库，无 commit 丢失**（BC-1 消解） | gen 匹配 → reveal + 浮窗 dismiss + settlingItemID=nil + session=nil → idle |

孤儿事件双保险：会话被外部 cancel 后，锚 cell 的 mouseDragged/mouseUp 仍会到达——容器转发分支因 `carryActive == false` 早退，cell 层 `didDrag` 已置位保证 mouseUp 不误当点击启动 app（约束 16 同款机制）。

### 1.3 commit 路由（gap5）——数据通路离开 View 层

```swift
struct LaunchpadCarryCommit {
    let itemID: String
    let origin: LaunchpadCarrySession.Origin
    let result: LaunchpadExternalDropResult       // 复用现有三分支数据模型
}
enum CarryStoreAction: Equatable {
    case move(id: String, target: LaunchpadDropTarget?)   // nil = 落尾
    case makeFolder(targetAppID: String, draggedID: String)
    case addToFolder(folderID: String, appID: String)
    case moveOutOfFolder(folderID: String, appID: String, result: LaunchpadExternalDropResult)
    case none                                              // isNoOp——跳过写盘，settle 照常飞回原槽
}
static func resolveCarryCommit(_ commit: LaunchpadCarryCommit,
                               frozenOrder: [LaunchpadDisplayCell]) -> CarryStoreAction
```

`resolveCarryCommit` 是纯函数（AT-5）：`.folder(fid)` → `.moveOutOfFolder`（store 现有逻辑含 nil-target 落尾、2-app 解散重定向，零改动）；`.rootPage` + `.reorder(.some(t))` → isNoOp 守卫（对 frozenOrder 判，DragGrid.swift:24-36 复用）后 `.move`；`.rootPage` + `.reorder(nil)` → frozenOrder 末项 == itemID 时 `.none`，否则 `.move(after: 末项)`（末项可为 folder 节点——`move(after: folderID)` 是既有合法操作，BR-8 点名）；`.makeFolder`/`.addToFolder` 直映射。

**storeApplier 由 OverlayController 构造 coordinator 时注入**（它同时持有 layoutStore 与 coordinator，LaunchpadOverlayController.swift:59）：执行 `captureVisibleOrder(frozenOrder)`（字母序物化，约束 15）+ 对应 store mutation，记录 landingID（makeFolder 返回新夹 id）供视觉通道用。编辑性判定用 `session.editableAtBegin`（会话起点冻结，不实时查 isLayoutEditable——BR-2 防御；实际上 mid-carry 切搜索会先触发 cancel，mouseUp 时刻该值必为 true）。

**mouseUp 同步序**：resolve → action → storeApplier 直写（@Published layout 正常 invalidate 视图，不踩「mouse handler 改 @State 不刷新」雷——@State 突变全部不在此通路）→ `commitToken += 1`。GridView `.onChange(of: commitToken)` 只做视觉：folder origin 的 `openFolderID = nil`、`relocateSelection(to: landingID)`（identity-anchored，约束 20）、`dragOrderSnapshot = nil`、必要的 currentPage 归位 withAnimation(pageSnap)。视图先拆则视觉丢失无害——数据已安全。

### 1.4 released 精确序（mouseUp 同步执行，编号即顺序）

1. `currentTargetContainer?.updateExternalDrag(atContainerPoint: lastLocal)` ——**终点重喂**：翻页后光标静止松手时新页尚无 gap，先喂一次终点分类再解析，落点回到光标槽而非退化落尾（AR-4）。
2. `(result, settleRect) = currentTargetContainer?.resolveExternalDrop() ?? (.reorder(空兜底), nil)` ——纯 peek，不碰状态（§7.1）；容器 nil 时保留 rootDropTarget 等价兜底：经 CarrySpace 喂 `rootDropTarget(atContainerPoint:)` 新入口。
3. `currentTargetContainer?.freezeExternalDrag()` ——清 externalDragActive/gap/stackTarget 旗标但**不重排**，让位 frame 原地冻结（消掉现 :668 `defer endExternalDrag` 的双重移动，BR-5）。
4. `flipRequest = nil`；停 dwell timer；turner.reset()。
5. `action = resolveCarryCommit(...)`；`storeApplier(action)`（`.none` 跳过写盘）。
6. `settlingItemID = itemID; settleGeneration += 1`。
7. 源容器 `endCarryAnchor()`：anchorCell 引用清空前先记 layoutID、`isDragging = false`、apply pendingGrid（root origin **改 apply 不丢弃**——丢弃会让源页停留陈旧模型；folder origin 沿用 teardownDragState 的丢弃，夹要关）、needsLayout——锚 cell 受 settlingItemID 谓词保护保持停泊（§7.3）。
8. `endReason = .committed; carryActive = false`（虚拟页收回）；`commitToken += 1`。
9. 浮窗 `settle(to: settleScreenRect, completion: { settleFinished(gen) })` + 0.5s timeout 兜底（均带 gen）；hard-cut 中间版直接 `settleFinished(gen)`。

### 1.5 与 eject 三件套及本地直拖的关系

**复用不替换**。容器侧四件套职责保持，扩展点收敛为一条容器级不变量：**begin/update/resolve/freeze/end 五个入口对 anchorCell 的排除规则统一为 activeCells 投影**（逐函数清单见 §2.2，避免逐处遗漏——AR-M1 教训）。`beginExternalDrag(itemID:allowsMerge:seedGap:)` 扩签名：folder 被携带时 `allowsMerge = false`（现 external 路径无此检查，因 eject 只携 app）；`commitExternalDrag()` 保留为兼容 shim（= resolve + end，默认行为不变），供迁移期 folder 旧路径与现有测试（LaunchpadDragToStackTests.swift:240/:252/:265 的无参调用编译不破，AT-7）。

**本地直拖状态机（beginDirectDrag/dragOrder/updateDrag/commitDrop）完整保留**：夹内网格继续用它做夹内重排；`coordinator == nil` 的容器（全部现有测试夹具默认值）走原路径，121 个既有测试不动。根页路由开关在 `beginDirectDrag` 内：`grid.folderContextID == nil && grid.coordinator != nil` → carry 分支（先问 coordinator 能否开会话，拒绝则整个 begin no-op），否则原样。

**容器转发分支的位置写死**（AR-3/BC-5/BR-7）：`updateDirectDrag` 与 `endDirectDrag` 的 carry 转发分支**置于各自 draggedCell guard 之前**（:332 / :418），仅以 `grid?.coordinator?.carryActive == true` 为键（覆盖两种 origin；root carry 不设 draggedCell，按原位置实现事件会被 guard 吞死）。现 :336-341 的 ejectActive 分支被此统一分支吸收。

---

## 2. 拖拽承载与锚 cell（D4 修订版）

### 2.1 根页 lift 即浮窗流程

cell 仲裁不动（6pt + allowsCustomOrderActions，DragGrid.swift:1005-1018）。`beginCarryLift` 顺序（一个 MainActor 帧内）：

1. **先问 coordinator**：`coordinator.beginCarry(...)` gate 链不过 → return，容器零状态改动（BR-4；手势由已置位的 didDrag 吞掉）。
2. `isDragging = true`（pendingGrid 延迟纪律照常，约束 9）；`anchorCell = cell`；**不设 draggedCell、不设 dragOrder**（dragOrder 残留会让 layout() 回退分支按含锚顺序留洞，AC-2）。`hasActiveDrag` 重定义为 `draggedCell != nil || anchorCell != nil`（hover 抑制 :991 继续生效；右键防御另升 coordinator 级，§9.3）。
3. `grid.onDragBegan()` → GridView 冻结 dragOrderSnapshot，并**把快照交给会话**（`session.frozenVisibleOrder`，约束 15 + AR-11）。同一闭包内 GridView 清场翻页器残留：`pageScrollEndWork?.cancel(); pageDragTranslation = 0`（无动画归零，AC-6/BC-2）。
4. 取浮窗视觉：app 用 `cell.primaryIcon`；**夹 cell 必须走 `cell.cacheDisplay(in:to:)` 快照**（夹面板是 draw 出来的，primaryIcon 为 nil）。浮窗定位 = 光标 − grabOffset（保抓取点，免 lift 视觉跳变；eject 维持居中不动）。
5. coordinator：标定 CarrySpace（§5，纯推送值，此刻条带已被步骤 3 清场保证静止）→ 经 floatingPresenterFactory 建浮窗（borderless / ignoresMouseEvents / level+1，DragCoordinator.swift:53-66 原样搬进生产实现）→ `pages[currentPage].beginExternalDrag(itemID:, allowsMerge: isApp, seedGap: 锚在 activeCells 的序)` → 启 dwell timer（注入驱动）。
6. 容器停泊锚：`cell.setFrameOrigin(carryParkOrigin)`，`carryParkOrigin = (-100_000, -100_000)`。

**seedGap = 锚原槽位** → `layoutCellsWithGap` 对 activeCells 是恒等布局：lift 瞬间棋盘纹丝不动、原槽位即让位 gap、图标浮起——iOS 拿起观感，且不依赖首帧分类喂点。

**停泊语义**：禁 `isHidden`（spike：mouseDragged/mouseUp 永久丢失）；不用 `alphaValue = 0`（非 layer-backed 视觉存疑，约束 8）。-100k 保证在任何窗口可视区之外（macOS 14 起 `clipsToBounds` 默认 false，不能指望容器裁剪）；停泊后 trackingArea/hitTest 都落空，不产生杂散 hover/命中；spike 已证事件流继续投递给 mouseDown 视图。`isLifted` 不置位——放大视觉由浮窗承担（iconSide × 1.1）。

### 2.2 锚 cell 的排除面（逐处清单 + 不变量）

容器新增 `private weak var anchorCell` 与 `var activeCells: [LaunchpadGridCellView] { cells.filter { $0 !== anchorCell } }`。**布局跳过谓词统一为三元**（AC-3）：`cell !== draggedCell && cell !== anchorCell && cell.layoutID != grid?.coordinator?.settlingItemID`。

| 位置 | 改法 |
|---|---|
| `layoutCells` 两条路径（:247、:255） | skip 谓词换三元版（锚与 settling cell 永不被写回槽位，约束 10 同理） |
| `layout()` override（:209-219） | externalDragActive 走 gap 路径（已是 activeCells）；**回退分支在 anchorCell != nil 时以 activeCells 为 order**（紧凑布局、邻居补位——handoff 离开源页后任何意外 layout pass 不再打回留洞布局，AC-2） |
| `layoutCellsWithGap`（:648-662） | 迭代 activeCells，且应用三元 skip（锚留停泊点） |
| `updateExternalDrag`（:617-643） | `!cells.isEmpty` → `!activeCells.isEmpty`；slot/target 全取 activeCells；新增 `atContainerPoint:` 入口（coordinator 喂已换算的本地点，原 windowPoint 入口保留给夹内/遗留路径与 :621 测试缝） |
| `resolveExternalDrop` / `rootDropTarget` | gap→id 映射基于 activeCells——锚天然不可能成为 .before/.after 目标，免掉自指 isNoOp 边角 |
| `rebuildCells` | 不需要改——carry 期间源容器 apply 全程被 isDragging 延迟（pendingGrid），rebuild 不会发生（约束 5/18） |

### 2.3 回收路径

- **commit**：§1.4-7 的 endCarryAnchor + needsLayout；锚受 settlingItemID 谓词保持停泊，post-commit apply 按 layoutID 复用（同页落点）或 removeFromSuperview（跨页落点）；reveal（§7.3）是唯一 un-park 入口。**no-op commit 不再「直接 return 跳过一切」**：仅跳过写盘，settle 飞回原槽 + reveal 照常——「原位抖一下放手」后图标不会消失（AR-1 的根治：不靠特判，靠管线无条件走完）。
- **cancel**：`cancelCarryAnchor()` 清 anchorCell + needsLayout，settlingItemID 未置位，layoutCells 把锚写回真实槽位——即时复原，fail-safe。

---

## 3. 跨页交接 handoff（gap1）

### 3.1 注册点改造（先修两家都发现的隐藏死锁）

现状 `apply()` 的注册在 `guard !isDragging else { pendingGrid = grid; return }` 之后（DragGrid.swift:165 vs :174）。root carry 中源容器 isDragging = true：翻走再翻回源页时源容器永远不会重注册，handoff 在「拖出去又拖回来」这个最常见路径上直接失效。改法：

```swift
func apply(grid: LaunchpadDragGrid) {
    // must not read self.grid — deferred apply keeps it stale (BC-6)
    if let page = grid.pageIndex { grid.coordinator?.registerPageContainer(self, page: page) }
    guard !isDragging else { pendingGrid = grid; return }
    ...
}
```

`LaunchpadDragGrid` 新增 `pageIndex: Int?`（GridView pageContent 传 page；夹网格为 nil 不注册）。注册是纯字典写 + reattach 检查，不碰 cells，提前安全（对抗复核已确认 handoff 不读 self.grid，注释锁防未来回归）。`viewWillMove(toWindow: nil)` 反注册。所有页容器全量注册（非仅 isCurrentRootPage）——`pages[target]` 在翻页瞬间必已可用。eject 旧 `rootContainer` 指针改读 `pages[geometry.currentPage]`。

### 3.2 驱动：单一 currentPage 漏斗

**不枚举翻页入口**（goToPage/snapToNearestPage/handleMove/relocateSelection/hideApp/searchText reset 共六处直改 currentPage——枚举必漏，AT-2）。GridView 根部：

```swift
.onChange(of: currentPage) { dragCoordinator.currentPageDidChange($0) }
```

```swift
func currentPageDidChange(_ page: Int) {
    geometry.currentPage = page
    guard let session, session.isCarrying, page != currentTargetPage else { return }
    currentTargetPage = page
    currentTargetContainer?.endExternalDrag()          // 旧页 gap 动画收口
    currentTargetContainer = pages[page]?.value
    currentTargetContainer?.beginExternalDrag(itemID:, allowsMerge:, seedGap: nil)
    session.resumeTracking()                            // .awaitingHandoff → .tracking
    feedLastPoint()                                     // 新页 gap 即刻打开，不等下次 mouse 事件
}
```

时序：flipRequest → `.onChange` → goToPage（withAnimation(pageSnap) 改 @State，受控事务，约束 2）→ 同一更新周期内 currentPage 漏斗 → handoff。非 lazy HStack 全量挂载（GridView.swift:225）保证目标页容器早已在注册表。翻页动画进行中新容器即开始让位——iOS 同款（滑入时已让位），分类坐标用动画终态（§5.2）。

### 3.3 兜底：按容器身份的 reattachIfNeeded（修 A 的死代码兜底，AT-4/AR-10）

```swift
func reattachIfNeeded(_ container: LaunchpadGridContainerView, page: Int) {
    guard let session, session.isCarrying,
          page == currentTargetPage, container !== currentTargetContainer else { return }
    currentTargetContainer?.endExternalDrag()
    currentTargetContainer = container
    container.beginExternalDrag(itemID:, allowsMerge:, seedGap: nil)
    session.resumeTracking(); feedLastPoint()
}
```

注册时调用。幂等判据是**容器身份（===）而非页号**——覆盖「页号已对、容器未接管」的两种迟到路径：虚拟尾页容器晚于 flip 才 mount（理论竞态）、pageCount 收缩 clamp 后同页换容器。`currentPageDidChange` 与 `reattachIfNeeded` 共享同一 begin/end 原语，两端幂等。

gap 状态归属结论（gap1）：gap/merge/滞回/死区留容器；「谁是活动容器」归注册表；end/begin 配对只发生在漏斗 + reattach + viewWillMove 自清三点，共同维持单活跃不变式。空容器（虚拟页）的 begin 照常置位（:606 守卫不查 cells）；`updateExternalDrag` 被 `!activeCells.isEmpty` 挡住（空页无让位者，正确）；**可落性来自 resolve 分支而非 update 分支**（`guard let gap, !cells.isEmpty else { return .reorder(nil) }`，:673 现成）。

---

## 4. 边缘翻页状态机（D5/D6/gap6）

### 4.1 纯状态机 API（B 骨架）

```swift
struct LaunchpadEdgePageTurner {
    struct Config {
        var dwell: TimeInterval = 0.7
        var repeatCooldown: TimeInterval = 0.8    // 驻留连翻节拍（D6-A）
        var edgeWidth: CGFloat = 44
        // 不变式：dwell ≥ snapVisualSettle && repeatCooldown ≥ snapVisualSettle
    }
    enum Zone: Equatable { case left, right }
    enum Decision: Equatable { case none, flip(direction: Int) }
    enum State: Equatable { case idle, arming(zone: Zone, since: TimeInterval),
                            cooldown(zone: Zone, readyAt: TimeInterval) }
    private(set) var state: State = .idle
    mutating func update(point: CGPoint, pageWidth: CGFloat, now: TimeInterval) -> Decision
    mutating func reset()
}
```

`point` 是 §5 算出的 **page-local** 点（与喂分类的同一个——一份算术两用）。Zone 判定只用 x 且**显式包含越界值**：`x < edgeWidth → .left`（含负值——光标在条带 48/24pt padding 或更靠屏缘时 page-local x < 0）、`x > pageWidth − edgeWidth → .right`（含超界）。这同时解决了 AC-5 的两个问题：不再需要不可靠的「窗口宽」数据源；compact 模式 24pt padding 区天然归入热区，「够不到」不存在。热区与首末列 slot 的轻微重叠是 iOS 同款行为，接受并列入真机调参项。时间全参数注入（约束 21，HotCornerMonitor 模式升级版）。

### 4.2 转移表（全定义）

| 状态 \ 输入 | 点在 zone Z | 点在另一 zone Z′ | 点不在 zone |
|---|---|---|---|
| idle | → arming(Z, now)；.none | （同左） | idle；.none |
| arming(Z, since)，now−since < dwell | 保持；.none | → arming(Z′, now)（换边重计）；.none | → idle；.none |
| arming(Z, since)，now−since ≥ dwell | → cooldown(Z, now+cd)；**.flip(Z)** | → arming(Z′, now)；.none | → idle；.none |
| cooldown(Z, readyAt)，now < readyAt | 保持；.none | → arming(Z′, now)；.none | → idle；.none |
| cooldown(Z, readyAt)，now ≥ readyAt | → cooldown(Z, now+cd)；**.flip(Z)**（驻留连翻：第二次起按 0.8s 节拍连发，不再重计 dwell） | → arming(Z′, now)；.none | → idle；.none |

驱动源两个：moved 事件（光标移动中）与 30Hz Timer tick（光标静止——mouseDragged 停发，Timer 是唯一驱动；显式 add 到 RunLoop.main 的 `.eventTracking` 与 `.common` 两个 mode，约束 3）。两者收敛到同一 `update(point: lastLocal, ...)` 调用，无第二份状态（约束 4）。tick 只读 last 点 + turner.update，O(1) 零 IO（约束 22）。**Timer 驱动经注入缝**（`dwellTickDriver`，默认真 Timer，测试注入手动泵——AT-6 的泄漏与 flaky 源根治）。

### 4.3 翻页动画期间的 dwell 语义（gap6）

不设独立 suspended 状态——**cooldown 在时间上吞掉动画窗口**：fire 后进 cooldown(0.8) ≥ snapVisualSettle；fire 后离区再回来最早再 fire = 回来 + dwell(0.7) ≥ snapVisualSettle。分类层面的「动画期挂起」由 `.awaitingHandoff` 承担——turner 只管时间，session 只管交接。

**常量互锁不能是虚锁**（BT-4）：pageSnap 的 spring 参数本身收进共享常量——

```swift
enum LaunchpadPageAnimation {
    static let snapResponse: CGFloat = 0.34
    static let snapDamping: CGFloat = 0.86
    static let snapVisualSettle: TimeInterval = 0.65   // 保守取 ≈1.9×response（ζ≈0.86 感知沉降 ~2×response，BC-7）
}
```

GridView 的 pageSnap 从这组常量构造；单测断言 `dwell ≥ snapVisualSettle && repeatCooldown ≥ snapVisualSettle && snapVisualSettle ≥ snapResponse × 1.9`——改 spring 必须进同一文件，红灯承诺才成立。连翻第二跳是否落在动画未稳期列入步骤 6 真机实测，必要时 repeatCooldown 上调至 0.9-1.0（仍在 D6-A 区间）。

### 4.4 flipRequest 通道与目标页校验

```swift
struct LaunchpadFlipRequest: Equatable { let token: Int; let targetPage: Int }
@Published private(set) var flipRequest: LaunchpadFlipRequest?
```

session 收 `.flip(d)` → coordinator 校验 `target = currentTargetPage + d ∈ [0, displayLast]`（displayLast 含虚拟尾页索引 == pageCount，§6；落地步骤 6 前过渡 clamp 到 pageCount−1，BT-7）；越界丢弃（turner 已自进 cooldown，按节拍重试再被丢，无副作用）。合法 → token+1 发布 → `.awaitingHandoff(target)`。

消费端双保险（AR-5/BR-3a）：GridView `.onChange(of: flipRequest)` 首行 `guard let req, dragCoordinator.carrySession?.isCarrying == true else { return }` → `goToPage(req.targetPage)`；发布端在 released/cancel 时撤销（§1.4-4）。绝不从 mouse handler 直接 withAnimation（约束 2）。**夹出 carry 同样享受**：事件源是夹 cell、根页 hitTest 为 nil（约束 19），边缘检测本就只能由 coordinator 基于转发点驱动——本设计天然满足。

---

## 5. 页几何数据源（D7/gap3）——回归 D7-A 本义：纯推送 + 显式算术，零 convert

### 5.1 背景事实链与裁决

SwiftUI `.offset` 是渲染变换，不进 AppKit frame 链——`convert(windowPoint, from: nil)` 在 page p 偏差恰为 p×pageW（DragGrid.swift:595/:621 实测）；活滑动期 convert 还会振荡（PROGRESS.md:52）。两份草稿分别用「一次性 convert 标定」（A）与「convert 后补 p×W」（B）——前者违反约束 6 字面，后者机制上是被否决的 D7-B；两家审查（AC-4/BC-3）独立收敛到同一替代：**热路径与标定全程不碰 convert**。

### 5.2 数据结构与推送

```swift
struct LaunchpadPageGeometry: Equatable {
    var pageWidth: CGFloat = 0
    var gridHeight: CGFloat = 0
    var pageCount: Int = 1          // 真实页数（不含虚拟尾页）
    var perPage: Int = 1
    var viewportMinX: CGFloat = 0   // 视口左缘，AppKit window 空间——跨翻页恒定（视口即当前页）
    var viewportTopY: CGFloat = 0   // 网格区顶缘，AppKit window 空间（容器 isFlipped 的 y 锚）
}
```

- **谁推**：GridView `syncGeometry(size:)`，挂在 `updateLayout(size:)` 末尾（onAppear + geo.size 变化）与 `.onChange(of: pageCount)`；Equatable 去重防抖动写入。viewport 来源：包住分页条带的外层 GeometryReader（在 `.offset` 之外，其 frame 不受翻页影响）`geo.frame(in: .global)`，换算到 AppKit window bottom-left 空间（SwiftUI global 与 hosting view 同空间，仅 y 翻转需 host 高度——换算细节由步骤 0 探针定稿，见下）。
- **currentPage** 经 §3.2 漏斗推送（不进 Equatable 快照，避免每帧比较）。
- **交叉校验探针（落地步骤 0）**：debug 下用「注册容器 frame-chain 原点 − p×pageW」第二路推导 viewportMinX 与推送值对账，偏差 > 0.5pt 打日志 + assert。frame-chain 原点查询（`container.convert(.zero, to: nil)`）不受渲染 offset 影响（这正是 bug 的成因本身），可作为推送换算被证伪时的备选数据源——**接口（CarrySpace 纯值）不变，仅换数据源**。
- **几何突变 fail-safe**（A 嫁接）：carry 中 pageWidth/perPage 与会话起点不符（窗口被 resize）→ `cancelCarry(.geometryChanged)`，不做 mid-carry 重标定。

### 5.3 显式算术（LaunchpadCarrySpace，纯值类型）

```swift
struct LaunchpadCarrySpace {
    let viewportMinX: CGFloat, viewportTopY: CGFloat, pageWidth: CGFloat
    func local(fromWindow w: NSPoint) -> NSPoint {            // 喂分类 + 喂 turner
        NSPoint(x: w.x - viewportMinX, y: viewportTopY - w.y) // 容器 flipped：top-left 原点
    }
    func windowRect(fromLocal r: CGRect) -> NSRect {          // settle 反向（§7.1）
        NSRect(x: viewportMinX + r.minX, y: viewportTopY - r.maxY, width: r.width, height: r.height)
    }
}
```

关键性质：**视口即页**——结果对任意「正可见页」相同，无需按页加偏移；coordinator 只喂 `currentTargetContainer` 这一个容器。**翻页动画进行中用动画终态**：currentPage @State 改变是瞬时的（只有 offset 在动画），漏斗同步更新 currentTargetPage，分类对滑入页的最终位置生效——与「滑入即让位」一致，无错窗（前提 `pageDragTranslation == 0`，由 §2.1-3 清场 + §9.4 输入冻结共同保证）。window → screen 用 `window.convertPoint(toScreen:)`——NSWindow 级转换，无 SwiftUI 污染（合法，:337 已用）。

**可测性**（BT-3/AT-3）：CarrySpace 是纯值，测试直接构造注入（无 window guard、无 convert）；页偏移性质（视口不变性、round-trip、y 翻转）全部可单测真驱。**page>0 出夹落点 bug 在此一步顺带修复**：eject 的 moveEject/commitOut 路径改经 CarrySpace 喂 `atContainerPoint:` 新入口（:595/:621 两处错读点退役到遗留路径），可独立提交（§11 步骤 2）。

---

## 6. 虚拟尾页（D8/gap8）

### 6.1 条件与渲染

```swift
private var displayPageCount: Int { pageCount + (dragCoordinator.carryActive && isLayoutEditable ? 1 : 0) }
```

**carry 一开始就 +1**（非临近边缘才加）：空容器零成本，且保证 flip 前已 mount 已注册（§3.3 兜底退化为理论防御）；iOS 拖拽中本来就显示新页圆点。两种 origin 都享受（夹出 carry 也能翻到新页——任务要求）。ForEach 尾部追加，既有页 identity（整数页号）不动（约束 18）。虚拟页 items 切片天然为 []（:252-254 现成守卫）。

### 6.2 落点语义——与 iOS 的有意分歧（必须写进 README 与 PR 描述，AR-7）

约束 13 禁稀疏页/占位 cell，落虚拟页的 commit 语义**恒为全局落尾**：

- **folderEject**：根数 +1，恰跨 perPage 边界（末真页已满）时虚拟页**真正成为新页**，落点页号不变、无跳动——任务「停最后一页右缘生成新页可落」的实际达成路径。
- **rootPage**：reorder 是 remove+insert，数组长度恒定，**页数永不因此 +1**——落虚拟页等于「移到全局末尾」，提交后虚拟页收回、视口回落到末真页尾。两份草稿的「页号恰好不变」论断对此路径为假（A races 证伪）。**回落必须是连续动画**：commit 视觉通道（§1.3）把 relocateSelection 与 currentPage 归位包进同一 `withAnimation(pageSnap)`，圆点收回与页回弹连成一段运动，不闪跳。

虚拟页是**拖拽期的悬停透出**，不是可持久的稀疏页。

### 6.3 pageCount 消费点审计清单（A 骨架）

| 位置（GridView.swift） | 改法 |
|---|---|
| :222 `visiblePage = min(currentPage, pageCount-1)` | → `displayPageCount - 1` |
| :225 `ForEach(0..<pageCount)` | → `0..<displayPageCount` |
| :239 `if pageCount > 1` + :416 圆点 ForEach | → displayPageCount |
| :274 onPageSwipe、:490 goToPage clamp | → `displayPageCount - 1`；非 carry 时两者相等，统一无害 |
| :502/:521/:536 handlePageDrag/handlePageScroll/snapToNearestPage | 顶部 `guard dragCoordinator.carrySession == nil`（§9.4 输入冻结；含 settling 期）；内部 pageCount 不改 |
| :527-529 pageScrollEndWork 去抖 work item | **carry 入口清场 cancel + 归零**（§2.1-3）+ snapToNearestPage 顶部 guard 双保险（AC-6/BC-2——guard 单独加会把归零职责一起吞掉，残留 translation 冻结条带） |
| :449 updateLayout `currentPage = selectedIndex/perPage` 回拽 | carry 豁免（§8） |
| :455-483 handleMove 键盘翻页 | 顶部 `guard carrySession == nil`（搜索框是 first responder，方向键 mid-carry 可达） |
| :398-402 relocateSelection、:545 snap 重映射 | 不改——只在 carry 结束后运行 |
| 容器 scrollWheel（DragGrid.swift:704-724） | `if grid?.coordinator?.carryActive == true { return }`（滚动事件不随 mouse-down 锚定，mid-carry 仍可达） |

### 6.4 圆点、无障碍与收回

虚拟页圆点普通样式（iOS 同款不特殊化）；AX label 新 key `grid.page.virtualLabel`（「新页面」）；`accessibilityAction` 保留——AX 翻页经 goToPage → currentPage 漏斗 → handoff，机制一致且安全（mid-carry 鼠标按着 tap 不可达，AX 可达但走同一受控通道；settling 期被 §8 gate 拒绝）。收回：commit 路径见 §6.2；**cancel 路径**在 `.onChange(of: carryActive)` 里 `guard dragCoordinator.endReason == .cancelled` 后 `withAnimation(pageSnap) { currentPage = min(currentPage, pageCount-1) }`——endReason 在 carryActive 翻 false 前置位，commit/cancel 不再靠同一布尔猜语义（AR-8）；两个 `.onChange` 的声明顺序写死 commitToken 在前并加注释钉住。

---

## 7. settle 落位动画（gap4）——数据先行，动画纯视觉

分两阶段落地：**先 hard-cut（行为与今日 eject 一致），后 flight**——独立 commit，可单独回退。settlingItemID 停泊机制**从 hard-cut 版就启用**（AT-8：commit 到 post-commit apply 之间的窗口期同样需要锚保护）。

### 7.1 解析与目标矩形（resolveExternalDrop，纯 peek——BR-5）

```swift
func resolveExternalDrop() -> (result: LaunchpadExternalDropResult, settleLocalRect: CGRect?)
```

无副作用地 peek 当前 armed/gap 状态：gap 让位中 → `slotRect(gap)`（gap 本身就是空槽）；merge armed → 目标 cell 的 iconFrame（浮窗缩落到目标图标上，iOS 吸收感）；空容器/虚拟页 → `slotRect(0)`；容器 nil → nil（浮窗原地淡出）。收口职责分离：`freezeExternalDrag()`（commit 路径，冻结不重排）与 `endExternalDrag()`（cancel/handoff 路径，动画收口）是仅有的两个收口点。`commitExternalDrag()` 保留为 shim（peek + end，带默认行为）供旧路径与现有测试。坐标链：settleLocalRect → `CarrySpace.windowRect` → `convertToScreen`（§5.3，零 convert 进条带）。

### 7.2 浮窗换乘（flight 版）

浮窗协议 `settle(to: NSRect, completion:)`：生产实现 `NSAnimationContext`（duration 0.25，贝塞尔 (0.34,1.18,0.5,1)——与容器 settle :244 同曲线）驱动 `animator().setFrame`；测试 spy 同步调 completion（BT-5a——现有 eject 测试的同步语义在 shim 下继续成立）。completion 与 0.5s timeout 兜底**都带 settleGeneration**（捕获当时代数，不匹配即 no-op——杜绝 stale 回调拆新会话的浮窗/un-park 新会话的停泊，AR-6）。

### 7.3 停泊/揭示协议（防双影——AC-3 修正版）

1. 数据已在 mouseUp 落库（§1.4），store @Published → body 重估 → 各容器 apply 新模型 → 落位 cell 排进 gap 槽（**让位即终局**：gap 布局各 cell frame 与提交后布局逐项相同，换乘零位移）。
2. apply 末尾：若某 cell.layoutID == `coordinator.settlingItemID` → frame 停泊离屏（源页锚本就泊着，按 layoutID 复用免费衔接）。**三元布局谓词（§2.2）保证停泊期间任何 layout pass 都不会把 settling cell 写回槽位**——A 草稿「与锚同机制」的类比在 teardown 清掉 draggedCell 后不成立，谓词必须显式含 settlingItemID。
3. 浮窗飞抵 → completion（gen 匹配）→ `revealSettledCell(itemID)` 广播各注册容器：un-park 到槽位（硬切——浮窗恰好停在槽位上，肉眼无缝）→ 浮窗 dismiss → `settlingItemID = nil` → session = nil。
4. **兜底**：0.5s timeout 无条件 reveal + 拆浮窗（动画 completion 丢失/窗口提前关闭时图标不可永久隐身）；cancel/force-complete 同样先 reveal。merge 落夹：reveal 按 id 找不到即 no-op（item 进夹消失，apply 已更新夹缩略图）；merge 改变可见集存在一帧重建，靠浮窗 dismiss 与 rebuild 同事务压最小化——列入真机验证点。

---

## 8. selectedIndex / currentPage 拖拽期豁免（D9-A）

- **goToPage carry 变体**：`if dragCoordinator.carrySession == nil { selectedIndex = min(target*perPage, count-1) }`——carry 期只动 currentPage 不挪 selectedIndex（约束 20：虚拟页无 item 可指，挪了必被 :449 回拽）；clamp 上界统一 `displayPageCount - 1`。
- **手动翻页 gate 键 = `carrySession != nil`**（非 carryActive）：覆盖 settling 期——mouseUp 后 0.25s 飞行窗口内鼠标已抬，页点 tap/AX/滚轮全部可达，gate 不含 settling 会让浮窗飞向正在滑走的页（BR-3b）。flip 通道（flipRequest 漏斗）是 carry 期唯一翻页入口。
- **updateLayout 回拽豁免**（:448-449）：carry 期不执行 `currentPage = selectedIndex/perPage`；selectedIndex 的合法性钳制保留。
- **commit 后按 id 重映射**：恒走 `relocateSelection(to: landingID)`（:398-402，identity-anchored）：reorder → itemID、makeFolder → 新夹 id、addToFolder → 目标夹 id。cancel 不动 selection，只 clamp currentPage（§6.4）。

---

## 9. 竞态与生命周期（gap7/gap10/约束 17）

### 9.1 退出路径全矩阵（触发 × gate 位置 × 行为）

| # | 场景 | 入口/gate | 行为 |
|---|---|---|---|
| 1 | 正常 mouseUp | endDirectDrag **首行**（draggedCell guard 之前）`if coord.carryActive → carryReleased` | §1.4 released 序；root origin 本地 teardown apply pendingGrid（不丢弃）；refocusSearchField |
| 2 | overlay 主动关闭（Esc/失焦/deactivate） | OverlayController.close() :161 `cancelEject` → `cancelCarry(.overlayClosed)` | **全同步直调收尾**（§9.2）：先于 orderOut 确定性拆浮窗/timer（浮窗非真 child window，约束 1）。**settling 期：force-complete——数据已落库，仅快进视觉**，无 commit 丢失（BC-1/BR-1 的结构性消解） |
| 3 | 源页容器 unmount（filtered 收缩砍源页 / overlay 拆除） | viewWillMove(toWindow: nil) 扩展：`if anchorCell != nil → cancelCarry(.anchorUnmounted)`；反注册 `pages[pageIndex]`；`if externalDragActive → endExternalDrag()` | mouseUp 已随 view 永久丢失（约束 5），cancel 是唯一安全选择；dwell timer/turner/浮窗/虚拟页旗标全在 cancelCarry 单点回收（约束 17） |
| 4 | 非源页容器 unmount（虚拟页收回/尾页缩减） | 同钩子的 endExternalDrag（现有行为）+ 反注册 | 若恰是 currentTargetContainer，弱引用归 nil → moved 喂空 no-op，released 走容器 nil 兜底（§1.4-2） |
| 5 | filtered mid-carry 收缩但源页幸存（catalog 异步重载/卸载） | 不主动 cancel（与 eject 现行哲学一致） | 源页 isDragging 延迟 apply 护锚；commit 对 frozenOrder 解析，store 对失效 id 落尾兜底（LayoutStore.swift:172）；pageCount onChange 推送收缩，coordinator clamp currentTargetPage |
| 6 | 搜索态切入 mid-carry（按住拖时打字） | `.onChange(of: searchText)` 首行 `if dragCoordinator.carrySession != nil { cancelCarry(.searchActivated) }`，先于 closeFolder/selectedIndex 重置 | 锚复原、gap 收口，随后 filtered 摊平安全 rebuild；后续孤儿事件被 §1.2 双保险吞掉（约束 16） |
| 7 | settle 期打字/Esc | 同 6/2 的入口，session 在 settling | force-complete 视觉；**数据在 mouseUp 已提交，isLayoutEditable guard 不在数据通路上**（storeApplier 用 editableAtBegin），BR-2 消解 |
| 8 | 几何突变（resize/perPage 变） | updatePageGeometry 检测与会话起点不符 → cancelCarry(.geometryChanged) | 标定空间失效，fail-safe |
| 9 | settling 期重入 lift | §1.2 settling×lift：force-complete 后开新会话 | 不存在「第二个 cell 被停泊却无浮窗」的半开状态（BR-4） |
| 10 | **mid-carry 右键**（两家审查共同新发现） | cell rightMouseDown 守卫扩为 `container?.hasActiveDrag == true \|\| container?.grid?.coordinator?.carryActive == true` | 现守卫（:1029-1032）per-container，root carry 翻到非源页后该页 hasActiveDrag==false、interactionEnabled==true（无夹保护）→ NSMenu tracking loop 吞 mouseUp 卡死会话——升 coordinator 级 gate 关死（AR-9/BC-4/BR-6） |
| 11 | lift 前 0.1s 内刚滚动过 | §2.1-3 carry 入口清场 + snapToNearestPage guard | pageDragTranslation ≡ 0 during carry——§5.3 算术前提由 carry 入口自己保证，不靠「恰好静止」（AC-6/BC-2） |
| 12 | flight 中断 | §7.2 gen-token 化的 timeout + cancel 先 reveal | 图标不可永久隐身 |

### 9.2 cancelCarry 单点实现（全同步，不经任何 @Published 投递——BC-1 教训）

`flipRequest = nil` → 停 timer → turner.reset → `currentTargetContainer?.endExternalDrag()` → 源容器 `cancelCarryAnchor()`（root）/ teardownDragState（folder，既有路径）→ 浮窗 `dismiss()` → `settlingItemID = nil` → `endReason = .cancelled` → `carryActive = false` → `carrySession = nil`。无 token。所有清理动作在调用栈内完成，与现 cancelEject 的同步性等价——退出路径不依赖视图树存活。

### 9.3 carry 入口 gate 链（gap10 双保险）

1. cell 仲裁层：`allowsCustomOrderActions == false` 不 lift（:1014 现有，didDrag 仍置位吞手势，约束 16）；
2. coordinator 层：GridView 同步推送 `isCarryAllowed = isLayoutEditable`；`beginCarry` guard 链 = `session == nil（或 settling 先 force-complete）&& isCarryAllowed`——封掉「夹打开瞬间切搜索」等窗口边路（夹 grid 没有 allowsCustomOrderActions gate）；
3. turner 只在会话内 tick——搜索态进不了 carry，传递性安全。

### 9.4 carry 期输入冻结（消灭并发翻页变量）

容器 scrollWheel、handlePageDrag/handlePageScroll/handleMove、snapToNearestPage 全部 gate（§6.3 清单）；页点 tap/AX 经 goToPage 变体放行但 settling 期拒绝（§8）。收益：`pageDragTranslation ≡ 0`，turner 与手动翻页不竞争 currentPage——范围决策记录在 §12。

---

## 10. 测试计划（gap9）

新文件落 `Plugins/Launchpad/Tests/`，加文件后 `make generate`（约束 21）。注入缝清单（BT-5/AT-3 的回应，写进 API 而非测试期凿洞）：① `floatingPresenterFactory`（默认生产实现，测试换 spy，协议含 move/settle(to:completion:)/dismiss）；② `dwellTickDriver`（默认真 Timer，测试手动泵；turner 的 now 同源注入）；③ CarrySpace 纯值直接构造注入（生产由推送几何构造）；④ coordinator test-facing 只读面：`var hasFloatingWindow: Bool`、`var isDwellTimerRunning: Bool`、`internal private(set) currentTargetContainer/currentTargetPage`、`registeredPageIndices: [Int]`；⑤ `resolveCarryCommit` 纯函数直驱；⑥ 容器暴露 `private(set) isExternalDragActive`。夹具基类 tearDown 强制 `coordinator.cancelCarry(.shutdown)`（防跨测例泄漏）。

**A. LaunchpadEdgePageTurnerTests（纯时间序列）**：dwell 0.7s 触发（左/右）、离区/换边重置、cooldown 内不二发、驻留连翻 0.8s 节拍（喂 3s 序列断言 fire 在 ~0.7/1.5/2.3）、fire 后重入需满 dwell、33ms 抖动步进仍触发、reset、**Config 不变式 vs LaunchpadPageAnimation 常量**（含 `snapVisualSettle ≥ snapResponse × 1.9` 的数学锁，BT-4）、**越界 x（负值/超 pageWidth）归入 zone**。

**B. LaunchpadCarrySpaceTests（坐标算术纯单测）**：page-local 换算视口不变性（翻两页后同一 window 点结果不变）、local→window→local round-trip、flipped y、windowRect 反向、**夹具注入非零 pageWidth 真驱页偏移路径**（BT-3）。

**C. LaunchpadCarrySessionTests（状态机完备性，spy 浮窗 + 注入 tick）**：lift 开源页会话且 seedGap 在原槽、flip 发布请求并挂起分类（.awaitingHandoff 不喂分类——断言基于真容器 externalGapIndex 不变性，放弃 ClassifierSpy 提法）、containerRegistered 交接并重喂 last 点、**awaitingHandoff 中 released 先撤销 flipRequest**（断言无二次翻页）、**released 后 flipRequest 不再被消费**、cancel(carrying) 无 token 无写盘、**cancel(settling) force-complete 且写盘恰一次**（断言 store 已变 + 浮窗拆除）、**settling 期重入 lift force-complete 后新会话可开**、**stale settleFinished(旧 gen) 被忽略**、事件全表驱动 `testTransitionTableIsTotal`（每状态×每事件断言定义结果——B 的核心交付）、folder origin 同享边缘翻页。

**D. LaunchpadCrossPageCarryTests（多容器夹具：makePage(items:page:coordinator:) 两个 windowless 容器 + 真注册表）**：handoff 后 old gap 收口 + new 让位、**翻回 isDragging 源页仍重注册并接管**（§3.1 hoist 回归锁）、**同页换容器 reattach（身份比较）**、**空注册表 flip 后迟到注册补 begin**（AT-4 用例）、moveCarry 只喂当前目标页、空虚拟页 begin/update/resolve → .reorder(nil)、被携带 folder 永不 arm merge、**drop 紧跟 flip 落在光标槽**（终点重喂，AR-4）、源页 unmount cancel 全量回收（断言 hasFloatingWindow==false + timer 停 + 注册表清）。

**E. LaunchpadCarryAnchorTests（D4 停泊不变量）**：lift 停泊 + seedGap 恒等布局（邻居 frame 逐项不动）、**循环 layout()/layoutCellsWithGap 永不写锚 frame**（含 handoff 离开源页后的变体——断言紧凑无洞，AC-2）、**settlingItemID 置位期间循环 layout() cell 恒在停泊点**（AC-3）、**no-op commit 后 reveal 把锚复位到原槽且零写盘**（FakePluginStorage.writeCount + frame 断言，AR-1）、settle reveal 复位、**commit 后 post-commit apply 前手动 layout() 锚仍停泊**（AT-8）。

**F. 仲裁与精度（扩展 LaunchpadDragToStackTests fakeMouse 模式）**：root lift 经容器入口路由到 carry（断言 carryActive + 锚 frame == 停泊点全程不动 + 浮窗存在）、**carry 形态精度对仗用例**（BT-6：锚在场时悬停另一 app 中心 → .makeFolder(目标)；悬停第三 cell 右缝 → .reorder(.after(该 cell))；目标永不等于锚 id）、搜索态长拖被吞不开会话、`coordinator == nil` 回退本地直拖（121 旧测例语义显式锁）、**mid-carry 非源页右键不弹菜单**、**scroll 后 0.1s 内 lift → translation == 0 且 work item 失效**、root mouseUp 经 endDirectDrag 首行分支触发 commit（锁 guard 顺序，BR-7）。

**G. 既有资产声明**：现有 eject 测试经 shim 全绿（commit/token 仍 mouseUp 同步，:225/:335 断言不变——BT-1）；**步骤 7 后旧根页直拖精度测试覆盖语义降格为夹内路径，文件内注释注明**（BT-6）；store/reconciler 测例零改动。GridView 层（displayPageCount/onChange 路由/settle 视觉）SwiftUI 不可单测——按 memory 纪律 `make run` + cliclick + screencapture 真机驱动，清单：page0/pageN 页内重排、**pageN 根页 lift 浮窗贴光标**（grab-offset 必须走推送几何——frame-chain convert 在 page>0 偏 page×pageWidth，无窗口单测观测不到该视觉，真机是唯一回归锁）、边缘连翻三页（实测第二跳与动画稳定性）、满板级联、夹出跨页落点（page>0 修复确认）、虚拟页落尾回落动画、mid-carry Esc/打字/关 overlay（**且各 cancel 后下一手势必须能重新 lift**——闩锁不得跨手势）、settle 期 Esc、mid-carry 右键、merge settle 闪烁观察。

---

## 11. 落地顺序（每步可编译可测、独立 commit）

0. **几何探针（spike 分支，不进主干）**：page 0/1/2 静止与 pageSnap 动画中段各采样「推送 viewport」vs「frame-chain 原点推导」vs 视觉位置，定稿 SwiftUI global → AppKit window 的 y 换算与数据源；产出写 PROGRESS。这是 §5 的放行门——两路都证伪才需要回到设计桌。
1. **纯新增零行为变化**：LaunchpadEdgePageTurner + LaunchpadCarrySpace/PageGeometry + LaunchpadPageAnimation 常量收编（pageSnap 改从常量构造）+ 测试 A/B。make generate。
2. **几何推送 + 注册表 + page>0 出夹修复（独立可发版 bug fix）**：syncGeometry 推送、registerPageContainer(page:)（apply 首行 hoist + 注释锁 + viewWillMove 反注册）、currentPage 漏斗、eject 路径切 `atContainerPoint:` 入口。现有 eject 测试全绿 + 真机 page>0 出夹验证 + **两指滚到 page>0 后出夹落点**（AT-2 验收点）。〔中风险——动已上线 eject〕
3. **carry 会话骨架 + eject 迁移**：LaunchpadCarrySession + FloatingIconPresenting + storeApplier 注入 + resolveCarryCommit + commitToken 视觉通道替换 ejectToken 数据职责（数据改同步落库）、OverlayController 改 cancelCarry。测试 C 的 folder origin 行 + G 回归。〔高风险回归点 #1：动已验证出夹链路〕
4. **handoff**：漏斗交接 + reattachIfNeeded + resolveExternalDrop/freezeExternalDrag 拆分（commitExternalDrag 转 shim）。测试 D 前半。顺带修掉「eject carry 翻页 gap 残留」已知缺陷（gap1），用户可见改善。
5. **边缘翻页接线**：turner 接注入 Timer、flipRequest 通道与双保险、goToPage carry 变体、§9.4 输入冻结、§9.1 行 10/11 的 gate。**过渡期 flip clamp 到真实页 [0, pageCount−1]**（BT-7）。夹出 carry 先行获得边缘翻页，可单独真机验收。
6. **虚拟尾页**：displayPageCount + §6.3 清单逐项 + 圆点/AX + 回落动画 + flip clamp 放宽到含虚拟索引 + 测试 D 空页条目。〔高风险回归点 #2：动 GridView 分页核心，全量测试 + 真机翻页/圆点验证〕
7. **根页 lift 升格为 carry**：anchorCell 停泊 + activeCells 排除面（含 layout() 回退分支）+ beginCarryLift 分流 + 容器转发/释放统一早分支（guard 之前）+ hasActiveDrag 重定义 + 右键 coordinator gate + hard-cut settle（settlingItemID 就位、立即 reveal）+ §9 全部退出路径。测试 C/D/E/F 余量。〔最高风险回归点：替换最高频手势；本地拖路径仍被夹内网格与 nil-coordinator 测试钉死；粘滞/死区/pendingGrid 纪律逐条对照约束 9/10/11 复核〕
8. **flight settle**：浮窗 settle(to:) 飞行 + reveal 延迟到 completion + gen-token 兜底。独立可回退。
9. **收尾**：退役 :595/:621 遗留 convert 路径与 eject shim（若测试证明不可达）、README 用户可见行为更新、docs/superpowers 设计文档归档、PROGRESS 清理、全量测试 + 真机回归清单全跑。

---

## 12. 不做什么

- **§2 建夹 dwell 时间门、§3 出夹 dwell + 渐进关闭 + 弹出后夹保持打开**——不动 mergeRect 即时 arm 与无条件 closeFolder（TODO 下版条目）。
- **§4 手感打磨**：无 haptic、无 lift 弹簧/jiggle；浮窗视觉 = 现 eject 浮窗（snapshot @ 1.1×）；flight settle 是本期唯一动画增项。
- **§5 文件夹命名**。
- **稀疏页/持久空页**：约束 13 否决；虚拟页仅为拖拽期透出，rootPage 落虚拟页 = 全局落尾 + 动画回落（§6.2 已声明的 iOS 分歧）。
- **非目标页实时级联预览**：carry 中只有当前目标页让位，其余页 commit 后一次性重排（iOS 是全页实时级联——接受的 v1 偏差，约束 14/15 的代价）。
- **carry 期手动翻页并行**（两指滚/空白拖/键盘）：§9.4 冻结，边缘 dwell 是 carry 期唯一翻页通道——范围决策，非遗漏。
- 不重写本地直拖状态机（夹内重排保留）；不做单一大容器（D1-B）/真滚动容器（D7-C）/物理 re-host（D1-C）；模型层零页概念不破（约束 13）：不持久化页号、不动 store/reconciler/LaunchpadDropTarget。
- 多显示器 carry、惯性甩动翻页、拖拽中圆点长按快翻、拖拽中逐槽实时 store 提交（约束 14 永久禁止）。

---

## 13. 对抗审查处置记录

全部 6 个 blocker、23 个 major 逐条处置；无整条驳回（两条以替代机制解决并注明）。minor 处置附后。

### 设计 A 的审查

| ID | 镜头/级别 | 问题 | 处置 |
|---|---|---|---|
| AC-B1 | constraints/blocker | beginExternalDrag 互斥 guard（:606）未解除，A 的 lift 顺序下 seedGap 会话静默 no-op | **改设计**：采 B 路线——锚走 anchorCell 新字段、不设 draggedCell，:606 guard 原样保留，硬约束 9 语义零重新协商（§2.1）。审查建议的「放宽 guard」不采纳——保留互斥不变量比豁免它更安全 |
| AC-M1 | constraints/major | 「layout() 非 external 分支不可达」断言为假，handoff 离开源页后留洞 | **改设计**：carry 分支不设 dragOrder；layout() 回退分支 anchorCell != nil 时以 activeCells 为 order；错误论证删除；测试 E 加 handoff 后循环 layout 变体（§2.2） |
| AC-M2 | constraints/major | flight settle 的 apply 末尾停泊被同轮 layout pass 决定性撤销（双影是主路径） | **改设计**：布局跳过谓词扩为三元（draggedCell/anchorCell/settlingItemID），统一应用三条布局路径；reveal 是唯一 un-park 入口；测试 E 加停泊期循环 layout 断言（§7.3/§2.2） |
| AC-M3 | constraints/major | 标定 convert 违反硬约束 6 字面，且存在无 convert 替代 | **改设计**：废弃 convert 标定，改纯推送（GeometryReader .global frame → window 空间 viewport），CarrySpace 纯值零 convert；探针降级为交叉校验 + 备选数据源（§5） |
| AC-M4 | constraints/major | windowWidth 数据源错位（geo 宽 = pageWidth ≠ 窗宽），右热区压末列、compact 够不到 | **改设计**：热区判定改 page-local x + 越界值显式归区（B §4 方案），不再需要窗宽；与 slot 重叠列入真机调参（§4.1） |
| AC-M5 | constraints/major | pageScrollEndWork 去抖 work item 被 guard 吞掉后 translation 永久冻结 | **改设计**：carry 入口清场（cancel work item + 无动画归零）+ snapToNearestPage guard 双保险 + 测试 F 用例；§5.3 前提改为「carry 入口自己保证静止」（§2.1-3/§9.1 行 11） |
| AC-M6 | constraints/major | commit 异步 token 消费窗口未闭合：快照可被覆盖、overlay close 丢提交 | **改设计**：commit 同步化（mouseUp 直调注入 storeApplier），快照随会话冻结，窗口结构性消失；token 退化为视觉通道（§1.3/§1.4） |
| AR-B1 | races/blocker | no-op commit 无锚回收路径，「原位抖一下放手」图标永久隐身 | **改设计**：no-op 仅跳过写盘，settle 飞回原槽 + reveal 管线无条件走完；测试 E 断言锚 frame 复位 + 零写盘（§2.3/§7） |
| AR-M1 | races/major | beginExternalDrag guard（同 AC-B1） | 同 AC-B1 |
| AR-M2 | races/major | updateDirectDrag 无 carry 转发分支，ejectActive 别名让现有分支对 root carry 失效 | **改设计**：统一早分支以 carryActive 为键、置于 draggedCell guard 之前（§1.5）；测试 F 断言锚 frame 全程停泊 |
| AR-M3 | races/major | 翻页后静止松手 → 新页无 gap → 落点退化全局落尾 | **改设计**：released 序第一步终点重喂分类再 resolve；容器 nil 保留 rootDropTarget 等价兜底（§1.4-1/2）；测试 D 用例 |
| AR-M4 | races/major | dwell fire 与 mouseUp 同帧：未消费 flipRequest 在 drop 后照常翻页 | **改设计**：released/cancel 统一撤销 flipRequest；消费端 guard `session?.isCarrying == true`（§1.4-4/§4.4）；测试 C 用例 |
| AR-M5 | races/major | (settling, lift) 未定义转移 + 0.5s「无条件」兜底拆新浮窗 | **改设计**：转移表补 settling×lift = force-complete 后开新会话；settle 回调全部带 generation token（§1.2/§7.2）；测试 C 两用例 |
| AR-M6 | races/major | 「落虚拟页页号不变」不变量错误：rootPage 永不增页，必然跳回 | **改设计**：§6.2 重写——folderEject 跨界才成真页；rootPage 落虚拟页 = 全局落尾 + withAnimation(pageSnap) 连续回落；README/PR 标注 iOS 模型分歧 |
| AR-M7 | races/major | carryActive onChange 无法区分 cancel/commit，clamp 与 relocate 顺序未定义 | **改设计**：endReason 在翻 carryActive 前置位，cancel clamp 以其为 guard；commit 归位走 commitToken 通道；两个 onChange 声明顺序写死并注释（§6.4） |
| AR-M8 | races/major | mid-carry 右键：per-container hasActiveDrag 拦不住非源页菜单吞 mouseUp | **改设计**：右键守卫升 coordinator 级（hasActiveDrag ∨ carryActive）；§9.1 补行 10；测试 F + 真机清单（§9.1） |
| AT-B1 | tests/blocker | beginExternalDrag guard（同 AC-B1），自报测试按原文实现必红 | 同 AC-B1；测试 E 的 seedGap 用例同时断言 isExternalDragActive == true，把雷钉死 |
| AT-M1 | tests/major | geometry.currentPage 推送点枚举不完整（snapToNearest/handleMove/relocate/hideApp/searchText 五处漏） | **改设计**：放弃枚举，单一 `.onChange(of: currentPage)` 漏斗（§3.2）；步骤 2 验收补「两指滚到 page>0 后出夹」真机点 |
| AT-M2 | tests/major | lift 全路径无 windowless 缝（convert 标定/screen 点/cacheDisplay），违反约束 21 | **改设计**：CarrySpace 改纯值注入（推送标定后天然无 convert）；浮窗经工厂注入 spy；screen 点缺失退化 .zero 继续建会话；快照闭包注入。缝清单写进 §10 |
| AT-M3 | tests/major | 注册兜底条件按字面是死代码（页号比较自相矛盾） | **改设计**：reattachIfNeeded 按容器身份（===）判幂等，持 currentTargetContainer 弱引用；测试 D 补迟到注册用例（§3.3） |
| AT-M4 | tests/major | commit 路由全在 GridView 私有方法，自称可测的零写盘测例写不出来；快照归属竞态 | **改设计**：resolveCarryCommit 纯函数 + storeApplier 注入 + 快照随会话冻结（§1.3）；套件直驱纯函数 + FakePluginStorage。审查建议的「快照打包进 request」以「快照进 session」替代实现（onDragBegan 闭包传递，coordinator 拿得到） |

A 的 minors：AC-m1（虚拟页未满页跳动）并入 AR-M6 的统一语义；AR-m1（兜底 vs guard 矛盾）并入 AT-M3；AR-m2（快照归属）并入 AT-M4——同步消费后窗口消失；AT-m1（Timer 泄漏）→ dwellTickDriver 注入 + tearDown 纪律；AT-m2（测试可见性/默认参数）→ test-facing 只读面 + commitExternalDrag shim 默认行为；AT-m3（hard-cut 帧序）→ settlingItemID 自 hard-cut 版启用 + 测试 E 用例。全部采纳。

### 设计 B 的审查

| ID | 镜头/级别 | 问题 | 处置 |
|---|---|---|---|
| BC-B1 | constraints/blocker | committing×cancel 经 @Published 收尾：overlay close 同步拆视图后 onChange 永不投递 → 浮窗泄漏（违约束 1）+ commit 丢失 + 会话永久 wedge | **改设计（本终稿最大裁决）**：废弃 settle-后-commit 整个机制。数据在 mouseUp 同步落库（注入 storeApplier，不经视图）；cancel 全同步直调收尾（§9.2）；settling 仅视觉，cancel = force-complete。「commit 必达」由同步性结构保证而非状态机承诺 |
| BC-M1 | constraints/major | pageScrollEndWork 残留（同 AC-M5） | 同 AC-M5 |
| BC-M2 | constraints/major | localPoint 的 convert+补偿机制上是被否决的 D7-B，却自标 D7-A | **改设计**：同 AC-M3——回归 D7-A 本义纯推送；§7.1 反向同改纯算术；探针提前到步骤 0 作放行门 |
| BC-M3 | constraints/major | hasActiveDrag 重定义后右键暴露面（同 AR-M8） | 同 AR-M8 |
| BR-B1 | races/blocker | 同 BC-B1（含「下次打开启动台全部拖拽转发进死会话」后果链） | 同 BC-B1；附加：终态改为 session = nil（去掉 .ended 枚举），僵尸会话结构性不存在（§1.1） |
| BR-M1 | races/major | settle 窗口内打字 → cancel(.searchActivated) 快进 → 路由撞 isLayoutEditable guard，已松手提交被静默丢弃 | **结构性消解 + 防御**：commit 同步于 mouseUp（打字事件必然在其后，窗口为零）；storeApplier 用 editableAtBegin 判定，数据通路不查实时 isLayoutEditable（§1.3/§9.1 行 7）。审查建议的「四个 handler 加 allowWhileSearching 参数」不采纳——数据通路已离开这四个 handler |
| BR-M2 | races/major | committing 期 currentPage 可变/flipRequest 未撤/注册表换走 → gap 残留竞态族 | **改设计四点收口**：(a) released/cancel 撤销 flipRequest + 消费端 guard（§1.4/§4.4）；(b) 手动翻页 gate 键 = session != nil 含 settling（§8）；(c) gap 会话在 released 序同步 freeze，settling 期注册表换走无副作用（§1.2）；(d) settling 期注册不触发 handoff（isCarrying guard） |
| BR-M3 | races/major | settle 期二次 lift 会话碰撞：容器先改状态后被 beginCarry 拒绝，cell 停泊却无浮窗 | **改设计**：gate 提到容器侧步骤 0（beginCarry 返回可否，拒绝则容器零改动）；settling×lift = force-complete 后开新会话（§1.2/§2.1-1）；测试 C 用例 |
| BR-M4 | races/major | commitExternalDrag 的 defer endExternalDrag「解析即收口」与 settle 需要 gap 保持矛盾，按字面实现两条死路 | **改设计**：新增 resolveExternalDrop 纯 peek（顺带产出 settle 目标 rect）+ freezeExternalDrag/endExternalDrag 显式收口分离；commitExternalDrag 保留为 shim 供现有测试（§7.1/§1.4-3） |
| BR-M5 | races/major | 右键（同 AR-M8/BC-M3） | 同 AR-M8 |
| BT-B1 | tests/blocker | settle 后才 bump token 与现有同步断言（:225/:335）矛盾，「全绿」与「延迟 bump」不能同时为真 | **结构性消解**：终稿 commit/token 均在 mouseUp 同步（§1.4-8），现有断言语义不变保绿；浮窗 settle 经协议注入，spy 同步 completion（§7.2/§10-G） |
| BT-B2 | tests/blocker | 「commit 必达」在 overlay close 不成立且为相对现状的回归；路由活在 View 私有层，等步骤 7 才发现要返工 | **改设计**：同 BC-B1 + AT-M4——设计阶段即把路由提为纯函数 + 注入 applier；附带收益：commit 路由五分支可单测（§1.3） |
| BT-M1 | tests/major | windowless 缝 guard 早退使页偏移测试空转绿灯，步骤 2 回归锁全押真机 | **结构性消解**：纯推送后算术无 window guard、无 convert——测试 B 真驱页偏移；夹具注入非零 pageWidth（§5.3/§10-B） |
| BT-M2 | tests/major | snapVisualSettle 测试是虚锁：改 spring 参数测试照样绿 | **改设计**：spring 参数本身收进 LaunchpadPageAnimation，pageSnap 从常量构造，测试加 `settle ≥ response × 1.9` 数学锁（§4.3） |
| BT-M3 | tests/major | FloatSpy/ClassifierSpy/注册表三类测试替身无对应 API 缝，13 个测试近半写不出 | **改设计**：floatingPresenterFactory + settle(to:completion:) 协议形状定义；分类挂起断言改基于真容器 externalGapIndex（放弃 ClassifierSpy，按审查建议改口）；注册表/目标容器暴露 internal 只读面（§10 缝清单） |

B 的 minors：BC-m1（updateDirectDrag guard 位置）/ BR-m1（endDirectDrag guard 位置）→ §1.5 写死分支位置 + 测试 F 锁 guard 顺序；BC-m2（注册 hoist 安全）→ 注释锁 + 回归测试采纳；BC-m3（snapVisualSettle 余量临界）→ 保守取 0.65 + 真机实测项；BR-m2（.reorder(nil) 分支一致性）→ 快照清理入视觉通道、编辑性走冻结值、「末项可为 folder」点名（§1.3）；BT-m1（旧精度测试假安全感）→ 测试 F 补 carry 形态精度对仗用例 + 覆盖降格注释；BT-m2（步骤 5/6 clamp 过渡）→ §11 步骤 5 写明过渡 clamp。全部采纳。
