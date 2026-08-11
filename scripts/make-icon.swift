#!/usr/bin/env swift
// Renders the Mac app icon — the same two linked rings as the Android launcher
// icon — and packages it as mac-app/Ecosystem/AppIcon.icns.
//
// Run: swift scripts/make-icon.swift

import AppKit
import Foundation

// Matches android-app/.../ic_launcher_foreground.xml and values/colors.xml
let background = NSColor(srgbRed: 0x1B / 255, green: 0x5E / 255, blue: 0x20 / 255, alpha: 1)
let ringFront = NSColor.white
let ringBack = NSColor(srgbRed: 0xA5 / 255, green: 0xD6 / 255, blue: 0xA7 / 255, alpha: 1)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    // macOS icons sit in a rounded square with a margin around them.
    let margin = size * 0.10
    let plate = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let corner = plate.width * 0.225
    let platePath = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner,
                           transform: nil)

    // Subtle vertical gradient keeps it from looking flat at large sizes.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let top = background.blended(withFraction: 0.18, of: .white)!
    let colors = [top.cgColor, background.cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY),
                           end: CGPoint(x: 0, y: plate.minY), options: [])
    ctx.restoreGState()

    // Two interlocking rings: the phone and the Mac, joined.
    let radius = plate.width * 0.205
    let stroke = plate.width * 0.075
    let offset = radius * 0.78
    let centerY = plate.midY
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)

    // Same overlap order as the phone: white ring first, green over it.
    ctx.setStrokeColor(ringFront.cgColor)
    ctx.addEllipse(in: CGRect(x: plate.midX - offset - radius, y: centerY - radius,
                              width: radius * 2, height: radius * 2))
    ctx.strokePath()

    ctx.setStrokeColor(ringBack.cgColor)
    ctx.addEllipse(in: CGRect(x: plate.midX + offset - radius, y: centerY - radius,
                              width: radius * 2, height: radius * 2))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes iconutil expects for a complete .icns.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    let data = drawIcon(size: variant.pixels).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let output = root.appendingPathComponent("mac-app/Ecosystem/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(output.path)")
