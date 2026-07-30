import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanInstallerScannerTests: XCTestCase {
    /// 固定观测时刻，让"7 天"判定与真实时间无关。
    private let observationDate = Date(timeIntervalSince1970: 1_800_000_000)
    private var temporaryDirectory: DiskCleanTempDirectory!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = try DiskCleanTempDirectory(name: "DiskCleanInstallerScannerTests")
        try temporaryDirectory.makeDirectory("Downloads")
    }

    override func tearDownWithError() throws {
        temporaryDirectory?.remove()
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - 扩展名

    func testSelectsStaleInstallerPackagesByDefault() throws {
        try makeDownload("Xcode.xip", bytes: 40, ageDays: 30)
        try makeDownload("App.dmg", bytes: 30, ageDays: 30)
        try makeDownload("Driver.pkg", bytes: 20, ageDays: 30)
        try makeDownload("Ubuntu.iso", bytes: 10, ageDays: 30)

        let candidates = try scanCandidates()

        XCTAssertEqual(
            candidates.map(\.kind),
            [.diskImage, .installerPackage, .discImage, .signedArchive],
            "结果按路径排序：App.dmg / Driver.pkg / Ubuntu.iso / Xcode.xip"
        )
        XCTAssertTrue(candidates.allSatisfy(\.isSelectedByDefault))
        XCTAssertTrue(candidates.allSatisfy { $0.note == nil })
    }

    /// `.zip` 可能是用户自己打的资料包，任何年龄都不默认勾选。
    func testZipIsListedButNeverSelectedByDefault() throws {
        try makeDownload("Tool.zip", bytes: 12, ageDays: 400)

        let candidates = try scanCandidates()

        XCTAssertEqual(candidates.map(\.kind), [.zipArchive])
        XCTAssertFalse(candidates[0].isSelectedByDefault)
        XCTAssertEqual(candidates[0].note, .mayNotBeInstaller)
    }

    func testMatchesExtensionCaseInsensitively() throws {
        try makeDownload("Legacy.DMG", bytes: 8, ageDays: 30)

        let candidates = try scanCandidates()

        XCTAssertEqual(candidates.map(\.kind), [.diskImage])
    }

    func testIgnoresUnrelatedFiles() throws {
        try makeDownload("notes.txt", bytes: 4, ageDays: 30)
        try makeDownload("README", bytes: 4, ageDays: 30)
        try makeDownload("archive.dmg.part", bytes: 4, ageDays: 30)

        XCTAssertTrue(try scanCandidates().isEmpty)
    }

    // MARK: - 年龄边界

    /// 严格大于 7 天才默认勾选：刚下载的可能还没装。
    func testRecentInstallerIsListedWithoutDefaultSelection() throws {
        try makeDownload("Fresh.dmg", bytes: 8, ageDays: 3)

        let candidates = try scanCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertFalse(candidates[0].isSelectedByDefault)
        XCTAssertEqual(candidates[0].note, .recentlyModified)
    }

    func testAgeBoundaryIsExclusive() throws {
        try makeDownload("Exactly.dmg", bytes: 8, age: DiskCleanInstallerScanner.defaultStaleAge)
        try makeDownload("JustOver.dmg", bytes: 8, age: DiskCleanInstallerScanner.defaultStaleAge + 1)

        let candidates = try scanCandidates()

        XCTAssertEqual(
            candidates.map { [$0.displayName, "\($0.isSelectedByDefault)"] },
            [["Exactly.dmg", "false"], ["JustOver.dmg", "true"]]
        )
    }

    func testStaleAgeIsConfigurable() throws {
        try makeDownload("TwoDays.dmg", bytes: 8, ageDays: 2)

        let candidates = try scanCandidates(staleAge: 24 * 60 * 60)

        XCTAssertTrue(candidates[0].isSelectedByDefault)
    }

    // MARK: - 顶层与类型约束

    /// 顶层不递归：子目录多半是用户自己整理的资料。
    func testDoesNotRecurseIntoSubdirectories() throws {
        try makeDownload("Archive/Old.dmg", bytes: 8, ageDays: 100)

        XCTAssertTrue(try scanCandidates().isEmpty)
    }

    func testIgnoresDirectoriesAndSymlinksNamedLikeInstallers() throws {
        try temporaryDirectory.makeDirectory("Downloads/Bundle.pkg")
        try makeDownload("real.dmg", bytes: 8, ageDays: 100)
        try temporaryDirectory.makeSymlink("Downloads/alias.dmg", destination: "real.dmg")

        let candidates = try scanCandidates()

        XCTAssertEqual(candidates.map(\.displayName), ["real.dmg"])
    }

    // MARK: - 元数据

    func testReportsSizeModificationTimeAndPath() throws {
        try makeDownload("App.dmg", bytes: 2048, ageDays: 10)

        let candidate = try XCTUnwrap(scanCandidates().first)

        XCTAssertEqual(candidate.path, temporaryDirectory.resolve("Downloads/App.dmg").path)
        XCTAssertEqual(candidate.id, candidate.path)
        XCTAssertEqual(candidate.byteSize, 2048)
        XCTAssertEqual(
            candidate.modifiedAt.timeIntervalSince1970,
            observationDate.addingTimeInterval(-10 * 24 * 60 * 60).timeIntervalSince1970,
            accuracy: 1
        )
    }

    // MARK: - 不可达

    /// TCC 拒绝与"目录里没有安装包"是两回事：前者要引导授权，后者才是真的没有。
    func testPermissionDeniedIsDistinctFromEmptyResult() throws {
        try makeDownload("App.dmg", bytes: 8, ageDays: 100)
        try temporaryDirectory.denyAccess(to: "Downloads")

        let outcome = makeScanner().scan()

        XCTAssertEqual(outcome, .denied(path: temporaryDirectory.resolve("Downloads").path))
        XCTAssertTrue(outcome.candidates.isEmpty)
    }

    func testMissingDownloadsDirectoryIsUnavailable() throws {
        let missing = temporaryDirectory.resolve("Missing").path

        let outcome = makeScanner(downloadsPath: missing).scan()

        XCTAssertEqual(outcome, .unavailable(path: missing, reason: .walkError))
    }

    func testEmptyDirectoryScansSuccessfully() {
        XCTAssertEqual(makeScanner().scan(), .scanned(candidates: []))
    }

    // MARK: - 夹具

    private func makeScanner(
        downloadsPath: String? = nil,
        staleAge: TimeInterval = DiskCleanInstallerScanner.defaultStaleAge
    ) -> DiskCleanInstallerScanner {
        let observationDate = observationDate
        return DiskCleanInstallerScanner(
            downloadsPath: downloadsPath ?? temporaryDirectory.resolve("Downloads").path,
            staleAge: staleAge,
            now: { observationDate }
        )
    }

    private func scanCandidates(
        staleAge: TimeInterval = DiskCleanInstallerScanner.defaultStaleAge
    ) throws -> [DiskCleanInstallerCandidate] {
        let outcome = makeScanner(staleAge: staleAge).scan()
        guard case let .scanned(candidates) = outcome else {
            XCTFail("期望 scanned，实际 \(outcome)")
            return []
        }
        return candidates
    }

    private func makeDownload(_ relativePath: String, bytes: Int, ageDays: Double) throws {
        try makeDownload(relativePath, bytes: bytes, age: ageDays * 24 * 60 * 60)
    }

    private func makeDownload(_ relativePath: String, bytes: Int, age: TimeInterval) throws {
        let file = try temporaryDirectory.makeFile("Downloads/\(relativePath)", bytes: bytes)
        try FileManager.default.setAttributes(
            [.modificationDate: observationDate.addingTimeInterval(-age)],
            ofItemAtPath: file.path
        )
    }
}
