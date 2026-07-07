# 启动台 #19 自定义排序与文件夹最终落地设计文档

> 本文档综合四套已评分方案，以方案 #1（数据模型/持久化）与方案 #2（最小增量投影）为骨架，嫁接方案 #4 评审中标注「必采纳」的 AppKit 拖拽范式与刷新链路修正。所有架构断言以精读真实代码为准；冲突处给出明确取舍理由。

---

## 1. 概述与已定决策回顾

为启动台插件实现 #19，分两期叠加在现有 `LaunchpadGridView`（`selectedIndex` 单一真值 + `filtered` 派生 + HStack offset 分页）之上：

- **19a**：自定义排序 + 拖拽重排。
- **19b**：文件夹（单层，文件夹内只放 App）。

**核心架构判断（综合方案 #1/#2，评审一致「必采纳」）**：把「自定义排序 + 文件夹」做成 `catalog.apps`（恒为字母序真值源）之上、`filtered` 之下的**一层纯数据 reconcile 投影**。下游分页/选择/搜索的单一真值链（`selectedIndex` 及其所有边界钳制）**完全零改动**，把重排从「危险的真值重写」降级为「安全的下游投影」。

**已敲定产品决策（不推翻）**：

| 决策 | 落地方式 |
|------|----------|
| 排序：默认字母序；拖动即进「自定义排序」模式；提供「恢复字母序」入口 | 「布局是否存在」即模式标志；首次成功 drop 物化字母序快照并落盘；设置页按钮恢复 |
| 搜索：临时扁平化（忽略文件夹/自定义布局，平铺过滤结果）；清空恢复原布局 | 搜索 = `filtered` 计算分支切换，**从不触碰持久化**；清空即天然恢复 |
| 新增 App：追加到自定义顺序末尾（不打乱已有顺序） | reconcile 时新 id 一律 append 到根层末尾 |
| 分期：先 19a，再 19b，两期都设计 | 一套 `LaunchpadLayout` 树一次覆盖两期，避免二次迁移；19a 只产 `.app` 节点 |
| 平台：macOS 14+，SwiftUI + AppKit；描述式 UI；状态变更走刷新链路；持久化走 PluginStorage（`plugin.launchpad.<key>` 作用域） | 新建 `LaunchpadLayoutStore`，仿 `AppHotkeyStore` 的 `JSONEncoder + data(forKey:)` |

**两条被评审揪出、必须写进设计的现实约束（地基级，方案 #3/#4 都踩过）**：

1. **overlay 网格不吃 `onStateChange`**。`LaunchpadGridView` 被塞进 `LaunchpadOverlayController` 的独立 `NSWindow`/`NSHostingView`；它唯一的 `@ObservedObject` 是 `catalog`。`onStateChange?()` 驱动的是 `PluginHost` 的菜单栏/设置派生态，**与已打开的 overlay 网格无关**。现有 `onHide` 之所以即时生效，是因为 grid 改自己的 `@State sessionHidden`。**结论：布局变更后让网格重渲染，必须靠网格自己持有的响应式状态，不能依赖 `onStateChange`。**（见 §5 状态字段与刷新链路）
2. **拖拽实现照搬 `MenuBarHidden` 范式**：整页一个 `NSViewRepresentable` 包一棵纯 AppKit 子视图树，per-item 用 `NSView: NSDraggingSource`，**翻页也交给这棵 AppKit 树自己裁决鼠标事件**，从根上消除「SwiftUI HStack DragGesture vs per-cell NSView」的手势仲裁难题。（见 §5 拖拽机制）

---

## 2. App 身份键的选择

**主键：沿用 `LaunchpadAppItem.id = url.resolvingSymlinksInPath().path`（resolved 绝对路径 String）。** 四套方案一致、评审一致认定正确。

**论证（已核对代码）**：
- 该 id 已是三处的同一把钥匙：`LaunchpadAppCatalog.icon(for:)` 的 `NSCache` key、`LaunchpadPreferences.hiddenAppIDs` 的持久化键、`LaunchpadAppScanner` 的字母序 tie-break 键。统一身份键避免「隐藏」和「排序」用两套 id 导致 reconcile 对不上。
- `LaunchpadAppScanner` 刻意 main-actor-free / off-main 纯扫描（不碰 `NSWorkspace`/读 `Info.plist`）以免阻塞。换 bundleID 主键会破坏这条性能边界，需给 147 个 App 加 per-app plist I/O（冲击现有 ~47ms 预算）。

**稳定性 / App 增删改名移动的影响**：

| 场景 | 影响 | 处理 |
|------|------|------|
| **原地更新**（覆盖安装到同路径） | path 不变，id 不变 | 自定义顺序/文件夹归属**存活**。这是比设计自身担忧更窄的好情况 |
| **改名（仅显示名变）** | id（路径）不变 | 顺序不受影响；`name` 仅作显示与弱 fallback |
| **移动 / 重装到新路径** | 旧 id 在布局里变孤儿，新路径作为「新 App」追加末尾 | reconcile 静默跳过孤儿、新 id append。用户感知 =「这个 App 跑到最后去了」，**良性降级，不崩、不丢其它数据** |
| **卸载** | 旧 id 变孤儿 | reconcile 静默跳过、保留条目（容错窗口），见 §10 边界 |

