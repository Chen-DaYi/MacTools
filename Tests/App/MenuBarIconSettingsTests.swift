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

    func testTemplateGalleryAssetAdaptsThroughAppKitButton() async throws {
        let sourceURL = try makeTransparentImageFile(
            name: "template-black.png",
            artworkColor: .black
        )
        let baseURL = URL(fileURLWithPath: sourceURL.deletingLastPathComponent().path + "/", isDirectory: true)
        let asset = MenuBarIconGalleryAsset(
            id: "template-gallery-icon",
            title: "Template Gallery Icon",
            categoryID: "tests",
            version: "1",
            renderingMode: .template,
            previewPath: sourceURL.lastPathComponent,
            framePaths: [sourceURL.lastPathComponent],
            framePathPattern: nil,
            archivePath: nil,
            archiveFramePathPattern: nil,
            frameCount: 1,
            frameDuration: 1.0 / 6.0
        )
        let remoteRoot = rootDirectory
            .appendingPathComponent("MenuBarIcons", isDirectory: true)
            .appendingPathComponent("RemoteAssets", isDirectory: true)
        let store = MenuBarIconRemoteAssetStore(rootDirectory: remoteRoot)
        let preview = try await store.loadPreviewImage(
            for: asset,
            contentBaseURL: baseURL,
            allowsFileResources: true
        )
        let selection = try await store.installAsset(
            asset,
            contentBaseURL: baseURL,
            allowsFileResources: true
        )
        let settings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)

        settings.useRemoteAsset(selection)
        let payload = settings.imagePayload(for: NSAppearance(named: .darkAqua))
        let reloadedSettings = MenuBarIconSettings(userDefaults: userDefaults, rootDirectory: rootDirectory)
        let reloadedPayload = reloadedSettings.imagePayload(for: NSAppearance(named: .darkAqua))
        let lightBrightness = averageBrightnessWhenRendered(payload.image, appearance: .aqua)
        let darkBrightness = averageBrightnessWhenRendered(payload.image, appearance: .darkAqua)

        XCTAssertTrue(preview.isTemplate)
        XCTAssertEqual(selection.renderingMode, .template)
        XCTAssertTrue(payload.isTemplate)
        XCTAssertTrue(payload.animationFrames.allSatisfy(\.isTemplate))
        XCTAssertTrue(reloadedPayload.isTemplate)
        XCTAssertTrue(reloadedPayload.animationFrames.allSatisfy(\.isTemplate))
        XCTAssertLessThan(lightBrightness, 30)
        XCTAssertGreaterThan(darkBrightness, 100)
        XCTAssertGreaterThan(darkBrightness - lightBrightness, 80)
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

    private func makeTransparentImageFile(name: String, artworkColor: NSColor) throws -> URL {
        let directory = rootDirectory.appendingPathComponent("Fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        artworkColor.setFill()
        NSRect(x: 8, y: 8, width: 16, height: 16).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(MenuBarIconProcessing.pngData(from: image))
        try data.write(to: url)
        return url
    }

    private func averageBrightnessWhenRendered(
        _ image: NSImage,
        appearance: NSAppearance.Name
    ) -> Int {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.appearance = NSAppearance(named: appearance)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.image = image

        guard let representation = button.bitmapImageRepForCachingDisplay(in: button.bounds) else {
            return 0
        }
        representation.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: representation)

        guard let source = representation.cgImage else {
            return 0
        }
        let width = source.width
        let height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }

        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let statistics = stride(from: 0, to: pixels.count, by: 4).reduce(into: (brightness: 0, count: 0)) { result, pixelOffset in
            guard pixels[pixelOffset + 3] > 8 else {
                return
            }
            result.brightness += (
                Int(pixels[pixelOffset])
                    + Int(pixels[pixelOffset + 1])
                    + Int(pixels[pixelOffset + 2])
            ) / 3
            result.count += 1
        }
        guard statistics.count > 0 else {
            return 0
        }
        return statistics.brightness / statistics.count
    }
}
