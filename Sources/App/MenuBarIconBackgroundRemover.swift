import AppKit
import CoreGraphics
import Foundation
import simd

enum MenuBarIconBackgroundRemover {
    static func removingBackground(
        from image: NSImage
    ) -> NSImage? {
        guard
            let source = cgImage(from: image),
            let context = bitmapContext(width: source.width, height: source.height)
        else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.draw(source, in: rect)

        guard let data = context.data else {
            return nil
        }

        let pointer = data.bindMemory(to: UInt8.self, capacity: source.width * source.height * 4)
        let backgroundColor = averageCornerColor(pointer: pointer, width: source.width, height: source.height)
        applyAlphaMask(
            pointer: pointer,
            width: source.width,
            height: source.height,
            backgroundColor: backgroundColor,
            tolerance: 0.16
        )

        guard let output = context.makeImage() else {
            return nil
        }

        return NSImage(cgImage: output, size: image.size)
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func averageCornerColor(
        pointer: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int
    ) -> SIMD3<Double> {
        let sampleSize = max(1, min(width, height, 8))
        let origins = [
            (x: 0, y: 0),
            (x: max(width - sampleSize, 0), y: 0),
            (x: 0, y: max(height - sampleSize, 0)),
            (x: max(width - sampleSize, 0), y: max(height - sampleSize, 0))
        ]

        var total = SIMD3<Double>(repeating: 0)
        var weight = 0.0

        for origin in origins {
            for y in origin.y..<(origin.y + sampleSize) {
                for x in origin.x..<(origin.x + sampleSize) {
                    let offset = ((y * width) + x) * 4
                    let alpha = Double(pointer[offset + 3]) / 255
                    guard alpha > 0 else {
                        continue
                    }

                    total += SIMD3<Double>(
                        Double(pointer[offset]) / 255,
                        Double(pointer[offset + 1]) / 255,
                        Double(pointer[offset + 2]) / 255
                    ) * alpha
                    weight += alpha
                }
            }
        }

        guard weight > 0 else {
            return SIMD3<Double>(repeating: 1)
        }

        return total / weight
    }

    private static func applyAlphaMask(
        pointer: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        backgroundColor: SIMD3<Double>,
        tolerance: Double
    ) {
        let softEdge = max(tolerance * 0.8, 0.02)
        let count = width * height

        for pixelIndex in 0..<count {
            let offset = pixelIndex * 4
            let color = SIMD3<Double>(
                Double(pointer[offset]) / 255,
                Double(pointer[offset + 1]) / 255,
                Double(pointer[offset + 2]) / 255
            )
            let distance = simd_distance(color, backgroundColor)

            guard distance < tolerance + softEdge else {
                continue
            }

            let alphaFactor = min(max((distance - tolerance) / softEdge, 0), 1)
            let originalAlpha = Double(pointer[offset + 3])
            pointer[offset + 3] = UInt8((originalAlpha * alphaFactor).rounded())
        }
    }
}
