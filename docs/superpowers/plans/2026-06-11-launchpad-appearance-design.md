# 启动台外观与个性化功能设计 —— 2026-06-11

> 来源：`docs/superpowers/plans/2026-06-09-launchpad-ios-fidelity-todo.md` §B「新功能（下一批，按用户原话）」功能 6–10。本文档合成四份子设计（改名 / 外观系统 7+8 / 缩略图预览 9 / 玻璃背景 10），统一了 7/8/9 共享的布局纯函数接口与持久化键名。只做设计——落地排在并行修 bug workflow（§A 反馈 #1–#5）之后或在其分支上 rebase。

---

## 0. 结论速览

### 0.1 功能清单（用户原话 → 设计落点）

| # | 用户原话 | 设计落点 |
|---|---|---|
| 6 | 文件夹改名（§5 提前）：现在完全没有改名入口 | 夹面板标题常驻 bridged NSTextField 内联编辑 + folder 右键菜单 +（可选）建夹自动打开聚焦（§2） |
| 7 | 隐藏 app 名字 + 图标整体放大：iOS 式「只看图标」模式 | `hidesAppNames` 偏好 → metrics 去 label 区，cell 124→84@64pt，行数自动变多（§3） |
| 8 | 自定义图标大小，动态重算行列；窗口大小也可调 | `iconSize`（48–96pt）+ `compactScalePercent`（55–90%）→ metrics 全量派生 + compact 窗口联动（§3） |
| 9 | 设置内排列缩略图预览：半透明占位实时展示排列效果 | `LaunchpadLayoutPreviewModel` 纯函数派生 + 纯 SwiftUI 画布，与真实视图共用同一套布局函数（§4） |
| 10 | 背景 liquid glass 效果调整：玻璃感/透明度可调 | 主背景 `.ultraThinMaterial` → 参数化 `NSVisualEffectView`，3 预设档 + 自定义（材质×暗化）（§5） |

### 0.2 共享基础：metrics 参数化纯函数（先做它）

功能 7/8/9 的共同地基是把 `LaunchpadGridMetrics` 从「一组硬编码常量 + GridView 里的镜像副本」升级为**单源纯函数派生**（§1）。这一步**行为零变化**（默认值逐字节等于现 116/124/64/8/16，全部既有测试不动），是后续三个功能的前置工程，**只做一次**：

- `LaunchpadAppearance`（偏好值快照）→ `LaunchpadGridMetrics.resolve(_:)`（唯一解析入口）→ 注入 SwiftUI 分页层、AppKit 网格、夹面板、carry 浮窗、compact 窗口。
- `LaunchpadLayoutMath`（Chrome 常量集中 + 窗口尺寸 + 视口 + 行列容量）——真实视图与功能 9 的预览调**同一套函数**，预览的「所见即所得」靠这一点硬保证。
- 顺手修掉 `apply(grid:)` 快路径不比较 metrics 的缺口（同 items 换 metrics 不刷新 cell 尺寸）。

功能 6（改名）和功能 10（玻璃）与这块地基**正交**：改名只通过已有的 `metrics` 形参取几何、不引用字面量；玻璃只动背景层、不碰几何。两者可先行。

### 0.3 落地顺序（每步独立 commit，编译 + 相关单测过再走下一步）

| 阶段 | 内容 | 依赖 |
|---|---|---|
| **P0a 改名**（4–5 commits） | store 打磨 → RenameField+状态机 → 接入 folderPanel → 右键菜单 →（可选，可砍）建夹自动聚焦 | 无；与 P0b、P1 并行安全 |
| **P0b 玻璃**（3–4 commits） | 模型+持久化+测试 → 渲染层（GlassBackdrop）→ 设置页+小预览 →（独立后续）macOS 26 glassEffect | 无 |
| **P1 共享地基**（3 commits） | metrics 字段+resolve（byte-compat 锚点测试）→ LaunchpadLayoutMath 抽取+删 GridView 镜像常量 → apply(grid:) sameMetrics 修补 | 排在修 bug workflow 之后 rebase（重叠文件：`LaunchpadDragGrid.swift` #1、`LaunchpadEdgePageTurner.swift` #5） |
| **P2 外观系统 7+8**（4 commits） | Preferences 三键 → 贯通注入（OverlayController 快照 → GridView → pageContent 补传 → folderPanel）→ compact 窗口联动 → 设置 UI+本地化+参数化回归 | **依赖 P1** |
| **P3 缩略图预览 9**（2 commits） | PreviewModel+测试 → 预览视图挂入「外观」分组+本地化 | **依赖 P1 + P2**（消费其键与 resolve；画布底可复用 P0b 的背景配方） |

每阶段结束做一轮真机验证（`make run` + cliclick + screencapture，per memory：裸 `open` 跑旧包）。

---

## 1. 共享基础：布局纯函数层（功能 7/8/9 的地基）

### 1.1 硬编码审计（必须收编的点）

