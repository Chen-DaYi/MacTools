import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MenuBarIconSettingsTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var rootDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "MenuBarIconSettingsTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuBarIconSettingsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        try super.tearDownWithError()
    }

    func testImportPersistsCurrentCustomIcon() throws {
        let sourceURL = try makeImageFile(name: "status-icon.png", color: .systemBlue)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL, for: .light)
        let payload = settings.imagePayload(for: NSAppearance(named: .aqua))

        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertFalse(payload.isTemplate)
        XCTAssertEqual(payload.image.size, NSSize(width: 18, height: 18))

        let reloadedSettings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        let reloadedPayload = reloadedSettings.imagePayload(for: NSAppearance(named: .aqua))
        XCTAssertTrue(reloadedSettings.hasCustomIcon)
        XCTAssertFalse(reloadedPayload.isTemplate)
        XCTAssertEqual(reloadedPayload.image.size, NSSize(width: 18, height: 18))
    }

    func testRenderedImageNormalizesNonSquareSourceToStandardHeight() throws {
        let sourceURL = try makeImageFile(
            name: "wide.png",
            color: .systemOrange,
            size: NSSize(width: 120, height: 36)
        )
        let sourceImage = try XCTUnwrap(NSImage(contentsOf: sourceURL))

        let renderedImage = try XCTUnwrap(MenuBarIconProcessing.renderedImage(from: sourceImage))

        XCTAssertEqual(renderedImage.size.height, MenuBarIconProcessing.standardIconPointSize)
        XCTAssertGreaterThan(renderedImage.size.width, MenuBarIconProcessing.standardIconPointSize)
    }

    func testResetToDefaultClearsCustomSelection() throws {
        let sourceURL = try makeImageFile(name: "reset.png", color: .systemGreen)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL, for: .light)
        settings.resetToDefault()

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertTrue(settings.imagePayload(for: NSAppearance(named: .aqua)).isTemplate)
    }

    private func makeImageFile(
        name: String,
        color: NSColor,
        size: NSSize = NSSize(width: 32, height: 32)
    ) throws -> URL {
        let directory = rootDirectory.appendingPathComponent("Fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(MenuBarIconProcessing.pngData(from: image))
        try data.write(to: url)
        return url
    }

}
