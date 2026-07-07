# Agent Instructions for MacTools

## 指令范围
- 本文件是本仓库的 canonical agent 指南，适用于整个仓库。
- 若子目录未来出现更近的 `AGENTS.md`，以更近文件为准。
- `CLAUDE.md`、`GEMINI.md` 只做兼容入口；共享规则应优先维护在本文件。

## 项目概览
- MacTools 是原生 macOS 菜单栏工具集合，面向高频、轻量、不打扰的系统能力。
- 技术栈为 Swift 6、SwiftUI + AppKit，最低支持 macOS 14.0。
- 功能以插件组织。当前插件源码统一放在 `Plugins/<PluginName>/`，通过 `MacToolsPluginKit`、动态插件包和 catalog 接入宿主。
- 用户可见文案当前以中文为主；新增文案需保持简洁、清楚、接近 macOS 原生表达。

## 关键目录
- `Sources/App/`：应用入口、菜单栏状态项、面板、设置页和窗口路由。
- `Sources/Core/Plugins/`：插件宿主、动态插件加载、包安装、catalog 校验和展示偏好。
- `Sources/Core/Shortcuts/`：全局快捷键模型、存储和管理。
- `Sources/Core/Permissions/`：系统权限检查。
- `Sources/Core/Diagnostics/`：统一日志入口。
- `Sources/Core/Updates/`：Sparkle 更新检查与关于页更新状态。
- `Sources/MacToolsPluginKit/`：插件协议、描述式 UI 模型、快捷键模型和运行时上下文。
- `Plugins/<PluginName>/`：插件 manifest、源码、bundle 入口、资源和相邻测试。
- `Tests/`：App/Core 共享逻辑的 XCTest；插件测试优先放在对应插件目录下。
- `Configs/`：Xcode build settings 与 `Info.plist`。
- `docs/plugins/`：插件包、catalog、本地调试和发布流程文档。
- `docs/superpowers/`：较大的产品/交互设计规格与实施计划。
- `scripts/`：发布、签名、公证和 GitHub Release 辅助脚本。

## 构建与运行
- 先运行 `make setup` 初始化 `LocalConfig.xcconfig`，再填写 `DEVELOPMENT_TEAM` 与 `BUNDLE_IDENTIFIER_PREFIX`。
- `project.yml` 是 XcodeGen 的根项目源文件；插件 target/scheme 由 `scripts/plugins/generate-plugin-project-config.rb` 扫描 `Plugins/*/plugin.json` 后生成到本地 `Configs/GeneratedPlugins.yml`，该生成文件不提交。
- 生成项目：`make generate`。不要直接运行裸 `xcodegen generate`，否则可能缺少最新插件生成配置。
- 编译校验：`make build`。
- 本地运行：`make run`，会同步最新 Debug 插件包并生成本地开发 catalog。
- 只同步已编译的 Debug 插件包和本地开发 catalog：`make sync-debug-plugins`。
- 单独构建本地插件包并生成 Debug catalog：`make build-plugin`。
- 构建指定插件：`make build-plugin PLUGIN=<插件目录名或插件 ID>`。
- 运行完整测试：`xcodebuild -project MacTools.xcodeproj -scheme MacTools -configuration Debug -derivedDataPath build/DerivedData test -quiet`。
- 运行单个测试类：在完整测试命令后加 `-only-testing:MacToolsTests/<TestClassName>`。
- 只在需要发布时使用 `./scripts/release-local.sh`；签名、公证、发布和打 tag 前必须确认用户意图。