| 位置 | 现状 | 处理 |
|---|---|---|
| `LaunchpadDragGrid.swift:7-13` | `LaunchpadGridMetrics` cellWidth=116 / cellHeight=124 / iconSide=64 / columnSpacing=8 / rowSpacing=16 | 加派生字段 + `resolve(_:)`；默认初始化器保持现值（byte-compat，既有测试不动） |
| `LaunchpadGridView.swift:69-72` | 私有镜像常量 116/124 +「Must match LaunchpadGridMetrics」注释 | **删除**，改读注入 metrics——单源后这条注释性约定消失 |
| `LaunchpadGridView.swift:308`（pageContent） | root 页 `LaunchpadDragGrid` **没传 metrics**，吃默认值 | 补传注入 metrics。最容易漏的缝合点：漏了则 SwiftUI 分页几何与 AppKit 网格不一致，跨页 carry 落点全错 |
| `LaunchpadGridView.swift:681`（folderPanel） | 现场 `LaunchpadGridMetrics()` + `maxWidth: 760` cap | 复用注入 metrics（夹内名字显隐策略见拍板 #A1）；760 改为「5 列宽 + padding」派生 |
| `LaunchpadGridCellView`（`:1146/:1159/:1165`） | iconFrame y=8、label y=icon+8 高 32、字号 12 | 8/8/32 收编为 metrics 字段 `iconTopInset/labelGap/labelHeight`；字号 12 保持常量 |
| `LaunchpadDragGrid.swift:438`、`:961` | carry 抓点 `iconCentre = minY + 8 + iconSide/2`、iconRect 的裸 `8` | 换 `metrics.iconTopInset`，否则隐藏名字模式下 settle 飞行落点和抓点偏移 |
| `mergeRect`（`:729-738`） | 按 `metrics.iconSide` 派生但 `inset: 8` 固定 | `mergeInset = max(6, iconSide × 0.125)`（64pt 时仍为 8，回归不变） |
| `LaunchpadGridView.swift:491-509`（updateLayout） | 列/行容量计算 + 26pt 页点预留，内嵌在视图 | 抽成 `LaunchpadLayoutMath.pageGrid`；固定列分支补溢出 clamp |
| `LaunchpadOverlayController.swift:281-292` | compact 窗口 `min(960, w×0.72) × min(680, h×0.82)` | 重写为 `LaunchpadLayoutMath.compactFrame(visible:scalePercent:metrics:)`（§3.4） |
| `LaunchpadDragCoordinator.swift:408` | carry 浮窗 `side = iconSide × 1.1` | 已参数化——metrics 流通后自动正确 |
| `LaunchpadEdgePageTurner.swift:21` | `edgeWidth = 44` 固定 | **本批不动**（修 bug workflow 正在调 #5 热区/末列共存）；Config 已是 struct，留 metrics 派生口给那条 workflow |
| `LaunchpadGridView.swift:499` 页点高 26 | 布局常量 | 收进 `LaunchpadLayoutMath.Chrome`（视图与预览引用同一组，防「扣 chrome」漂移） |

### 1.2 统一接口（功能 7/8/9 唯一的一份；新文件 `Plugins/Launchpad/Sources/LaunchpadLayoutMath.swift`）

> 合成裁定：两份子设计的接口在此统一。值快照采用 preview 设计的 `LaunchpadAppearance` struct（单入参，预览直接消费）；持久化键采用 appearance 设计的 Int/取反键方案（`PluginStorage` 无 `double(forKey:)`，且 `bool(forKey:)` 未设值返回 false——`hidesAppNames` 取反键名使「未设置 = 现状显示名字」，零迁移；preview 设计原拟的 `iconSide: Double` / `showAppLabels: Bool` **弃用**）。字段名取 `showsLabels` / `labelGap`。

```swift
/// 外观偏好值快照（功能 7/8 拥有写入；resolve 与预览只消费）。
struct LaunchpadAppearance: Equatable {
    var iconSide: CGFloat = 64      // 功能 8：48...96，步进 4
    var showsLabels: Bool = true    // 功能 7：!hidesAppNames
}

struct LaunchpadGridMetrics: Equatable {
    var cellWidth: CGFloat = 116
    var cellHeight: CGFloat = 124
    var iconSide: CGFloat = 64
    var columnSpacing: CGFloat = 8
    var rowSpacing: CGFloat = 16
    // 新增（默认值 = 现行为，反解自硬编码）
    var showsLabels: Bool = true
    var iconTopInset: CGFloat = 8
    var labelGap: CGFloat = 8
    var labelHeight: CGFloat = 32

    /// 唯一解析入口。resolve(默认 appearance) 必须逐字段 == LaunchpadGridMetrics()（回归锚点）。
    static func resolve(_ appearance: LaunchpadAppearance) -> LaunchpadGridMetrics
}

enum LaunchpadLayoutMath {
    /// chrome 常量集中地：搜索栏 28、VStack spacing 20/14、上 60/24、下 32/20、左右 48/24、页点 26
    /// —— 从 GridView body 与 updateLayout 抽出，视图与预览引用同一组。
    struct Chrome { /* … */ static func standard(isCompact: Bool) -> Chrome }

    /// compact 窗口帧（功能 8c）。地板 = 4列×3行 + chrome；默认 72% 复现今天 0.72/0.82 观感；
    /// 移除 960/680 硬 cap（行为变化，见拍板 #A5）。
    static func compactFrame(visible: NSRect, scalePercent: Int, metrics: LaunchpadGridMetrics) -> NSRect

    /// 窗口尺寸 → 网格可用视口（扣 chrome + 搜索栏 + 页点预留）。
    static func gridViewport(mode: LaunchpadPreferences.WindowMode, windowSize: CGSize) -> CGSize

    /// 容量计算 —— updateLayout(size:) 的纯函数化；fixedColumns 溢出时 clamp 到可容纳列数。
    /// 真实视图与预览共用这一个函数 = 所见即所得的硬保证。
    static func pageGrid(viewport: CGSize, metrics: LaunchpadGridMetrics, fixedColumns: Int?) -> (columns: Int, rows: Int)
}
```

派生公式（@64pt 反推验证）：

| 字段 | 显示名字 | 隐藏名字 | @64pt 验证 |
|---|---|---|---|
| cellWidth | `iconSide + 52` | `iconSide + 28`（待拍板 #A3，推荐收紧） | 116 ✓ / 92 |
| cellHeight | `8 + iconSide + 8 + 32 + 12 = iconSide + 60` | `8 + iconSide + 12 = iconSide + 20` | 124 ✓ / 84 |
| labelHeight | 32 | 0（label `isHidden`） | — |
| columnSpacing / rowSpacing | 8 / 16 不变（resolve 留参数位，拍板 #A7） | 同 | — |

固定 chrome（+52/+60）而非比例系数：48pt 时 label 仍有足够宽放两行字；96pt 时密度接近 iOS。

隐藏名字时 cell 内部行为：`label.isHidden = true`；`hitTest` 跳过 label 条（只命中 icon±2pt）；`setAccessibilityLabel` / `toolTip` **仍设 app 名**（无障碍与悬停提示成为看名字的途径）；选中高亮 / 文件夹 plate / mergeRect 全由 `iconFrame` 派生，自动正确。图标质量无忧：`NSWorkspace.icon(forFile:)` 是多 representation NSImage，96pt@2x 内无损，缓存不用改。

### 1.3 `apply(grid:)` 的缺口（必修）

`LaunchpadDragGrid.swift:204-218` 快路径只比较 `sameItems`/`sameColumns`——metrics 变了但 items 没变时不触发 `needsLayout` 也不把新 metrics 传进 cell。加 `sameMetrics` 判断：不等则走 `rebuildCells`（`cell.update(cell:icons:metrics:)` 已支持）+ `needsLayout`。会话内 metrics 不变所以现在无害，为功能 9 与正确性补上。

