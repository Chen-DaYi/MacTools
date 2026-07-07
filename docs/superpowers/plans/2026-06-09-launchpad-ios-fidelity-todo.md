# 启动台 iOS 化 TODO（下个版本）

> 来源：2026-06-09 多 agent 对抗性审计（map 当前流程 + 研究 iOS/macOS 真实行为 + 逐条对比 + 验证）。
> 本版本只做 **手指接力拖出文件夹 + 修确凿 bug**（见 §0）；以下 §1–§5 是**下个版本**要做的完整 iOS 化，按影响排序。
> 结构性结论：gaps #2/#3/#1 都卡在同一个根——**现在每页是独立 AppKit 容器**，而 iOS 是**单一线性数组铺进多页**。真正 iOS 化要往「单一拖拽上下文跨页」改架构。

## §0 本版本（拖出文件夹 — 安全版已落地，两个限制待补）
**已落地**：拖出文件夹 = 松手在文件夹**外**时把 app 落到**光标所在根槽位**（非末尾）+ 关文件夹；松手在**内**则夹内重排（撤销）。出夹判定用**被拖 cell.frame vs slot 几何（container 坐标系）**，不用 window→view 的 `convert`（穿 SwiftUI scaleEffect 不可靠，曾导致夹内小拖动误弹出）。commit 全在 mouseUp（拖动中不碰 SwiftUI，避免卡死）。store 层 `moveOutOfFolder(to:)` + 落点解析 + 撤销均有单测；codex 审过。

**待补（下版或按需）**：
1. **可见浮层反馈**：现在拖出文件夹边缘后图标被裁切看不见（盲放）。要做「图标实时吸在光标上」必须用**独立子窗口**渲染浮层（**绝不能** addSubview 到 NSHostingView、**绝不能**在 mouseDragged 里 `withAnimation` 改 @State —— 那会卡死，已踩）。子窗口在 mouseDown/crossing 时建、AppKit ordering、mouseUp 关；folder 仍在松手才关。
2. **page>0 落点错**：`rootDropTarget` 用 root container 的 `convert(windowPoint)`，SwiftUI 分页 `.offset` 不被 AppKit convert 计入 → page>0 时落点横向偏 `pageWidth*page`、被 clamp 到首列。**page 0 正确**（常见）。属 §1 跨页坐标家族，一起修。

## §1 跨页拖动 + 边缘自动翻页（High，结构性）
- **现状**：每页一个独立 `LaunchpadGridContainerView`；`beginDirectDrag` 只快照当前页的 `cells`，重排只在本页数组内；被拖 NSView 物理上在某一页容器里，过不去。拖图标时永远出不了当前页（`slotIndex` 把 col 钳在 `[0,columns-1]`）。
- **iOS**：单一数组跨页；拖到左/右边缘热区停 ~0.7s 翻一页（带 cooldown 防连翻），图标始终吸在手指；满页时尾图标溢出级联到下一页；停在最后一页右缘生成新页。
- **要做**：把 order 建模成**跨所有页的单一数组**；拖到边缘 dwell（`Timer` on `.eventTracking`）→ `goToPage` + 把被拖 cell 重新 host 到新页容器继续重排；满页 insert-and-shift 跨页级联；最后一页右缘生成新页。
- 设计参考：`docs/superpowers/plans/2026-06-05-launchpad-19-folders-and-reorder-design.md:225`（已把跨页拖动 defer 到 19a 增量，并记了 `selectedIndex` 重映射问题）。
- codeRef：`LaunchpadDragGrid.swift:272`（beginDirectDrag 快照单页）、`:282`（updateDirectDrag 无边缘逻辑）、`:472`（slotIndex 钳当前页）。

## §2 建夹 dwell 时间门（Med）
- **现状**：`updateDrag` 一进 `mergeRect`（中心 ~48×48）就 `setStackTarget`，**无时间门**；注释/测试名里的「dwell」是几何包含的误导性叫法，没有真 timer。中心死区还**硬挡**「从居中图标上拖过去重排」（reorder 分支里 `m.minX<=x<=m.maxX` 直接 `return`）。
- **iOS**：中心 + **停顿 ~0.5s** 才 arm/commit；提前离开取消；目标图标「口袋」随 dwell 渐开。
- **要做**：进 `mergeRect` 起 `Timer(~0.5s, .eventTracking)`，fire 才 `setStackTarget`；离开中心取消；merge well 随 dwell 从小到大动画。这样快速划过一排不再每个中心都闪建夹意图。
- codeRef：`LaunchpadDragGrid.swift:378`。

## §3 出夹 dwell 时间门（Med，本版本先做几何版，下版加 dwell + 渐进关闭动画）
- **iOS**：到边缘**停顿**才关 + 弹出；蹭一下不弹；弹出后若文件夹仍 ≥2 个，文件夹**保持打开**继续管理。
- **要做（下版完善）**：出夹也用边缘 band + `Timer` dwell；弹出一个后若 ≥2 个保持文件夹打开（现在无条件 `closeFolder`）；加「即将关闭」的渐进动画反馈。
- codeRef：`LaunchpadGridView.swift:590-593`（无条件 closeFolder）、`LaunchpadDragGrid.swift:292`（纯几何 36px）。