**取舍：19a/19b 都不做 bundleID 二级匹配。** 方案 #1 提出「bundleID+name 作弱 fallback、唯一匹配才改写、歧义不猜」，评审虽认其「风险控制最好」，但同时指出两个落地硬伤：(a) `LaunchpadAppItem` 当前无 bundleID 字段，填充它要破坏 off-main 扫描纯净性或加 per-app I/O；(b) 触发漂移对账依赖的钩子不可靠（见下）。**取舍结论：v1 不引入 bundleID，与 `hiddenAppIDs` 现状保持同样局限（移动即孤儿），把失败模式锁在「重装 App 回末尾」这个可接受降级上。** 若将来要修，hidden + order 一起做，统一在 catalog 层加 bundleID 副键——但明确划在 #19 之外，避免范围蔓延。

> **保留 `bundleID` 字段位但不填充**：`LaunchpadAppRef` 的 schema 保留可空 `bundleID`（见 §3），仅为将来迁移留 Codable 兼容空间，v1 恒为 `nil`，绝不参与匹配逻辑。

**文件夹身份键：独立 UUID 字符串。** App id 永远以 `/` 开头（绝对路径），文件夹 id 用 UUID，命名空间天然不冲突。文件夹名可被用户改，但 id 永不变——改名只改 `name` 字段，不影响布局引用或持久化键。（回答 openQuestion「文件夹 id 用 UUID 还是名字」：用 UUID。）

---

## 3. 数据模型（内存表示）

**一套 `LaunchpadLayout` 浅树，一次覆盖 19a + 19b**（方案 #1 的「让非法状态不可表达」，评审「必采纳」）：

```swift
struct LaunchpadLayout: Codable {
    var version: Int = 2                 // 从 2 起步，预留 1 给假想的纯 [String] v1
    var nodes: [LaunchpadLayoutNode]
}

enum LaunchpadLayoutNode: Codable, Hashable {
    case app(LaunchpadAppRef)
    case folder(id: String /* UUID */, name: String, children: [LaunchpadAppRef])
    // 手写 Codable：用 "kind": "app" | "folder" 判别字段，
    // 不依赖 Swift 自动 enum 编码，便于将来兼容地加字段
}

struct LaunchpadAppRef: Codable, Hashable {
    var id: String          // 路径主键
    var bundleID: String?   // 保留字段，v1 恒为 nil（见 §2 取舍）
    var name: String        // 弱 fallback / 调试可读性
}
```

**关键类型约束**：

- `folder` 的 `children` 只装 `LaunchpadAppRef`（**不是** `LaunchpadLayoutNode`）——从类型层面禁止「文件夹套文件夹」（macOS Launchpad 同款两层约束），让非法状态在编译期就不可表达。**这是评审三次点名「必采纳」的好品味。**
- 19a 阶段 `nodes` 只含 `.app`；`.folder` 分支由 19b 启用，但 schema 一次定死，**19a→19b 不改持久化格式、不需要二次迁移**。

**渲染用展开类型（computed，不持久化）**：

```swift
enum LaunchpadDisplayCell: Identifiable {
    case app(LaunchpadAppItem)
    case folder(id: String, name: String, items: [LaunchpadAppItem])

    var id: String {        // 统一稳定身份：app 用路径，folder 用 "folder.<uuid>"
        switch self { case .app(let a): return a.id
                      case .folder(let fid, _, _): return "folder.\(fid)" }
    }
}
```

> **运行时身份陷阱（MEMORY.md 教训）**：app cell 与 folder cell 混在一个渲染序列里，`ForEach`/AppKit diff 的 id 必须用 `LaunchpadDisplayCell.id` 这个跨类型统一稳定键，否则拖拽/动画错位（正是「SwiftUI 视图身份 / AX 动作运行时 bug」的坑）。必须真机驱动验证而非只静态审查。

**「自定义模式」标志 = 布局存在性，不引入额外 `isCustomSorted: Bool`**（方案 #3 优点，评审认可）：
- `layout` 持久化键不存在（`nil`）= 未进入自定义模式 = 字母序。
- `layout` 存在 = 自定义模式。
- 少一个可能与布局不一致的状态。「恢复字母序」= 删除 `layout` 键回到 `nil`。

> 取舍：方案 #1/#2/#4 都另存一个 `sortMode`/`isCustomSorted`。采用方案 #3 的 optional 存在性表达，因为它从根上消除「标志说自定义但布局为空」或反之的不一致态。

---

## 4. PluginStorage 持久化格式 + 版本化与迁移

**作用域**：`plugin.launchpad.<key>`（沿用 `context.storage`，与现有 `windowMode`/`columns`/`hiddenAppIDs`/`hotCorner` 并列，不冲突）。

**新建 `LaunchpadLayoutStore`（`@MainActor final class ObservableObject`，仿 `AppHotkeyStore`）**：

- 持有注入的 `PluginStorage` + `JSONEncoder`/`JSONDecoder`；`load` on init、`persist()` write-through、`load`/`save` 分离（与 `FanControlPresetStore` 范式一致）。
- **必须是 `ObservableObject` 且对外暴露 `@Published`**（评审揪出的关键修正：方案 #3/#4 设计成普通 class，grid 不 observe 就不重渲染）。网格以 `@ObservedObject` 注入此 store（见 §5）。
- **不塞进 `LaunchpadPreferences` 的 didSet 海里**：布局是 Codable 树（非标量），单独 store 更清晰、可独立单测。但与 `LaunchpadPreferences` 一样在 `LaunchpadPlugin.init` 用同一个 `context.storage` 构造。

