import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// 规则 v1 → v2 映射快照（设计 §5.4、§11"规则映射"行）。
///
/// 这些断言是迁移的护栏：v2 目录只允许改变归属与元数据，不允许悄悄增删 glob 或丢掉 v1 规则 id。
final class DiskCleanRuleCatalogV2Tests: XCTestCase {
    private let catalog = DiskCleanRuleCatalogV2.current

    /// v1 的伪动态规则只有静态兜底 glob，v2 把它们落为 path target；
    /// 这是 v2 相对 v1 *目录* 新增的 glob 全集，任何其他新增都应让本测试失败。
    private let expectedGlobsAbsentFromFirstVersionCatalog: Set<String> = [
        // v1 `.xcodeDerivedData` 兜底
        "~/Library/Developer/Xcode/DerivedData/*",
        // v1 包管理器动态规则中未被其它规则覆盖的两条
        "~/.cache/go-build/*",
        "~/Library/Caches/mise/*",
        // v1 `.serviceWorkerCache` 兜底
        "~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage/*/*",
        "~/Library/Application Support/Arc/*/Service Worker/CacheStorage/*/*",
        "~/Library/Application Support/BraveSoftware/Brave-Browser/*/Service Worker/CacheStorage/*/*",
        "~/Library/Application Support/Vivaldi/*/Service Worker/CacheStorage/*/*",
        "~/Library/Application Support/Code/Service Worker/CacheStorage/*/*",
        "~/Library/Application Support/Cursor/Service Worker/CacheStorage/*/*"
    ]

    // MARK: - legacyRuleID 覆盖

    func testLegacyRuleIDsCoverFirstVersionRuleIDsExactly() {
        // 只看规则 target：P2 合成 target（`purge.*` / `installer.*`）不是 v1 规则的迁移产物，
        // 它们的候选由专用扫描器发现，legacyRuleID 与自身 id 相同只是为了让审计日志有个稳定名字。
        let legacyIDs = Set(catalog.ruleTargets.map(\.legacyRuleID))
        let firstVersionIDs = Set(DiskCleanRuleCatalog.moleFirstVersion.rules.map(\.id))

        XCTAssertEqual(legacyIDs, firstVersionIDs)
        XCTAssertEqual(firstVersionIDs.count, 43)
    }

    func testSplitLegacyRulesKeepEveryTargetUnderTheSameLegacyID() {
        XCTAssertEqual(
            catalog.targets(legacyRuleID: "cache.user-essentials").map(\.id),
            ["cache.user-essentials.caches", "cache.user-essentials.logs"]
        )
        XCTAssertEqual(
            catalog.targets(legacyRuleID: "developer.rust-go-docker").map(\.id),
            ["developer.rust-go", "developer.docker"]
        )
        XCTAssertEqual(
            catalog.targets(legacyRuleID: "browser.chrome").map(\.id),
            ["browser.chrome", "browser.chrome.service-worker"]
        )
    }

    // MARK: - glob 归属

    func testEveryFirstVersionGlobHasExactlyOneOwningTarget() {
        var ownersByGlob: [String: [String]] = [:]
        for target in catalog.targets {
            for glob in target.pathGlobs {
                ownersByGlob[glob, default: []].append(target.id)
            }
        }

        let duplicated = ownersByGlob.filter { $0.value.count > 1 }
        XCTAssertTrue(duplicated.isEmpty, "glob 被多个 target 同时拥有：\(duplicated)")

        let firstVersionGlobs = Self.firstVersionPathGlobs()
        let missing = firstVersionGlobs.subtracting(ownersByGlob.keys)
        XCTAssertTrue(missing.isEmpty, "v1 glob 在 v2 无归属：\(missing.sorted())")

        let added = Set(ownersByGlob.keys).subtracting(firstVersionGlobs)
        XCTAssertEqual(added, expectedGlobsAbsentFromFirstVersionCatalog)
    }

