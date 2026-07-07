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

    func testImportPersistsCustomIconAndRecentItem() throws {
        let sourceURL = try makeImageFile(name: "status-icon.png", color: .systemBlue)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL, for: .light)
        let payload = settings.imagePayload(for: NSAppearance(named: .aqua))

        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertNil(settings.lastErrorMessage)
        XCTAssertEqual(settings.recentItems.first?.displayName, "status-icon")
        XCTAssertFalse(payload.isTemplate)
        XCTAssertEqual(payload.image.size, NSSize(width: 18, height: 18))

        let reloadedSettings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        XCTAssertTrue(reloadedSettings.hasCustomIcon)
        XCTAssertEqual(reloadedSettings.recentItems.count, 1)
    }

    func testDarkAppearanceFallsBackToLightCustomIcon() throws {
        let sourceURL = try makeImageFile(name: "shared.png", color: .systemRed)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL, for: .light)

        XCTAssertTrue(settings.hasCustomIcon)
        XCTAssertEqual(
            settings.imagePayload(for: NSAppearance(named: .darkAqua)).image.size,
            NSSize(width: 18, height: 18)
        )
    }

    func testResetToDefaultClearsCustomSelectionButKeepsRecents() throws {
        let sourceURL = try makeImageFile(name: "reset.png", color: .systemGreen)
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.importIcon(from: sourceURL, for: .light)
        settings.resetToDefault()

        XCTAssertFalse(settings.hasCustomIcon)
        XCTAssertEqual(settings.recentItems.count, 1)
        XCTAssertTrue(settings.imagePayload(for: NSAppearance(named: .aqua)).isTemplate)
    }

    func testRecentItemsKeepOnlyLatestSix() throws {
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        for index in 0..<7 {
            let sourceURL = try makeImageFile(name: "recent-\(index).png", color: .systemBlue)
            settings.importIcon(from: sourceURL)
        }

        XCTAssertEqual(settings.recentItems.count, 6)
        XCTAssertEqual(settings.recentItems.first?.displayName, "recent-6")
        XCTAssertFalse(settings.recentItems.contains { $0.displayName == "recent-0" })
    }

    func testAnimationSpeedPolicyClampsAndUsesSystemLoad() {
        XCTAssertEqual(
            MenuBarIconAnimationSpeedPolicy.normalizedManualMultiplier(9),
            MenuBarIconAnimationSpeedPolicy.maximumMultiplier
        )

        let lowLoadMultiplier = MenuBarIconAnimationSpeedPolicy.multiplier(
            mode: .adaptiveSystemLoad,
            manualMultiplier: 1,
            systemLoad: MenuBarIconAnimationSystemLoad(cpuUsage: 0.1, gpuUsage: nil, memoryUsage: 0.2)
        )
        let highLoadMultiplier = MenuBarIconAnimationSpeedPolicy.multiplier(
            mode: .adaptiveSystemLoad,
            manualMultiplier: 1,
            systemLoad: MenuBarIconAnimationSystemLoad(cpuUsage: 0.9, gpuUsage: 0.8, memoryUsage: 0.7)
        )

        XCTAssertGreaterThan(highLoadMultiplier, lowLoadMultiplier)
        XCTAssertLessThanOrEqual(highLoadMultiplier, MenuBarIconAnimationSpeedPolicy.maximumMultiplier)
    }

    private func makeImageFile(name: String, color: NSColor) throws -> URL {
        let directory = rootDirectory.appendingPathComponent("Fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(MenuBarIconProcessing.pngData(from: image))
        try data.write(to: url)
        return url
    }
}