### 1.4 数据流：单源注入路径

```
LaunchpadPreferences (iconSize, hidesAppNames) ──→ var appearance: LaunchpadAppearance（只读派生）
        │ open() 时快照（同 sessionMode 纪律）
        ▼
OverlayController.sessionMetrics = LaunchpadGridMetrics.resolve(preferences.appearance)
        ├─→ targetFrame(on:) → LaunchpadLayoutMath.compactFrame（§3.4）
        ▼
LaunchpadGridView(metrics: sessionMetrics)        ← 删私有 116/124
        ├─→ updateLayout(size:) → LaunchpadLayoutMath.pageGrid
        ├─→ pageContent → LaunchpadDragGrid(metrics:)   ← 补传（关键缝合点）
        ├─→ folderPanel / folderGrid(metrics:)          ← 替换现场构造
        └─→ LaunchpadViewportRelay → syncGeometry(perPage/pageWidth)
                ▼
LaunchpadDragCoordinator / CarrySpace / 浮窗 side / settle flight（自动正确）
```

**会话快照纪律**：appearance 与 `sessionMode` 同点快照，改设置在**下次唤出启动台生效**；明确禁止 overlay 内热更新 appearance（需重审 settle 飞行/anchor park 全部几何假设，而设置页与 overlay 几乎不可能同时可见，收益为零）。打开设置窗口必然触发 overlay `resignKey` 关闭（`LaunchpadOverlayController.swift:344-354`），语义自洽。

### 1.5 与跨页拖拽 / 分页 / carry 的连锁影响审计

1. **carry 浮窗**：root lift（`:531`）与 folder eject（`:447`）的 `iconSide` 都取所在网格 metrics → 自动随设置缩放。
2. **几何推送**：`LaunchpadPageGeometry.perPage` 由 relay 从 `columnCount×rowCount` 推送，metrics 变化只通过 perPage/页宽体现，`syncGeometry` Equatable 去重照常。
3. **零迁移**：持久化 layout 是跨页扁平数组，页是 `filtered` 纯切片 → 任何 metrics 改动重开后自然重新铺页；`relocateSelection/goToPage/handleMove` 读活的 perPage，无需改。
4. **固定列溢出**：`updateLayout` 固定列分支不感知宽度（96pt×12 列 = 2088pt 溢出）→ `effectiveColumns = min(固定值, columnsThatFit(width))` 静默 clamp（拍板 #A4）。
5. **mid-carry 改设置**：会话内 metrics 是快照不可变；窗口 resize/屏幕切换引发的 pageWidth/perPage 变化已由 `cancelCarry(.geometryChanged)` fail-safe（`Coordinator.swift:325-337`）覆盖——不引入 mid-carry 重标定，补回归测试：同 pageWidth、perPage 20→12 → 必须 cancel。
6. **settle flight**：`settleTargetLocalRect` 按 `metrics.iconSide` 取目标矩形 → 终点自动正确；`LaunchpadSettleFlightTests` 用非默认 metrics 参数化重跑。
7. **建夹/重排判定**：mergeRect 与死区全由 metrics 派生，48pt 时 merge 热区 36×36 仍可用；出夹 36px 边带与 iconSide 无强耦合，保持常量。
8. **虚拟尾页/跨页级联**：按 perPage 切片，正交不受影响。

### 1.6 可单测面

| 测试 | 内容 |
|---|---|
| `LaunchpadGridMetricsTests`（新） | `resolve(默认)` 逐字段 == `LaunchpadGridMetrics()`（byte-compat 锚点）；隐藏名字 cellHeight==iconSide+20、labelHeight==0；宽高随 iconSide 单调；mergeInset 在 48/64/96 下 mergeRect ⊂ slotRect |
| `LaunchpadLayoutMathTests`（新） | pageGrid：1456×900+默认+auto 手算锚定；fixedColumns 溢出 clamp；极小视口 ≥(1,1)；iconSide 增大 columns/rows 单调不增（48...96 property 式）；windowSize/gridViewport：compact 默认 72% 复现现帧、chrome 扣减后视口为正；隐藏名字同高度行数 5→7 量级 |
| `LaunchpadCellHitTestTests`（扩） | 隐藏名字时 label 条 hitTest==nil，icon±2 仍命中 |
| sameMetrics（新用例） | 构造 container、同 items 换 metrics 调 apply → cell frame 变化 |
| 既有护栏 | `LaunchpadDragToStackTests`/`LaunchpadCrossPageCarryTests`/`LaunchpadSettleFlightTests` 在 `resolve(48,隐名)` 与 `resolve(96,显名)` 两组下参数化重跑 |

### 1.7 落地步骤（P1，3 commits）

1. metrics 字段 + `resolve()` + cell 的 8/8/32 改读 metrics + label 显隐/hitTest + mergeInset；默认值 byte-compat；`LaunchpadGridMetricsTests` + CellHitTest。新文件后 `make generate`。
2. `LaunchpadLayoutMath.swift`（Appearance/Chrome/compactFrame/gridViewport/pageGrid）；`updateLayout` 改调用 + 删 GridView 镜像常量 + `:438/:961` 裸 8 收编；`LaunchpadLayoutMathTests` + 跑既有 carry 测试。
3. `apply(grid:)` sameMetrics 修补 + 单测。

---

## 2. 功能 6：文件夹改名

### 2.1 数据模型 / 持久化

**不新增任何持久化键。** 改名写入既有 `customLayout` folder 节点的 `name`；folder UUID 永不变；`LaunchpadLayout.currentVersion` 不 bump。`store.renameFolder(_:name:)` 已存在（`LaunchpadLayoutStore.swift:238`，有单测），需两处打磨：

1. **no-change guard**：现实现无条件 `setLayout`——trimmed 后同名也写盘 + 触发 `@Published` 全量重渲染。对齐 `reorderChild` 纪律：`guard trimmed != currentName else { return }`。失焦即提交的语义下，「点开又点走」的高频路径不能每次写盘。
2. **空名回退本地化**：`:245` 硬编码「未命名」→ 参数化 `renameFolder(_:name:fallback: String = "未命名")`，调用方传 `localization.string("folder.defaultName")`。

