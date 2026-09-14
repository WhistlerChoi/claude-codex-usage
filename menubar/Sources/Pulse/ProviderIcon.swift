import AppKit

/// The two usage providers shown in the menu bar, each with a small brand-colored mark.
///
/// The marks are vector approximations drawn in code (no bundled logo assets): the Claude
/// sunburst as twelve rounded rays, the Codex/OpenAI knot as six interlocking L-shaped
/// strokes. Colors are fixed brand colors — the icon says *who*, the percentage next to it
/// keeps the usage-threshold color and says *how much*.
enum Provider {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var brandColor: NSColor {
        switch self {
        case .claude: return NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)  // #D97757
        case .codex: return NSColor(srgbRed: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255, alpha: 1)   // #10A37F
        }
    }

    private static var cache: [String: NSImage] = [:]

    /// A square, non-template icon `pointSize` points on a side, drawn in `brandColor`.
    func icon(pointSize: CGFloat) -> NSImage {
        let key = "\(displayName)-\(pointSize)"
        if let cached = Provider.cache[key] { return cached }
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true
        brandColor.set()
        switch self {
        case .claude: Provider.drawClaudeMark(size: pointSize)
        case .codex: Provider.drawCodexMark(size: pointSize)
        }
        image.unlockFocus()
        image.isTemplate = false
        Provider.cache[key] = image
        return image
    }

    /// Twelve rounded rays radiating from the center, alternating long/short.
    private static func drawClaudeMark(size s: CGFloat) {
        let center = NSPoint(x: s / 2, y: s / 2)
        let rayWidth = s * 0.13
        let inner = s * 0.10
        for i in 0..<12 {
            let outer = (i % 2 == 0) ? s * 0.48 : s * 0.38
            let rect = NSRect(x: -rayWidth / 2, y: inner, width: rayWidth, height: outer - inner)
            let ray = NSBezierPath(roundedRect: rect, xRadius: rayWidth / 2, yRadius: rayWidth / 2)
            var transform = AffineTransform(translationByX: center.x, byY: center.y)
            transform.rotate(byDegrees: CGFloat(i) * 30 + 15)
            ray.transform(using: transform)
            ray.fill()
        }
    }

    /// Six L-shaped strokes with 60° symmetry: each runs from an inner hexagon vertex out to
    /// the outer hexagon, then along one outer edge, so the strokes interlock into a knot.
    private static func drawCodexMark(size s: CGFloat) {
        let center = NSPoint(x: s / 2, y: s / 2)
        let outerR = s * 0.43
        let innerR = s * 0.20
        let stroke = s * 0.10
        func vertex(_ r: CGFloat, _ deg: CGFloat) -> NSPoint {
            let rad = deg * .pi / 180
            return NSPoint(x: center.x + r * cos(rad), y: center.y + r * sin(rad))
        }
        for i in 0..<6 {
            let a = CGFloat(i) * 60 + 90
            let path = NSBezierPath()
            path.lineWidth = stroke
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: vertex(innerR, a))
            path.line(to: vertex(outerR, a))
            path.line(to: vertex(outerR, a + 60))
            path.stroke()
        }
    }
}
