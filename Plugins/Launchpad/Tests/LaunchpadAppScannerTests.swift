import XCTest
@testable import MacTools
@testable import LaunchpadPlugin

final class LaunchpadAppScannerTests: XCTestCase {

    // MARK: - strippedAppSuffix (only trailing ".app", never mid-string)

    func testStrippedAppSuffixRemovesOnlyTrailingDotApp() {
        XCTAssertEqual(LaunchpadAppScanner.strippedAppSuffix("Safari.app"), "Safari")
        XCTAssertEqual(LaunchpadAppScanner.strippedAppSuffix("Safari"), "Safari")
        XCTAssertEqual(LaunchpadAppScanner.strippedAppSuffix("App Store"), "App Store")
        // ".app" in the middle must NOT be removed (the bug Codex flagged).
        XCTAssertEqual(LaunchpadAppScanner.strippedAppSuffix("My.app Helper"), "My.app Helper")
        // Only ONE trailing suffix removed.
        XCTAssertEqual(LaunchpadAppScanner.strippedAppSuffix("Weird.app.app"), "Weird.app")
        XCTAssertEqual(LaunchpadAppScanner.strippedAppSuffix(""), "")
    }

    // MARK: - nested-helper guard (path-level)

    func testIsNestedInsideAnotherApp() {
        XCTAssertFalse(LaunchpadAppScanner.isNestedInsideAnotherApp(URL(fileURLWithPath: "/Applications/Foo.app")))
        XCTAssertFalse(LaunchpadAppScanner.isNestedInsideAnotherApp(URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")))
        XCTAssertTrue(LaunchpadAppScanner.isNestedInsideAnotherApp(
            URL(fileURLWithPath: "/Applications/Foo.app/Contents/Helpers/Bar.app")
        ))
    }

    // MARK: - isValidAppBundle (directory + Contents/Info.plist)

    func testIsValidAppBundleRequiresDirectoryAndInfoPlist() throws {
        let tmp = try makeTempDir()
        let validApp = try makeAppBundle(in: tmp, named: "Real.app")
        let emptyDirApp = tmp.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: emptyDirApp, withIntermediateDirectories: true)
        let fileApp = tmp.appendingPathComponent("File.app")
        try Data().write(to: fileApp)

        XCTAssertTrue(LaunchpadAppScanner.isValidAppBundle(at: validApp.path))
        XCTAssertFalse(LaunchpadAppScanner.isValidAppBundle(at: emptyDirApp.path)) // no Info.plist
        XCTAssertFalse(LaunchpadAppScanner.isValidAppBundle(at: fileApp.path))     // not a directory
        XCTAssertFalse(LaunchpadAppScanner.isValidAppBundle(at: tmp.appendingPathComponent("Missing.app").path))
    }

    // MARK: - scan over a fixture tree

    func testScanFindsAppsRecursivelyAndSorts() throws {
        let tmp = try makeTempDir()
        _ = try makeAppBundle(in: tmp, named: "Zebra.app")
        // Recursion: an app inside a subfolder (like /Applications/Utilities).
        let utilities = tmp.appendingPathComponent("Utilities", isDirectory: true)
        try FileManager.default.createDirectory(at: utilities, withIntermediateDirectories: true)
        _ = try makeAppBundle(in: utilities, named: "Alpha.app")

        let items = LaunchpadAppScanner.scan(roots: [tmp.path])
        XCTAssertEqual(items.map(\.name), ["Alpha", "Zebra"]) // sorted
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    func testScanExcludesCorruptBundleWithoutInfoPlist() throws {
        let tmp = try makeTempDir()
        _ = try makeAppBundle(in: tmp, named: "Good.app")
        // A directory named like an app but with no Info.plist (corrupt/placeholder).
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Broken.app"), withIntermediateDirectories: true
        )
        // A FILE named like an app.
        try Data().write(to: tmp.appendingPathComponent("NotReal.app"))

        let items = LaunchpadAppScanner.scan(roots: [tmp.path])
        XCTAssertEqual(items.map(\.name), ["Good"])
    }

    func testScanExcludesNestedHelperApp() throws {
        let tmp = try makeTempDir()
        let host = try makeAppBundle(in: tmp, named: "Host.app")
        // A real helper app embedded inside the host bundle. `.skipsPackageDescendants`
        // should prevent it from ever being yielded; the nested guard is the backstop.
        let helpersDir = host.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)
        _ = try makeAppBundle(in: helpersDir, named: "Helper.app")

        let items = LaunchpadAppScanner.scan(roots: [tmp.path])
        XCTAssertEqual(items.map(\.name), ["Host"]) // Helper.app excluded
    }

    func testScanSkipsNonexistentRoots() {
        let items = LaunchpadAppScanner.scan(roots: ["/no/such/path/\(UUID().uuidString)"])
        XCTAssertTrue(items.isEmpty)
    }

    func testScanDedupesSymlinkedDuplicate() throws {
        let tmp = try makeTempDir()
        let real = try makeAppBundle(in: tmp, named: "Real.app")
        let link = tmp.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let items = LaunchpadAppScanner.scan(roots: [tmp.path])
        // Real.app and Link.app resolve to the same path → a single deduped entry.
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, real.resolvingSymlinksInPath().path)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchpadAppScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Creates a minimal valid `.app` bundle (a directory with `Contents/Info.plist`).
    @discardableResult
    private func makeAppBundle(in parent: URL, named name: String) throws -> URL {
        let app = parent.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("<plist></plist>".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}