**存储键与格式**：

| 键 | 类型 | 默认 | 含义 |
|----|------|------|------|
| `"customLayout"` | `Data`（`JSONEncoder` 编码 `LaunchpadLayout`） | 缺失 = `nil` = 字母序 | 唯一布局真值，含 `version` |

**为什么 19a 也直接用 `Data` + 树，而非 `stringArray` 存 `[String]`**：19a 单独看可以用 `stringArray("customOrder")`，但 19b 必须换成 `Data` 并写一次 `stringArray→Data` 迁移。既然 19b 已敲定要做，**直接从 `Data` + 树状 `LaunchpadLayout` 起步，19a 只是树里全是 `.app` 节点**，省掉中途迁移。这是有意的「为 19b 预留格式」决策（采纳方案 #3，优于方案 #2/#4 的「19a 存 `[String]`、19b 再迁移」）。

**版本化与迁移**：

- **v0 → v2（当前线上 → 首发）**：v0 = 「无 `customLayout` 键」状态。`LaunchpadLayoutStore.init` 读不到 data → `layout = nil`、字母序。**老用户首次升级仍是字母序，零迁移成本。**
- **解码失败 / `version < 2`**：catch 后 fallback 到 `nil`（字母序），`AppLog` 记 warning，**绝不 crash**（照 `AppHotkeyStore` 的容错 + 补日志）。
- **未来 version 升级**：在 decode 后按 `layout.version` 做 in-memory upgrade，升级后立即 persist 回写，单测覆盖「读旧版本 → 内存升级 → 回写新版本」。
- **`migrateValueIfNeeded` 不误用**（评审核对：该 API 仅 key 改名语义——新 key 为空且旧 key 存在才搬运）。此处是格式起步，无 legacy 同义键，保留钩子位以备后用，但不靠它做格式升级。

**新增 App「追加末尾」如何落地**：reconcile 产出协调后的序列，但 **reconcile 本身不写盘**——只有用户显式动作（拖拽、建夹、改名、移入移出、恢复字母序）才调 `store.update → persist`。新 App 的「追加末尾」是**渲染期行为**（展开时把未引用的新 App 拼到尾部）；下次用户拖动该 App 时其位置才落盘。这避免「光打开启动台因为装了新软件就反复写盘」，正确复刻 `hiddenAppIDs` 仅在 hide/unhide 落盘的 write-through 语义。

> **写盘只由用户动作驱动、reconcile 保持纯读**（方案 #2/#3 共识，评审「必采纳」）——同时规避架构事实第 6 点的「reload 异步完成时正在 build 列表」写竞争。

**隐藏 App 交互**：`hiddenAppIDs` 优先级最高且与排序**正交**。reconcile 时**先按 hidden 过滤、再套布局**。被隐藏的 App 仍保留在 `layout` 条目里（数据层不删），取消隐藏后回到原自定义位置。`sessionHidden`（grid 会话态，每次 `open()` 从 `hiddenAppIDs` 重新 seed）与排序解耦：建议 hidden 过滤保持在 grid 现有位置，`orderedApps` 不感知 hidden（hidden 是显示层、排序是数据层）。

---

## 5. 19a 设计：拖拽重排机制、手势共存、模式切换、状态字段

### 5.1 拖拽实现：照搬 `MenuBarHidden` 的整页 AppKit 范式（评审「必采纳 A」）

**否决的路线**：
- ❌ SwiftUI `.draggable`/`.dropDestination`（方案 #2/#3）：macOS 14 上在分页 HStack offset 容器内无本仓库先例、与翻页 `DragGesture` 抢事件、offset 动画期 cell 命中漂移——方案自身均承认「实测需验证」。
- ❌ per-cell `NSViewRepresentable`（方案 #4 一度担忧的成本模型）：147 个 NSView 包装拖慢首屏。
- ❌ 全改 `NSCollectionView`：与现有 `LazyVGrid` 框架冲突、重量级。

**采用的路线**：**整页一个 `NSViewRepresentable` 包一棵纯 AppKit 子视图树**，参照 `Plugins/MenuBarHidden/Sources/MenuBarHiddenLayoutStripView.swift`（`MenuBarHiddenItemNSView: NSView, NSDraggingSource`，`mouseDragged` 里 `beginDraggingSession`，整条带是单个 `NSViewRepresentable` 包一整棵 AppKit 子树——per-item NSView 拖拽已在生产里跑）。

- **payload = `app.id` String**（沿用 `FeatureManagementTableView` 的 String-ID drag payload 语义：`onMove(id, target)`，数组 move）。
- **手势仲裁难题被根除**：翻页、拖拽、点击、右键全在这棵 AppKit 树内由鼠标事件统一裁决（`mouseDown`/`mouseDragged` 阈值判定 + `hitTest`），**不再和任何 SwiftUI `DragGesture` 并存抢事件**。R1（原「最高风险」）直接降级。
- **拖拽视觉**：源 cell 半透明（opacity ~0.35）+ 轻微放大（scale ~1.05）+ 阴影（克制、macOS 原生，替代竞品 jitter）；目标间隙画 2pt accent 色插入指示线（基于当前可见页的固定网格几何 `cellWidth`/`columnCount`/`rowCount`，不依赖动画中的瞬时 offset，规避坐标漂移）。
- **命中测试**：落点 → 当前可见页固定几何 → (行,列) → 「插入到 id X 之前/之后/末尾」的相对位置（**不是绝对索引**，规避 hidden/卸载导致的索引漂移污染持久化）。

