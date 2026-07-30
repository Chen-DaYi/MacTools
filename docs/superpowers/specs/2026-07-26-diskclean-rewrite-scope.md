# DiskClean 插件重写 — 功能范围对齐（2026-07-26）

## 背景

- 现有 DiskClean 插件（v1.0.8，约 3200 行）基于 Mole 第一版规则移植，自 1.0.0 起清理逻辑无功能迭代。
- 核心痛点是性能：`DiskCleanFileSystem.sizeOfItem` 用 `FileManager.enumerator` 逐文件 `attributesOfItem` 递归求和；扫描完全串行；进程检测每条规则 spawn 一次 `pgrep`。
- 重写参考 /Users/rk/work/ps/Burrow（开源系统工具，内置 Mole fork 引擎）。调研结论：Burrow 的引擎是私有 submodule（shell + Go 二进制子进程），源码不可得；可搬的是其**技术方案**（扫描性能手法、安全模型、交互设计），Swift 侧有完整参考实现。

## 已确认的决策

| 决策点 | 结论 |
|---|---|
| 扫描引擎 | 原生 Swift 重写，不捆绑 CLI。用 `getattrlistbulk`（或 `fts`）写快速 walker，规则用 Swift 定义、可测试 |
| 功能范围 | P0 性能+安全、P1 规则体系升级、P2 开发产物清扫、P2 残留安装包，全部纳入 |
| 删除方式 | 默认移到废纸篓（可恢复），设置项可切换为永久删除 |
| 审查 UI | 保持菜单栏面板 + 详情视图形态，详情视图升级为分类卡片 + 三态勾选 |

## 功能清单

### P0 性能重写
1. 原生快速 walker：`getattrlistbulk` 批量读取属性，替换 `FileManager.enumerator` 逐项求 size（Burrow 实测该路径快约 10 倍）。
2. 有界并发扫描：`TaskGroup` + 并发上限（参考 Burrow 的 3 路信号量，更宽会打满多核），替换串行扫描。
3. 流式结果：扫描过程中实时累计**估算**可回收字节数（逻辑大小估算，非精确可释放空间）、候选项增量出现，而不是等全部扫完。
4. 抗卡死：单候选项超时（参考 Burrow 20s/项、整体 300s），超时项显示部分结果；世代令牌 + 协作取消，过期结果丢弃、被取代的扫描不再派生新任务。
5. 大小缓存：同一路径短期内重复扫描复用结果。
6. 进程占用检测改为 `NSWorkspace` 一次性快照（或单次 `pgrep` 批量匹配），去掉每规则一次子进程。

### P0 安全升级（保留现有红线，另加 Burrow 实践）
保留：`DiskCleanSafetyPolicy`、白名单存储、敏感路径保护、执行前二次校验（AGENTS.md 安全边界要求，不得绕过）。

新增：
7. 运行中应用的缓存标记"使用中"，默认不勾选且**不可勾选**。
8. 扫描结果过期门：预览超过 5 分钟强制重扫。定位为误操作防护（防"扫完放半天再点清理"）；真正的删除时防线是执行前逐项复核（身份复核、锁定复核、安全策略二次校验），见设计文档 §6。
9. 删除方式：废纸篓（默认）/ 永久删除，确认按钮如实标注（"移到废纸篓 · X 项" vs "永久清理 · X 项"）。
10. 本地删除日志（追加式审计：时间、动作、分类、状态、路径），便于追溯。

### P1 规则体系升级
11. 分类从 3 个（缓存/开发者/浏览器）升级为新版 Mole 分类体系（10 类：用户基础项、应用缓存、系统缓存、日志、开发者缓存、浏览器、云与办公、通讯、AI 工具、虚拟化）。"应用残留"（已卸载应用孤儿目录）经设计评审后**延期**，不在本期交付。
12. 分类按风险从低到高排序展示；每类附一句诚实的后果说明（如浏览器缓存→"首次访问网站会稍慢"，开发者缓存→"首次构建会变慢"）。
13. 补齐现为空壳的动态规则：不可用模拟器（`simctl`）、JetBrains Toolbox 旧版本、浏览器旧版本、AI Agent 旧版本。
14. 完全磁盘访问（FDA）检测与引导：能力探测（尝试打开 TCC 保护文件，不读字节），无权限时在插件自有界面显示引导 + "受限扫描"提示，不静默漏扫。经设计评审确定**本期不改 PluginKit**（`PluginPermissionKind` 追加涉及 ABI 版本策略，宿主 loader 为严格版本相等校验），FDA 引导完全在插件内实现；迁移到宿主权限卡留待未来 PluginKit v4。注意 FDA 授权绑定进程启动，授权后需重启应用才生效。

### P2 新增清理范围
15. 开发产物清扫：扫描项目目录下的 `node_modules`、`target/`、`build/`、`dist/`、`__pycache__`；对所在 git 仓库有未提交/未推送改动的项加警示标记。
16. 残留安装包：下载目录中的 `.dmg/.pkg/.iso/.xip/.zip`。

### 明确不做（本插件范围外）
- 磁盘树图分析、重复文件、应用卸载、系统优化——如需要，作为独立插件另立项。
- 不捆绑任何 CLI 引擎二进制。

## 参考索引（Burrow 侧关键实现）

- 扫描性能：`macos/Sources/DiskScanner.swift`、`AnalyzeView.swift`（有界并发、超时、缓存、取消）
- 清理流程：`CleanView.swift`、`CleanList.swift`、`CleanSelection.swift`（三态选择）、`CleanImpactRanker.swift`（风险排序）、`CleanReviewView.swift`（后果文案）
- 安全：`MoleWhitelist.swift`（白名单会话）、`CleanLock.swift`（使用中锁定）、`MoActions.swift`（票据式策略门）、`RestorePlan.swift`
- FDA：`Privacy.swift`、`Components/AccessBanner.swift`
- 硬链接去重计数：`HardlinkAwareSizer.swift`
- 规则集代理（引擎源码不可得时的参考）：`windows/Assets/Mole/lib/clean/*.ps1`（上游 Mole v1.29.1 的 Windows 移植）
