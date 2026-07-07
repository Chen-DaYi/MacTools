import XCTest
@testable import MacTools

final class RightClickConfigurationStoreTests: XCTestCase {
    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("right-click-menu.json")
    }

    func testSaveThenLoadRoundTrips() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        var config = RightClickConfiguration.activeDefault
        config.preferredLanguages = ["en"]
        config.openInTerminal = false
        config.copyFileURL = false
        config.openWithApps = [
            RightClickOpenWithApp(name: "Code", appPath: "/Applications/Code.app", fileExtensions: ["txt", "md"])
        ]

        XCTAssertTrue(RightClickConfigurationStore.save(config, to: fileURL))
        let loaded = RightClickConfigurationStore.load(from: fileURL)

        XCTAssertEqual(loaded, config)
        XCTAssertEqual(loaded.preferredLanguages, ["en"])
        XCTAssertFalse(loaded.openInTerminal)
        XCTAssertEqual(loaded.openWithApps.first?.name, "Code")
        XCTAssertEqual(loaded.openWithApps.first?.fileExtensions, ["txt", "md"])
    }

    func testLoadMissingFileReturnsInactiveDefault() {
        XCTAssertEqual(RightClickConfigurationStore.load(from: makeTempFileURL()), .inactiveDefault)
    }

    func testLoadCorruptDataReturnsInactiveDefault() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertEqual(RightClickConfigurationStore.load(from: fileURL), .inactiveDefault)
    }

    /// A config written before newer keys existed must decode with defaults for
    /// the missing keys instead of failing the whole decode.
    func testDecodeToleratesMissingKeys() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(#"{"newFolder":false}"#.utf8).write(to: fileURL)

        let loaded = RightClickConfigurationStore.load(from: fileURL)
        XCTAssertTrue(loaded.menuEnabled)     // missing key -> active default for existing configs
        XCTAssertNil(loaded.preferredLanguages)
        XCTAssertFalse(loaded.newFolder)      // present key honored
        XCTAssertTrue(loaded.copyFileName)    // missing key → default
        XCTAssertTrue(loaded.openInTerminal)  // missing key → default
        XCTAssertEqual(loaded.openWithApps, [])
    }

    func testSetMenuEnabledInitializesActiveDefaultsWhenMissing() {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        RightClickConfigurationStore.setMenuEnabled(true, fileURL: fileURL)
        let loaded = RightClickConfigurationStore.load(from: fileURL)

        XCTAssertTrue(loaded.menuEnabled)
        XCTAssertEqual(loaded, .activeDefault)
    }

    func testSetMenuEnabledPreservesExistingSettings() throws {
        let fileURL = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        var config = RightClickConfiguration.activeDefault
        config.copyFileName = false
        config.openWithApps = [
            RightClickOpenWithApp(name: "Code", appPath: "/Applications/Code.app")
        ]
        XCTAssertTrue(RightClickConfigurationStore.save(config, to: fileURL))

        RightClickConfigurationStore.setMenuEnabled(false, fileURL: fileURL)
        var loaded = RightClickConfigurationStore.load(from: fileURL)
        XCTAssertFalse(loaded.menuEnabled)
        XCTAssertFalse(loaded.copyFileName)
        XCTAssertEqual(loaded.openWithApps.first?.name, "Code")

        RightClickConfigurationStore.setMenuEnabled(true, fileURL: fileURL)
        loaded = RightClickConfigurationStore.load(from: fileURL)
        XCTAssertTrue(loaded.menuEnabled)
        XCTAssertFalse(loaded.copyFileName)
        XCTAssertEqual(loaded.openWithApps.first?.name, "Code")
    }
}

final class RightClickOpenWithAppTests: XCTestCase {
    func testMatchesListedExtensionsCaseInsensitively() {
        let app = RightClickOpenWithApp(name: "Editor", appPath: "/E.app", fileExtensions: ["txt", "md"])
        XCTAssertTrue(app.matches(fileExtension: "txt"))
        XCTAssertTrue(app.matches(fileExtension: "TXT"))
        XCTAssertTrue(app.matches(fileExtension: "md"))
        XCTAssertFalse(app.matches(fileExtension: "png"))
    }

    func testEmptyExtensionsMatchesEverything() {
        let app = RightClickOpenWithApp(name: "Editor", appPath: "/E.app", fileExtensions: [])
        XCTAssertTrue(app.matches(fileExtension: "anything"))
        XCTAssertTrue(app.matches(fileExtension: ""))
    }
}

final class RightClickOpenWithParsingTests: XCTestCase {
    private func url(_ string: String) -> URL {
        var components = URLComponents()
        components.scheme = "mactools"
        components.host = "right-click"
        components.path = "/open-with"
        components.queryItems = queryItems(from: string)
        return components.url!
    }

    private func queryItems(from pairs: String) -> [URLQueryItem] {
        pairs.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return URLQueryItem(name: parts[0], value: parts.count > 1 ? parts[1] : nil)
        }
    }

    func testParseAcceptsValidAppAndFiles() {
        let request = RightClickURLRouter.parseOpenWithRequest(
            url("app=/Applications/Code.app&file=/tmp/a.txt&file=/tmp/b.md"),
            fileExists: { _ in true },
            isApplicationBundle: { _ in true }
        )
        XCTAssertEqual(request?.appURL.path, "/Applications/Code.app")
        XCTAssertEqual(request?.files.map(\.path), ["/tmp/a.txt", "/tmp/b.md"])
    }

    func testParseRejectsNonAppBundle() {
        XCTAssertNil(RightClickURLRouter.parseOpenWithRequest(
            url("app=/tmp/x&file=/tmp/a.txt"),
            fileExists: { _ in true },
            isApplicationBundle: { _ in false }
        ))
    }

    func testParseRejectsWhenNoFilesExist() {
        XCTAssertNil(RightClickURLRouter.parseOpenWithRequest(
            url("app=/Applications/Code.app&file=/tmp/missing"),
            fileExists: { _ in false },
            isApplicationBundle: { _ in true }
        ))
    }

    func testParseDropsMissingFilesKeepsExisting() {
        let request = RightClickURLRouter.parseOpenWithRequest(
            url("app=/Applications/Code.app&file=/tmp/exists&file=/tmp/missing"),
            fileExists: { $0 == "/tmp/exists" },
            isApplicationBundle: { _ in true }
        )
        XCTAssertEqual(request?.files.map(\.path), ["/tmp/exists"])
    }
}

final class RightClickURLSchemeTests: XCTestCase {
    func testBundleURLSchemesReadsDebugSchemeFromBundleInfo() {
        let bundle = URLSchemeBundleMock(urlTypes: [
            ["CFBundleURLSchemes": ["mactools-dev"]]
        ])

        XCTAssertEqual(RightClickURLRouter.bundleURLSchemes(bundle: bundle), ["mactools-dev"])
    }

    func testBundleURLSchemesFallsBackToReleaseSchemeWhenMissing() {
        XCTAssertEqual(RightClickURLRouter.bundleURLSchemes(bundle: URLSchemeBundleMock(urlTypes: nil)), ["mactools"])
    }
}

private final class URLSchemeBundleMock: Bundle, @unchecked Sendable {
    private let urlTypes: [[String: Any]]?

    init(urlTypes: [[String: Any]]?) {
        self.urlTypes = urlTypes
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? {
        key == "CFBundleURLTypes" ? urlTypes : nil
    }
}
