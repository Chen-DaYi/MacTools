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

    func testBundledDefaultIconIsAvailable() {
        XCTAssertNotNil(NSImage(named: NSImage.Name("MenuBarIcon")))
    }

    func testBundledAppIconIsAvailable() {
        XCTAssertNotNil(AppMetadata.appIcon)
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

    func testGalleryPreviewUsesTheSameStandardHeight() async throws {
        let sourceURL = try makeImageFile(
            name: "gallery-wide.png",
            color: .systemOrange,
            size: NSSize(width: 120, height: 36)
        )
        let baseURL = URL(fileURLWithPath: sourceURL.deletingLastPathComponent().path + "/", isDirectory: true)
        let asset = MenuBarIconGalleryAsset(
            id: "gallery-wide",
            title: "Gallery Wide",
            categoryID: "tests",
            version: "1",
            previewPath: sourceURL.lastPathComponent,
            framePaths: nil,
            framePathPattern: nil,
            archivePath: nil,
            archiveFramePathPattern: nil,
            frameCount: 1,
            frameDuration: 1.0 / 6.0
        )
        let store = MenuBarIconRemoteAssetStore(rootDirectory: rootDirectory)

        let preview = try await store.loadPreviewImage(
            for: asset,
            contentBaseURL: baseURL,
            allowsFileResources: true
        )

        XCTAssertEqual(preview.size.height, MenuBarIconProcessing.standardIconPointSize)
        XCTAssertGreaterThan(preview.size.width, MenuBarIconProcessing.standardIconPointSize)
    }

    func testAnimatedFramesShareVisibleBounds() throws {
        let firstFrame = NSImage(size: NSSize(width: 120, height: 36))
        firstFrame.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 60, height: 36).fill()
        firstFrame.unlockFocus()

        let secondFrame = NSImage(size: NSSize(width: 120, height: 36))
        secondFrame.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 60, y: 0, width: 60, height: 36).fill()
        secondFrame.unlockFocus()

        let renderedFrames = MenuBarIconProcessing.renderedImages(from: [firstFrame, secondFrame])

        guard renderedFrames.count == 2 else {
            return XCTFail("Expected both animation frames to render.")
        }
        XCTAssertEqual(renderedFrames[0].size, renderedFrames[1].size)
        XCTAssertEqual(renderedFrames[0].size.height, MenuBarIconProcessing.standardIconPointSize)
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