可选步骤 5 用：`LaunchpadDragCoordinator.VisualCommit` 增加 `createdFolderID: String?`——`storeApplier` 的 `.makeFolder`/`.moveOutOfFolder(.makeFolder)` 分支已持有新 folder UUID，纯数据透传。

### 2.2 标题字段：常驻 bridged NSTextField（核心结构决策）

`folderPanel` 顶部 `Text(folder.name)`（`LaunchpadGridView.swift:694`）替换为 `LaunchpadFolderRenameField`（`NSViewRepresentable` 包 NSTextField 子类）。**始终渲染同一个字段**，平时看是标题、点击即得光标——正是 macOS 原生 Launchpad 行为。理由：

- **视图身份炸点**：`folderShown` 注释已实证此 ZStack-over-AppKit 层级里条件插入视图无稳定身份；Text↔TextField 按编辑态切换是同一类炸点（first responder 随旧视图销毁丢失）。常驻一个 NSView 彻底绕开。
- **仓库先例**：搜索框就是因 SwiftUI 焦点在 NSHostingView + borderless overlay 不可靠才 bridge 真 `NSSearchField`；照搬同一 Coordinator + `doCommandBySelector` + `hasMarkedText()` IME 让行模式。
- **不开新窗口**：字段在 overlay 同窗，取得 first responder 只换 field editor，**不触发 resign active/key**，两个 resign 观察器无需新增豁免。

外观：无边框无背景无 focus ring、居中、字体 `.title2` 语义等价 semibold（与现 Text 视觉等同）；hover I-beam 即「可编辑」暗示（拍板 #R4）。宽度 `min(gridW, 360)` **由传入 metrics 推导**（gridW = cols×cellWidth + (cols-1)×columnSpacing），不写死 px——P1 落地后自动跟随外观设置，无需回头改。新 key：`folder.rename.placeholder`。本功能不新增设置项，`LaunchpadSettingsView` 不动。

### 2.3 提交语义状态机（单次提交 latch）

抽纯状态机 `LaunchpadRenameEditSession`（internal struct：originalName/currentText/isEditing/hasResolved），Coordinator 只转发事件——复用「拖拽逻辑抽 internal 方法单测驱动」的既有打法。

| 事件 | 行为 |
|---|---|
| 点击标题（成为 first responder） | 进入编辑，记录 originalName；程序化进入（菜单/自动聚焦）时全选 |
| 回车（`insertNewline`） | commit（trim → `store.renameFolder`）→ `refocusSearchField()`；夹保持打开 |
| Esc（`cancelOperation`） | cancel：恢复 originalName → refocus；**不**关夹 |
| 失焦（`controlTextDidEndEditing`） | commit。panel 背景补 `onTapGesture { endRenameEditing(commit: true) }`（点空白不会自动结束编辑） |
| 面板 unmount（scrim 关夹/打字搜索/teardown） | `dismantleNSView` 兜底：仍在编辑 → commit（store 同步写，不丢数据） |
| IME 组合中 | `hasMarkedText()` → `doCommandBySelector` 返回 false，回车/Esc 只作用于候选 |

**单次提交 latch**：回车既触发 `insertNewline` 又随后触发 end-editing；Esc 取消后的 end-editing 不得变 commit。`hasResolved` 保证一个会话 resolve 恰好一次（状态机单测主战场）；store no-change guard 是第二道防线。

### 2.4 Esc 阶梯

`installDismissHandlers` 的 local monitor（keyCode 53）新增第二豁免：first responder 的 field editor delegate 是改名字段时放行（现有第一豁免是 marked text）。形成阶梯：**取消改名 → 关文件夹 → 关启动台**。判定抽 `static func shouldRouteEsc(to:) -> Bool` 以便单测。

### 2.5 右键菜单

`contextMenu(for:)`（`LaunchpadDragGrid.swift:325`）补 folder 分支：**打开** / 分隔 / **重命名** / **解散文件夹**（拍板 #R2）。「重命名」= `onActivate(folder)` 打开夹 + 置 `pendingRenameFocusID`；folderPanel 出现且 id 匹配时 `makeFirstResponder` + 全选。搜索态夹已 dissolved 不可见、mid-drag 菜单抑制自然沿用。新 key：`grid.menu.renameFolder`、`grid.menu.dissolveFolder`。

### 2.6 （可选）建夹后自动打开 + 全选聚焦（拍板 #R1）

macOS 原生 Launchpad：建夹自动展开且名字全选可直接输入（现代 iOS 只展开不弹键盘）。本项目一贯对标 macOS → 推荐跟 macOS。两条建夹路径都接：旧路径 `handleMakeFolder` 直接开夹 + 聚焦；carry 路径经 `VisualCommit.createdFolderID` → **不立即开**（settle 飞行 0.25s 期间开 panel 会与 `settlingItemID` park 视觉打架）→ coordinator 在 reveal 完成处发布 `settleRevealToken`，view `.onChange` 消费（guard：夹仍在 filtered、无新 carry、overlay 未关）。此步动 commit 视觉链、风险最高，**单独成 commit、单独真机验证、可砍**而不影响其余。

### 2.7 与拖拽/carry 系统的交互

- rename 不改 order：reconcile 投影 folder name，`LaunchpadDisplayCell` Equatable 含 name → 落盘后 rebuild 更新 label，零新代码（`:206` 注释预留）。
- mid-carry 写入安全：`setLayout` 触发的 apply 被 `isDragging` guard defer 到 `pendingGrid`；更常见时序是夹内拖拽 `onDragBegan` 处显式 `endRenameEditing(commit: true)`（grid cell 不收 first responder，必须显式钩）。
- `LaunchpadPageGeometry` 零影响；`refocusSearchField` 所有既有抢焦路径对编辑中字段恰好是「失焦提交」，语义自洽。

### 2.8 可单测面