> **取舍说明**：方案 #2「整页改 AppKit 投入大」与方案 #4「per-cell NSView 太重」都被 `MenuBarHidden` 的「整页一个 representable + 内部纯 AppKit 子树」范式同时化解。这是评审在四套方案里挖出的、唯一有生产先例的可行路径。

### 5.2 reconcile：派生显示顺序（纯函数，可单测，无 UI）

```text
reconcile(apps: [LaunchpadAppItem], layout: LaunchpadLayout?, hidden: Set<String>)
    -> [LaunchpadDisplayCell]
```

1. 先按 `hidden` 从 `apps` 过滤，得 `visible`。
2. `layout == nil` → 直接返回 `visible`（已字母序）的 `.app` 序列（**默认态行为零变化**）。
3. `layout != nil`：建 `visible` 的 `id → item` 映射；
   - 顺序遍历 `layout.nodes`：
     - `.app(ref)`：`ref.id` 在映射且未 hidden → 输出该 app；否则**静默跳过**（孤儿/卸载/隐藏，容错窗口）。
     - `.folder`：`children.compactMap` 解析有效 items（过滤缺失/hidden）；空 folder（items 全没了）→ 跳过该 folder cell。
   - 收集所有已被引用的 id。
   - `visible` 里未被引用的 id（= 新装 app）→ 按字母序**追加到根层末尾**（产品决策）。
4. **去重**：同一 id 同时在 folder 与顶层时以 folder 为准、从顶层剔除（恰好出现一次）。

**四条可断言不变量（单测断言，方案 #1/#3 共识，评审「必采纳」）**：
1. `visible`、已在布局中的 id，相对顺序 == 布局相对顺序。
2. `visible`、不在布局中的新 id，全部出现在根层末尾，且内部按字母序。
3. 布局中存在但 `visible` 缺失的 id，保留在布局里不可见（容错窗口），不参与渲染。
4. hidden 优先：先滤 hidden 再套布局。

> **关键不变量（方案 #2，评审三次「必采纳」）**：`reconcile` 输出的**元素集合恒等于 `visible`，只是顺序不同**。因此下游 `perPage`/`pageCount`/`selectedIndex` 钳制/`goToPage` 全部一行不用动——这是把重排做成「安全下游投影」的根本理由。

### 5.3 「拖动即进自定义模式」

- `layout == nil`（字母序）时，第一次成功 drop 调 `materializeIfNeeded()`：把**当前展开序列的字母序全量快照**固化成全 `.app` 的 `LaunchpadLayout`，**再**执行这次 move。从此 `layout != nil` = 自定义模式，无需用户确认、无需开关。
- **快照来源必须锁定、与并发 reload 隔离**（评审揪出的时序脆弱点）：materialize 取的快照**不在 drop 回调里临读 `filtered` computed**（可能撞上异步 reload 的 stale 态）。改为：拖拽会话开始（`mouseDown` 起拖）那一刻，由 AppKit 视图持有「本次会话的展开序列冻结副本」，drop 时 materialize 用这个冻结副本，保证「拖一个之后其余保持原字母序」不跳乱。

### 5.4 「恢复字母序」入口

- 放 `LaunchpadSettingsView` 新增「排序」分组：显示当前模式（字母序/自定义）+「恢复字母序」按钮，**仅当 `layout != nil` 显示**（仿现有 `hiddenSection` 条件渲染，用 `PluginSettingsTheme`）。
- 点击 → `store.resetToAlphabetical()`（`removeObject(forKey: "customLayout")` → `layout = nil` → persist）→ 网格因 store `@Published` 变化重渲染回字母序。
- **不用隐蔽手势**（Cmd+长按等），符合现有「设置页是唯一管理面」约定（隐藏应用恢复也在设置页）。回答 openQuestion #3。

### 5.5 状态字段清单与刷新链路（地基修正）

**刷新链路（评审揪出的最严重事实错误的修正）**：overlay 网格不吃 `onStateChange`。布局变更让网格重渲染的机制是：

```text
用户拖拽/建夹/恢复  →  store.mutating 方法（改 layout 树 + persist）
                    →  store 是 @ObservedObject，@Published layout 变化
                    →  GridView 重新求值 → reconcile → 重渲染
                    →  （旁路）onStateChange?() 仅用于宿主菜单栏/设置派生态，与 overlay 无关
```

**网格新增/调整状态字段**：

| 字段 | 位置 | 作用 |
|------|------|------|
| `@ObservedObject layoutStore: LaunchpadLayoutStore` | GridView（**新增注入**） | 让 grid 真正 observe 布局；**这是方案 #3/#4 漏掉的关键，没它 reorder 后视图不更新** |
| `@State dragSourceID: String?` | grid 级（**非 per-cell**） | 拖拽源身份；置位即「编辑态」；hoist 到 grid 级避免 page slicing 重建 cell 时丢失拖拽视觉态 |
| `@State dragInsertTarget` | grid 级 | 当前插入位（before/after id）→ 画插入线 |
| 现有 `selectedIndex` / `currentPage` | 不变 | 单一真值；reconcile 后元素集合不变，钳制逻辑零改动 |

