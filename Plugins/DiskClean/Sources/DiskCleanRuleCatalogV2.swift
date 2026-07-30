import Foundation

/// 规则目录 v2（设计 §5.4 权威映射表）。
///
/// 与 v1 `DiskCleanRuleCatalog` 的关系：
/// - **glob 本身逐字保留**——白名单存储与用户认知都依赖这些字符串，迁移只改变归属与元数据。
/// - v1 的 43 条规则全部有归属；`legacyRuleID` 覆盖 v1 规则 id 全集（`DiskCleanRuleCatalogV2Tests` 快照断言）。
/// - v1 中同一 glob 出现在两条规则里的 6 处重复（Codex 五项、`com.figma.Desktop`）在 v2 归一到单一 target，
///   因此"每条 glob 恰有一个归属 target"成立。
/// - v1 的伪动态规则（`.xcodeDerivedData`、包管理器七项、`.serviceWorkerCache`）实际只用静态兜底 glob，
///   v2 直接落为 path target；真正需要运行时判断的四条走 `DiskCleanDynamicRules` 的 provider。
///
/// `reservedRootPaths` 一律写死为字面量，取值 = 该 target 每条 glob 的**固定目录前缀**
/// （首个 glob 元字符之前的最后一个完整路径组件），去重后按 glob 顺序排列。
/// 家目录下的裸文件 glob（`~/.zcompdump*`、`~/.gitconfig.bak*`）因此推导出 `~` 本身——
/// 它只保护 `~` 的祖先（`/Users`、`/`），是弱但正确的保留根，不要"顺手改深"：
/// 保留根必须是 glob 真正的固定前缀，改深会漏保护同前缀下未扫描的兄弟路径。
///
/// ## `requiresFullDiskAccess` 的判定（设计 §9）
///
/// **判定式：target 的每一条 glob 都落在 TCC 保护前缀内才置 true。** 只要有一条不在，就整体
/// 不标记，让被保护的那几条以 `permissionDenied` 单独降级——标记会让同 target 内**可清理**的
/// 路径一起被跳过，代价大于收益。混合 target 因此一律拆成两个（拆分保持 `legacyRuleID` 不变，
/// v1 映射快照不受影响）。
///
/// 认定的保护前缀，以及为什么各自都必须跳过：
/// - `~/Library/Containers/`、`~/Library/Group Containers/`：macOS 14 起的
///   `kTCCServiceSystemPolicyAppData`。**这一类会弹窗**（且授权只在本次运行有效），逐目录展开
///   十几条 glob 就是十几次弹窗——设计 §9 要避免的正是这个。
/// - `~/Library/Caches/com.apple.Safari`、`~/Library/Safari`：与 `~/Library/Safari` 同属
///   平台沙盒策略的 Safari 存储类，纯 FDA 保护，无弹窗，静默 EPERM。
/// - `~/Library/Suggestions`、`~/Library/Calendars`、`~/Library/Application Support/AddressBook`：
///   FDA / Calendar / Contacts 服务保护，同样静默 EPERM。不跳过只会得到一堆读不到的空候选。
///
/// 刻意**不**认定的几条（读得到，标记会白白少清理）：`~/Library/Caches` 本身、
/// `~/Library/Saved Application State`、`~/Library/Caches/com.apple.helpd`、
/// `~/Library/Caches/GeoServices`、`~/Library/DiagnosticReports`。
/// `~/Library/Autosave Information` 与 `~/Library/IdentityCaches` 证据不足，按不保护处理——
/// 猜错的代价只是这两条降级为 `permissionDenied`，不影响同 target 其余路径。
///
/// `DiskCleanRuleCatalogV2Tests` 用同一张前缀表反向推导标记并逐条比对，两个方向的漂移都会失败。
struct DiskCleanRuleCatalogV2: Sendable {
    let targets: [DiskCleanRuleTarget]

    static let current = DiskCleanRuleCatalogV2(
        targets: userAndAppTargets + developerTargets + browserTargets
            + developerArtifactTargets + installerTargets
    )

    /// 规则展开阶段的 target。P2 合成 target 不在其中——它们的候选由专用扫描器发现。
    var ruleTargets: [DiskCleanRuleTarget] {
        targets.filter { !$0.isExternallyDiscovered }
    }

    func targets(in category: DiskCleanCategoryID) -> [DiskCleanRuleTarget] {
        targets.filter { $0.category == category }
    }

    func target(id: String) -> DiskCleanRuleTarget? {
        targets.first { $0.id == id }
    }

    /// 同一条 v1 规则拆出的全部 target。审计与白名单迁移按 legacyRuleID 归集。
    func targets(legacyRuleID: String) -> [DiskCleanRuleTarget] {
        targets.filter { $0.legacyRuleID == legacyRuleID }
    }

    /// 展示顺序：分类按 `DiskCleanCategoryID.displayOrder`（风险低 → 高），分类内按 target 风险再按 id。
    var targetsInDisplayOrder: [DiskCleanRuleTarget] {
        DiskCleanCategoryID.displayOrder.flatMap { category in
            targets(in: category).sorted {
                $0.risk == $1.risk ? $0.id < $1.id : $0.risk < $1.risk
            }
        }
    }

    // MARK: - 用户与应用缓存（v1 `cache.*` 规则）