1. Store（扩 `LaunchpadFolderOpsTests`）：同名/trim 同名不写盘；fallback 参数化（默认参数保既有测试）。
2. `LaunchpadRenameEditSession`：回车 commit 一次 + 后续 end-editing 不重复（latch）；Esc cancel + 不 commit + 文本恢复；纯失焦 commit 一次；未编辑时 no-op。
3. Coordinator 转发：喂 selector 与 end-editing 断言回调；marked-text 时 `doCommandBySelector` 返回 false。
4. `shouldRouteEsc(to:)`：rename editor→true；搜索框→false；nil→false。
5. 菜单：folder cell 含「重命名/解散」，app cell 不含。
6. （步骤 5）`.makeFolder` 路径 `VisualCommit.createdFolderID == 新夹 id`，`.addToFolder/.move` 为 nil。

真机：双击改名→重开 overlay 名字保持；Esc 阶梯三连；中文 IME 组合中回车/Esc 不误触；改名中点 scrim 关夹后名字已提交。

### 2.9 落地步骤（P0a）

1. Store 打磨（guard + fallback）+ 测试。
2. RenameField + 状态机新文件（`make generate`）+ 单测，不接 UI。
3. 接入 folderPanel：替换标题、空白 tap、onDragBegan 钩、Esc 豁免、新 key；真机一轮。
4. 右键菜单 + `pendingRenameFocusID` + 菜单单测。
5. （可选可砍）建夹自动打开聚焦 + 单测 + 真机（重点看 settle 飞行与 panel zoom 衔接）。
6. README + TODO 文档勾掉 §5 改名部分。依赖：1→2→3 串行；4 依赖 3；5 独立于 4。

---

## 3. 功能 7+8：外观系统（隐藏名字 + 图标大小 + 动态行列 + 窗口联动）

> 布局接口与公式见 §1.2；本节只写偏好、设置 UI 与窗口联动。

### 3.1 持久化键（`LaunchpadPreferences`，沿用 `@Published + didSet` 单写 clamp 模式）

`PluginStorage` 只有 integer/bool/string/stringArray（`PluginRuntimeContext.swift:47-53`，无 double）→ 数值用 Int：

| 键 | 类型 | 默认（unset 哨兵） | clamp | 语义 |
|---|---|---|---|---|
| `iconSize` | Int（pt） | `0`=unset → **64** | `48...96` 步进 4 | metrics 唯一驱动量 |
| `hidesAppNames` | Bool | `false`（unset=false=现状，零迁移） | — | 取反键名 |
| `compactScalePercent` | Int（%） | `0`=unset → **72** | `55...90` | 紧凑窗宽占 visibleFrame 比例 |

`normalizedIconSize`（0→default、clamp、对齐步进）、`normalizedCompactScale` 照抄 `normalizedColumns` 写法。新增只读派生 `var appearance: LaunchpadAppearance`（`iconSide = CGFloat(normalized iconSize)`，`showsLabels = !hidesAppNames`），作为 resolve 与预览的唯一入参。

### 3.2 设置页 UI（对照 AGENTS「插件设置界面规范」）

继续走 `PluginConfiguration.makeView` 的 `LaunchpadSettingsView`，不加页面级标题，全部 `PluginSettingsTheme` token。**新增「外观」section**（`Label("外观", systemImage: "paintbrush")` + `sectionTitle` + `.secondary`），插在「窗口」与「网格」之间；功能 9 的预览是该分组卡片**第一行**（§4）：

| 行 | 控件 | 文案 |
|---|---|---|
| （功能 9 预览画布） | 见 §4.2 | — |
| 显示应用名称 | `Toggle` `.toggleStyle(.switch)` | 「显示应用名称」/「关闭后仅显示图标，排列更紧凑」 |
| 图标大小 | `Slider(48...96, step:4)` `frame(minWidth:160, idealWidth:200, maxWidth:240)` + 读数 `monospacedValue` `frame(width:52, .trailing)`；行用 `interactiveRowVertical` | 「图标大小」/「每页行列数随之变化」 |

「窗口」section 追加条件行（仅 compact 模式，同「每行图标」stepper 的条件展开模式）：「窗口大小」`Slider(55...90, step:5)` + 读数「72%」。

本地化键：`settings.appearance.title/showNames.*/iconSize.*`、`settings.window.size.*`。生效时机 = 下次打开（§1.4 快照纪律）。

### 3.3 compact 窗口联动

```swift
static func compactFrame(visible: NSRect, scalePercent: Int, metrics: LaunchpadGridMetrics) -> NSRect {
    let s = CGFloat(scalePercent) / 100
    let minW = 4 * (metrics.cellWidth + metrics.columnSpacing) + 48       // 地板：4列×3行 + chrome（回补末列 spacing——columnsThatFit 按整 pitch 取整，少一个 spacing 会只剩 3 列）
    let minH = 3 * metrics.cellHeight + 2 * metrics.rowSpacing + 112
    let w = min(max(visible.width  * s,                 minW), visible.width  * 0.95)
    let h = min(max(visible.height * min(s + 0.10, 0.92), minH), visible.height * 0.95)
    return NSRect(x: visible.midX - w/2, y: visible.midY - h/2, width: w, height: h)
}
```

默认 72% 复现今天观感；**行为变化**：移除 960/680 硬 cap（否则滑杆在大屏失效），PR 描述写明（拍板 #A5）。联动语义：图标调大 → 地板抬高 → compact 窗不会缩到放不下 4×3。屏幕变化路径自动走新函数；mid-carry setFrame 触发 relay 重推几何 → 既有 `cancelCarry(.geometryChanged)` 兜底。

### 3.4 可单测面（在 §1.6 之外）

`LaunchpadPreferencesTests` 扩：normalizedIconSize（0→64、47→48、97→96、步进对齐）、normalizedCompactScale、hidesAppNames unset=false、FakePluginStorage round-trip。`LaunchpadCompactFrameTests`：地板（大图标小滑杆不低于 4×3）、95% cap、72% 默认复现现帧。Carry 回归：mid-carry perPage 变化 → cancelled + 浮窗 dismiss。

### 3.5 落地步骤（P2，依赖 P1）

1. Preferences 三键 + clamp + appearance 派生 + 测试。
2. 贯通注入：`open()` 建 sessionMetrics → GridView(metrics:) → pageContent 补传 → folderPanel 复用；跑全量 Launchpad 测试类。
3. compactFrame 替换 targetFrame compact 分支 + 测试。
4. 设置 UI +本地化 + 参数化回归（48-隐名 / 96-显名 两组重跑 DragToStack/CrossPageCarry/SettleFlight/EjectE2E）。
5. 真机：fullscreen/compact × 显隐名字 × 48/64/96 截图核对密度；改设置→重开生效；建夹、跨页 carry、settle、出夹各一遍 Before→Action→After。