- **拖拽期冻结 `selectedIndex`**：`dragSourceID != nil` 时键盘 `handleMove` 早返回（`guard dragSourceID == nil`），避免拖拽中方向键打乱。
- **drop 后事务化**：改 layout → persist → reconcile → `selectedIndex` 按**被拖 app 的 id**重定位到其新全局索引（不是 min 钳制；评审揪出「selectedIndex 是位置型不是身份型，重排后高亮会黏在原位」）→ 清 `dragSourceID`/插入线。
- **overlay dismiss 加固**（评审揪出的具体炸点）：`LaunchpadOverlayController` 的 `didResignActiveNotification → close()` 会无条件关窗。19b 的文件夹改名 `TextField`、文件夹打开浮层若触发 app 短暂 resign active 会丢拖拽态/直接关窗。**必须在拖拽进行中（`dragSourceID != nil`）与文件夹打开态豁免或加固这个 resign 监听**（intra-window 拖拽本身不 resign，但辅助面板/sheet 会）。

### 5.6 翻页与拖拽共存（已被 §5.1 范式根除，仅余跨页增强）

因翻页与拖拽同在一棵 AppKit 树内裁决，无 SwiftUI 手势仲裁问题。**跨页拖拽列为 19a 增量子步骤**（非 v1 必需）：拖到网格左/右边缘停留 ~0.5s 触发翻页后继续拖。v1 跨页可「先翻到目标页再拖到页内位置」分两次完成（可接受）。注意 auto-page 翻页会改 `selectedIndex`，与拖拽期冻结意图冲突——翻页后按**被拖 app id** 重映射，不靠 index。

---

## 6. 搜索扁平化 ↔ 恢复布局的状态机

**核心洞察（方案 #2/#3 共识，评审一致「必采纳」）：搜索扁平化 = `filtered` 计算分支切换，不是数据迁移、从不触碰持久化。** 现有 `filtered`（`LaunchpadGridView.swift`）已按 `query.isEmpty` 分支，几乎零改动。

**状态 = `searchText` 一个变量**（无新增持久态）：

| 态 | 条件 | `filtered` 源 | 拖拽/建夹 |
|----|------|--------------|-----------|
| **布局态 A** | `searchText` 空 | `reconcile(catalog.apps, layout, hidden)` 展开序列（folder 作占位 cell，order 生效） | 启用 |
| **扁平搜索态 B** | `searchText` 非空 | 对**全量可见 app（含 folder 内 app 一并打散）** 做 `LaunchpadFuzzy` 模糊匹配 + 分数排序的**平铺**结果，完全忽略 layout/folder | **禁用** |

**转移**：
- **A → B（开始输入）**：现有 `onChange(of: searchText)` 已重置 `selectedIndex=0`/`currentPage=0`，复用。19b 文件夹打开态（`openFolderID`）强制收起。
- **B → A（清空搜索）**：`filtered` 自动回到 reconcile 展开序列（**因为 `layout` 从未被搜索动过**）。「恢复原自定义布局/文件夹」是**零成本天然结果**，没有「保存/恢复布局快照」的状态可丢。

**核心不变式**：搜索态是「只读投影」——`reconcile`、materialize 回写、任何 `layout` 写入一律 `guard searchText.isEmpty`，保证「清空即恢复、搜过不乱序」。搜索态下 folder 内 app 直接以独立 cell 参与匹配，folder 本身不出现，**不显示面包屑/来源标记**（回答 openQuestion #2，v1 从简）。

> **B→A 后 selectedIndex 与 custom+folder 布局的对齐**（评审揪出的细节）：清空后 `selectedIndex=0`/`currentPage=0` 复位即可（现有转移已做）。custom+folder 态下 `selectedIndex` 仍是「展开序列（folder 占一槽）的线性索引」，`currentPage = selectedIndex / perPage` 派生不变——因为 §5.2 不变量保证展开序列就是一条线性 `[LaunchpadDisplayCell]`，folder 只是其中一个 cell，分页派生与现状同构。

---

## 7. 19b 设计：文件夹

复用 §3 已定死的 `LaunchpadLayout` 树，只是开始产出 `.folder` 节点。

**模型**：`folder(id: UUID-string, name, children: [LaunchpadAppRef])`，单层、folder 内只放 app、类型层面禁止嵌套。

**创建（叠加成夹，借鉴竞品 macOS Launchpad）**：拖一个 app 图标 drop 时落点命中**另一个 app cell 的中心区域**（落点距目标 cell 中心 < cell 宽 ~35%，区别于落在间隙的「插入重排」）→ 原子事务：新建 `folder(id: UUID, name: 默认名, children: [被叠 app, 被拖 app])`，在 `nodes` 中用该 folder **替换被叠 app 的位置**，从根层移除被拖 app。默认名 v1 用「未命名」或第一个 app 名，用户可改。

**渲染**：folder cell = 2×2 缩略（取 `children` 前 4 个 `catalog.icon(for:)` 拼小图）+ 名称，占根层一个 cell 槽，参与现有分页（folder 也可跨页拖动）。