## 架构约定
- 新增插件放在 `Plugins/<PluginName>/`，至少包含 `plugin.json`、`Sources/` 和 `Bundle/`。
- 插件实现 `MacToolsPlugin`；菜单栏主面板实现 `PluginPrimaryPanel`，组件面板实现 `PluginComponentPanel`。
- `plugin.json.id` 必须稳定、可读，并与运行时 `PluginMetadata.id` 完全一致；每个 `.mactoolsplugin` 包只返回一个插件实例。
- `PluginHost` 负责插件排序、可见性、快捷键、权限卡片和派生展示状态；不要让具体插件直接操纵宿主 UI。
- 插件 UI 应通过 `PluginPanelState`、`PluginPanelDetail`、`PluginPanelControl` 等描述式模型表达；除 `PluginComponentPanel.makeView` 外，避免绕过现有面板框架自建菜单栏 UI。
- 插件状态与 UI 相关代码默认在 `@MainActor`；耗时扫描、文件系统或系统调用应避免长时间阻塞主线程。`primaryPanelState`、`componentPanelState` 应尽量只读取已有快照，不要在 getter 中同步扫描硬件、文件系统或网络。
- `PluginHost` 只负责派生面板项、组件项、设置项等通用展示状态，并会缓存组件视图和合并短时间内的状态重建；业务数据快照、缓存失效和刷新时机仍应由具体插件或组件负责。
- 插件状态变化后调用 `onStateChange?()`，使宿主重建派生状态。若状态会被外部系统事件改变（如显示器热插拔、权限变化、文件系统变化、日历授权变化），需要接入明确的事件监听或刷新入口，并配合 debounce/节流更新快照，避免依赖用户展开面板、切换设置页或全量 `refreshAll()` 才拿到新数据。例外：输入统计、采样计数等高频事件源可以只更新插件自身快照，不对每个事件调用 `onStateChange?()`；这类插件必须按面板/组件可见性或固定时间窗口节流上报 UI 变化，并确保用户主动打开面板或 `refresh()` 时能读到最新快照。
- 有跨插件通用意义的外部状态变化应优先抽象成 Core 层协议或观察器；例如显示器拓扑变化使用 `DisplayConfigurationObserving` 通知宿主，再由实现 `DisplayTopologyRefreshing` 的显示器相关插件刷新自身快照。
- 控件 ID、插件 ID、快捷键 ID 要稳定、可读，并尽量集中在功能内的私有常量中。
- 普通新增插件不需要更新根 `project.yml`；保持 `plugin.json.build.scheme` 指向对应 bundle scheme，生成器会自动创建 core target、bundle target、测试依赖和插件 scheme。若插件需要额外 framework、include path、bundle 资源或 target 覆盖，在 `Plugins/<PluginName>/project.yml` 中声明最小差异。

## 插件设置界面规范
- 插件设置页默认使用宿主设置页框架：`PluginConfiguration` 只提供当前插件的配置内容，页面主标题、图标、描述、权限卡、快捷键卡等通用区域交给 `PluginHost`/`SettingsView` 派生和渲染；不要在插件自定义配置里重复实现整页标题。
- 新增设置项优先使用 `settingsSections`、`permissionRequirements`、`shortcutDefinitions` 等描述式模型，由宿主统一排版；只有需要复杂交互、列表、拖放、图表或专用管理器时才提供 `PluginConfiguration.makeView` 自定义视图。
- 设置页主题常量统一使用 `MacToolsPluginKit.PluginSettingsTheme`。插件 target 不得依赖 `Sources/App/SettingsStyle.swift`，也不要复制一套插件私有 settings style；需要扩展主题时优先加到 `PluginSettingsTheme`，保持依赖方向为宿主 App -> PluginKit、插件 -> PluginKit。
- 自定义插件设置视图的字体层级以 `FanControlPresetManagerView` 为视觉基准，并通过 `PluginSettingsTheme.Typography` 表达：页面标题用 `pageTitle`，页面说明用 `pageDescription`；分组标题使用 `Label` + SF Symbol + `sectionTitle` + `.foregroundStyle(.secondary)`；普通行标题使用 `rowTitle`，强调行标题或表头使用 `emphasizedRowTitle`；说明、帮助、副标题使用 `rowDescription`；状态徽标使用 `statusBadge`；固定宽度数值读数使用 `monospacedValue`。这些 token 应优先映射 Apple 平台语义字体（如 `.title2`、`.body`、`.subheadline`），避免在插件里散落裸字号。
- 宿主设置页页面头使用 `PluginSettingsTheme.Typography.pageTitle` + `pageDescription`；插件自定义配置内容从分组开始，不再使用页面级标题，避免同一页出现多个视觉主标题。
- 自定义配置的排版以风扇控制为基准，并优先使用 `PluginSettingsTheme.Spacing`：外层分组间距用 `section`，分组标题与内容间距用 `sectionHeaderContent`；卡片/列表行横向 padding 用 `rowHorizontal`，普通行纵向 padding 用 `rowVertical`，包含编辑控件或滑杆的行用 `interactiveRowVertical`；行内主副标题间距用 `rowTitleDescription`，控件与文本间距用 `rowContentControl`。
- 卡片和列表容器优先使用 `PluginSettingsTheme.Palette` 与 `Radius`：通过背景色、留白和圆角区分区域，不给普通设置卡片加描边；宿主设置卡片用 `cardBackground`，插件自定义列表可用 macOS 原生 `nativeCardBackground`，圆角优先 `Radius.card`，宿主大卡片可用 `Radius.hostCard`。
- 控件布局要稳定：按钮使用系统 `.bordered`/`.borderedProminent` 与 `.controlSize(.small)`，开关使用 `.toggleStyle(.switch)`；滑杆、Picker、文本框等设置明确的最小/理想/最大宽度，数值文本给固定宽度，长标题和路径使用 `lineLimit`、`fixedSize` 或 text selection，避免窗口缩放时挤压或跳动。
- 文案保持中文、短句、接近 macOS 原生表达。标题描述“对象/设置项”，副标题描述“作用/当前状态”，不要把操作说明写成大段说明文字。

