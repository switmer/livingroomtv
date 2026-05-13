#!/usr/bin/env swift
// Renders AppIcon PNGs into an AppIcon.iconset directory.
// Usage: swift scripts/make-icon.swift <output-iconset-dir>
//
// After running, convert the iconset to .icns with:
//   iconutil --convert icns <output-iconset-dir> -o Resources/AppIcon.icns

import AppKit
import CoreGraphics

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output-iconset>\n".utf8))
    exit(1)
}

let outDir = CommandLine.arguments[1]
try? FileManager.default.removeItem(atPath: outDir)
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// macOS iconset expected sizes. Each tuple: (base-size, scale, filename).
let targets: [(Int, Int, String)] = [
    (16, 1, "icon_16x16.png"),
    (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"),
    (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"),
    (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"),
    (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"),
    (512, 2, "icon_512x512@2x.png"),
]

func render(pixels: Int) -> Data? {
    let canvasSize = CGFloat(pixels)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Inset the icon body so a soft drop shadow has somewhere to land. Apple
    // app icons sit ~5% in from the canvas edge for exactly this reason; a
    // full-bleed squircle has no margin to render shadow into.
    let margin = canvasSize * 0.05
    let size = canvasSize - margin * 2
    let radius = size * 0.225

    // Drop shadow: drawn at canvas level (before any clip / translate) so the
    // shadow blurs into the margin region. The fill is throwaway — it gets
    // covered by the gradient below — but `setShadow` needs a drawn shape to
    // cast a shadow from.
    let outerPath = CGPath(
        roundedRect: CGRect(x: margin, y: margin, width: size, height: size),
        cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -canvasSize * 0.012),
        blur: canvasSize * 0.045,
        color: CGColor(gray: 0, alpha: 0.45)
    )
    ctx.addPath(outerPath)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Translate so the rest of the drawing code can use (0, 0) as the icon's
    // top-left corner and `size` as the icon's working dimension.
    ctx.translateBy(x: margin, y: margin)

    // Rounded rectangle mask (macOS "squircle" approximation).
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Indigo → purple gradient background (matches AskAI sparkles theme).
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.35, green: 0.23, blue: 0.98, alpha: 1.0), // indigo
            CGColor(red: 0.64, green: 0.27, blue: 0.92, alpha: 1.0), // violet
            CGColor(red: 0.85, green: 0.31, blue: 0.70, alpha: 1.0), // pink-ish
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )

    // Subtle highlight sheen.
    let sheen = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: size * 0.55),
        options: []
    )

    // TV glyph: rounded rectangle "screen" with a play triangle.
    let screenW = size * 0.58
    let screenH = size * 0.38
    let screenX = (size - screenW) / 2
    let screenY = size * 0.30
    let screenRadius = size * 0.07

    // Screen fill
    let screenPath = CGPath(
        roundedRect: CGRect(x: screenX, y: screenY, width: screenW, height: screenH),
        cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil
    )
    ctx.addPath(screenPath)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillPath()

    // Play triangle inside the screen
    let triSize = screenH * 0.48
    let cx = size / 2
    let cy = screenY + screenH / 2
    ctx.move(to: CGPoint(x: cx - triSize * 0.35, y: cy + triSize * 0.5))
    ctx.addLine(to: CGPoint(x: cx - triSize * 0.35, y: cy - triSize * 0.5))
    ctx.addLine(to: CGPoint(x: cx + triSize * 0.55, y: cy))
    ctx.closePath()
    ctx.setFillColor(CGColor(red: 0.35, green: 0.23, blue: 0.98, alpha: 1.0))
    ctx.fillPath()

    // Stand "legs": two pill shapes below the screen
    let legY = screenY - size * 0.10
    let legH = size * 0.035
    let legW = size * 0.12
    let legRadius = legH / 2
    for dx in [-size * 0.11, size * 0.11] as [CGFloat] {
        let legPath = CGPath(
            roundedRect: CGRect(x: cx + dx - legW / 2, y: legY, width: legW, height: legH),
            cornerWidth: legRadius, cornerHeight: legRadius, transform: nil
        )
        ctx.addPath(legPath)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.fillPath()
    }

    // Thin inner highlight stroke around the squircle edge — gives the tile
    // crisp definition against any background. Stays inside the clip region
    // so it follows the rounded corners exactly.
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.setLineWidth(max(1, size * 0.006))
    ctx.strokePath()

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}

for (base, scale, name) in targets {
    let pixels = base * scale
    guard let data = render(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(2)
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try data.write(to: url)
    print("wrote \(name) (\(pixels)px)")
}