**打开**：点 folder cell → 不启动，弹**内嵌 overlay 子网格**（盖在主网格上方 ZStack 顶层、半透明压暗背景、点外部/Esc 关闭）。子网格复用同款 cell + icon cache + 19a 拖拽。**不另开 NSWindow**（避免触发 §5.5 的 resign-active 关窗）。

**命名**：打开态顶部可编辑 `TextField` → `store.renameFolder(id, name)` → persist。空名回退默认名。id（UUID）不变。

**移入**：拖根层 app 叠到 folder cell → `addToFolder`（append 到 `children` 末尾，从根层移除）。

**移出**：打开态把 app 拖出浮层边界，或右键「移出文件夹」→ `removeFromFolder`（从 `children` 移除，**追加到根层末尾**——与「新增 App 追加末尾」语义一致）。
> 取舍：拖出浮层的跨层坐标复杂度高，v1 可先用浮层内右键「移到根层」兜底，纯拖出列为增量。

**删除 / 空夹清理（自动解散）**：
- `children` 降到 **1** → 自动解散：把最后一个 app 提回根层**原 folder 位置**（不是末尾，避免突兀），删除 folder 节点，避免「单 App 文件夹」垃圾态。
- `children` 降到 **0** → 直接删 folder 节点。
- 右键「解散文件夹」显式入口：`children` 全部释放回顶层原位、移除 folder。

**自动解散与容错窗口的冲突调和**（方案 #1/#4 都标为「需真机验证」的张力，此处给明确取舍）：
- **持久层 vs 渲染层分离**：卸载/外置卷未挂载导致 folder 多数 `children` 临时不可见时——**渲染期**按「有效 items 数」决定是否展示为空夹/解散，但**不立即改写持久层**。只有**用户显式操作**（手动拖最后一个出夹）才触发持久层的自动解散落盘。
- 这样「外置卷未挂载 → 夹临时只剩 1 个可见」只在渲染上降级，卷重新挂载后 folder 完整回来，**不会出现「夹突然散了又回来还落了盘」**。代价：渲染层与持久层短暂不一致，但用户感知是「App 临时不可见」而非「夹被破坏」，可接受。

**原子性（回答 openQuestion #1）**：建夹/移入/移出/解散都是 store 上一个方法，内部完成「改 layout 树 → 去重/解散判定 → persist → 触发 grid 重渲染」一次性事务，对外原子，UI 不出现「app 既在顶层又在夹里」的中间态。

**与分页/搜索关系**：
- 分页：folder cell 与 app cell 同槽，`perPage`/`pageCount` 基于 `LaunchpadDisplayCell.count`，逻辑不变。打开浮层时主网格分页状态冻结，关闭恢复，不改 `selectedIndex` 真值。
- 搜索：见 §6——彻底扁平化，folder 内 app 平铺进候选，folder 不出现、不显面包屑。
- reconcile 与文件夹：新扫描 app 一律进**根层末尾**（不试图回到「上次所在文件夹」，回答 openQuestion #3「新 App 只进根层级」）。

**无障碍**：folder cell 标「文件夹，N 个应用」并补 `accessibilityAction`（现有 cell/page dot 已有此模式）；重排提供 Cmd+方向键 / `accessibilityAction`「前移/后移」兜底，**绝不让拖拽成为唯一重排途径**（MEMORY.md 教训）。

---

## 8. 分期实现步骤（每步可独立编译 / 测试 / 出 PR）

> 每步完成即 PROGRESS.md + commit（auto-checkpoint）。新增源文件后跑 `make generate` 再 `make build`，单测 `-only-testing:MacToolsTests/<TestClass>`。

### 19a 自定义排序 + 拖拽重排

| 步 | 内容 | 验证 |
|----|------|------|
| **19a-1** 数据层 | 新建 `LaunchpadLayout`/`LaunchpadLayoutNode`/`LaunchpadAppRef` Codable（手写 kind 判别）+ `LaunchpadLayoutStore`（`ObservableObject`，`@Published layout`，load/save 分离，解码失败 fallback nil + 日志，`materializeIfNeeded`/`move(id:before/after:)`/`resetToAlphabetical`）。纯数据无 UI。 | 编解码 round-trip、空→字母序、坏数据 fallback 单测 |
| **19a-2** reconcile 纯函数 | `reconcile(apps, layout, hidden) → [LaunchpadDisplayCell]`（19a 阶段只产 `.app`）。 | 四不变量单测：保序/新增末尾/缺失跳过/hidden 优先；异步新增不打乱 |
| **19a-3** grid 接 reconcile（只读，仍不可拖） | `LaunchpadGridView` 注入 `@ObservedObject layoutStore`；展开序列源切到 reconcile；搜索分支不变。**`layout == nil` 时与现状逐像素一致**（回归基线）。 | 手工塞一份 layout 验证自定义顺序生效；字母序回归 |
| **19a-4** AppKit 拖拽重排（当页） | 整页 `NSViewRepresentable` + per-item `NSDraggingSource`（照搬 `MenuBarHidden`）；源高亮/插入线；drop → `materializeIfNeeded` + move + persist；冻结 `selectedIndex`、drop 后按 id 重定位；resign-active 豁免。 | 真机 Before/Action/After：拖动 A 到 B → 重开 overlay 顺序保持；首拖后进自定义 |
| **19a-5** 恢复字母序入口 | `LaunchpadSettingsView` 加「排序」分组 + 按钮（`layout != nil` 才显示）→ `resetToAlphabetical`。 | 自定义后点恢复 → 重开为字母序、键清空 |
| **19a-6**（增量，可选） | 跨页拖拽：边缘悬停自动翻页；键盘/AX 重排兜底。 | 三场景互不误触真机验证 |

