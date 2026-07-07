# 启动台标签外观系统 + 文件夹 iOS 弹出动画 设计（2026-06-13）

**用户决策**：颜色=4档预设(自动/白/黑/强调)；字号=随图标协调缩放(小/中/大)；粒度=共用一套外观+文件夹标题派生略大(3 控件)。

=== 标签系统计划 ===
【裁决：以方案 A（minimal 预设）为主干，吸收方案 C 的两点 iOS 取向；明确否决方案 B 的自由 ColorPicker 与随 iconSize 比例缩放。】

# 文件夹名 vs app 名「是否分开」的裁决
分开，但按架构唯一可行的边界分：作用域 = ①【网格标签】(app 名 + 折叠态文件夹名，共用 cell.label，DragGrid:1210，无法在网格层再细分) ②【打开后文件夹大标题】(LaunchpadFolderRenameField，独立 NSTextField)。
- 颜色 + 字重：两个作用域共享同一组用户选择(视觉统一、控件不爆炸)。
- 字号：网格标签暴露一个「字号档」(小/中/大)；文件夹大标题不单独暴露字号控件，而是相对网格档派生(始终 ≥ app 名、字重保底 .semibold)——这满足用户「文件夹名字体 + app 字体 style/大小可配」诉求，又把控件数压到 3 个 Picker。
- 否决「网格里折叠文件夹名独立于 app 名」：cell.label 是同一 NSTextField，要分需在 configure() 的 .app/.folder 两 case 各设 font/color，复杂度高、收益边际(折叠文件夹名与 app 名同视觉语境)。

# 数据模型（新建 Plugins/Launchpad/Sources/LaunchpadLabelStyle.swift，照搬 LaunchpadBackgroundStyle 的 String-raw enum 模式）
三个枚举，全 String rawValue + CaseIterable + Identifiable(id=rawValue) + label(localization:) + 派生值：
1. LaunchpadLabelColor: automatic/light/dark/accent；nsColor 派生(.automatic→NSColor.labelColor 零迁移, light→.white, dark→.black, accent→.controlAccentColor)。
2. LaunchpadLabelWeight: regular/medium/semibold/bold；nsFontWeight→NSFont.Weight；文件夹标题用 emphasized 派生(下限 .semibold，保证标题永不细于历史)。
3. LaunchpadLabelSize: small/medium(默认,=历史 12pt 基线)/large；纯函数 fontSize(iconSide:)：small→11(固定)；medium→clamp(round(iconSide*0.18),11,15)；large→clamp(round(iconSide*0.21),12,17)。文件夹标题 fontSize = max(title2.pointSize, labelFontSize)（labelFontSize 即上面 LaunchpadLabelSize.fontSize(iconSide:) 的计算结果），保证标题 ≥ app 名。
   —— 这一档采纳方案 C「字号与 iconSize 协调」，但 default(medium) 在 @64pt 派生 12pt 命中历史，且 labelHeight 用 max(32, ceil(systemFontLineHeight(size)*2)+pad)，仅 large/超大图标才长高，默认严格不动几何。

LaunchpadAppearance(LaunchpadLayoutMath.swift:6-11) 加三字段，安全默认守 byte-compat：
  var labelColor: LaunchpadLabelColor = .automatic
  var labelWeight: LaunchpadLabelWeight = .regular
  var labelSize: LaunchpadLabelSize = .medium

LaunchpadGridMetrics(DragGrid.swift:9-22) 加「成品」字段(注入 cell 用具体值，不进枚举以保 Equatable 干净——NSColor 不进 metrics，存 LaunchpadLabelColor 枚举，cell 用时调 .nsColor)：
  var labelColor: LaunchpadLabelColor = .automatic   // == 历史隐含 .labelColor
  var labelFontSize: CGFloat = 12                      // == 历史硬编码 12
  var labelFontWeight: NSFont.Weight = .regular        // NSFont.Weight 是 RawRepresentable CGFloat，Equatable OK
  + folderTitleFontSize: CGFloat = title2.pointSize、folderTitleWeight: NSFont.Weight = .semibold（resolve 一并算好，FolderRenameField 不再 hardcode）

LaunchpadPreferences：Keys 加 "labelColor"/"labelWeight"/"labelSize"；3 个 @Published + didSet 写 storage.set(rawValue)；init 读 Enum(rawValue: storage.string ?? "") ?? 默认(照搬 backgroundStyle:220-225)；appearance 投影(:132-137)补三字段。全 String rawValue，PluginStorage 原生支持——零 NSColor/Data 持久化、零解码降级负担。

