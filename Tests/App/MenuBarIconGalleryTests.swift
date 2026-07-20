import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MenuBarIconGalleryTests: XCTestCase {
    func testCheckedInGalleryIncludesStaticAssetsAcrossAllCategories() throws {
        let galleryRoot = repositoryRoot
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("icon-gallery", isDirectory: true)
        let catalogData = try Data(contentsOf: galleryRoot.appendingPathComponent("catalog.json"))
        let catalog = try MenuBarIconGalleryCoding.decoder.decode(MenuBarIconGalleryCatalog.self, from: catalogData)
        let staticAssets = catalog.assets.filter { !$0.isAnimated }
        let staticAssetsByCategory = Dictionary(grouping: staticAssets, by: \.categoryID)

        XCTAssertEqual(staticAssets.count, 13)
        XCTAssertEqual(staticAssetsByCategory["featured"]?.count, 3)
        for category in catalog.categories where category.id != "featured" {
            XCTAssertEqual(staticAssetsByCategory[category.id]?.count, 2, "Missing static icons in \(category.id)")
        }
        XCTAssertTrue(staticAssets.allSatisfy { $0.frameCount == 1 })
        XCTAssertTrue(staticAssets.allSatisfy { $0.renderingMode == .template })
    }

    func testCheckedInStaticAssetsHaveTrackedSources() throws {
        let galleryRoot = repositoryRoot
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("icon-gallery", isDirectory: true)
        let catalogData = try Data(contentsOf: galleryRoot.appendingPathComponent("catalog.json"))
        let catalog = try MenuBarIconGalleryCoding.decoder.decode(MenuBarIconGalleryCatalog.self, from: catalogData)
        let staticAssetIDs = Set(catalog.assets.filter { !$0.isAnimated }.map(\.id))
        let manifestData = try Data(contentsOf: galleryRoot.appendingPathComponent("sources/manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        let sources = try XCTUnwrap(manifest?["sources"] as? [[String: Any]])
        let trackedAssetIDs = Set(sources.flatMap { source -> [String] in
            let assets = source["assets"] as? [[String: Any]] ?? []
            return assets.compactMap { $0["catalogID"] as? String }
        })

        XCTAssertEqual(trackedAssetIDs, staticAssetIDs)
    }

    func testCheckedInTemplateAssetsUseBlackTransparentFrames() throws {
        let galleryRoot = repositoryRoot
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("icon-gallery", isDirectory: true)
        let catalogData = try Data(contentsOf: galleryRoot.appendingPathComponent("catalog.json"))
        let catalog = try MenuBarIconGalleryCoding.decoder.decode(MenuBarIconGalleryCatalog.self, from: catalogData)
        let templateAssets = catalog.assets.filter { $0.renderingMode == .template }

        XCTAssertFalse(templateAssets.isEmpty)
        for asset in templateAssets {
            for index in 0..<asset.frameCount {
                let frameURL = galleryRoot
                    .appendingPathComponent("assets", isDirectory: true)
                    .appendingPathComponent(asset.id, isDirectory: true)
                    .appendingPathComponent("frames", isDirectory: true)
                    .appendingPathComponent(String(format: "frame-%03d.png", index))
                let image = try XCTUnwrap(
                    NSImage(contentsOf: frameURL),
                    "Missing template frame: \(frameURL.path)"
                )

                XCTAssertTrue(
                    isBlackTransparentTemplate(image),
                    "Template asset contains non-black or opaque-background artwork: \(frameURL.path)"
                )
            }
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func isBlackTransparentTemplate(_ image: NSImage) -> Bool {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return false
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
            return false
        }

        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hasVisiblePixel = false
        var hasTransparentPixel = false

        for pixelOffset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[pixelOffset + 3])
            if alpha <= 8 {
                hasTransparentPixel = true
                continue
            }

            hasVisiblePixel = true
            let red = Int(pixels[pixelOffset])
            let green = Int(pixels[pixelOffset + 1])
            let blue = Int(pixels[pixelOffset + 2])
            let maximumChannel = max(red, green, blue)
            let minimumChannel = min(red, green, blue)
            let allowedChannelValue = max(12, Int(Double(alpha) * 0.12))
            guard maximumChannel - minimumChannel <= 6,
                  maximumChannel <= allowedChannelValue
            else {
                return false
            }
        }

        return hasVisiblePixel && hasTransparentPixel
    }
}
