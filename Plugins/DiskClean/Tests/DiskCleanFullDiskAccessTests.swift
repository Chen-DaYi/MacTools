import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

/// FDA 能力探针（设计 §9）。
///
/// 全部经注入的可读性 seam，**绝不碰真实的 TCC 保护文件**：跑测试的机器可能恰好授予了
/// 终端 FDA，那样断言就会跟着环境走。
final class DiskCleanFullDiskAccessTests: XCTestCase {
    private let tccPath = "/Users/diskclean-tests/Library/Application Support/com.apple.TCC/TCC.db"
    private let safariPath = "/Users/diskclean-tests/Library/Safari/Bookmarks.plist"

    // MARK: - 探测矩阵

    func testReportsGrantedWhenFirstProbePathOpens() {
        let readability = FakeDiskCleanFileReadability(openablePaths: [tccPath])
        let probe = makeProbe(readability: readability)

        XCTAssertTrue(probe.hasFullDiskAccess)
        XCTAssertEqual(readability.probedPaths, [tccPath], "首条成功后不该继续试第二条")
    }

    /// 全新账户可能还没有 TCC.db。第二条能开同样说明有 FDA。
    func testReportsGrantedWhenOnlyFallbackProbePathOpens() {
        let readability = FakeDiskCleanFileReadability(openablePaths: [safariPath])
        let probe = makeProbe(readability: readability)

        XCTAssertTrue(probe.hasFullDiskAccess)
        XCTAssertEqual(readability.probedPaths, [tccPath, safariPath])
    }

    /// 被拒绝与文件不存在在探针里是同一件事：都无法证明有 FDA。
    /// 方向必须 fail-safe——误报"有"会让引擎照常展开受保护 target，换回一堆读不到的空候选。
    func testReportsDeniedWhenNoProbePathOpens() {
        let readability = FakeDiskCleanFileReadability()
        let probe = makeProbe(readability: readability)

        XCTAssertFalse(probe.hasFullDiskAccess)
        XCTAssertEqual(readability.probedPaths, [tccPath, safariPath], "全部试完才能下结论")
    }

    func testReportsDeniedWhenProbePathListIsEmpty() {
        let probe = DiskCleanFullDiskAccessProbe(
            probePaths: [],
            readability: FakeDiskCleanFileReadability(openablePaths: [tccPath])
        )

        XCTAssertFalse(probe.hasFullDiskAccess)
    }

    // MARK: - 进程内缓存

    /// FDA 绑定进程启动，运行期间不会变化——这正是状态卡提示"退出并重新打开"的理由。
    /// 缓存顺带保证同一次扫描里每个 target 看到的是同一个答案。
    func testCachesResultForTheLifetimeOfTheProcess() {
        let readability = FakeDiskCleanFileReadability(openablePaths: [tccPath])
        let probe = makeProbe(readability: readability)

        XCTAssertTrue(probe.hasFullDiskAccess)
        XCTAssertTrue(probe.hasFullDiskAccess)
        XCTAssertTrue(probe.hasFullDiskAccess)

        XCTAssertEqual(readability.probedPaths, [tccPath], "重复读取不该重复探测")
    }

    func testCachesNegativeResultToo() {
        let readability = FakeDiskCleanFileReadability()
        let probe = makeProbe(readability: readability)

        XCTAssertFalse(probe.hasFullDiskAccess)
        XCTAssertFalse(probe.hasFullDiskAccess)

        XCTAssertEqual(readability.probedPaths, [tccPath, safariPath])
    }

    // MARK: - 默认探测目标

    /// 探测目标必须停留在"静默 EPERM"那一类。Documents / Downloads / Desktop 与沙盒容器
    /// 会**弹窗**，拿它们探测等于每次启动都骚扰用户一次。
    func testDefaultProbePathsStayInSilentlyDeniedLocations() {
        let paths = DiskCleanFullDiskAccessProbe.defaultProbePaths(homeDirectory: "/Users/diskclean-tests")

        XCTAssertEqual(paths, [tccPath, safariPath])
        for path in paths {
            XCTAssertFalse(path.contains("/Documents/"))
            XCTAssertFalse(path.contains("/Downloads/"))
            XCTAssertFalse(path.contains("/Desktop/"))
            XCTAssertFalse(path.contains("/Library/Containers/"))
        }
    }

    // MARK: - 授权引导

    func testSettingsURLPointsAtFullDiskAccessPane() {
        XCTAssertEqual(
            DiskCleanFullDiskAccessGuide.settingsURLString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
        XCTAssertNotNil(DiskCleanFullDiskAccessGuide.settingsURL)
    }

    // MARK: - 辅助

    private func makeProbe(readability: FakeDiskCleanFileReadability) -> DiskCleanFullDiskAccessProbe {
        DiskCleanFullDiskAccessProbe(
            probePaths: DiskCleanFullDiskAccessProbe.defaultProbePaths(
                homeDirectory: "/Users/diskclean-tests"
            ),
            readability: readability
        )
    }
}