# 渲染（单一注入链，font/color 与 iconSize 同纪律）
preferences.appearance → LaunchpadGridMetrics.resolve(appearance)(LayoutMath:25-43，新增透传 labelColor/labelFontSize/labelFontWeight + folderTitle*，labelHeight 仅非默认字号档调整) → OverlayController.open():187 sessionMetrics 快照 → GridView.metrics:41 → DragGrid.metrics → cell。
- 落地面1 cell.label：init(DragGrid:1270-1278) 把 `.systemFont(ofSize:12)` 改为 `.systemFont(ofSize: metrics.labelFontSize, weight: metrics.labelFontWeight)` + 新增显式 `label.textColor = metrics.labelColor.nsColor`(automatic→.labelColor 零行为变化)。**关键**：update(DragGrid:1290-1296)必须对称 re-apply font+textColor——现状 update 只重设 frame/isHidden 不碰字体颜色(已读源码确认)，漏改会导致同 items 换 metrics 时字体不刷新。验证：testApplyWithSameItemsButNewMetricsRelaysOutCells(:144) 已驱动 update 路径，扩断言即可。
- 落地面2 文件夹大标题：LaunchpadFolderRenameField 加入参 titleColor:NSColor + titleFont:NSFont(GridView:851 调用处从 folderMetrics 派生传入)。makeNSView:75/77-78 改为读入参；centeredPlaceholder(:89/:106)已用 field.font 自动跟随；updateNSView 须 re-apply textColor/font(NSViewRepresentable 复用同一 field 实例，参数变了不在 update 同步则 reopen 不刷新)。
- configure()(DragGrid:1300-1317) 只动 stringValue/accessibility，不碰字体颜色——AX label/toolTip 始终有值不变。

# 设置 UI（LaunchpadSettingsView.appearanceSection:204-258，Icon Size Slider 之后追加三行，复用 row(title:description:){control} + section helper）
- 「标签字号」row：Picker(.segmented) selection:$preferences.labelSize ForEach allCases→label(localization:)，.labelsHidden().fixedSize()（照搬背景 segmented Picker:306-319，**务必 .fixedSize()** 防 NSSegmentedControl 溢出卡片——背景分组踩过这坑）。副标题「与图标大小协调缩放」。
- 「标签字重」row：同 .segmented Picker(常规/中等/半粗/加粗)。若 en 标签过宽改 .menu + .frame(width:110)(照搬 backgroundMaterial Picker:330-336)。
- 「标签颜色」row：.menu Picker(自动/白色/黑色/强调色) .frame(width:110)。副标题「深色背景下可选浅色更清晰」。
三行无条件常显(不像 background custom 有从属)。可选润色：hidesAppNames=true 时 .disabled 灰显。文案中文短句、PluginSettingsTheme.Typography token(row helper 已封装)。

# 文件
- 新建 Plugins/Launchpad/Sources/LaunchpadLabelStyle.swift（三枚举）
- Plugins/Launchpad/Sources/LaunchpadLayoutMath.swift（Appearance:6-11 加三字段；resolve:25-43 透传 + labelHeight 派生）
- Plugins/Launchpad/Sources/LaunchpadDragGrid.swift（GridMetrics:9-22 加成品字段；init:1270-1278 + update:1290-1296 应用 font/textColor）
- Plugins/Launchpad/Sources/LaunchpadPreferences.swift（Keys:172-183 + 3 @Published + init:205-231 + appearance:132-137）
- Plugins/Launchpad/Sources/LaunchpadSettingsView.swift（appearanceSection 追加三行 + bindings）
- Plugins/Launchpad/Sources/LaunchpadFolderRenameField.swift（加 titleColor/titleFont 入参；makeNSView:75/77-78 + updateNSView:106）
- Plugins/Launchpad/Sources/LaunchpadGridView.swift:851（folderPanel 传 titleColor/titleFont）
- Plugins/Launchpad/Resources/Localizable.xcstrings（枚举标签 key labelColor.*/labelWeight.*/labelSize.* + settings.appearance.label*.title/.description，每 key extractionState:"manual" + en/zh-Hans，sourceLanguage zh-Hans）
- 新建 Plugins/Launchpad/Tests/LaunchpadLabelStyleTests.swift
- Plugins/Launchpad/Tests/LaunchpadGridMetricsTests.swift（锚点:17-44 增字段断言）
- Plugins/Launchpad/Tests/LaunchpadPreferencesTests.swift（round-trip + appearance 派生）
- README.md / README.zh-CN.md（用户可见外观能力）

# 测试
- GridMetricsTests.testResolveDefaultAppearanceMatchesDefaultMetricsFieldByField(:17)：增 labelColor==.automatic / labelFontSize==12 / labelFontWeight==.regular，且 labelHeight 仍==32（守 byte-compat 锚点，否则该测试红）。
- testDefaultMetricsPinTheHistoricalValues(:33)：增同三行 pin。
- 新 testLabelSizeDrivesLabelHeight：small/medium(@64) 不改 labelHeight(=32)、large/大图标按 ceil(lineHeight*2) 长高且 cellHeight 随之。
- 新 testResolveInjectsLabelStyleIntoMetrics：resolve 把字重/颜色/字号原样带进 metrics。
- 扩 testApplyWithSameItemsButNewMetricsRelaysOutCells(:144)：换字重/字号 metrics 后 cell.label.font.pointSize/weight + textColor 实际变化(驱动 update 路径运行时验证)。
- 新建 LaunchpadLabelStyleTests：三枚举 nsColor/nsFontWeight/fontSize(iconSide:) 全 case 映射 distinct + automatic.nsColor==NSColor.labelColor 锚定零迁移 + label(localization:) 全 case（照搬 LaunchpadBackgroundStyleTests 模式）。
- PreferencesTests：testLabelStyleDefaultsWhenStorageEmpty(.automatic/.regular/.medium) + testLabelStyleRoundTrip(FakePluginStorage 写 rawValue→fresh 读回) + testUnknownStoredLabelValuesFallBackToDefaults("neon"→.automatic) + 扩 testAppearanceDerivation(:176) 含三字段。
- 单类命令：完整 test 命令后加 -only-testing:MacToolsTests/LaunchpadLabelStyleTests / -only-testing:MacToolsTests/LaunchpadGridMetricsTests。

