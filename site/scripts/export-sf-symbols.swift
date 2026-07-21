#!/usr/bin/env swift

import AppKit
import Foundation

let symbols = [
    "app.dashed",
    "arrow.clockwise",
    "arrow.counterclockwise",
    "arrow.up.right.square",
    "airpod.left",
    "airpod.right",
    "airpods.chargingcase",
    "battery.100",
    "battery.100.bolt",
    "bolt.fill",
    "chart.bar.xaxis",
    "checkmark",
    "checkmark.circle.fill",
    "chevron.down",
    "chevron.left",
    "chevron.right",
    "circle",
    "circle.lefthalf.filled",
    "circle.righthalf.filled",
    "computermouse",
    "computermouse.fill",
    "contextualmenu.and.cursorarrow",
    "cpu",
    "cpu.fill",
    "curlybraces",
    "cursorarrow.click.2",
    "display",
    "eject",
    "fan",
    "hammer",
    "internaldrive",
    "iphone",
    "keyboard",
    "keyboard.badge.eye",
    "lamp.floor",
    "laptopcomputer",
    "lock",
    "macwindow.on.rectangle",
    "magnifyingglass",
    "memorychip",
    "menubar.arrow.up.rectangle",
    "menubar.rectangle",
    "mic.slash",
    "minus.circle",
    "moon",
    "network",
    "power",
    "powerplug",
    "questionmark.circle",
    "rectangle.2.swap",
    "rectangle.bottomthird.inset.filled",
    "rectangle.topthird.inset.filled",
    "scroll",
    "shippingbox.fill",
    "sidebar.squares.leading",
    "slider.horizontal.3",
    "sparkles",
    "speaker.slash",
    "square.grid.2x2",
    "square.grid.3x3.fill",
    "stop.fill",
    "sun.max",
    "switch.2",
    "terminal",
    "text.bubble",
    "trash",
    "wrench.and.screwdriver.fill",
]

let compactSymbols = Set([
    "airpod.left",
    "airpod.right",
    "airpods.chargingcase",
    "computermouse.fill",
    "iphone",
    "laptopcomputer",
])

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let siteURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let repositoryURL = siteURL.deletingLastPathComponent()
let outputURL = repositoryURL.appendingPathComponent("docs/assets/sf-symbols", isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let configuration = NSImage.SymbolConfiguration(pointSize: 26, weight: .semibold)

for symbolName in symbols {
    guard
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    else {
        fputs("Unavailable SF Symbol: \(symbolName)\n", stderr)
        continue
    }

    let canvasDimension: CGFloat = compactSymbols.contains(symbolName) ? 40 : 64
    let canvasSize = NSSize(width: canvasDimension, height: canvasDimension)
    let canvas = NSImage(size: canvasSize)
    canvas.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    let drawingRect = NSRect(
        x: (canvasSize.width - symbol.size.width) / 2,
        y: (canvasSize.height - symbol.size.height) / 2,
        width: symbol.size.width,
        height: symbol.size.height
    )
    symbol.draw(in: drawingRect)
    canvas.unlockFocus()

    guard
        let tiff = canvas.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fputs("Unable to render SF Symbol: \(symbolName)\n", stderr)
        continue
    }

    try png.write(to: outputURL.appendingPathComponent("\(symbolName).png"), options: .atomic)
}
