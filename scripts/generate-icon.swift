#!/usr/bin/env swift
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon.swift <output.iconset>\n", stderr)
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
try? fileManager.removeItem(at: output)
try fileManager.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func makeIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "TilesIcon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: scale, height: scale).fill()

    let backgroundRect = NSRect(x: scale * 0.055, y: scale * 0.055, width: scale * 0.89, height: scale * 0.89)
    let background = NSBezierPath(roundedRect: backgroundRect, xRadius: scale * 0.215, yRadius: scale * 0.215)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.18, green: 0.12, blue: 0.55, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.92, alpha: 1),
        NSColor(calibratedRed: 0.05, green: 0.76, blue: 0.78, alpha: 1)
    ])?.draw(in: background, angle: -42)

    let shine = NSBezierPath(ovalIn: NSRect(x: scale * 0.13, y: scale * 0.55, width: scale * 0.72, height: scale * 0.48))
    NSColor.white.withAlphaComponent(0.10).setFill()
    shine.fill()

    let tileArea = NSRect(x: scale * 0.19, y: scale * 0.22, width: scale * 0.62, height: scale * 0.56)
    let gap = max(1, scale * 0.025)
    let columnWidth = (tileArea.width - gap * 2) / 3
    for column in 0..<3 {
        let rect = NSRect(x: tileArea.minX + CGFloat(column) * (columnWidth + gap),
                          y: tileArea.minY,
                          width: columnWidth,
                          height: tileArea.height)
        let tile = NSBezierPath(roundedRect: rect, xRadius: scale * 0.035, yRadius: scale * 0.035)
        NSColor.white.withAlphaComponent(column == 1 ? 0.92 : 0.70).setFill()
        tile.fill()
    }

    let handle = NSBezierPath(roundedRect: NSRect(x: scale * 0.465, y: scale * 0.39, width: scale * 0.07, height: scale * 0.22),
                              xRadius: scale * 0.035, yRadius: scale * 0.035)
    NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.58, alpha: 0.82).setFill()
    handle.fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "TilesIcon", code: 2)
    }
    return data
}

for (name, size) in variants {
    try makeIcon(size: size).write(to: output.appendingPathComponent(name))
}