=== 动画计划 ===
【动画最终设计：采纳实验「选项 A = offset-based 纯 SwiftUI 视口坐标」，并明确兜底。坐标方案可行，已对源码逐点核实。】

# 现状（已核实）
GridView.swift:219-228 唯一渲染点：folderPanel 当前 `.scaleEffect(folderShown ? 1 : 0.55, anchor: .center).opacity(...)`——从 ZStack 自身正中心缩放。要替换为「从被点文件夹格子长出」。folderShown 纪律(:491-498 openFolderPanel / :763-777 closeFolder)、folderOpenAnimation .spring(0.50,0.78)/folderCloseAnimation .spring(0.32,0.92)(:781-782) 全部确认。

# 坐标方案（可行，全程不触 AppKit y-flip）
纯 SwiftUI 视口坐标，零 convert(避开 design §5 / DragGrid 多处实测的「convert 穿 scaleEffect/.offset 会偏 page×pageWidth 且活动期振荡」陷阱)：
1. index = filtered.firstIndex(where: layoutID==openFolderID)；folderPage = index/perPage；slot = index%perPage（perPage:153=columnCount*rowCount）。
2. cellRect = LaunchpadLayoutMath.slotRect(index:slot, columns:columnCount, containerWidth:geo.size.width, metrics:metrics)（:174-191，纯几何、top-left、SwiftUI 与之同向 y-down，无需翻转；containerWidth 取 pagedGrid 的 geo.size.width:369-405，与 AppKit 容器 bounds 同源）。
3. cellCenterInViewport = (cellRect.midX, cellRect.midY)；视口中心 = (geo.size.width/2, geo.size.height/2)。
4. 视口相对 ZStack 偏移 Δ：从 chrome(computed property :87 = Chrome.standard(isCompact:))派生——Δ.x = chrome.horizontalPadding；Δ.y = chrome.topPadding + chrome.searchBarHeight + chrome.stackSpacing。**禁止写死 60/48 字面量**(compact/fullscreen 不同，必须从 chrome 派生)。
5. collapsedOffset(panel 自身居中于 ZStack 为基准) = (cellCenterInViewport + Δ) − ZStack 中心。
实现：folderShown=false 时 panel.offset(collapsedOffset) + .scaleEffect(~0.18, anchor:.center)；folderShown=true 时 offset=.zero + scale=1。offset 与 scale **必须挂同一** .animation(folderShown ? folderOpenAnimation : folderCloseAnimation, value: folderShown)——不引入 transition(ZStack-over-AppKit 下 tuple-derived view 无稳定 identity，:73-75 注释)、不新增第二驱动 value 造成两段不同步。保留 :772-777 的 asyncAfter 0.34s unmount 守卫。

# 否决备选
- 选项 B(scaleEffect anchor=UnitPoint 归一化)：UnitPoint 相对 panel 自身 bounds，panel 尺寸随 folder.items 动态变(folderPanel:825-846 panelMaxWidth/visibleH)，cell 在 panel 外时 UnitPoint 落 <0/>1 视觉是「从远处冲来」非「长出」，panel 含 .padding/shadow 难精确——双重易错，仅 offset 落地遇阻时备选。
- 选项 C(窗口空间 + CarrySpace 反算)：folder panel 是 SwiftUI 视图，引入 AppKit 窗口空间要做 y-up↔y-down 二次翻转，且 viewport relay push 是 layout() 时异步、打开瞬间可能滞后——当前 SwiftUI panel 架构不推荐。

# 兜底（硬要求）
folderPage != currentPage、或 index 找不到(folder 在 0.x s 内被 dissolve)、或 geo 未布局(geo.size==0) 时，collapsedOffset 退回 .zero + anchor 回 .center(即现状屏幕中心缩放)。需对 firstIndex 显式 guard(可能 nil)。与 settleTargetLocalRect 的「nil→hard-cut」降级哲学一致，保证不把 panel 甩到屏外或 NaN。

# 风险
- folderShown 双驱动同步：offset/scale/opacity 必须同一 animation(value: folderShown)，否则三段错拍。
- collapsedOffset 在打开瞬间需 geo 已布局——首帧 geo 可能为 0，靠兜底 .center 接住。
- 多页：理论上 folder 必在 currentPage(activateCell:483-489 同步 selection/page)，但 context-menu rename/post-create auto-open 可能在别页——兜底覆盖。
- 不动设置页预览(folder 弹出是运行时 overlay 行为，不进缩略图)，避免无关改动。