    private static let userAndAppTargets: [DiskCleanRuleTarget] = [
        DiskCleanRuleTarget(
            id: "cache.user-essentials.caches",
            legacyRuleID: "cache.user-essentials",
            category: .userEssentials,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.user-essentials.logs",
            legacyRuleID: "cache.user-essentials",
            category: .logs,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Logs/*"
            ]),
            reservedRootPaths: [
                "~/Library/Logs"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.macos-app-state",
            legacyRuleID: "cache.macos-app-state",
            category: .systemCaches,
            risk: .medium,
            kind: .path(globs: [
                "~/Library/Saved Application State/*",
                "~/Library/Caches/com.apple.photoanalysisd",
                "~/Library/Caches/com.apple.akd",
                "~/Library/Caches/com.apple.WebKit.Networking/*",
                "~/Library/DiagnosticReports/*",
                "~/Library/Caches/com.apple.QuickLook.thumbnailcache",
                "~/Library/Caches/Quick Look/*",
                "~/Library/Caches/com.apple.iconservices*",
                "~/Library/Autosave Information/*",
                "~/Library/IdentityCaches/*"
            ]),
            reservedRootPaths: [
                "~/Library/Saved Application State",
                "~/Library/Caches/com.apple.photoanalysisd",
                "~/Library/Caches/com.apple.akd",
                "~/Library/Caches/com.apple.WebKit.Networking",
                "~/Library/DiagnosticReports",
                "~/Library/Caches/com.apple.QuickLook.thumbnailcache",
                "~/Library/Caches/Quick Look",
                "~/Library/Caches",
                "~/Library/Autosave Information",
                "~/Library/IdentityCaches"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.macos-app-state.protected",
            legacyRuleID: "cache.macos-app-state",
            category: .systemCaches,
            risk: .medium,
            kind: .path(globs: [
                "~/Library/Suggestions/*",
                "~/Library/Calendars/Calendar Cache",
                "~/Library/Application Support/AddressBook/Sources/*/Photos.cache"
            ]),
            reservedRootPaths: [
                "~/Library/Suggestions",
                "~/Library/Calendars/Calendar Cache",
                "~/Library/Application Support/AddressBook/Sources"
            ],
            requiresFullDiskAccess: true
        ),
        DiskCleanRuleTarget(
            id: "cache.apple-sandboxed-apps",
            legacyRuleID: "cache.apple-sandboxed-apps",
            category: .appCaches,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Application Support/com.apple.wallpaper/aerials/thumbnails/*",
                "~/Library/Caches/com.apple.helpd/*",
                "~/Library/Caches/GeoServices/*"
            ]),
            reservedRootPaths: [
                "~/Library/Application Support/com.apple.wallpaper/aerials/thumbnails",
                "~/Library/Caches/com.apple.helpd",
                "~/Library/Caches/GeoServices"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.apple-sandboxed-apps.containers",
            legacyRuleID: "cache.apple-sandboxed-apps",
            category: .appCaches,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.mediaanalysisd/Data/tmp/*",
                "~/Library/Containers/com.apple.AppStore/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.configurator.xpc.InternetService/Data/tmp/*",
                "~/Library/Containers/com.apple.wallpaper.extension.aerials/Data/tmp/*",
                "~/Library/Containers/com.apple.geod/Data/tmp/*",
                "~/Library/Containers/com.apple.stocks/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.AvatarUI.AvatarPickerMemojiPicker/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.AMPArtworkAgent/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.NeptuneOneExtension/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.AppleMediaServicesUI.UtilityExtension/Data/tmp/*",
                "~/Library/Group Containers/group.com.apple.contentdelivery/Logs/*",
                "~/Library/Group Containers/group.com.apple.contentdelivery/Library/Logs/*"
            ]),
            reservedRootPaths: [
                "~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches",
                "~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches",
                "~/Library/Containers/com.apple.mediaanalysisd/Data/tmp",
                "~/Library/Containers/com.apple.AppStore/Data/Library/Caches",
                "~/Library/Containers/com.apple.configurator.xpc.InternetService/Data/tmp",
                "~/Library/Containers/com.apple.wallpaper.extension.aerials/Data/tmp",
                "~/Library/Containers/com.apple.geod/Data/tmp",
                "~/Library/Containers/com.apple.stocks/Data/Library/Caches",
                "~/Library/Containers/com.apple.AvatarUI.AvatarPickerMemojiPicker/Data/Library/Caches",
                "~/Library/Containers/com.apple.AMPArtworkAgent/Data/Library/Caches",
                "~/Library/Containers/com.apple.CoreDevice.CoreDeviceService/Data/Library/Caches",
                "~/Library/Containers/com.apple.NeptuneOneExtension/Data/Library/Caches",
                "~/Library/Containers/com.apple.AppleMediaServicesUI.UtilityExtension/Data/tmp",
                "~/Library/Group Containers/group.com.apple.contentdelivery/Logs",
                "~/Library/Group Containers/group.com.apple.contentdelivery/Library/Logs"
            ],
            requiresFullDiskAccess: true
        ),
        DiskCleanRuleTarget(
            id: "cache.cloud-storage",
            legacyRuleID: "cache.cloud-storage",
            category: .cloudOffice,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.dropbox.*",
                "~/Library/Caches/com.getdropbox.dropbox",
                "~/Library/Caches/com.google.GoogleDrive",
                "~/Library/Caches/com.baidu.netdisk",
                "~/Library/Caches/com.alibaba.teambitiondisk",
                "~/Library/Caches/com.box.desktop",
                "~/Library/Caches/com.microsoft.OneDrive"
            ]),
            reservedRootPaths: [
                "~/Library/Caches",
                "~/Library/Caches/com.getdropbox.dropbox",
                "~/Library/Caches/com.google.GoogleDrive",
                "~/Library/Caches/com.baidu.netdisk",
                "~/Library/Caches/com.alibaba.teambitiondisk",
                "~/Library/Caches/com.box.desktop",
                "~/Library/Caches/com.microsoft.OneDrive"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.office-apps",
            legacyRuleID: "cache.office-apps",
            category: .cloudOffice,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.microsoft.Word",
                "~/Library/Caches/com.microsoft.Excel",
                "~/Library/Caches/com.microsoft.Powerpoint",
                "~/Library/Caches/com.microsoft.Outlook/*",
                "~/Library/Caches/com.apple.iWork.*",
                "~/Library/Caches/com.kingsoft.wpsoffice.mac",
                "~/Library/Caches/org.mozilla.thunderbird/*",
                "~/Library/Caches/com.apple.mail/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.microsoft.Word",
                "~/Library/Caches/com.microsoft.Excel",
                "~/Library/Caches/com.microsoft.Powerpoint",
                "~/Library/Caches/com.microsoft.Outlook",
                "~/Library/Caches",
                "~/Library/Caches/com.kingsoft.wpsoffice.mac",
                "~/Library/Caches/org.mozilla.thunderbird",
                "~/Library/Caches/com.apple.mail"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.office-apps.containers",
            legacyRuleID: "cache.office-apps",
            category: .cloudOffice,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Containers/com.microsoft.Word/Data/Library/Caches/*",
                "~/Library/Containers/com.microsoft.Word/Data/tmp/*",
                "~/Library/Containers/com.microsoft.Word/Data/Library/Logs/*",
                "~/Library/Containers/com.microsoft.Excel/Data/Library/Caches/*",
                "~/Library/Containers/com.microsoft.Excel/Data/tmp/*",
                "~/Library/Containers/com.microsoft.Excel/Data/Library/Logs/*"
            ]),
            reservedRootPaths: [
                "~/Library/Containers/com.microsoft.Word/Data/Library/Caches",
                "~/Library/Containers/com.microsoft.Word/Data/tmp",
                "~/Library/Containers/com.microsoft.Word/Data/Library/Logs",
                "~/Library/Containers/com.microsoft.Excel/Data/Library/Caches",
                "~/Library/Containers/com.microsoft.Excel/Data/tmp",
                "~/Library/Containers/com.microsoft.Excel/Data/Library/Logs"
            ],
            requiresFullDiskAccess: true
        ),
        DiskCleanRuleTarget(
            id: "cache.virtualization",
            legacyRuleID: "cache.virtualization",
            category: .virtualization,
            risk: .medium,
            kind: .path(globs: [
                "~/Library/Caches/com.vmware.fusion",
                "~/Library/Caches/com.parallels.*",
                "~/VirtualBox VMs/.cache",
                "~/.vagrant.d/tmp/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.vmware.fusion",
                "~/Library/Caches",
                "~/VirtualBox VMs/.cache",
                "~/.vagrant.d/tmp"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.communication",
            legacyRuleID: "cache.communication",
            category: .communication,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Application Support/discord/Cache/*",
                "~/Library/Application Support/legcord/Cache/*",
                "~/Library/Application Support/Slack/Cache/*",
                "~/Library/Caches/us.zoom.xos/*",
                "~/Library/Caches/com.tencent.xinWeChat/*",
                "~/Library/Caches/ru.keepcoder.Telegram/*",
                "~/Library/Caches/com.microsoft.teams2/*",
                "~/Library/Caches/net.whatsapp.WhatsApp/*",
                "~/Library/Caches/com.skype.skype/*",
                "~/Library/Caches/com.tencent.meeting/*",
                "~/Library/Caches/com.tencent.WeWorkMac/*",
                "~/Library/Caches/com.feishu.*/*",
                "~/Library/Application Support/Microsoft/Teams/Cache/*",
                "~/Library/Application Support/Microsoft/Teams/Application Cache/*",
                "~/Library/Application Support/Microsoft/Teams/Code Cache/*",
                "~/Library/Application Support/Microsoft/Teams/GPUCache/*",
                "~/Library/Application Support/Microsoft/Teams/logs/*",
                "~/Library/Application Support/Microsoft/Teams/tmp/*"
            ]),
            reservedRootPaths: [
                "~/Library/Application Support/discord/Cache",
                "~/Library/Application Support/legcord/Cache",
                "~/Library/Application Support/Slack/Cache",
                "~/Library/Caches/us.zoom.xos",
                "~/Library/Caches/com.tencent.xinWeChat",
                "~/Library/Caches/ru.keepcoder.Telegram",
                "~/Library/Caches/com.microsoft.teams2",
                "~/Library/Caches/net.whatsapp.WhatsApp",
                "~/Library/Caches/com.skype.skype",
                "~/Library/Caches/com.tencent.meeting",
                "~/Library/Caches/com.tencent.WeWorkMac",
                "~/Library/Caches",
                "~/Library/Application Support/Microsoft/Teams/Cache",
                "~/Library/Application Support/Microsoft/Teams/Application Cache",
                "~/Library/Application Support/Microsoft/Teams/Code Cache",
                "~/Library/Application Support/Microsoft/Teams/GPUCache",
                "~/Library/Application Support/Microsoft/Teams/logs",
                "~/Library/Application Support/Microsoft/Teams/tmp"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.ai-assistants",
            legacyRuleID: "cache.ai-assistants",
            category: .aiTools,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.openai.chat/*",
                "~/Library/Caches/com.anthropic.claudefordesktop/*",
                "~/Library/Logs/Claude/*",
                "~/Library/Logs/com.openai.codex/*",
                "~/Library/Application Support/Codex/Cache/*",
                "~/Library/Application Support/Codex/Code Cache/*",
                "~/Library/Application Support/Codex/GPUCache/*",
                "~/Library/Application Support/Codex/DawnGraphiteCache/*",
                "~/Library/Application Support/Codex/DawnWebGPUCache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.openai.chat",
                "~/Library/Caches/com.anthropic.claudefordesktop",
                "~/Library/Logs/Claude",
                "~/Library/Logs/com.openai.codex",
                "~/Library/Application Support/Codex/Cache",
                "~/Library/Application Support/Codex/Code Cache",
                "~/Library/Application Support/Codex/GPUCache",
                "~/Library/Application Support/Codex/DawnGraphiteCache",
                "~/Library/Application Support/Codex/DawnWebGPUCache"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.creative-tools",
            legacyRuleID: "cache.creative-tools",
            category: .appCaches,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.bohemiancoding.sketch3/*",
                "~/Library/Application Support/com.bohemiancoding.sketch3/cache/*",
                "~/Library/Caches/Adobe/*",
                "~/Library/Caches/com.adobe.*/*",
                "~/Library/Caches/com.figma.Desktop/*",
                "~/Library/Application Support/Adobe/Common/Media Cache Files/*",
                "~/Library/Caches/net.telestream.screenflow10/*",
                "~/Library/Caches/com.apple.FinalCut/*",
                "~/Library/Caches/com.blackmagic-design.DaVinciResolve/*",
                "~/Movies/CacheClip/*",
                "~/Library/Caches/com.adobe.PremierePro.*/*",
                "~/Library/Caches/org.blenderfoundation.blender/*",
                "~/Library/Caches/com.maxon.cinema4d/*",
                "~/Library/Caches/com.autodesk.*/*",
                "~/Library/Caches/com.sketchup.*/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.bohemiancoding.sketch3",
                "~/Library/Application Support/com.bohemiancoding.sketch3/cache",
                "~/Library/Caches/Adobe",
                "~/Library/Caches",
                "~/Library/Caches/com.figma.Desktop",
                "~/Library/Application Support/Adobe/Common/Media Cache Files",
                "~/Library/Caches/net.telestream.screenflow10",
                "~/Library/Caches/com.apple.FinalCut",
                "~/Library/Caches/com.blackmagic-design.DaVinciResolve",
                "~/Movies/CacheClip",
                "~/Library/Caches/org.blenderfoundation.blender",
                "~/Library/Caches/com.maxon.cinema4d"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.productivity-media",
            legacyRuleID: "cache.productivity-media",
            category: .appCaches,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.tw93.MiaoYan/*",
                "~/Library/Caches/com.klee.desktop/*",
                "~/Library/Caches/klee_desktop/*",
                "~/Library/Caches/com.orabrowser.app/*",
                "~/Library/Caches/com.filo.client/*",
                "~/Library/Caches/com.flomoapp.mac/*",
                "~/Library/Application Support/Quark/Cache/videoCache/*",
                "~/.cache/kaku/*",
                "~/Library/Caches/com.spotify.client/*",
                "~/Library/Caches/com.apple.Music",
                "~/Library/Caches/com.apple.podcasts",
                "~/Library/Caches/com.apple.TV/*",
                "~/Library/Caches/tv.plex.player.desktop",
                "~/Library/Caches/com.netease.163music",
                "~/Library/Caches/com.tencent.QQMusic/*",
                "~/Library/Caches/com.kugou.mac/*",
                "~/Library/Caches/com.kuwo.mac/*",
                "~/Library/Caches/com.colliderli.iina",
                "~/Library/Caches/org.videolan.vlc",
                "~/Library/Caches/io.mpv",
                "~/Library/Caches/com.iqiyi.player",
                "~/Library/Caches/com.tencent.tenvideo",
                "~/Library/Caches/tv.danmaku.bili/*",
                "~/Library/Caches/com.douyu.*/*",
                "~/Library/Caches/com.huya.*/*",
                "~/Library/Caches/smart.stremio*/*",
                "~/Library/Application Support/stremio/stremio-server/stremio-cache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.tw93.MiaoYan",
                "~/Library/Caches/com.klee.desktop",
                "~/Library/Caches/klee_desktop",
                "~/Library/Caches/com.orabrowser.app",
                "~/Library/Caches/com.filo.client",
                "~/Library/Caches/com.flomoapp.mac",
                "~/Library/Application Support/Quark/Cache/videoCache",
                "~/.cache/kaku",
                "~/Library/Caches/com.spotify.client",
                "~/Library/Caches/com.apple.Music",
                "~/Library/Caches/com.apple.podcasts",
                "~/Library/Caches/com.apple.TV",
                "~/Library/Caches/tv.plex.player.desktop",
                "~/Library/Caches/com.netease.163music",
                "~/Library/Caches/com.tencent.QQMusic",
                "~/Library/Caches/com.kugou.mac",
                "~/Library/Caches/com.kuwo.mac",
                "~/Library/Caches/com.colliderli.iina",
                "~/Library/Caches/org.videolan.vlc",
                "~/Library/Caches/io.mpv",
                "~/Library/Caches/com.iqiyi.player",
                "~/Library/Caches/com.tencent.tenvideo",
                "~/Library/Caches/tv.danmaku.bili",
                "~/Library/Caches",
                "~/Library/Application Support/stremio/stremio-server/stremio-cache"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.productivity-media.containers",
            legacyRuleID: "cache.productivity-media",
            category: .appCaches,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Caches/*",
                "~/Library/Containers/com.ideasoncanvas.mindnode/Data/Library/Caches/*",
                "~/Library/Containers/com.apple.podcasts/Data/tmp/StreamedMedia",
                "~/Library/Containers/com.apple.podcasts/Data/tmp/*.heic",
                "~/Library/Containers/com.apple.podcasts/Data/tmp/*.img",
                "~/Library/Containers/com.apple.podcasts/Data/tmp/*CFNetworkDownload*.tmp"
            ]),
            reservedRootPaths: [
                "~/Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Caches",
                "~/Library/Containers/com.ideasoncanvas.mindnode/Data/Library/Caches",
                "~/Library/Containers/com.apple.podcasts/Data/tmp/StreamedMedia",
                "~/Library/Containers/com.apple.podcasts/Data/tmp"
            ],
            requiresFullDiskAccess: true
        ),
        DiskCleanRuleTarget(
            id: "cache.utilities",
            legacyRuleID: "cache.utilities",
            category: .appCaches,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/net.xmac.aria2gui",
                "~/Library/Caches/org.m0k.transmission",
                "~/Library/Caches/com.qbittorrent.qBittorrent",
                "~/Library/Caches/com.downie.Downie-*",
                "~/Library/Caches/com.folx.*/*",
                "~/Library/Caches/com.charlessoft.pacifist/*",
                "~/Library/Caches/com.youdao.YoudaoDict",
                "~/Library/Caches/com.eudic.*",
                "~/Library/Caches/com.bob-build.Bob",
                "~/Library/Caches/com.cleanshot.*",
                "~/Library/Caches/com.reincubate.camo",
                "~/Library/Caches/com.xnipapp.xnip",
                "~/Library/Caches/com.readdle.smartemail-Mac",
                "~/Library/Caches/com.airmail.*",
                "~/Library/Caches/com.todoist.mac.Todoist",
                "~/Library/Caches/com.any.do.*",
                "~/.zcompdump*",
                "~/.lesshst",
                "~/.viminfo.tmp",
                "~/.wget-hsts",
                "~/.cacher/logs/*",
                "~/.kite/logs/*",
                "~/Library/Caches/dev.warp.Warp-Stable/*",
                "~/Library/Logs/warp.log",
                "~/Library/Caches/SentryCrash/Warp/*",
                "~/Library/Caches/com.mitchellh.ghostty/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/net.xmac.aria2gui",
                "~/Library/Caches/org.m0k.transmission",
                "~/Library/Caches/com.qbittorrent.qBittorrent",
                "~/Library/Caches",
                "~/Library/Caches/com.charlessoft.pacifist",
                "~/Library/Caches/com.youdao.YoudaoDict",
                "~/Library/Caches/com.bob-build.Bob",
                "~/Library/Caches/com.reincubate.camo",
                "~/Library/Caches/com.xnipapp.xnip",
                "~/Library/Caches/com.readdle.smartemail-Mac",
                "~/Library/Caches/com.todoist.mac.Todoist",
                "~",
                "~/.lesshst",
                "~/.viminfo.tmp",
                "~/.wget-hsts",
                "~/.cacher/logs",
                "~/.kite/logs",
                "~/Library/Caches/dev.warp.Warp-Stable",
                "~/Library/Logs/warp.log",
                "~/Library/Caches/SentryCrash/Warp",
                "~/Library/Caches/com.mitchellh.ghostty"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.games-notes-remote",
            legacyRuleID: "cache.games-notes-remote",
            category: .appCaches,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.valvesoftware.steam/*",
                "~/Library/Application Support/Steam/htmlcache/*",
                "~/Library/Application Support/Steam/appcache/*",
                "~/Library/Application Support/Steam/depotcache/*",
                "~/Library/Application Support/Steam/steamapps/shadercache/*",
                "~/Library/Application Support/Steam/logs/*",
                "~/Library/Caches/com.epicgames.EpicGamesLauncher/*",
                "~/Library/Caches/com.blizzard.Battle.net/*",
                "~/Library/Application Support/Battle.net/Cache/*",
                "~/Library/Caches/com.ea.*/*",
                "~/Library/Caches/com.gog.galaxy/*",
                "~/Library/Caches/com.riotgames.*/*",
                "~/Library/Application Support/minecraft/logs/*",
                "~/Library/Application Support/minecraft/crash-reports/*",
                "~/Library/Application Support/minecraft/webcache/*",
                "~/Library/Application Support/minecraft/webcache2/*",
                "~/.lunarclient/game-cache/*",
                "~/.lunarclient/launcher-cache/*",
                "~/.lunarclient/logs/*",
                "~/.lunarclient/offline/*/logs/*",
                "~/.lunarclient/offline/files/*/logs/*",
                "~/Library/Caches/net.pcsx2.PCSX2/*",
                "~/Library/Application Support/PCSX2/cache/*",
                "~/Library/Logs/PCSX2/*",
                "~/Library/Caches/net.rpcs3.rpcs3/*",
                "~/Library/Application Support/rpcs3/logs/*",
                "~/Library/Caches/notion.id/*",
                "~/Library/Caches/md.obsidian/*",
                "~/Library/Caches/com.logseq.*/*",
                "~/Library/Caches/com.bear-writer.*/*",
                "~/Library/Caches/com.evernote.*/*",
                "~/Library/Caches/com.yinxiang.*/*",
                "~/Library/Caches/com.teamviewer.*/*",
                "~/Library/Caches/com.anydesk.*/*",
                "~/Library/Caches/com.todesk.*/*",
                "~/Library/Caches/com.sunlogin.*/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.valvesoftware.steam",
                "~/Library/Application Support/Steam/htmlcache",
                "~/Library/Application Support/Steam/appcache",
                "~/Library/Application Support/Steam/depotcache",
                "~/Library/Application Support/Steam/steamapps/shadercache",
                "~/Library/Application Support/Steam/logs",
                "~/Library/Caches/com.epicgames.EpicGamesLauncher",
                "~/Library/Caches/com.blizzard.Battle.net",
                "~/Library/Application Support/Battle.net/Cache",
                "~/Library/Caches",
                "~/Library/Caches/com.gog.galaxy",
                "~/Library/Application Support/minecraft/logs",
                "~/Library/Application Support/minecraft/crash-reports",
                "~/Library/Application Support/minecraft/webcache",
                "~/Library/Application Support/minecraft/webcache2",
                "~/.lunarclient/game-cache",
                "~/.lunarclient/launcher-cache",
                "~/.lunarclient/logs",
                "~/.lunarclient/offline",
                "~/.lunarclient/offline/files",
                "~/Library/Caches/net.pcsx2.PCSX2",
                "~/Library/Application Support/PCSX2/cache",
                "~/Library/Logs/PCSX2",
                "~/Library/Caches/net.rpcs3.rpcs3",
                "~/Library/Application Support/rpcs3/logs",
                "~/Library/Caches/notion.id",
                "~/Library/Caches/md.obsidian"
            ]
        ),
        DiskCleanRuleTarget(
            id: "cache.launchers-system-utils",
            legacyRuleID: "cache.launchers-system-utils",
            category: .appCaches,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.runningwithcrayons.Alfred/*",
                "~/Library/Caches/cx.c3.theunarchiver/*",
                "~/Library/Caches/com.raycast.macos/urlcache/*",
                "~/Library/Caches/com.raycast.macos/fsCachedData/*",
                "~/Library/Caches/com.runjuu.Input-Source-Pro/*",
                "~/Library/Caches/macos-wakatime.WakaTime/*",
                "~/Library/Application Support/WeType/com.onevcat.Kingfisher.ImageCache.WeType/*",
                "~/Library/Application Support/WeType/DictUpdate/*",
                "~/Library/Application Support/mihomo-party/Cache/*",
                "~/Library/Application Support/mihomo-party/Code Cache/*",
                "~/Library/Application Support/mihomo-party/GPUCache/*",
                "~/Library/Application Support/mihomo-party/DawnGraphiteCache/*",
                "~/Library/Application Support/mihomo-party/DawnWebGPUCache/*",
                "~/Library/Application Support/mihomo-party/logs/*",
                "~/Library/Caches/ws.stash.app.mac/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.runningwithcrayons.Alfred",
                "~/Library/Caches/cx.c3.theunarchiver",
                "~/Library/Caches/com.raycast.macos/urlcache",
                "~/Library/Caches/com.raycast.macos/fsCachedData",
                "~/Library/Caches/com.runjuu.Input-Source-Pro",
                "~/Library/Caches/macos-wakatime.WakaTime",
                "~/Library/Application Support/WeType/com.onevcat.Kingfisher.ImageCache.WeType",
                "~/Library/Application Support/WeType/DictUpdate",
                "~/Library/Application Support/mihomo-party/Cache",
                "~/Library/Application Support/mihomo-party/Code Cache",
                "~/Library/Application Support/mihomo-party/GPUCache",
                "~/Library/Application Support/mihomo-party/DawnGraphiteCache",
                "~/Library/Application Support/mihomo-party/DawnWebGPUCache",
                "~/Library/Application Support/mihomo-party/logs",
                "~/Library/Caches/ws.stash.app.mac"
            ]
        )
    ]

    // MARK: - 开发者产物与工具缓存（v1 `developer.*` 规则）

    private static let developerTargets: [DiskCleanRuleTarget] = [
        DiskCleanRuleTarget(
            id: "developer.xcode-derived-data",
            legacyRuleID: "developer.xcode-derived-data",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Developer/Xcode/DerivedData/*"
            ]),
            reservedRootPaths: [
                "~/Library/Developer/Xcode/DerivedData"
            ],
            lockedByBundleIDs: [
                "com.apple.dt.Xcode"
            ],
            skipWhenProcessIsRunning: [
                "Xcode"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.xcode-user-caches",
            legacyRuleID: "developer.xcode-user-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.apple.dt.Xcode/*",
                "~/Library/Developer/Xcode/iOS Device Logs/*",
                "~/Library/Developer/Xcode/watchOS Device Logs/*",
                "~/Library/Developer/Xcode/Products/*",
                "~/Library/Developer/Xcode/Archives/*",
                "~/Library/Developer/Xcode/DocumentationCache/*",
                "~/Library/Developer/Xcode/DocumentationIndex/*",
                "~/Library/Developer/Xcode/UserData/IB Support/*",
                "~/Library/Developer/Xcode/iOS DeviceSupport/*/Symbols/System/Library/Caches/*",
                "~/Library/Developer/Xcode/iOS DeviceSupport/*.log",
                "~/Library/Developer/Xcode/watchOS DeviceSupport/*/Symbols/System/Library/Caches/*",
                "~/Library/Developer/Xcode/watchOS DeviceSupport/*.log",
                "~/Library/Developer/Xcode/tvOS DeviceSupport/*/Symbols/System/Library/Caches/*",
                "~/Library/Developer/Xcode/tvOS DeviceSupport/*.log"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.apple.dt.Xcode",
                "~/Library/Developer/Xcode/iOS Device Logs",
                "~/Library/Developer/Xcode/watchOS Device Logs",
                "~/Library/Developer/Xcode/Products",
                "~/Library/Developer/Xcode/Archives",
                "~/Library/Developer/Xcode/DocumentationCache",
                "~/Library/Developer/Xcode/DocumentationIndex",
                "~/Library/Developer/Xcode/UserData/IB Support",
                "~/Library/Developer/Xcode/iOS DeviceSupport",
                "~/Library/Developer/Xcode/watchOS DeviceSupport",
                "~/Library/Developer/Xcode/tvOS DeviceSupport"
            ],
            lockedByBundleIDs: [
                "com.apple.dt.Xcode"
            ],
            skipWhenProcessIsRunning: [
                "Xcode"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.simulator-unavailable",
            legacyRuleID: "developer.simulator-unavailable",
            category: .developer,
            risk: .medium,
            kind: .dynamic(provider: DiskCleanDynamicRuleProviders.unavailableSimulators),
            reservedRootPaths: [
                "~/Library/Developer/CoreSimulator/Devices"
            ],
            lockedByBundleIDs: [
                "com.apple.iphonesimulator"
            ],
            skipWhenProcessIsRunning: [
                "Simulator"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.simulator-caches",
            legacyRuleID: "developer.simulator-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Developer/CoreSimulator/Caches/*",
                "~/Library/Developer/CoreSimulator/Devices/*/data/tmp/*",
                "~/Library/Logs/CoreSimulator/*",
                "~/Library/Developer/CoreSimulator/Profiles/Runtimes/*/Contents/Resources/RuntimeRoot/System/Library/Caches/*"
            ]),
            reservedRootPaths: [
                "~/Library/Developer/CoreSimulator/Caches",
                "~/Library/Developer/CoreSimulator/Devices",
                "~/Library/Logs/CoreSimulator",
                "~/Library/Developer/CoreSimulator/Profiles/Runtimes"
            ],
            lockedByBundleIDs: [
                "com.apple.iphonesimulator"
            ],
            skipWhenProcessIsRunning: [
                "Simulator"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.package-manager-dynamic-caches",
            legacyRuleID: "developer.package-manager-dynamic-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/.cache/go-build/*",
                "~/Library/Caches/mise/*"
            ]),
            reservedRootPaths: [
                "~/.cache/go-build",
                "~/Library/Caches/mise"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.javascript-caches",
            legacyRuleID: "developer.javascript-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/.npm/_cacache/*",
                "~/.npm/_npx/*",
                "~/.npm/_logs/*",
                "~/.npm/_prebuilds/*",
                "~/Library/pnpm/store/*",
                "~/.bun/install/cache/*",
                "~/.tnpm/_cacache/*",
                "~/.tnpm/_logs/*",
                "~/.yarn/cache/*",
                "~/Library/Caches/Yarn/*",
                "~/.cache/typescript/*",
                "~/.cache/electron/*",
                "~/.cache/node-gyp/*",
                "~/.node-gyp/*",
                "~/.turbo/cache/*",
                "~/.vite/cache/*",
                "~/.cache/vite/*",
                "~/.cache/webpack/*",
                "~/.parcel-cache/*",
                "~/.cache/eslint/*",
                "~/.cache/prettier/*"
            ]),
            reservedRootPaths: [
                "~/.npm/_cacache",
                "~/.npm/_npx",
                "~/.npm/_logs",
                "~/.npm/_prebuilds",
                "~/Library/pnpm/store",
                "~/.bun/install/cache",
                "~/.tnpm/_cacache",
                "~/.tnpm/_logs",
                "~/.yarn/cache",
                "~/Library/Caches/Yarn",
                "~/.cache/typescript",
                "~/.cache/electron",
                "~/.cache/node-gyp",
                "~/.node-gyp",
                "~/.turbo/cache",
                "~/.vite/cache",
                "~/.cache/vite",
                "~/.cache/webpack",
                "~/.parcel-cache",
                "~/.cache/eslint",
                "~/.cache/prettier"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.python-caches",
            legacyRuleID: "developer.python-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/pip/*",
                "~/.cache/pip/*",
                "~/.pyenv/cache/*",
                "~/.cache/poetry/*",
                "~/.cache/uv/*",
                "~/.cache/ruff/*",
                "~/.cache/mypy/*",
                "~/.pytest_cache/*",
                "~/.jupyter/runtime/*",
                "~/.cache/huggingface/*",
                "~/.cache/torch/*",
                "~/.cache/tensorflow/*",
                "~/.conda/pkgs/*",
                "~/anaconda3/pkgs/*",
                "~/.cache/wandb/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/pip",
                "~/.cache/pip",
                "~/.pyenv/cache",
                "~/.cache/poetry",
                "~/.cache/uv",
                "~/.cache/ruff",
                "~/.cache/mypy",
                "~/.pytest_cache",
                "~/.jupyter/runtime",
                "~/.cache/huggingface",
                "~/.cache/torch",
                "~/.cache/tensorflow",
                "~/.conda/pkgs",
                "~/anaconda3/pkgs",
                "~/.cache/wandb"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.rust-go",
            legacyRuleID: "developer.rust-go-docker",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/.cargo/registry/cache/*",
                "~/.cargo/git/*",
                "~/.rustup/downloads/*",
                "~/Library/Caches/go-build/*",
                "~/go/pkg/mod/*"
            ]),
            reservedRootPaths: [
                "~/.cargo/registry/cache",
                "~/.cargo/git",
                "~/.rustup/downloads",
                "~/Library/Caches/go-build",
                "~/go/pkg/mod"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.docker",
            legacyRuleID: "developer.rust-go-docker",
            category: .developer,
            risk: .medium,
            kind: .path(globs: [
                "~/.docker/buildx/cache/*"
            ]),
            reservedRootPaths: [
                "~/.docker/buildx/cache"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.mobile-caches",
            legacyRuleID: "developer.mobile-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/Google/AndroidStudio*/*",
                "~/.android/build-cache/*",
                "~/.android/cache/*",
                "~/.cache/swift-package-manager/*",
                "~/Library/Caches/org.swift.swiftpm/*",
                "~/.expo/expo-go/*",
                "~/.expo/android-apk-cache/*",
                "~/.expo/ios-simulator-app-cache/*",
                "~/.expo/native-modules-cache/*",
                "~/.expo/schema-cache/*",
                "~/.expo/template-cache/*",
                "~/.expo/versions-cache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/Google",
                "~/.android/build-cache",
                "~/.android/cache",
                "~/.cache/swift-package-manager",
                "~/Library/Caches/org.swift.swiftpm",
                "~/.expo/expo-go",
                "~/.expo/android-apk-cache",
                "~/.expo/ios-simulator-app-cache",
                "~/.expo/native-modules-cache",
                "~/.expo/schema-cache",
                "~/.expo/template-cache",
                "~/.expo/versions-cache"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.jvm-caches",
            legacyRuleID: "developer.jvm-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/.m2/repository/*",
                "~/.sbt/*",
                "~/.ivy2/cache/*",
                "~/.gradle/caches/*",
                "~/.gradle/daemon/*"
            ]),
            reservedRootPaths: [
                "~/.m2/repository",
                "~/.sbt",
                "~/.ivy2/cache",
                "~/.gradle/caches",
                "~/.gradle/daemon"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.jetbrains-toolbox-old-versions",
            legacyRuleID: "developer.jetbrains-toolbox-old-versions",
            category: .developer,
            risk: .medium,
            kind: .dynamic(provider: DiskCleanDynamicRuleProviders.jetbrainsToolboxOldVersions),
            reservedRootPaths: [
                "~/Library/Application Support/JetBrains/Toolbox/apps"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.ai-agent-old-versions",
            legacyRuleID: "developer.ai-agent-old-versions",
            category: .aiTools,
            risk: .medium,
            kind: .dynamic(provider: DiskCleanDynamicRuleProviders.aiAgentOldVersions),
            reservedRootPaths: [
                "~/.local/share/claude/versions",
                "~/.claude/versions",
                "~/.codex/versions",
                "~/.local/share/opencode/versions"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.editor-caches",
            legacyRuleID: "developer.editor-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Application Support/Code/logs/*",
                "~/Library/Application Support/Code/Cache/*",
                "~/Library/Application Support/Code/CachedExtensions/*",
                "~/Library/Application Support/Code/CachedData/*",
                "~/Library/Application Support/Code/DawnGraphiteCache/*",
                "~/Library/Application Support/Code/DawnWebGPUCache/*",
                "~/Library/Application Support/Code/GPUCache/*",
                "~/Library/Application Support/Code/CachedExtensionVSIXs/*",
                "~/Library/Application Support/Code/Service Worker/ScriptCache/*",
                "~/Library/Caches/com.microsoft.VSCode/Cache/*",
                "~/Library/Caches/com.sublimetext.*/*",
                "~/Library/Caches/Zed/*",
                "~/Library/Logs/Zed/*",
                "~/Library/Caches/copilot/*",
                "~/.cache/vscode-ripgrep/*",
                "~/Library/Caches/Cursor/*",
                "~/Library/Application Support/Cursor/CachedData/*",
                "~/Library/Application Support/Cursor/CachedExtensionVSIXs/*",
                "~/Library/Application Support/Cursor/GPUCache/*",
                "~/Library/Application Support/Cursor/DawnGraphiteCache/*",
                "~/Library/Application Support/Cursor/DawnWebGPUCache/*",
                "~/Library/Application Support/Cursor/Service Worker/ScriptCache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Application Support/Code/logs",
                "~/Library/Application Support/Code/Cache",
                "~/Library/Application Support/Code/CachedExtensions",
                "~/Library/Application Support/Code/CachedData",
                "~/Library/Application Support/Code/DawnGraphiteCache",
                "~/Library/Application Support/Code/DawnWebGPUCache",
                "~/Library/Application Support/Code/GPUCache",
                "~/Library/Application Support/Code/CachedExtensionVSIXs",
                "~/Library/Application Support/Code/Service Worker/ScriptCache",
                "~/Library/Caches/com.microsoft.VSCode/Cache",
                "~/Library/Caches",
                "~/Library/Caches/Zed",
                "~/Library/Logs/Zed",
                "~/Library/Caches/copilot",
                "~/.cache/vscode-ripgrep",
                "~/Library/Caches/Cursor",
                "~/Library/Application Support/Cursor/CachedData",
                "~/Library/Application Support/Cursor/CachedExtensionVSIXs",
                "~/Library/Application Support/Cursor/GPUCache",
                "~/Library/Application Support/Cursor/DawnGraphiteCache",
                "~/Library/Application Support/Cursor/DawnWebGPUCache",
                "~/Library/Application Support/Cursor/Service Worker/ScriptCache"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.cloud-devops-caches",
            legacyRuleID: "developer.cloud-devops-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/.kube/cache/*",
                "~/.local/share/containers/storage/tmp/*",
                "~/.aws/cli/cache/*",
                "~/.config/gcloud/logs/*",
                "~/.azure/logs/*",
                "~/.cache/terraform/*",
                "~/.grafana/cache/*",
                "~/.prometheus/data/wal/*",
                "~/.jenkins/workspace/*/target/*",
                "~/.cache/gitlab-runner/*",
                "~/.github/cache/*",
                "~/.circleci/cache/*",
                "~/.sonar/*"
            ]),
            reservedRootPaths: [
                "~/.kube/cache",
                "~/.local/share/containers/storage/tmp",
                "~/.aws/cli/cache",
                "~/.config/gcloud/logs",
                "~/.azure/logs",
                "~/.cache/terraform",
                "~/.grafana/cache",
                "~/.prometheus/data/wal",
                "~/.jenkins/workspace",
                "~/.cache/gitlab-runner",
                "~/.github/cache",
                "~/.circleci/cache",
                "~/.sonar"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.language-caches",
            legacyRuleID: "developer.language-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/.bundle/cache/*",
                "~/.composer/cache/*",
                "~/Library/Caches/composer/*",
                "~/.nuget/packages/*",
                "~/.cache/bazel/*",
                "~/.cache/zig/*",
                "~/Library/Caches/deno/*",
                "~/.hex/cache/*",
                "~/.cabal/packages/*",
                "~/.opam/download-cache/*"
            ]),
            reservedRootPaths: [
                "~/.bundle/cache",
                "~/.composer/cache",
                "~/Library/Caches/composer",
                "~/.nuget/packages",
                "~/.cache/bazel",
                "~/.cache/zig",
                "~/Library/Caches/deno",
                "~/.hex/cache",
                "~/.cabal/packages",
                "~/.opam/download-cache"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.database-api-caches",
            legacyRuleID: "developer.database-api-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.sequel-ace.sequel-ace/*",
                "~/Library/Caches/com.eggerapps.Sequel-Pro/*",
                "~/Library/Caches/redis-desktop-manager/*",
                "~/Library/Caches/com.navicat.*",
                "~/Library/Caches/com.dbeaver.*",
                "~/Library/Caches/com.redis.RedisInsight",
                "~/Library/Caches/com.postmanlabs.mac/*",
                "~/Library/Caches/com.konghq.insomnia/*",
                "~/Library/Caches/com.tinyapp.TablePlus/*",
                "~/Library/Caches/com.getpaw.Paw/*",
                "~/Library/Caches/com.charlesproxy.charles/*",
                "~/Library/Caches/com.proxyman.NSProxy/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.sequel-ace.sequel-ace",
                "~/Library/Caches/com.eggerapps.Sequel-Pro",
                "~/Library/Caches/redis-desktop-manager",
                "~/Library/Caches",
                "~/Library/Caches/com.redis.RedisInsight",
                "~/Library/Caches/com.postmanlabs.mac",
                "~/Library/Caches/com.konghq.insomnia",
                "~/Library/Caches/com.tinyapp.TablePlus",
                "~/Library/Caches/com.getpaw.Paw",
                "~/Library/Caches/com.charlesproxy.charles",
                "~/Library/Caches/com.proxyman.NSProxy"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.misc-caches",
            legacyRuleID: "developer.misc-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.unity3d.*/*",
                "~/Library/Caches/com.mongodb.compass/*",
                "~/Library/Caches/com.github.GitHubDesktop/*",
                "~/Library/Caches/SentryCrash/*",
                "~/Library/Caches/KSCrash/*",
                "~/Library/Caches/com.crashlytics.data/*",
                "~/Library/Application Support/Antigravity/Cache/*",
                "~/Library/Application Support/Antigravity/Code Cache/*",
                "~/Library/Application Support/Antigravity/GPUCache/*",
                "~/Library/Application Support/Antigravity/DawnGraphiteCache/*",
                "~/Library/Application Support/Antigravity/DawnWebGPUCache/*",
                "~/Library/Application Support/Filo/production/Cache/*",
                "~/Library/Application Support/Filo/production/Code Cache/*",
                "~/Library/Application Support/Filo/production/GPUCache/*",
                "~/Library/Application Support/Filo/production/DawnGraphiteCache/*",
                "~/Library/Application Support/Filo/production/DawnWebGPUCache/*",
                "~/Library/Application Support/Claude/Cache/*",
                "~/Library/Application Support/Claude/Code Cache/*",
                "~/Library/Application Support/Claude/GPUCache/*",
                "~/Library/Application Support/Claude/DawnGraphiteCache/*",
                "~/Library/Application Support/Claude/DawnWebGPUCache/*",
                "~/Library/Application Support/Claude/sentry/*",
                "~/Library/Application Support/Claude/pending-uploads/*",
                "~/Library/Application Support/Qoder/Cache/*",
                "~/Library/Application Support/Qoder/CachedData/*",
                "~/Library/Application Support/Qoder/CachedExtensionVSIXs/*",
                "~/Library/Application Support/Qoder/Code Cache/*",
                "~/Library/Application Support/Qoder/GPUCache/*",
                "~/Library/Application Support/Qoder/DawnGraphiteCache/*",
                "~/Library/Application Support/Qoder/DawnWebGPUCache/*",
                "~/Library/Application Support/Qoder/logs/*",
                "~/.cache/prisma/*",
                "~/.cache/opencode/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches",
                "~/Library/Caches/com.mongodb.compass",
                "~/Library/Caches/com.github.GitHubDesktop",
                "~/Library/Caches/SentryCrash",
                "~/Library/Caches/KSCrash",
                "~/Library/Caches/com.crashlytics.data",
                "~/Library/Application Support/Antigravity/Cache",
                "~/Library/Application Support/Antigravity/Code Cache",
                "~/Library/Application Support/Antigravity/GPUCache",
                "~/Library/Application Support/Antigravity/DawnGraphiteCache",
                "~/Library/Application Support/Antigravity/DawnWebGPUCache",
                "~/Library/Application Support/Filo/production/Cache",
                "~/Library/Application Support/Filo/production/Code Cache",
                "~/Library/Application Support/Filo/production/GPUCache",
                "~/Library/Application Support/Filo/production/DawnGraphiteCache",
                "~/Library/Application Support/Filo/production/DawnWebGPUCache",
                "~/Library/Application Support/Claude/Cache",
                "~/Library/Application Support/Claude/Code Cache",
                "~/Library/Application Support/Claude/GPUCache",
                "~/Library/Application Support/Claude/DawnGraphiteCache",
                "~/Library/Application Support/Claude/DawnWebGPUCache",
                "~/Library/Application Support/Claude/sentry",
                "~/Library/Application Support/Claude/pending-uploads",
                "~/Library/Application Support/Qoder/Cache",
                "~/Library/Application Support/Qoder/CachedData",
                "~/Library/Application Support/Qoder/CachedExtensionVSIXs",
                "~/Library/Application Support/Qoder/Code Cache",
                "~/Library/Application Support/Qoder/GPUCache",
                "~/Library/Application Support/Qoder/DawnGraphiteCache",
                "~/Library/Application Support/Qoder/DawnWebGPUCache",
                "~/Library/Application Support/Qoder/logs",
                "~/.cache/prisma",
                "~/.cache/opencode"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.shell-network-caches",
            legacyRuleID: "developer.shell-network-caches",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/.gitconfig.lock",
                "~/.gitconfig.bak*",
                "~/.oh-my-zsh/cache/*",
                "~/.config/fish/fish_history.bak*",
                "~/.bash_history.bak*",
                "~/.zsh_history.bak*",
                "~/.cache/pre-commit/*",
                "~/.cache/curl/*",
                "~/.cache/wget/*",
                "~/Library/Caches/curl/*",
                "~/Library/Caches/wget/*"
            ]),
            reservedRootPaths: [
                "~/.gitconfig.lock",
                "~",
                "~/.oh-my-zsh/cache",
                "~/.config/fish",
                "~/.cache/pre-commit",
                "~/.cache/curl",
                "~/.cache/wget",
                "~/Library/Caches/curl",
                "~/Library/Caches/wget"
            ]
        ),
        DiskCleanRuleTarget(
            id: "developer.homebrew",
            legacyRuleID: "developer.homebrew",
            category: .developer,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/Homebrew/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/Homebrew"
            ]
        )
    ]

    // MARK: - 浏览器缓存（v1 `browser.*` 规则）

    private static let browserTargets: [DiskCleanRuleTarget] = [
        DiskCleanRuleTarget(
            id: "browser.safari",
            legacyRuleID: "browser.safari",
            category: .browsers,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.apple.Safari/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.apple.Safari"
            ],
            requiresFullDiskAccess: true
        ),
        DiskCleanRuleTarget(
            id: "browser.chrome",
            legacyRuleID: "browser.chrome",
            category: .browsers,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/Google/Chrome/*",
                "~/Library/Application Support/Google/Chrome/*/Application Cache/*",
                "~/Library/Application Support/Google/Chrome/*/GPUCache/*",
                "~/Library/Application Support/Google/Chrome/component_crx_cache/*",
                "~/Library/Application Support/Google/Chrome/ShaderCache/*",
                "~/Library/Application Support/Google/Chrome/GrShaderCache/*",
                "~/Library/Application Support/Google/Chrome/GraphiteDawnCache/*",
                "~/Library/Application Support/Google/GoogleUpdater/crx_cache/*",
                "~/Library/Application Support/Google/GoogleUpdater/*.old",
                "~/Library/Caches/Chromium/*",
                "~/.cache/puppeteer/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/Google/Chrome",
                "~/Library/Application Support/Google/Chrome",
                "~/Library/Application Support/Google/Chrome/component_crx_cache",
                "~/Library/Application Support/Google/Chrome/ShaderCache",
                "~/Library/Application Support/Google/Chrome/GrShaderCache",
                "~/Library/Application Support/Google/Chrome/GraphiteDawnCache",
                "~/Library/Application Support/Google/GoogleUpdater/crx_cache",
                "~/Library/Application Support/Google/GoogleUpdater",
                "~/Library/Caches/Chromium",
                "~/.cache/puppeteer"
            ],
            lockedByBundleIDs: [
                "com.google.Chrome"
            ],
            skipWhenProcessIsRunning: [
                "Google Chrome"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.chrome.service-worker",
            legacyRuleID: "browser.chrome",
            category: .browsers,
            risk: .medium,
            kind: .path(globs: [
                "~/Library/Application Support/Google/Chrome/*/Service Worker/ScriptCache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Application Support/Google/Chrome"
            ],
            lockedByBundleIDs: [
                "com.google.Chrome"
            ],
            skipWhenProcessIsRunning: [
                "Google Chrome"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.edge",
            legacyRuleID: "browser.edge",
            category: .browsers,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.microsoft.edgemac/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.microsoft.edgemac"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.arc-dia",
            legacyRuleID: "browser.arc-dia",
            category: .browsers,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/company.thebrowser.Browser/*",
                "~/Library/Application Support/Arc/*/GPUCache/*",
                "~/Library/Application Support/Arc/ShaderCache/*",
                "~/Library/Application Support/Arc/GrShaderCache/*",
                "~/Library/Application Support/Arc/GraphiteDawnCache/*",
                "~/Library/Caches/company.thebrowser.dia/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/company.thebrowser.Browser",
                "~/Library/Application Support/Arc",
                "~/Library/Application Support/Arc/ShaderCache",
                "~/Library/Application Support/Arc/GrShaderCache",
                "~/Library/Application Support/Arc/GraphiteDawnCache",
                "~/Library/Caches/company.thebrowser.dia"
            ],
            lockedByBundleIDs: [
                "company.thebrowser.Browser"
            ],
            skipWhenProcessIsRunning: [
                "Arc"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.arc-dia.service-worker",
            legacyRuleID: "browser.arc-dia",
            category: .browsers,
            risk: .medium,
            kind: .path(globs: [
                "~/Library/Application Support/Arc/*/Service Worker/ScriptCache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Application Support/Arc"
            ],
            lockedByBundleIDs: [
                "company.thebrowser.Browser"
            ],
            skipWhenProcessIsRunning: [
                "Arc"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.brave",
            legacyRuleID: "browser.brave",
            category: .browsers,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/BraveSoftware/Brave-Browser/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/*/Application Cache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/*/GPUCache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/component_crx_cache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/ShaderCache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/GrShaderCache/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/GraphiteDawnCache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/BraveSoftware/Brave-Browser",
                "~/Library/Application Support/BraveSoftware/Brave-Browser",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/component_crx_cache",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/ShaderCache",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/GrShaderCache",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/GraphiteDawnCache"
            ],
            lockedByBundleIDs: [
                "com.brave.Browser"
            ],
            skipWhenProcessIsRunning: [
                "Brave Browser"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.brave.service-worker",
            legacyRuleID: "browser.brave",
            category: .browsers,
            risk: .medium,
            kind: .path(globs: [
                "~/Library/Application Support/BraveSoftware/Brave-Browser/*/Service Worker/ScriptCache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Application Support/BraveSoftware/Brave-Browser"
            ],
            lockedByBundleIDs: [
                "com.brave.Browser"
            ],
            skipWhenProcessIsRunning: [
                "Brave Browser"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.helium-yandex",
            legacyRuleID: "browser.helium-yandex",
            category: .browsers,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/net.imput.helium/*",
                "~/Library/Application Support/net.imput.helium/*/GPUCache/*",
                "~/Library/Application Support/net.imput.helium/component_crx_cache/*",
                "~/Library/Application Support/net.imput.helium/extensions_crx_cache/*",
                "~/Library/Application Support/net.imput.helium/GrShaderCache/*",
                "~/Library/Application Support/net.imput.helium/GraphiteDawnCache/*",
                "~/Library/Application Support/net.imput.helium/ShaderCache/*",
                "~/Library/Application Support/net.imput.helium/*/Application Cache/*",
                "~/Library/Caches/Yandex/YandexBrowser/*",
                "~/Library/Application Support/Yandex/YandexBrowser/ShaderCache/*",
                "~/Library/Application Support/Yandex/YandexBrowser/GrShaderCache/*",
                "~/Library/Application Support/Yandex/YandexBrowser/GraphiteDawnCache/*",
                "~/Library/Application Support/Yandex/YandexBrowser/*/GPUCache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/net.imput.helium",
                "~/Library/Application Support/net.imput.helium",
                "~/Library/Application Support/net.imput.helium/component_crx_cache",
                "~/Library/Application Support/net.imput.helium/extensions_crx_cache",
                "~/Library/Application Support/net.imput.helium/GrShaderCache",
                "~/Library/Application Support/net.imput.helium/GraphiteDawnCache",
                "~/Library/Application Support/net.imput.helium/ShaderCache",
                "~/Library/Caches/Yandex/YandexBrowser",
                "~/Library/Application Support/Yandex/YandexBrowser/ShaderCache",
                "~/Library/Application Support/Yandex/YandexBrowser/GrShaderCache",
                "~/Library/Application Support/Yandex/YandexBrowser/GraphiteDawnCache",
                "~/Library/Application Support/Yandex/YandexBrowser"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.firefox",
            legacyRuleID: "browser.firefox",
            category: .browsers,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/Firefox/*",
                "~/Library/Application Support/Firefox/Profiles/*/cache2/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/Firefox",
                "~/Library/Application Support/Firefox/Profiles"
            ],
            lockedByBundleIDs: [
                "org.mozilla.firefox"
            ],
            skipWhenProcessIsRunning: [
                "Firefox"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.opera-vivaldi",
            legacyRuleID: "browser.opera-vivaldi",
            category: .browsers,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/com.operasoftware.Opera/*",
                "~/Library/Caches/com.vivaldi.Vivaldi/*",
                "~/Library/Application Support/Vivaldi/*/GPUCache/*",
                "~/Library/Application Support/Vivaldi/ShaderCache/*",
                "~/Library/Application Support/Vivaldi/GrShaderCache/*",
                "~/Library/Application Support/Vivaldi/GraphiteDawnCache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/com.operasoftware.Opera",
                "~/Library/Caches/com.vivaldi.Vivaldi",
                "~/Library/Application Support/Vivaldi",
                "~/Library/Application Support/Vivaldi/ShaderCache",
                "~/Library/Application Support/Vivaldi/GrShaderCache",
                "~/Library/Application Support/Vivaldi/GraphiteDawnCache"
            ],
            lockedByBundleIDs: [
                "com.vivaldi.Vivaldi"
            ],
            skipWhenProcessIsRunning: [
                "Vivaldi"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.opera-vivaldi.service-worker",
            legacyRuleID: "browser.opera-vivaldi",
            category: .browsers,
            risk: .medium,
            kind: .path(globs: [
                "~/Library/Application Support/Vivaldi/*/Service Worker/ScriptCache/*"
            ]),
            reservedRootPaths: [
                "~/Library/Application Support/Vivaldi"
            ],
            lockedByBundleIDs: [
                "com.vivaldi.Vivaldi"
            ],
            skipWhenProcessIsRunning: [
                "Vivaldi"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.comet-orion-zen",
            legacyRuleID: "browser.comet-orion-zen",
            category: .browsers,
            risk: .low,
            kind: .path(globs: [
                "~/Library/Caches/Comet/*",
                "~/Library/Caches/com.kagi.kagimacOS/*",
                "~/Library/Caches/zen/*"
            ]),
            reservedRootPaths: [
                "~/Library/Caches/Comet",
                "~/Library/Caches/com.kagi.kagimacOS",
                "~/Library/Caches/zen"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.service-worker",
            legacyRuleID: "browser.service-worker",
            category: .browsers,
            risk: .medium,
            kind: .path(globs: [
                "~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage/*/*",
                "~/Library/Application Support/Arc/*/Service Worker/CacheStorage/*/*",
                "~/Library/Application Support/BraveSoftware/Brave-Browser/*/Service Worker/CacheStorage/*/*",
                "~/Library/Application Support/Vivaldi/*/Service Worker/CacheStorage/*/*"
            ]),
            reservedRootPaths: [
                "~/Library/Application Support/Google/Chrome",
                "~/Library/Application Support/Arc",
                "~/Library/Application Support/BraveSoftware/Brave-Browser",
                "~/Library/Application Support/Vivaldi"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.service-worker.editors",
            legacyRuleID: "browser.service-worker",
            category: .developer,
            risk: .medium,
            kind: .path(globs: [
                "~/Library/Application Support/Code/Service Worker/CacheStorage/*/*",
                "~/Library/Application Support/Cursor/Service Worker/CacheStorage/*/*"
            ]),
            reservedRootPaths: [
                "~/Library/Application Support/Code/Service Worker/CacheStorage",
                "~/Library/Application Support/Cursor/Service Worker/CacheStorage"
            ]
        ),
        DiskCleanRuleTarget(
            id: "browser.old-versions",
            legacyRuleID: "browser.old-versions",
            category: .browsers,
            risk: .medium,
            kind: .dynamic(provider: DiskCleanDynamicRuleProviders.oldBrowserVersions),
            reservedRootPaths: [
                "~/Library/Application Support/Google/GoogleUpdater",
                "~/Library/Application Support/Microsoft/EdgeUpdater",
                "~/Library/Application Support/BraveSoftware/BraveUpdater"
            ]
        )
    ]

    // MARK: - P2 开发产物清扫（设计 §10.1）

    /// 合成 target，一个种类一条。
    ///
    /// 拆到种类粒度而不是合并成一条 `purge.artifacts`：`targetID` 会原样写进审计日志（§7.8），
    /// 事后翻日志时"删了哪一类产物"必须一眼看得出来。
    ///
    /// **风险一律 medium**：真实风险取决于候选自身的事实（所在仓库脏不脏），由展开来源经
    /// `DiskCleanCandidateFacts.risk` 覆盖成 low。目录里给的是覆盖缺失时的兜底值，方向
    /// fail-safe——漏了覆盖只会导致不默认勾选，不会把脏仓库的产物默认选上。
    ///
    /// **`reservedRootPaths` 为空**是本文件唯一的例外：扫描根由用户配置，目录里没有任何固定
    /// 前缀可写。保留根改由展开来源在运行时给出（全体已配置的根都进工件保留集），
    /// `DiskCleanScanEngineTests` 断言这一点。
    private static let developerArtifactTargets: [DiskCleanRuleTarget] = DiskCleanPurgeKind.allCases.map { kind in
        DiskCleanRuleTarget(
            id: kind.targetID,
            legacyRuleID: kind.targetID,
            category: .developerArtifacts,
            risk: .medium,
            kind: .external,
            reservedRootPaths: []
        )
    }

    // MARK: - P2 残留安装包（设计 §10.2）

    /// 合成 target，一个扩展名一条。风险与保留根的处理同开发产物，区别是范围固定为
    /// `~/Downloads` 顶层，因此保留根可以静态写死。
    private static let installerTargets: [DiskCleanRuleTarget] = DiskCleanInstallerKind.allCases.map { kind in
        DiskCleanRuleTarget(
            id: kind.targetID,
            legacyRuleID: kind.targetID,
            category: .installers,
            risk: .medium,
            kind: .external,
            reservedRootPaths: [DiskCleanInstallerScanner.defaultDownloadsPath]
        )
    }
}