    func testFirstVersionDuplicatedGlobsAreOwnedByTheMoreSpecificCategory() {
        // v1 里 Codex 五项与 Figma 同时出现在两条规则中；v2 归一到语义更贴切的分类。
        XCTAssertEqual(
            Self.owner(of: "~/Library/Application Support/Codex/Cache/*", in: catalog)?.id,
            "cache.ai-assistants"
        )
        XCTAssertEqual(
            Self.owner(of: "~/Library/Caches/com.figma.Desktop/*", in: catalog)?.id,
            "cache.creative-tools"
        )
    }

    func testPathTargetsDeclareAtLeastOneGlob() {
        for target in catalog.ruleTargets where !target.isDynamic {
            XCTAssertFalse(target.pathGlobs.isEmpty, "path target 无 glob：\(target.id)")
        }
    }

    func testTargetIDsAreUniqueAndNonEmpty() {
        let ids = catalog.targets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains { $0.isEmpty })
        for target in catalog.targets {
            XCTAssertEqual(catalog.target(id: target.id)?.id, target.id)
        }
    }

    // MARK: - 保留根

    func testReservedRootPathsAreNonEmptyNormalizedAbsolutePaths() {
        let home = "/Users/diskclean-tests"
        for target in catalog.targets {
            if target.id.hasPrefix("purge.") {
                // 唯一允许为空的一类：扫描根由用户配置，目录里没有固定前缀可写。
                // 保留根改由展开来源在运行时给出，见
                // `DiskCleanScanEngineTests.testDeveloperArtifactScanReservesConfiguredRoots`。
                XCTAssertTrue(target.reservedRootPaths.isEmpty, "开发产物 target 不应写死保留根：\(target.id)")
            } else {
                XCTAssertFalse(target.reservedRootPaths.isEmpty, "target 缺少保留根：\(target.id)")
            }
            for path in target.expandedReservedRootPaths(homeDirectory: home) {
                XCTAssertTrue(path.hasPrefix("/"), "保留根非绝对路径：\(target.id) \(path)")
                XCTAssertFalse(path.contains { "*?[".contains($0) }, "保留根含 glob：\(target.id) \(path)")
                XCTAssertFalse(path.contains("//"), "保留根未规范化：\(target.id) \(path)")
                XCTAssertFalse(path.hasSuffix("/"), "保留根有尾斜杠：\(target.id) \(path)")
                XCTAssertEqual(
                    path,
                    (path as NSString).standardizingPath,
                    "保留根未规范化：\(target.id) \(path)"
                )
            }
        }
    }

    /// 真正的判据是**路径任意一级都不能是符号链接**——sizing 的根 opener 用 `O_NOFOLLOW_ANY`
    /// （详见 `DiskCleanRootOpener` 类型注释），中间级符号链接同样以 ELOOP 被拒；
    /// 末级符号链接反而是合法候选（按链接本身计，不跟随）。
    ///
    /// 该判据只有运行时 `realpath(3)` 能定论，而目录里的 glob 大多指向本机不一定存在的路径，
    /// 因此这里静态拦住 macOS 上三个众所周知的符号链接前缀（`/var -> private/var`、
    /// `/tmp -> private/tmp`、`/etc -> private/etc`）。将来收录系统目录必须写 `/private/...` 物理路径。
    /// 注意 `resolvingSymlinksInPath()` 帮不上忙：它倾向剥掉 `/private` 而不是补上。
    func testNoTargetPathStartsWithSymlinkedSystemPrefix() {
        let symlinkedRoots = ["/var", "/tmp", "/etc"]
        for target in catalog.targets {
            for path in target.pathGlobs + target.reservedRootPaths {
                for root in symlinkedRoots {
                    XCTAssertNotEqual(path, root, "路径需写 /private 物理路径：\(target.id) \(path)")
                    XCTAssertFalse(
                        path.hasPrefix(root + "/"),
                        "路径经过符号链接目录，应改写为 /private 物理路径：\(target.id) \(path)"
                    )
                }
            }
        }
    }

    /// 保留根必须等于 glob 固定目录前缀的去重集合——独立重算一次，防止手改 glob 后忘记同步保留根。
    func testPathTargetReservedRootsEqualGlobFixedPrefixes() {
        for target in catalog.ruleTargets where !target.isDynamic {
            var expected: [String] = []
            for glob in target.pathGlobs {
                let prefix = Self.fixedDirectoryPrefix(of: glob)
                if !expected.contains(prefix) {
                    expected.append(prefix)
                }
            }
            XCTAssertEqual(target.reservedRootPaths, expected, "保留根与 glob 固定前缀不一致：\(target.id)")
        }
    }

    func testDynamicTargetReservedRootsCoverProviderScopes() {
        XCTAssertEqual(
            catalog.target(id: "developer.simulator-unavailable")?.reservedRootPaths,
            ["~/Library/Developer/CoreSimulator/Devices"]
        )
        XCTAssertEqual(
            catalog.target(id: "developer.jetbrains-toolbox-old-versions")?.reservedRootPaths,
            ["~/Library/Application Support/JetBrains/Toolbox/apps"]
        )
        XCTAssertEqual(
            catalog.target(id: "browser.old-versions")?.reservedRootPaths.first,
            "~/Library/Application Support/Google/GoogleUpdater"
        )
    }

    // MARK: - 风险与分类

    func testDynamicTargetsAreAtLeastMediumRisk() {
        let dynamicTargets = catalog.targets.filter(\.isDynamic)
        XCTAssertEqual(dynamicTargets.count, 4)
        XCTAssertEqual(
            Set(dynamicTargets.map(\.id)),
            [
                "developer.simulator-unavailable",
                "developer.jetbrains-toolbox-old-versions",
                "developer.ai-agent-old-versions",
                "browser.old-versions"
            ]
        )
        for target in dynamicTargets {
            XCTAssertGreaterThanOrEqual(target.risk, .medium, "动态 target 风险过低：\(target.id)")
        }
    }

    func testMappingTableRiskAndCategoryForSplitAndElevatedTargets() {
        assertTarget("cache.user-essentials.caches", category: .userEssentials, risk: .low)
        assertTarget("cache.user-essentials.logs", category: .logs, risk: .low)
        assertTarget("cache.macos-app-state", category: .systemCaches, risk: .medium)
        assertTarget("cache.virtualization", category: .virtualization, risk: .medium)
        assertTarget("developer.rust-go", category: .developer, risk: .low)
        assertTarget("developer.docker", category: .developer, risk: .medium)
        assertTarget("developer.ai-agent-old-versions", category: .aiTools, risk: .medium)
        assertTarget("browser.safari", category: .browsers, risk: .low)
        assertTarget("browser.chrome.service-worker", category: .browsers, risk: .medium)
        assertTarget("browser.service-worker", category: .browsers, risk: .medium)
    }

    func testServiceWorkerTargetsAreAllMediumRisk() {
        let serviceWorkerTargets = catalog.targets.filter { $0.id.contains("service-worker") }
        XCTAssertEqual(serviceWorkerTargets.count, 6)
        for target in serviceWorkerTargets {
            XCTAssertEqual(target.risk, .medium, "Service Worker target 应为 medium：\(target.id)")
        }
    }

    func testCategoryDisplayOrderCoversAllCasesWithNonDecreasingRisk() {
        XCTAssertEqual(Set(DiskCleanCategoryID.displayOrder), Set(DiskCleanCategoryID.allCases))
        XCTAssertEqual(DiskCleanCategoryID.displayOrder.count, DiskCleanCategoryID.allCases.count)

        let risks = DiskCleanCategoryID.displayOrder.map(\.risk)
        XCTAssertEqual(risks, risks.sorted())
    }

    func testEveryCategoryOwnsAtLeastOneTarget() {
        for category in DiskCleanCategoryID.allCases {
            XCTAssertFalse(catalog.targets(in: category).isEmpty, "分类无 target：\(category.rawValue)")
        }
    }

    func testTargetsInDisplayOrderAreCategoryThenRiskOrdered() {
        let ordered = catalog.targetsInDisplayOrder
        XCTAssertEqual(ordered.count, catalog.targets.count)

        let categoryRank = Dictionary(
            uniqueKeysWithValues: DiskCleanCategoryID.displayOrder.enumerated().map { ($0.element, $0.offset) }
        )
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            let previousRank = categoryRank[previous.category] ?? 0
            let nextRank = categoryRank[next.category] ?? 0
            XCTAssertLessThanOrEqual(previousRank, nextRank)
            if previous.category == next.category {
                XCTAssertLessThanOrEqual(previous.risk, next.risk)
            }
        }
    }

    // MARK: - 锁定与 FDA

    func testProcessLockedTargetsAlsoDeclareBundleIDs() {
        for target in catalog.targets where !target.skipWhenProcessIsRunning.isEmpty {
            XCTAssertFalse(
                target.lockedByBundleIDs.isEmpty,
                "声明了进程名却没有 bundle ID：\(target.id)"
            )
        }
    }

    func testFirstVersionProcessLocksArePreserved() {
        XCTAssertEqual(
            catalog.target(id: "developer.xcode-derived-data")?.skipWhenProcessIsRunning,
            ["Xcode"]
        )
        XCTAssertEqual(
            catalog.target(id: "developer.simulator-unavailable")?.skipWhenProcessIsRunning,
            ["Simulator"]
        )
        XCTAssertEqual(
            catalog.target(id: "browser.chrome.service-worker")?.lockedByBundleIDs,
            ["com.google.Chrome"]
        )
    }

    /// TCC 保护前缀表（设计 §9）。
    ///
    /// 在测试里**独立声明一次**，标记由它反向推导：目录里手动置了 `requiresFullDiskAccess`
    /// 却不该置、或该置而漏置，两个方向都会失败。新增 target 时若整组 glob 落在保护范围内
    /// 却忘了标记，同样在这里被拦下。
    ///
    /// 依据见 `DiskCleanRuleCatalogV2` 的类型注释；简述：容器类是 macOS 14 起的
    /// `kTCCServiceSystemPolicyAppData`（会弹窗），Safari 缓存与 Suggestions/Calendars/AddressBook
    /// 是 FDA / Calendar / Contacts 保护（静默 EPERM）。
    private static let tccProtectedPrefixes = [
        "~/Library/Containers/",
        "~/Library/Group Containers/",
        "~/Library/Caches/com.apple.Safari",
        "~/Library/Safari",
        "~/Library/Suggestions",
        "~/Library/Calendars",
        "~/Library/Application Support/AddressBook"
    ]

    func testFullDiskAccessMarksAreDerivableFromTCCProtectedPrefixes() {
        for target in catalog.ruleTargets where !target.pathGlobs.isEmpty {
            let allProtected = target.pathGlobs.allSatisfy { glob in
                Self.tccProtectedPrefixes.contains { glob.hasPrefix($0) }
            }
            XCTAssertEqual(
                target.requiresFullDiskAccess,
                allProtected,
                allProtected
                    ? "全部 glob 都在 TCC 保护范围内却未标记：\(target.id)"
                    : "含非保护 glob 却标记了 FDA，会连可清理路径一起跳过：\(target.id)"
            )
        }
    }

    /// 标记集合快照。防止"拆一个 target 忘了标记"这类改动无声改变未授权用户的扫描覆盖面。
    func testFullDiskAccessTargetSnapshot() {
        XCTAssertEqual(
            catalog.targets.filter(\.requiresFullDiskAccess).map(\.id).sorted(),
            [
                "browser.safari",
                "cache.apple-sandboxed-apps.containers",
                "cache.macos-app-state.protected",
                "cache.office-apps.containers",
                "cache.productivity-media.containers"
            ]
        )
    }

    /// 动态与合成 target 永远不标记：前者的 provider 自己会失败降级，后者根本不经规则展开，
    /// 标记只会让 `fdaRestricted` 报出一个用户找不到对应内容的 target id。
    func testDynamicAndExternalTargetsNeverRequireFullDiskAccess() {
        for target in catalog.targets where target.isDynamic || target.isExternallyDiscovered {
            XCTAssertFalse(target.requiresFullDiskAccess, "不该标记 FDA：\(target.id)")
        }
    }

    /// 拆分出来的 FDA target 必须与原 target 同分类同风险——拆分的理由只有 TCC，
    /// 不该顺手改变用户看到的归类。
    func testFullDiskAccessSplitsKeepParentCategoryAndRisk() {
        for target in catalog.targets where target.requiresFullDiskAccess {
            let siblings = catalog.targets(legacyRuleID: target.legacyRuleID)
            for sibling in siblings where sibling.id != target.id {
                XCTAssertEqual(sibling.category, target.category, "拆分改变了分类：\(target.id)")
                XCTAssertEqual(sibling.risk, target.risk, "拆分改变了风险：\(target.id)")
            }
        }
    }

    // MARK: - P2 合成 target

    func testExternalTargetsCoverEveryPurgeAndInstallerKind() {
        XCTAssertEqual(
            catalog.targets(in: .developerArtifacts).map(\.id),
            DiskCleanPurgeKind.allCases.map(\.targetID)
        )
        XCTAssertEqual(
            catalog.targets(in: .installers).map(\.id),
            DiskCleanInstallerKind.allCases.map(\.targetID)
        )
        for target in catalog.targets(in: .developerArtifacts) + catalog.targets(in: .installers) {
            XCTAssertTrue(target.isExternallyDiscovered, "P2 target 应为 external：\(target.id)")
            XCTAssertTrue(target.pathGlobs.isEmpty, "P2 target 不该有 glob：\(target.id)")
            // 兜底风险必须 >= medium：展开来源漏给覆盖值时，方向应当是"不默认勾选"。
            XCTAssertGreaterThanOrEqual(target.risk, .medium, "P2 兜底风险过低：\(target.id)")
        }
    }

    /// 合成 target 必须真实存在于目录里——`DiskCleanPlanner.makePlan` 按 targetID 回查目录，
    /// 查不到就抛 `unknownTarget`，P2 候选会变成永远清理不掉的死项。
    func testEveryExternalTargetIDResolvesInCatalog() {
        for kind in DiskCleanPurgeKind.allCases {
            XCTAssertNotNil(catalog.target(id: kind.targetID), "缺少 target：\(kind.targetID)")
        }
        for kind in DiskCleanInstallerKind.allCases {
            XCTAssertNotNil(catalog.target(id: kind.targetID), "缺少 target：\(kind.targetID)")
        }
    }

    func testRuleTargetsExcludeExternalTargets() {
        XCTAssertFalse(catalog.ruleTargets.contains { $0.isExternallyDiscovered })
        XCTAssertEqual(
            catalog.ruleTargets.count + DiskCleanPurgeKind.allCases.count + DiskCleanInstallerKind.allCases.count,
            catalog.targets.count
        )
    }

    // MARK: - 辅助

    private func assertTarget(
        _ id: String,
        category: DiskCleanCategoryID,
        risk: DiskCleanRisk,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let target = catalog.target(id: id) else {
            return XCTFail("缺少 target：\(id)", file: file, line: line)
        }
        XCTAssertEqual(target.category, category, "分类不符：\(id)", file: file, line: line)
        XCTAssertEqual(target.risk, risk, "风险不符：\(id)", file: file, line: line)
    }

    private static func owner(of glob: String, in catalog: DiskCleanRuleCatalogV2) -> DiskCleanRuleTarget? {
        catalog.targets.first { $0.pathGlobs.contains(glob) }
    }

    private static func firstVersionPathGlobs() -> Set<String> {
        var globs: Set<String> = []
        for rule in DiskCleanRuleCatalog.moleFirstVersion.rules {
            for target in rule.targets {
                if case let .path(glob) = target {
                    globs.insert(glob)
                }
            }
        }
        return globs
    }

    /// 首个 glob 元字符之前的最后一个完整路径组件。无元字符时即路径本身。
    private static func fixedDirectoryPrefix(of glob: String) -> String {
        guard let metaIndex = glob.firstIndex(where: { "*?[".contains($0) }) else {
            return glob
        }
        let head = glob[glob.startIndex..<metaIndex]
        guard let slashIndex = head.lastIndex(of: "/") else {
            return String(head)
        }
        return String(head[head.startIndex..<slashIndex])
    }
}