## Swift 代码风格
- 保持现有 Swift 风格：小类型、明确命名、早返回、少全局状态。
- 优先使用 Apple 原生框架；引入第三方依赖前先说明理由。插件私有的系统 framework/include path 优先写入对应 `Plugins/<PluginName>/project.yml`。
- 使用 `AppLog` 添加 OSLog category，避免在应用代码中使用裸 `print`。
- 与 AppKit、CoreGraphics、IOKit、EventKit 等系统 API 交互时，保留失败分支和降级路径。
- 文件、路径、权限、显示器 ID、快捷键绑定等外部输入必须校验后再使用。
- 不要把签名证书、notary 凭证、bundle 前缀、开发团队 ID 等本地敏感配置写入仓库。

## 功能安全边界
- 磁盘清理：不得绕过 `DiskCleanSafetyPolicy`、白名单、敏感路径保护和执行前二次校验；扩大清理范围必须补测试。
- 物理清洁模式：必须保留可退出路径、辅助功能权限引导、多屏覆盖和睡眠/锁屏后的安全退出逻辑。
- 隐藏刘海：不要破坏用户原始壁纸；注意多显示器、Space 切换和壁纸变化场景。
- 显示器亮度：优先保留 Apple 原生、DDC/CI、Gamma/Shade 回退链路，外接屏失败时不要崩溃。
- 显示器分辨率：切换前确认显示器仍连接且目标模式仍存在；错误应转为用户可理解状态。
- 日历：不要假设权限已授予；权限不足时应提供清楚引导而非静默失败。
- 更新发布：Sparkle appcast、版本号、签名和公证相关改动要小心，避免提交本地发布产物。

## 测试要求
- 行为改动优先补或更新相邻 XCTest；测试文件命名使用 `<TypeName>Tests.swift`。
- 插件测试优先放在 `Plugins/<PluginName>/Tests/`；Core/App 共享逻辑测试放在 `Tests/Core/` 或 `Tests/App/` 对应目录。
- 文件系统测试使用临时目录或 fake store，禁止删除真实用户目录。
- 插件交互测试应覆盖 `PluginPanelAction`、派生 `PluginPanelState`、权限状态和错误状态。
- 无法运行测试时，在最终回复中明确说明原因和建议的本地验证命令。

## 文档与资源
- 用户可见功能变化需同步更新 `README.md`。
- 插件目录、manifest、catalog 或发布流程变化需同步更新 `docs/plugins/` 和 `CONTRIBUTING.md`。
- 大型产品/交互变更可在 `docs/superpowers/specs/` 或 `docs/superpowers/plans/` 添加日期前缀文档。
- 图标、asset catalog、`LocalConfig.xcconfig`、发布 env 文件通常由用户或生成流程维护；不要无关改动。

## Agent 工作流
- 开始修改前用 `rg`/`rg --files` 快速定位现有模式，优先复用相邻实现。
- 保持改动聚焦，不顺手重构无关模块，不覆盖用户已有改动。
- 修改 `project.yml` 后运行或建议运行 `make generate`。
- 验证从最小相关测试开始，再视情况运行完整测试或 `make build`。
- 不要自动 commit、创建分支、打 tag、发布 release 或清理用户文件，除非用户明确要求。
