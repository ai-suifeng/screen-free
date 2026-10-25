// Renders the app icon into Takes/Resources/Assets.xcassets/AppIcon.appiconset.
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: ~10% margin, continuous-corner squircle.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    squircle.addClip()
    let gradient = NSGradient(colors: [NSColor(red: 1, green: 0.42, blue: 0.4, alpha: 1),
                                       NSColor(red: 0.88, green: 0.27, blue: 0.6, alpha: 1),
                                       NSColor(red: 0.5, green: 0.33, blue: 0.98, alpha: 1)])!
    gradient.draw(in: body, angle: -45)
    // Soft top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    ctx.restoreGState()

    // Back "take" card.
    let cw = body.width * 0.6, ch = body.width * 0.44
    let back = CGRect(x: body.midX - cw / 2 + s * 0.05, y: body.midY - ch / 2 + s * 0.07, width: cw, height: ch)
    NSColor.white.withAlphaComponent(0.35).setFill()
    NSBezierPath(roundedRect: back, xRadius: s * 0.05, yRadius: s * 0.05).fill()

    // Front card with a record dot.
    let front = CGRect(x: body.midX - cw / 2 - s * 0.02, y: body.midY - ch / 2 - s * 0.03, width: cw, height: ch)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.04, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: front, xRadius: s * 0.05, yRadius: s * 0.05).fill()
    ctx.restoreGState()
    let d = s * 0.15
    let dot = CGRect(x: front.midX - d / 2, y: front.midY - d / 2, width: d, height: d)
    ctx.saveGState()
    NSBezierPath(ovalIn: dot).addClip()
    NSGradient(colors: [NSColor(red: 1, green: 0.36, blue: 0.36, alpha: 1), NSColor(red: 0.86, green: 0.26, blue: 0.62, alpha: 1)])!
        .draw(in: dot, angle: -45)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
var images: [String] = []
for (size, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try! render(size * scale).write(to: dir.appendingPathComponent(name))
        images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(size)x\#(size)"}"#)
    }
}
try! #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
    .write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("ok")
