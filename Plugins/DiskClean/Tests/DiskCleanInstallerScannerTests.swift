import Darwin
import Foundation
import XCTest
@testable import MacTools
@testable import DiskCleanPlugin

final class DiskCleanInstallerScannerTests: XCTestCase {
    /// Fixed observation time so the "7 days" check is independent of wall-clock time.
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

    // MARK: - Extensions

    func testSelectsStaleInstallerPackagesByDefault() throws {
        try makeDownload("Xcode.xip", bytes: 40, ageDays: 30)
        try makeDownload("App.dmg", bytes: 30, ageDays: 30)
        try makeDownload("Driver.pkg", bytes: 20, ageDays: 30)
        try makeDownload("Ubuntu.iso", bytes: 10, ageDays: 30)

        let candidates = try scanCandidates()

        XCTAssertEqual(
            candidates.map(\.kind),
            [.diskImage, .installerPackage, .discImage, .signedArchive],
            "results are sorted by path: App.dmg / Driver.pkg / Ubuntu.iso / Xcode.xip"
        )
        XCTAssertTrue(candidates.allSatisfy(\.isSelectedByDefault))
        XCTAssertTrue(candidates.allSatisfy { $0.note == nil })
    }

    /// `.zip` may be a user archive; never selected by default at any age.
    func testZipIsListedButNeverSelectedByDefault() throws {
        try makeDownload("Tool.zip", bytes: 12, ageDays: 400)

        let candidates = try scanCandidates()

        XCTAssertEqual(candidates.map(\.kind), [.zipArchive])
        XCTAssertFalse(candidates[0].isSelectedByDefault)
        XCTAssertEqual(candidates[0].note, .mayNotBeInstaller)
    }

    func testRecentInstallerIsListedWithoutDefaultSelection() throws {
        try makeDownload("Fresh.dmg", bytes: 8, ageDays: 3)

        let candidates = try scanCandidates()

        XCTAssertEqual(candidates.count, 1)
        XCTAssertFalse(candidates[0].isSelectedByDefault)
        XCTAssertEqual(candidates[0].note, .recentlyModified)
    }

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

    // MARK: - Metadata

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

    // MARK: - Unreachable

    /// TCC denial is not the same as "no installers in the directory": the former needs authorization guidance.
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

    func testEnumerationErrorIsNotReportedAsSuccessfulScan() {
        let downloads = temporaryDirectory.resolve("Downloads").path
        let observationDate = observationDate
        let scanner = DiskCleanInstallerScanner(
            downloadsPath: downloads,
            staleAge: DiskCleanInstallerScanner.defaultStaleAge,
            sourceFactory: ThrowingInstallerSourceFactory(code: EIO),
            now: { observationDate }
        )

        let outcome = scanner.scan()

        guard case let .unavailable(path, reason) = outcome else {
            return XCTFail("expected unavailable, got \(outcome)")
        }
        XCTAssertEqual(path, downloads)
        XCTAssertEqual(reason, .walkError)
    }

    func testPermissionDeniedEnumerationIsDenied() {
        let downloads = temporaryDirectory.resolve("Downloads").path
        let observationDate = observationDate
        let scanner = DiskCleanInstallerScanner(
            downloadsPath: downloads,
            staleAge: DiskCleanInstallerScanner.defaultStaleAge,
            sourceFactory: ThrowingInstallerSourceFactory(code: EACCES),
            now: { observationDate }
        )

        let outcome = scanner.scan()

        guard case let .denied(path) = outcome else {
            return XCTFail("expected denied, got \(outcome)")
        }
        XCTAssertEqual(path, downloads)
    }

    // MARK: - Fixtures

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
            XCTFail("expected scanned, got \(outcome)")
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

/// Source factory that owns the fd and fails the first `nextBatch`, simulating mid-stream readdir error.
private struct ThrowingInstallerSourceFactory: DiskCleanDirectoryEntrySourceFactory {
    let code: Int32

    func makeSource(fileDescriptor: Int32) throws -> any DiskCleanDirectoryEntrySource {
        ThrowingInstallerSource(fileDescriptor: fileDescriptor, code: code)
    }
}

private final class ThrowingInstallerSource: DiskCleanDirectoryEntrySource {
    let directoryFileDescriptor: Int32
    private let code: Int32
    private var isClosed = false

    init(fileDescriptor: Int32, code: Int32) {
        self.directoryFileDescriptor = fileDescriptor
        self.code = code
    }

    func nextBatch() throws -> [DiskCleanWalkEntry]? {
        throw DiskCleanPOSIXError(code: code)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(directoryFileDescriptor)
    }
}