### 19b 文件夹

| 步 | 内容 | 验证 |
|----|------|------|
| **19b-1** 模型填实 | `LaunchpadLayoutNode.folder` Codable 实现；`LaunchpadDisplayCell.folder`；reconcile 扩展（解析 folder、过滤缺失 children、跳过空夹、去重、新 app 进根层）。**19a 纯 `.app` 行为不回归**（schema 未变，无迁移）。 | folder reconcile 单测：有效 items/空夹跳过/去重/新 app 追加根层 |
| **19b-2** folder cell 渲染 + 打开浮层（只读） | 2×2 缩略 cell；点开内嵌 overlay 子网格；子 app 启动；Esc/点外关闭。 | 手工塞含 folder 的 layout 验证渲染/打开/启动 |
| **19b-3** 建夹（叠加）+ 拖入 folder | drop 区分插入 vs 叠加（中心区判定）；app→app 建夹、app→folder 入夹（原子事务）。 | 拖 A 叠 B → 生成含 A、B 的 folder，重开保持 |
| **19b-4** 命名 + 移出 + 解散 | 打开态 `TextField` 改名；右键/拖出移出；children≤1 自动解散；右键解散。resign-active 加固。 | 每条路径 Before/After + 重开持久化 |
| **19b-5** 搜索打散校验 | 搜索态 folder 内 app 平铺参与匹配、folder 不出现；清空恢复 folder 布局。 | 状态机往返真机验证 |

---

## 9. 测试计划（要补的 XCTest）

> 放 `Plugins/Launchpad/Tests/`，跑在 `MacToolsTests` bundle（`@testable import MacTools` + `@testable import LaunchpadPlugin`）。复用 fake `PluginStorage`——注意现有 `FakeStorage` 是 `LaunchpadPreferencesTests` 内的 **private nested class**（评审揪出），需**提取成共享 fixture** 或新建一份共享 `FakePluginStorage`。

**`LaunchpadLayoutStoreTests`**：
- 默认空 → `layout == nil` → 字母序透传。
- 持久化 round-trip：写 layout → 重建 store → 读回一致。
- 坏数据 / `version < 2` → fallback nil（不 crash）+ 日志。
- `materializeIfNeeded`：nil → 全 `.app` 快照固化。
- `move(id:before/after:)` / `resetToAlphabetical` → 键清空。
- 未来 version 内存升级 → 回写（钩子测试）。

**`LaunchpadReconcileTests`**（纯函数，重点）：
- nil layout → 字母序。
- 四不变量：已知 id 保序 / 新 id 追加末尾且内部字母序 / 缺失 id 容错跳过 / hidden 先过滤。
- **App 增删稳定性**：异步「数量不变但内容变化（一个 app 换另一个）」→ 旧 id 跳过、新 id 末尾，不打乱其余。
- 同名双路径（`/Applications/X.app` vs `~/Applications/X.app`）→ 路径主键区分，各占一条不合并。
- **19b**：folder 有效 items / 空夹跳过 / 顶层与 folder 同 id 去重 / 新 app 不进 folder。

**`LaunchpadFolderOpsTests`**（19b store 方法，纯逻辑）：
- `makeFolder`/`addToFolder`/`removeFromFolder`/`renameFolder`/`dissolve` 各自落盘 round-trip。
- children≤1 自动解散把最后一个提回原位。
- 改名后 id（UUID）不变。

**搜索恢复**（可在 grid 层做轻量逻辑测试或真机验证）：搜索期 `guard searchText.isEmpty` 拦截所有写盘；清空后展开序列恒等于搜索前。

**首拖序列连续性**：`layout == nil` 直接 move（不 materialize）会让其余全当新 app 跳乱 → 断言必须先 materialize 冻结快照。

> 无法运行测试时在回复中说明原因与本地验证命令（`make build` + 单测命令）。

---

## 10. 边界场景与风险清单

**边界场景**：