---

## 4. 功能 9：设置内排列缩略图预览

> 完全建立在 §1 的共享函数上：预览与真实启动台调**同一套** `resolve / compactFrame / gridViewport / pageGrid`，所见即所得是结构保证而非约定。预览**自身零持久化**——只读投影 `iconSize / hidesAppNames / windowMode / columns / compactScalePercent`（及画布底的背景配方，§5）。

### 4.1 预览派生模型（纯函数，view 只画不算）

```swift
struct LaunchpadLayoutPreviewModel: Equatable {
    struct Tile: Equatable { var iconRect: CGRect; var labelRect: CGRect? }
    var screenSize: CGSize      // 缩放后的"屏幕"画布
    var windowRect: CGRect      // 缩放后的启动台窗口（fullscreen 时 == 画布）
    var tiles: [Tile]           // 满页占位（rows×columns）
    var columns: Int, rows: Int
    var scale: CGFloat

    static func make(appearance: LaunchpadAppearance, mode: WindowMode, fixedColumns: Int?,
                     compactScalePercent: Int, screen: CGSize, previewWidth: CGFloat) -> Self
    // 内部依次调 compactFrame/windowSize → gridViewport → pageGrid → 按 metrics slot 公式铺满一页 → 等比缩放
}
```

`screen` 取设置窗口所在屏（`view.window?.screen`），回退 `NSScreen.main`，再回退 1512×982；caption 注明按当前屏估算（多屏不枚举，与 overlay「鼠标所在屏」决策一致）。**帧口径必须与 `targetFrame(on:)` 完全一致**：fullscreen 用 `screen.frame`（真实 overlay 盖住菜单栏和 Dock），compact 用 `screen.visibleFrame`（真实面板在可见区居中）——两个口径都传入模型，同屏下 caption 才不会比真实启动台少一行/一列。

### 4.2 UI（「外观」分组卡片第一行，滑杆/开关紧随其下）

- 画布：`frame(maxWidth: .infinity)` + `aspectRatio(screenAspect, .fit)` + `frame(maxHeight: 200)`——窗口缩放等比不跳动。`GeometryReader` 只包预览行取宽。
- caption：「7 列 × 5 行 · 每页 35 个」，`Typography.monospacedValue` + `.secondary`；不放行标题、不写大段说明。键：`settings.appearance.preview.caption/accessibility`。
- 渲染（纯 SwiftUI shape，≤100 占位，零图标、零 catalog IO）：屏幕底 `RoundedRectangle` 0.05 → 启动台窗口 `windowRect` `.quaternary`（compact 时小于屏幕居中，**顺带可视化窗口大小滑杆**，拍板 #P1）→ 搜索栏 `Capsule` 占位（定位读 `Chrome`）→ tile：squircle `opacity(0.16)`（圆角比例与真实选中框一致）+ `showsLabels` 时 label `Capsule` 0.10 → 底部 3 页点。画布底层可叠功能 10 的同配方玻璃小样（共用 recipe，拍板 #G6）。
- 动画 `.easeOut(0.15), value: model`（model Equatable）；无障碍：整体 `accessibilityElement(children: .ignore)` + 「当前设置每页 %d 列 %d 行，共 %d 个」。
- 实时性：滑杆 Binding 写 `@Published` → 整页重算 → 预览同帧更新，无需额外管线；每 tick O(perPage) 纯算术，无需 memo。

### 4.3 可单测面（`LaunchpadLayoutPreviewModelTests`）

tiles.count == columns×rows；所有 iconRect ⊆ windowRect ⊆ 画布；隐藏名字 → labelRect 全 nil；等比性（任意 tile 的 scale 一致）；fullscreen windowRect==画布、compact 居中且小于画布；compactScalePercent 变化 → windowRect 随动。

### 4.4 落地步骤（P3，依赖 P1+P2）

1. PreviewModel + 测试。
2. 预览视图挂入「外观」分组首行 + 本地化键。
3. 验证：`-only-testing` + `make build`；`make run` 设置页截图（Read 核对：拖滑杆行列变化、compact/fullscreen 窗口占位差异、隐藏名字 label 条消失），再唤出真实启动台对照预览列×行一致（Before→Action→After）。

风险与缓解：chrome 漂移 → 常量集中 `Chrome`（§1 已做）；预览屏与实际唤出屏不同 → caption 注明估算。

---

## 5. 功能 10：背景 Liquid Glass 调整

### 5.1 现状与关键结论

overlay 窗口本身透明无玻璃（`isOpaque=false`、`backgroundColor=.clear`）；玻璃感全部来自 `LaunchpadGridView.swift:134-138` 的 `Rectangle().fill(.ultraThinMaterial)`（behind-window 取样桌面，兼任空白点击关闭层），**不可调**。要可调必须换成参数化 `NSVisualEffectView(.behindWindow)`——SwiftUI Material 无 material 枚举可选；仓库已有 `FrostedGlassScrim`（夹 scrim，`NSVisualEffectView` representable + hitTest 穿透）可泛化复用。

两条硬约束：**effect view 的 `alphaValue` 必须保持 1.0**（Apple 文档：部分透明 effect view 渲染未定义）→「透明度滑杆」实现口径 = 上层黑色暗化层 opacity + 材质厚薄选择；`state` 固定 `.active`（`.followsWindowActiveState` 会在失 key 瞬间——如 carry 浮窗子窗口出现——材质变灰闪烁）。

### 5.2 数据模型 / 持久化（新文件 `LaunchpadBackgroundStyle.swift`，纯模型不 import AppKit）

```swift
enum LaunchpadBackgroundStyle: String, CaseIterable { case clear, standard, deep, custom }   // 清透/标准/深邃/自定义
enum LaunchpadGlassMaterial: String, CaseIterable { case launchpad, frosted, hud, subtle }
// → .fullScreenUI / .popover / .hudWindow / .underWindowBackground（白名单；.sheet/.menu/.windowBackground 偏不透明，不入）
struct LaunchpadBackgroundRecipe: Equatable { var material: LaunchpadGlassMaterial; var dimOpacity: Double; var forcesDarkAppearance: Bool }
// 纯函数：func recipe(customMaterial:customDimPercent:) -> LaunchpadBackgroundRecipe
```

