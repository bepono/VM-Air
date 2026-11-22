// Draws the VM Manager app icon into an .iconset folder.
//   swift make-icon.swift <out.iconset>
// Then: iconutil -c icns <out.iconset>
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// Draw on a 1024×1024 canvas (y up).
func draw(_ c: CGContext) {
    // macOS icon grid: 824×824 body, 100 px margin, continuous-ish corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    c.addPath(bodyPath)
    c.setFillColor(color(0x2A2470))
    c.fillPath()
    c.restoreGState()

    // Body gradient: indigo → teal.
    c.saveGState()
    c.addPath(bodyPath)
    c.clip()
    let bg = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0x3A2C93), color(0x2D5BB8), color(0x18A6A0)] as CFArray,
        locations: [0, 0.55, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 160, y: 940), end: CGPoint(x: 880, y: 80), options: [])
    // Soft highlight in the upper left.
    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(
        glow, startCenter: CGPoint(x: 300, y: 820), startRadius: 0,
        endCenter: CGPoint(x: 300, y: 820), endRadius: 520, options: [])
    c.restoreGState()

    // A window on its own, behind: the "other" VM.
    func window(_ r: CGRect, fill: CGColor, bar: CGColor, alpha: CGFloat) {
        let path = CGPath(roundedRect: r, cornerWidth: 46, cornerHeight: 46, transform: nil)
        c.saveGState()
        c.setAlpha(alpha)
        c.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.35))
        c.addPath(path)
        c.setFillColor(fill)
        c.fillPath()
        c.restoreGState()

        c.saveGState()
        c.setAlpha(alpha)
        c.addPath(path)
        c.clip()
        c.setFillColor(bar)
        c.fill(CGRect(x: r.minX, y: r.maxY - 78, width: r.width, height: 78))
        for (i, dot) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            c.setFillColor(color(UInt32(dot)))
            c.fillEllipse(in: CGRect(x: r.minX + 40 + CGFloat(i) * 46, y: r.maxY - 56, width: 32, height: 32))
        }
        c.restoreGState()
    }

    window(
        CGRect(x: 318, y: 404, width: 486, height: 380), fill: color(0xF4F6FB), bar: color(0xDCE1EC),
        alpha: 0.55)
    let front = CGRect(x: 214, y: 236, width: 540, height: 420)
    window(front, fill: color(0x12151F), bar: color(0x262B3A), alpha: 1)

    // Prompt in the front window: a chevron and a cursor block.
    c.saveGState()
    c.setStrokeColor(color(0x34E0C8))
    c.setLineWidth(30)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.move(to: CGPoint(x: front.minX + 74, y: front.minY + 250))
    c.addLine(to: CGPoint(x: front.minX + 150, y: front.minY + 192))
    c.addLine(to: CGPoint(x: front.minX + 74, y: front.minY + 134))
    c.strokePath()
    c.setFillColor(color(0x34E0C8))
    let cursor = CGRect(x: front.minX + 190, y: front.minY + 118, width: 96, height: 28)
    c.addPath(CGPath(roundedRect: cursor, cornerWidth: 10, cornerHeight: 10, transform: nil))
    c.fillPath()
    // A faint second "word" after the cursor.
    c.setFillColor(color(0xFFFFFF, 0.16))
    c.addPath(
        CGPath(
            roundedRect: CGRect(x: front.minX + 330, y: front.minY + 178, width: 140, height: 28),
            cornerWidth: 10, cornerHeight: 10, transform: nil))
    c.fillPath()
    c.restoreGState()
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let ctx = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
        draw(ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
print("wrote \(out.path)")
