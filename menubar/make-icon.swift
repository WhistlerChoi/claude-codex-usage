// Generate the Pulse app icon (AppIcon.icns) — a white speedometer/gauge glyph on a
// warm Claude-orange squircle, matching the gauge shown in the About header (header.png).
//
// Usage:
//   swift make-icon.swift                 # build AppIcon.icns (+ AppIcon.iconset/)
//   swift make-icon.swift --preview p.png # also write a 512px preview PNG
//
// Requires macOS 13+ (SF Symbols). The .icns is committed and copied into the bundle
// by build-app.sh, so this script only needs to be re-run when the icon design changes.
import AppKit

// Warm Claude-family gradient (same tones as the About header fallback).
let topColor = NSColor(srgbRed: 0.90, green: 0.52, blue: 0.34, alpha: 1.0)  // light coral
let bottomColor = NSColor(srgbRed: 0.62, green: 0.27, blue: 0.17, alpha: 1.0)  // deep terracotta

/// Pick the first available gauge-style SF Symbol (names vary across macOS versions).
func gaugeSymbol(pointSize: CGFloat) -> NSImage {
    let names = ["gauge.medium", "gauge", "speedometer", "gauge.with.needle"]
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    for name in names {
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            return img
        }
    }
    fatalError("No gauge SF Symbol available on this system")
}

/// White-tint a (template) symbol image.
func whiteTinted(_ symbol: NSImage) -> NSImage {
    let out = NSImage(size: symbol.size)
    out.lockFocus()
    symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

/// Render the icon at `px` × `px` pixels and return PNG data.
func renderIcon(px: Int) -> Data {
    let S = CGFloat(px)
    let bmp = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)

    // macOS icon grid: rounded square fills ~80.5% of the canvas, leaving a transparent margin.
    let side = S * 0.8047
    let margin = (S - side) / 2.0
    let radius = side * 0.2237
    let squircle = NSRect(x: margin, y: margin, width: side, height: side)
    let path = NSBezierPath(roundedRect: squircle, xRadius: radius, yRadius: radius)
    path.addClip()

    NSGradient(colors: [topColor, bottomColor])?.draw(in: squircle, angle: -55)

    // Gauge glyph, centered, ~52% of the squircle width, in white.
    let glyph = whiteTinted(gaugeSymbol(pointSize: side * 0.52))
    let g = glyph.size
    let scale = min((side * 0.56) / g.width, (side * 0.56) / g.height)
    let gw = g.width * scale, gh = g.height * scale
    let gRect = NSRect(x: (S - gw) / 2.0, y: (S - gh) / 2.0, width: gw, height: gh)
    glyph.draw(in: gRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return bmp.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let fm = FileManager.default

// Build the .iconset (the sizes/names `iconutil` expects).
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for v in variants {
    try! renderIcon(px: v.px).write(to: iconset.appendingPathComponent(v.name))
}

// Convert to .icns.
let icns = here.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else { fatalError("iconutil failed") }
try? fm.removeItem(at: iconset)
print("✅ Wrote \(icns.path)")

if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try! renderIcon(px: 512).write(to: out)
    print("   preview → \(out.path)")
}