1. **空 layout / 首次使用**：`nil` → 字母序，升级无感（向后兼容现有用户）。
2. **孤儿 id（移动/卸载）**：reconcile 静默跳过、保留持久条目（容错窗口，容忍临时移动/外置卷）；漂移新 id 追加末尾。不崩、不丢其它数据。
3. **新装 app**：追加根层末尾，不打乱、不进 folder、不弹通知（回答 openQuestion #4，保持安静）。
4. **异步 reload 中途插入**：reconcile 纯读、新 app 只在末尾出现；`selectedIndex` 夹紧到有效范围（现有逻辑）。
5. **隐藏与排序交叉**：hidden 先过滤再排；隐藏的 app 仍在 layout，取消隐藏回原位；隐藏 folder 内最后一个可见 app → 渲染期跳过该 folder（不删持久层）。
6. **拖拽中 reload 完成**：落地按**被拖 id** 定位（非 index），不受 reload 影响。
7. **拖到原位 / 搜索态拖拽**：原位 = no-op 不写盘；搜索态拖拽禁用。
8. **folder 减到 1 / 空 folder**：自动解散回原位 / 删空夹；外置卷临时不可见只渲染降级、不落盘（§7 取舍）。
9. **首拖序列连续性**：`layout==nil` 首 drop 必须先 materialize 冻结快照再 move，否则其余跳乱。
10. **坏数据 / 版本不符**：解码失败 → nil（字母序），绝不崩。
11. **重名 folder**：UUID 标识，允许同名；空名回退默认名。
12. **columns/分页变化（updateLayout）**：布局顺序与 `perPage` 无关，只重算切片、`selectedIndex` 重夹紧（现有逻辑保留）。
13. **多显示器 / Space 切换 / screen 参数变化**：overlay 现有 `didChangeScreenParameters` 重算 frame，与排序数据无关；layout 是数据层不受影响。
14. **热更新 `.updating`**：不清持久 layout，进程内不重激活，靠重启读回（与 `reason.requiresStateCleanup` 语义一致）。
15. **compact 窗口模式**：folder 浮层在 GridView 内 ZStack（不另开窗），随浮窗尺寸自适应；需真机验证 compact + fullscreen 两种模式不挤压。

**风险清单（按危险度）**：

| # | 风险 | 缓解 | 残留 |
|---|------|------|------|
| R1 | **overlay 网格不响应布局变更**（地基） | store 设为 `ObservableObject`，grid 以 `@ObservedObject` 注入；布局变更不靠 `onStateChange` | 必须 19a-3 真机验证 reorder 后视图确实更新 |
| R2 | **AppKit 拖拽整页范式集成** | 照搬 `MenuBarHidden` 生产先例；翻页同树裁决消除手势仲裁 | 整页 AppKit 子树渲染需性能验证（懒加载只实例化可见页） |
| R3 | **resign-active 关窗丢拖拽态/文件夹态** | 拖拽进行中 + 文件夹打开态豁免/加固 `didResignActive` 监听；浮层不另开 NSWindow | 19b-2/19b-4 必须真机验证辅助面板不触发关窗 |
| R4 | **selectedIndex 位置型 vs 身份型**（重排后高亮黏原位） | drop 后按被拖 app id 重定位 selectedIndex，非 min 钳制 | 真机验证拖动后选中框跟随 app |
| R5 | **首拖 materialize 时序**（撞并发 reload 用 stale 快照） | 拖拽会话起始冻结展开序列副本，drop 用冻结副本 materialize | 单测 + 19a-4 截图双保险 |
| R6 | **path-based id 脆弱**（移动即孤儿） | 与 hiddenAppIDs 同局限，静默剔除；最坏「回末尾」 | 已知限制，非本期解决 |
| R7 | **自动解散 vs 容错窗口张力** | 渲染层降级、持久层只在用户显式操作落盘 | 真机验证「外置卷未挂载」文案与时机 |
| R8 | **写盘频率**（reconcile 自愈若每次 reload 写） | reconcile 纯读不写盘；写盘只由用户动作驱动、且先比对再 set | 单测断言「无变化不写」 |
| R9 | **运行时视图身份**（app/folder 混排 diff 错位） | `LaunchpadDisplayCell.id` 跨类型统一稳定键；真机驱动验证 | MEMORY.md 教训，必须运行时验证 |
| R10 | **跨页拖拽体验残缺**（v1 先翻页再拖） | 列为 19a-6 增量；v1 体验差距标注 | interactionQuality 打折，可接受 |

---

## 11. 待与产品确认的开放问题

> **已敲定决策（2026-06-05）**：
> - **时序**：19a 待 #129/#130/#115/#113 合入 main、基线干净后再从 main 起，不在 #129 上 stack。
> - **跨页拖拽（下方 #1）**：v1 **不做**，归入 19a-6 增量；首版用「先翻页再拖到页内」分两次完成。

1. ~~**跨页拖拽是否进 v1**~~ —— **已决：不进 v1**，列 19a-6 增量。v1 用「先翻页再拖」分两次完成。
2. **建夹默认名**：v1 用「未命名」还是「第一个 app 名」？（建议「未命名」，强制用户感知可改名。）
3. **孤儿条目清理策略**：v1 保守「永不自动删、仅静默跳过」（外置卷场景比卸载更需保护）。是否需在设置页加「清理已失效条目」手动按钮？（建议作为可选低优先项，默认留垃圾不误删。）
4. **拖出浮层移出 folder**：v1 用浮层内右键「移到根层」兜底，纯拖出浮层列为增量。是否接受？
5. **搜索结果是否标注来源文件夹**：v1 不显示面包屑（纯扁平）。是否需要后续打磨项加来源标记？
2. **建夹默认名**：v1 用「未命名」还是「第一个 app 名」？（建议「未命名」，强制用户感知可改名。）
3. **孤儿条目清理策略**：v1 保守「永不自动删、仅静默跳过」（外置卷场景比卸载更需保护）。是否需在设置页加「清理已失效条目」手动按钮？（建议作为可选低优先项，默认留垃圾不误删。）
4. **拖出浮层移出 folder**：v1 用浮层内右键「移到根层」兜底，纯拖出浮层列为增量。是否接受？
5. **搜索结果是否标注来源文件夹**：v1 不显示面包屑（纯扁平）。是否需要后续打磨项加来源标记？
