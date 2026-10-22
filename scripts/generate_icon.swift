import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: generate_icon.swift <iconset-directory> <icns-output>\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let icnsOutput = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

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

func render(size: Int, to url: URL) throws {
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
    ) else { throw NSError(domain: "BookooIcon", code: 1) }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024

    // Match the in-app identity: a single macOS system-blue rounded square
    // with the same clean white drop used by the menu and sidebar.
    let background = NSBezierPath(
        roundedRect: NSRect(x: 64 * scale, y: 64 * scale, width: 896 * scale, height: 896 * scale),
        xRadius: 208 * scale,
        yRadius: 208 * scale
    )
    NSColor(srgbRed: 10.0 / 255.0, green: 132.0 / 255.0, blue: 1.0, alpha: 1).setFill()
    background.fill()

    let drop = NSBezierPath()
    drop.move(to: NSPoint(x: 512 * scale, y: 762 * scale))
    drop.curve(
        to: NSPoint(x: 332 * scale, y: 452 * scale),
        controlPoint1: NSPoint(x: 472 * scale, y: 684 * scale),
        controlPoint2: NSPoint(x: 332 * scale, y: 548 * scale)
    )
    drop.curve(
        to: NSPoint(x: 512 * scale, y: 262 * scale),
        controlPoint1: NSPoint(x: 332 * scale, y: 346 * scale),
        controlPoint2: NSPoint(x: 412 * scale, y: 262 * scale)
    )
    drop.curve(
        to: NSPoint(x: 692 * scale, y: 452 * scale),
        controlPoint1: NSPoint(x: 612 * scale, y: 262 * scale),
        controlPoint2: NSPoint(x: 692 * scale, y: 346 * scale)
    )
    drop.curve(
        to: NSPoint(x: 512 * scale, y: 762 * scale),
        controlPoint1: NSPoint(x: 692 * scale, y: 548 * scale),
        controlPoint2: NSPoint(x: 552 * scale, y: 684 * scale)
    )
    drop.close()
    NSColor.white.setFill()
    drop.fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "BookooIcon", code: 2)
    }
    try png.write(to: url, options: .atomic)
}

for (name, size) in variants {
    try render(size: size, to: outputDirectory.appendingPathComponent(name))
}

// Build the modern PNG-backed ICNS container directly. This avoids depending on
// iconutil behavior that varies between Command Line Tools releases.
let icnsChunks: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

var body = Data()
for (type, filename) in icnsChunks {
    let png = try Data(contentsOf: outputDirectory.appendingPathComponent(filename))
    body.append(contentsOf: type.utf8)
    appendBigEndian(UInt32(png.count + 8), to: &body)
    body.append(png)
}

var icns = Data("icns".utf8)
appendBigEndian(UInt32(body.count + 8), to: &icns)
icns.append(body)
try icns.write(to: icnsOutput, options: .atomic)