`LaunchpadGlassMaterial → NSVisualEffectView.Material` 映射放视图文件 fileprivate extension，模型层无 AppKit。`LaunchpadPreferences` 追加（同 §3.1 模式）：

| 属性 | Key | 默认 | 说明 |
|---|---|---|---|
| `backgroundStyle` | `backgroundStyle` | `.standard` | 未知 raw → fallback `.standard`（同 windowMode 写法） |
| `backgroundMaterial` | `backgroundMaterial` | `.launchpad` | 仅 custom 档生效 |
| `backgroundDimPercent` | `backgroundDimPercent` | `12` | Int 百分比（无 double）；`normalizedDim` 钳 0...60；用 `object(forKey:) == nil` 判未设值 |

预设档（数值为真机调参起点，截图对照定稿）：

| 档位 | material | dim | 外观 | 定位 |
|---|---|---|---|---|
| 清透 | `.fullScreenUI` | 0.00 | 跟随系统 | 最大化透出桌面 |
| 标准（默认） | `.fullScreenUI` | 0.12 | 跟随系统 | **校准目标：与现 `.ultraThinMaterial` 观感等价**，老用户无感（拍板 #G1） |
| 深邃 | `.hudWindow` | 0.28 | 强制 `darkAqua`（仅罩玻璃，拍板 #G2） | 沉浸聚焦 |
| 自定义 | 白名单 4 选 1 | 滑杆 0–60% | 跟随系统 | 进阶 |

### 5.3 设置页 UI

「窗口」之后插 `backgroundSection`（`Label("背景", systemImage: "circle.lefthalf.filled")`），复用 `section/row` 积木：行 1「玻璃风格」segmented 四段（副标题随档位短句变化）；选「自定义」追加（同 columns 条件展开）：行 2「玻璃材质」menu Picker 四项、行 3「背景暗化」`Slider(0...60, step:5)`（minWidth 120/idealWidth 160）+ 尾随读数 `monospacedValue` 固定宽 44。键 `settings.background.*`。

**内联小预览卡**（约 220×80，分组卡片顶部）：桌面感渐变垫底 + 同配方 `NSVisualEffectView`（withinWindow 取样渐变）+ dim 层，随设置实时变——因为设置窗口成 key 时 overlay 必关，无法边调边看真 overlay，调参类功能没预览不可用；功能 9 落地时把此配方吸收为预览画布的背景层（拍板 #G6）。

### 5.4 渲染层

1. 泛化 `FrostedGlassScrim → GlassBackdrop`（material/blendingMode/forcesDark 参数，保留 hitTest→nil 穿透）；夹 scrim 改用之，行为不变。
2. 主背景三层：`GlassBackdrop(…, .behindWindow, forcesDark:)` + `Rectangle().fill(.black.opacity(dim)).allowsHitTesting(false)` + 透明点击层（关闭语义原样保留）。
3. 配方注入走 `open()` 会话快照（同 §1.4 纪律），不做 live 绑定。
4. compact 圆角：behind-window blur 在 layer mask 下可能不跟圆角（AppKit 已知坑）→ 先按现状截图验证，漏 blur 则给 GlassBackdrop 加 `maskImage`。
5. 深邃档 `forcesDark` 只罩 GlassBackdrop 自身，不动 hosting view 整体 appearance（避免标签/搜索框/面板边框一起强制变色）；截图发现标签不可读再考虑提级。

### 5.5 不变量与性能（与拖拽/carry 零耦合，三条必守）

1. 背景层留在分页 `.offset` 之外（被 offset 包裹则每帧翻页触发 WindowServer 重采样 + 取样错位）。
2. 不进 AppKit frame 链、不碰 `LaunchpadPageGeometry` 推送；carry 浮窗是独立子窗口，不受影响。
3. 与 metrics 参数化正交（§1 是功能 7/8 的范围，本功能不动那些数字）；与功能 9 的唯一交集 = 预览同时消费「背景配方 + grid metrics」。

性能红线是层数不是面积：稳定态 1 层 behind-window blur（系统 Launchpad 同款成本），夹打开 2 层，不得加第三层常驻 effect view（dim 用纯色 Rectangle 免费）。material 切换瞬切不可动画——只在设置页发生（overlay 关着），无感知；不为切档过渡叠双 effect view。「减少透明度」辅助功能由 NSVisualEffectView 自动降级，验证清单加一条。

### 5.6 macOS 26 Liquid Glass 对齐（独立后续 commit，availability 门控）

- **全屏主背景保持 NSVisualEffectView，不上 Liquid Glass**——HIG 口径 glass 是「浮在内容上的控件/小表面」材质，系统自身全屏 overlay 也仍是 material backdrop；预设档以 `.fullScreenUI` 为基底即是对齐。
- compact 浮窗与夹面板：`#available(macOS 26.0, *)` 时分别用 `NSGlassEffectView` / `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))`，fallback 现状；同屏（compact 内开夹）需 `NSGlassEffectContainerView` 分组合并渲染 pass。深邃档叠 glass 是否发闷需真机 Tahoe 截图后定。

### 5.7 可单测面 + 落地步骤（P0b）

`LaunchpadBackgroundStyleTests`：三预设档 → 期望 recipe 逐一断言；custom 透传；dim clamp（-10→0、999→60，走 didSet 单写路径）；解码 fallback（未知 raw → standard/launchpad、未设值 → 默认三元组）；Preferences round-trip；`nsMaterial(for:)` 提成可见纯函数后加 CaseIterable 完备性测试。

1. 模型+持久化+测试（`make generate`）。
2. 渲染层：GlassBackdrop 泛化 + 主背景三层 + open() 快照注入；`make build`。
3. 设置页 + 小预览卡 + 本地化。
4. 真机视觉验证（强制）：4 档 × {fullscreen, compact} × {浅色, 深色} + 夹打开叠加 + 减少透明度开启；**重点 diff「标准档 vs 改动前 ultraThinMaterial」校准 dim 起点**；compact 四角 blur 检查。
5. 回归：全量 Launchpad 测试 + 空白点击关闭/Esc/carry 中翻页/夹动画在深邃档下无异常。
6. （独立后续）macOS 26 glassEffect。
7. README 一句话同步。

---