## §4 手感打磨（Low）
- **拿起**：现在 `isLifted=true` 直接 `imageView.frame=mergeIconFrame` **瞬间放大**、无阴影、无 haptic、无抖动。→ 用 `NSAnimationContext`/`CASpringAnimation` 弹簧放大 + CALayer 阴影 + `NSHapticFeedbackManager` 拿起反馈；（若对标 iOS 而非 Launchpad）非拖拽 cell 加低幅 off-center 抖动。codeRef：`LaunchpadDragGrid.swift:569`。
- **落下**：现在 `isLifted=false` 瞬间复位、settle 只有 0.13s easeOut、无 haptic。→ 落下 scale 走同一弹簧、settle 拉到 ~0.2-0.25s spring、commit 成功（`commitDrop` 返回 true）时 haptic。codeRef：`:331`。
- **让位瞄准**：现在按**光标点**算插入槽，略超前/滞后。→ 改按**被拖图标中心**（cursor − dragGrabOffset 校到 cell 中心）。codeRef：`:362`。

## §5 文件夹命名（Low）— ✅ 已落地（2026-06-11，设计见 2026-06-11-launchpad-appearance-design.md §2 / P0a）
- ✅ 夹面板标题 = 常驻 bridged NSTextField 内联改名（点击即编辑，Return 提交 / Esc 撤销 / 失焦提交）。
- ✅ folder 右键菜单：打开 / 重命名 / 解散文件夹（R2：无确认）。
- ✅ 建夹自动打开 + 名字全选聚焦（R1=B）：旧路径即开；carry 路径在 settle reveal 完成后开（`folderRevealToken`）。
- ⏳ 按 `LSApplicationCategoryType` 推断建议名替代「未命名」：另立任务（R3，排除在本批外）。

## 已确认「一致」的部分（不用动）
- 让位重排模型（true insert-and-shift + 边缘 hysteresis + 中心死区）——最像 iOS 的部分。
- 文件夹降到 1 个自动解散、幸存者归位——与 iOS 一致。
- macOS Launchpad 的点按即拖（无 jiggle）——本来就对标 Launchpad 而非 iOS 主屏，jiggle 是 iOS-only 差异，按需再加。

---

## 2026-06-11 用户真机试用反馈（§1 步骤 1-8 落地后）

### A. Bug / 打磨（本版必修）
1. **merge 建夹 settle 闪烁**：拖 app 到另一 app 建夹，目标图标先变成「被拖 app 的图标」再闪现为文件夹图标。settle 飞行期间目标 cell 的视觉冻结/reveal 次序问题（设计 §7.3-4 预言的真机观察点，确认存在）。
2. **app 可拖出启动台边界**：carry 浮窗无 clamp，图标可被拖出 overlay/屏幕（iOS 图标始终留在屏内）。浮窗位置需 clamp（保留 grab-offset）。
3. **文件夹 tile 选中视觉突兀**：选中蓝框内还套着夹 tile 自身的白/灰圆角背景，两层框叠加（见截图）。选中样式与夹背景需要融合。
4. **跨页放置溢出图标走位 + 闪烁**：跨页 drop 后被挤出的最后一个图标出现在本页「最下面新的一排」（容器 row-major 布局不知道页边界），应该向右缘飞出消失（去下一页）；过程伴随闪烁。
5. **边缘翻页 vs 边缘落点判定**：想把 app 放在页面边缘位置时容易误触发翻页，热区/驻留参数与让位判定的共存逻辑需调整（edgeWidth 44pt 与末列重叠的调参项）。
   - **已修（2026-06-11）**：edgeWidth 44→28 + 最外列 x 跨度豁免带（`LaunchpadEdgePageTurner.ExemptBands`，由 engaged 容器的 `outerColumnXSpans()` 注入）。行为变化：悬在首/末列图标上驻留不再翻页——翻页必须把光标推到列跨度以外（页边距或屏缘，iOS 同款）；虚拟尾页（无 cell）不豁免。豁免判据是几何列宽而非 gap 状态（gap 在边距/页外也保持开启，按 gap 豁免会杀死右缘翻页）。

### B. 新功能（下一批，按用户原话）
6. **文件夹改名**（§5 提前）：现在完全没有改名入口。
7. **隐藏 app 名字 + 图标整体放大**：iOS 式「只看图标」模式，去掉名字后 cell 变大。
8. **自定义图标大小**：直接调图标尺寸，动态重算每行/每列个数；窗口（启动台）大小也可动态调整。
9. **设置内排列缩略图预览**：等比例缩小的启动台缩略图，用半透明 app 占位实时展示当前大小设置下的排列效果。
10. **背景 liquid glass 效果调整**：背景玻璃感/透明度可调。
