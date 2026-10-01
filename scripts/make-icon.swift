#!/usr/bin/env swift
// Renders the app icon (a sunset over waves) and packs it into an .icns file.
// Usage: swift scripts/make-icon.swift Resources/AppIcon.icns

import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"
let canvas = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

func wave(baseY: CGFloat, amplitude: CGFloat, wavelength: CGFloat, phase: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    var x: CGFloat = 0
    while x <= CGFloat(canvas) {
        path.addLine(to: CGPoint(x: x, y: baseY + amplitude * sin(x / wavelength * 2 * .pi + phase)))
        x += 4
    }
    path.addLine(to: CGPoint(x: CGFloat(canvas), y: 0))
    path.closeSubpath()
    return path
}

func renderIcon() -> CGImage {
    let context = CGContext(
        data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.3))
    context.addPath(shape)
    context.setFillColor(color(0x3B2C9E))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // Sky.
    context.drawLinearGradient(
        gradient([color(0xFFC46B), color(0xFF7A8A), color(0x9A5CF0), color(0x3B2C9E)], [0, 0.4, 0.75, 1]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
    )

    // Sun with a soft glow.
    let sun = CGPoint(x: 512, y: 548)
    context.drawRadialGradient(
        gradient([color(0xFFF2D0, 0.85), color(0xFFD38A, 0)], [0, 1]),
        startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 340, options: []
    )
    context.setFillColor(color(0xFFF3D4))
    context.fillEllipse(in: CGRect(x: sun.x - 148, y: sun.y - 148, width: 296, height: 296))

    // Waves, back to front.
    let layers: [(baseY: CGFloat, amplitude: CGFloat, wavelength: CGFloat, phase: CGFloat, top: UInt32, bottom: UInt32)] = [
        (468, 26, 430, 0.4, 0x8F63F2, 0x6A44D8),
        (372, 32, 360, 2.1, 0x6340D6, 0x4A2DB5),
        (268, 30, 300, 4.2, 0x3F2AA8, 0x26197A),
    ]
    for layer in layers {
        context.saveGState()
        context.addPath(wave(baseY: layer.baseY, amplitude: layer.amplitude, wavelength: layer.wavelength, phase: layer.phase))
        context.clip()
        context.drawLinearGradient(
            gradient([color(layer.top), color(layer.bottom)], [0, 1]),
            start: CGPoint(x: 512, y: layer.baseY + layer.amplitude), end: CGPoint(x: 512, y: 100), options: []
        )
        context.restoreGState()
    }

    // Sunlight glinting on the water.
    context.setFillColor(color(0xFFE3B0, 0.55))
    for (index, width) in [220, 150, 96, 54].enumerated() {
        let y = 420 - CGFloat(index) * 44
        let rect = CGRect(x: 512 - CGFloat(width) / 2, y: y, width: CGFloat(width), height: 12)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
    }
    context.fillPath()

    // Glassy highlight on the upper half.
    context.drawLinearGradient(
        gradient([color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)], [0, 1]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: []
    )
    context.restoreGState()

    // Hairline edge.
    context.addPath(shape)
    context.setStrokeColor(color(0xFFFFFF, 0.18))
    context.setLineWidth(3)
    context.strokePath()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, to url: URL) throws {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    try data.write(to: url)
}

let icon = renderIcon()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try writePNG(icon, size: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(icon, size: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(outputPath)")