## 6. 待用户拍板（openQuestions 汇总，已合并重复项）

| # | 问题 | 推荐 |
|---|---|---|
| R1 | 建夹后行为：A 仅自动打开（现代 iOS）；B 自动打开+名字全选聚焦（macOS 原生）；C 本批只做改名入口不做自动打开 | **B**（项目一贯对标 macOS Launchpad）；但它动 settle 飞行视觉链、风险最高，独立 commit、不顺可降级 C |
| R2 | folder 右键菜单是否带「解散文件夹」；要不要二次确认 | **带上，不加确认弹窗**——dissolve 把 app 释放回网格不丢数据、重建成本低，加弹窗反而重 |
| R3 | 类别建议名（读 LSApplicationCategoryType 替代「未命名」）是否进本批 | **另立任务**——需在扫描期多读各 bundle Info.plist，与本批无依赖 |
| R4 | 改名字段平时是否加可见「可编辑」暗示（hover 淡背景） | **跟原生**：仅 I-beam 光标，无额外暗示 |
| A1 | 文件夹面板内是否跟随「隐藏名字」 | **夹内始终显示名字**（iOS 行为，夹内找 app 依赖名字）；根网格夹 tile 标签跟随全局开关，接受根/夹内不一致 |
| A2 | 图标大小范围 48–96pt（默认 64、步进 4）是否够 | **先 48–96 上线看反馈**——放宽到 40–128 会把 compact 最小窗口地板和 merge 热区（<32pt 难命中）推到边界 |
| A3 | 隐藏名字时 cellWidth 是否收紧（iconSide+28 vs 维持 +52） | **收紧到 +28**——隐藏名字的动机就是 iOS 式密度；perPage 跳变只在用户主动切开关时发生一次，可接受 |
| A4 | 固定列数+大图标放不下：静默 clamp 还是设置页动态提示 | **静默 clamp**——设置页拿不到 overlay 实际宽度难提示准；功能 9 预览的 caption（N 列×M 行）天然承担提示职责 |
| A5 | compact 移除 960×680 硬上限是行为变化；默认 72% 是否下调 | **保留 72%、移除硬 cap**，PR 写明行为变化（大屏觉得大可自行调小，这正是新滑杆的用途） |
| A6 | 窗口大小只做滑杆（55–90%）、不做拖拽边缘实时缩放 | **接受**——borderless overlay 改 resizable 成本高且与点击外部关闭冲突；实时预览交给功能 9 |
| A7 | columnSpacing/rowSpacing 是否随 iconSide 等比缩放 | **v1 固定 8/16**，`resolve` 留参数位，试用后觉得大图标挤再调 |
| P1 | compact 预览画布是否画「屏幕外框 + 居中窗口」两层 | **两层**——顺带把窗口大小滑杆可视化，几乎零成本 |
| P2 | 预览展示满页容量还是按实际 app 数截断 | **满页占位**——不读 catalog（设置页打开时可能未扫描完），预览语义是「容量」不是「现状」 |
| G1 | 「标准」档校准目标：复刻现 ultraThinMaterial 还是改系统 Launchpad 的 fullScreenUI 清透观感 | **严格复刻现状**（老用户零感知升级）；想要清透的用户一键切「清透」档即可 |
| G2 | 「深邃」档强制 darkAqua 范围：仅背景玻璃还是整个 overlay 内容 | **先仅罩背景玻璃**，真机截图浅色模式下标签对比度不足再提级到 host 层并整体验证 |
| G3 | 自定义档材质白名单 4 项是否够；要不要独立「强制深色」开关 | **4 项先行、不加独立开关**——深邃档已覆盖强制深色诉求，开关×材质的组合爆炸不值 |
| G4 | 夹 scrim/夹面板是否随背景档位联动（深邃档夹面板也加深） | **v1 固定不变**——夹面板是「浮在内容上的表面」，语义独立；真机看深邃档叠加态再议 |
| G5 | macOS 26 NSGlassEffectView/glassEffect 采用范围 | **仅 compact 浮窗 + 夹面板，全屏背景不上 liquid glass**（HIG 口径），availability 门控、独立后续 commit、单独 Tahoe 真机验证 |
| G6 | 玻璃设置的内联小预览本期做，还是合并到功能 9 | **本期做轻量版**（220×80 渐变垫底 + 同配方玻璃）——玻璃先行落地（P0b）而功能 9 在最后（P3），调参类功能没预览不可用；P3 落地时把配方吸收为预览画布背景层，不留两套 |


---

## 拍板记录（2026-06-11，用户离线 15h 授权期间由 Claude 代决，可翻案）

R1=B（建夹自动打开+全选聚焦，不顺降级 C）；R2=带解散入口无确认；R3=类别建议名另立任务；R4=无 hover 暗示仅 I-beam；A1=夹内恒显名字；A2=48–96pt 步进 4；A3=隐藏名字收紧 cellWidth 至 iconSide+28；A4=固定列静默 clamp；A5=保留默认 72% 移除 960×680 硬 cap（PR 写明行为变化）；A6=窗口大小仅滑杆 55–90%；A7=间距 v1 固定留参数位；P1=预览画两层（屏框+窗口）；P2=满页占位不读 catalog；G1=默认档严格复刻现状观感；G2=深邃档仅罩背景玻璃；G3=材质白名单 4 项无独立深色开关；G4=夹面板 v1 不联动档位；G5=glassEffect 仅 compact 浮窗+夹面板、#available 门控独立 commit；G6=玻璃轻量预览本期做、P3 时吸收为排列预览底层。

全部为合成者推荐项的采纳；理由见上文各 openQuestion 原文。

**A5 影响面修正（2026-06-12 终审）**：拍板与实现期叙述按「大屏」口径评估影响面是事实错误——旧 960×680 cap 的生效阈值是 visibleFrame 宽 >~1333pt 或高 >~829pt，默认缩放分辨率下所有现代内建屏全部命中（14" MBP 1512pt、13.6" Air 1470pt、16" MBP 1728pt）：紧凑模式存量用户升级后默认窗口约大 13%，并非仅外接大屏受影响。拍板结论维持不变（保留 72%、移除硬 cap），披露口径按此修正（相关代码注释 / README 已同步；`LaunchpadLayoutMathTests` 新增 1512×944 内建屏 delta pin）。
