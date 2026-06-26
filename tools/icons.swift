// Generates every icon the app needs by drawing the "swap" glyph directly (transparent,
// crisp, any color) — no external rasterizer, no baked-in background.
//   - Resources/menubar.png / menubar@2x.png  : black template glyph for the status bar
//   - build/AppIcon.iconset/*                 : gradient squircle + white glyph for the app icon
//   - .github/app-icon.png (optional)          : README icon
// Usage: swift icons.swift <resourcesDir> <iconsetDir> [githubDir]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: icons <resourcesDir> <iconsetDir> [githubDir]\n".utf8))
    exit(1)
}
let resDir = URL(fileURLWithPath: args[1])
let setDir = URL(fileURLWithPath: args[2])
let githubDir = args.count >= 4 ? URL(fileURLWithPath: args[3]) : nil
let fm = FileManager.default
try? fm.createDirectory(at: resDir, withIntermediateDirectories: true)
try? fm.createDirectory(at: setDir, withIntermediateDirectories: true)
if let githubDir {
    try? fm.createDirectory(at: githubDir, withIntermediateDirectories: true)
}

// "arrow-left-right" (Lucide) as polylines in a 24x24 viewBox.
let polylines: [[(CGFloat, CGFloat)]] = [
    [(8, 3), (4, 7), (8, 11)],   // top-left arrowhead
    [(4, 7), (20, 7)],           // top shaft
    [(16, 21), (20, 17), (16, 13)], // bottom-right arrowhead
    [(20, 17), (4, 17)],         // bottom shaft
]

/// Draw the glyph centered in a `box`-sized square (with `frac` of the canvas), flipping y for AppKit.
func drawGlyph(size: CGFloat, color: NSColor, frac: CGFloat) {
    let box = size * frac
    let ox = (size - box) / 2, oy = (size - box) / 2
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: ox + x / 24 * box, y: oy + (24 - y) / 24 * box) // flip y
    }
    let path = NSBezierPath()
    for line in polylines {
        path.move(to: pt(line[0].0, line[0].1))
        for p in line.dropFirst() { path.line(to: pt(p.0, p.1)) }
    }
    path.lineWidth = (2.1 / 24) * box
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color.setStroke()
    path.stroke()
}

func png(_ img: NSImage) -> Data {
    let size = img.size
    let width = max(1, Int(size.width.rounded()))
    let height = max(1, Int(size.height.rounded()))
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create bitmap representation")
    }

    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    img.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

// --- Menu bar template glyphs (black on transparent; AppKit recolors for light/dark) ---
func menubar(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    drawGlyph(size: size, color: .black, frac: 0.92)
    img.unlockFocus()
    return img
}
try png(menubar(size: 18)).write(to: resDir.appendingPathComponent("menubar.png"))
try png(menubar(size: 36)).write(to: resDir.appendingPathComponent("menubar@2x.png"))

// --- App icon: gradient squircle + white glyph ---
func appIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let inset = size * 0.092
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)

    // Soft drop shadow under the squircle.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: NSColor(white: 0, alpha: 0.30).cgColor)
    NSColor.black.setFill(); path.fill()
    ctx.restoreGState()

    // Near-black squircle with a hair of vertical depth.
    NSGradient(colors: [NSColor(white: 0.16, alpha: 1.0),
                        NSColor(white: 0.04, alpha: 1.0)])!
        .draw(in: path, angle: -90)

    // Subtle top sheen.
    ctx.saveGState(); path.addClip()
    NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0)])!
        .draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    ctx.restoreGState()

    drawGlyph(size: size, color: .white, frac: 0.60)
    img.unlockFocus()
    return img
}

let variants: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, s) in variants {
    try png(appIcon(size: s)).write(to: setDir.appendingPathComponent(name))
}

if let githubDir {
    try png(appIcon(size: 1024)).write(to: githubDir.appendingPathComponent("app-icon.png"))
    try? fm.removeItem(at: githubDir.appendingPathComponent("social-preview.png"))
}

print("icons: menubar.png/@2x + \(variants.count) app-icon variants")
