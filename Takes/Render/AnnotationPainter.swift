import AppKit
import CoreGraphics
import CoreText

/// Rasterizes vector annotations with Core Graphics. Coordinates are Core Image pixels (bottom-left origin).
enum AnnotationPainter {
    struct Sprite {
        var image: CGImage
        var origin: CGPoint
    }

    /// Draws `annotation` into a bitmap that covers only its bounds.
    /// `pt` is pixels per capture point; `progress` is seconds since the annotation started (for strokes).
    static func sprite(for a: Annotation, size S: CGSize, pt: Double, progress: Double) -> Sprite? {
        let lw = a.lineWidth * pt
        switch a.kind {
        case .box, .rect:
            let r = a.rect.ciRect(in: S)
            let badge = a.step != nil ? 26 * pt : 0
            let margin = lw * 3 + badge / 2 + 4
            return draw(bounds: r.insetBy(dx: -margin, dy: -margin)) { ctx, o in
                let rr = r.offsetBy(dx: -o.x, dy: -o.y)
                let radius = a.kind == .box ? min(10 * pt, rr.height / 3) : 4 * pt
                ctx.setStrokeColor(a.color.cgColor)
                ctx.setLineWidth(lw)
                if a.kind == .box {
                    ctx.setShadow(offset: .zero, blur: lw * 3, color: a.color.cgColor.copy(alpha: 0.7))
                }
                ctx.addPath(CGPath(roundedRect: rr, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.strokePath()
                if let step = a.step {
                    ctx.setShadow(offset: CGSize(width: 0, height: -pt), blur: 3 * pt, color: CGColor(gray: 0, alpha: 0.35))
                    let c = CGPoint(x: rr.minX, y: rr.maxY)
                    let d = badge
                    ctx.setFillColor(a.color.cgColor)
                    ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
                    ctx.setShadow(offset: .zero, blur: 0)
                    drawText("\(step)", in: ctx, center: c, size: d * 0.58, color: .white, bold: true)
                }
            }
        case .arrow:
            guard let first = a.points.first, let last = a.points.last else { return nil }
            let p0 = NormPoint(x: first.x, y: first.y).ciPoint(in: S)
            let p1 = NormPoint(x: last.x, y: last.y).ciPoint(in: S)
            let head = CGFloat(max(16 * pt, lw * 3.5))
            let bounds = CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p0.x - p1.x), height: abs(p0.y - p1.y))
                .insetBy(dx: -head - lw, dy: -head - lw)
            return draw(bounds: bounds) { ctx, o in
                let a0 = CGPoint(x: p0.x - o.x, y: p0.y - o.y), a1 = CGPoint(x: p1.x - o.x, y: p1.y - o.y)
                ctx.setShadow(offset: CGSize(width: 0, height: -pt), blur: 4 * pt, color: CGColor(gray: 0, alpha: 0.35))
                ctx.setStrokeColor(a.color.cgColor)
                ctx.setLineWidth(lw)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                let angle = atan2(a1.y - a0.y, a1.x - a0.x)
                let shaft = CGPoint(x: a1.x - cos(angle) * head * 0.6, y: a1.y - sin(angle) * head * 0.6)
                ctx.move(to: a0)
                ctx.addLine(to: shaft)
                ctx.strokePath()
                ctx.setFillColor(a.color.cgColor)
                ctx.move(to: a1)
                ctx.addLine(to: CGPoint(x: a1.x + head * cos(angle + .pi * 0.85), y: a1.y + head * sin(angle + .pi * 0.85)))
                ctx.addLine(to: CGPoint(x: a1.x + head * cos(angle - .pi * 0.85), y: a1.y + head * sin(angle - .pi * 0.85)))
                ctx.closePath()
                ctx.fillPath()
            }
        case .pen, .highlighter:
            let visible = a.points.filter { $0.t <= progress }
            guard visible.count >= 2 else { return nil }
            let pts = visible.map { NormPoint(x: $0.x, y: $0.y).ciPoint(in: S) }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                .insetBy(dx: -lw * 2, dy: -lw * 2)
            return draw(bounds: bounds) { ctx, o in
                ctx.setStrokeColor(a.color.cgColor.copy(alpha: a.kind == .highlighter ? 0.4 : 1)!)
                ctx.setLineWidth(lw)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                if a.kind == .pen {
                    ctx.setShadow(offset: .zero, blur: 2 * pt, color: CGColor(gray: 0, alpha: 0.25))
                }
                ctx.addLines(between: pts.map { CGPoint(x: $0.x - o.x, y: $0.y - o.y) })
                ctx.strokePath()
            }
        case .text:
            let r = a.rect.ciRect(in: S)
            let fontSize = max(10, r.height * 0.55)
            let text = a.text.isEmpty ? "文字" : a.text
            let width = textWidth(text, size: fontSize) + fontSize * 1.2
            let box = CGRect(x: r.minX, y: r.minY, width: max(width, r.height), height: r.height)
            return draw(bounds: box.insetBy(dx: -8 * pt, dy: -8 * pt)) { ctx, o in
                let b = box.offsetBy(dx: -o.x, dy: -o.y)
                ctx.setShadow(offset: CGSize(width: 0, height: -2 * pt), blur: 6 * pt, color: CGColor(gray: 0, alpha: 0.3))
                ctx.setFillColor(a.color.cgColor)
                ctx.addPath(CGPath(roundedRect: b, cornerWidth: b.height * 0.3, cornerHeight: b.height * 0.3, transform: nil))
                ctx.fillPath()
                ctx.setShadow(offset: .zero, blur: 0)
                let dark = a.color.r * 0.3 + a.color.g * 0.59 + a.color.b * 0.11 > 0.7
                drawText(text, in: ctx, center: CGPoint(x: b.midX, y: b.midY), size: fontSize,
                         color: dark ? .black : .white, bold: true)
            }
        case .spotlight, .magnify:
            // Drawn with Core Image; only the border is a sprite.
            let r = a.rect.ciRect(in: S)
            return draw(bounds: r.insetBy(dx: -lw * 3, dy: -lw * 3)) { ctx, o in
                let rr = r.offsetBy(dx: -o.x, dy: -o.y)
                let radius = min(12 * pt, rr.height / 3)
                ctx.setStrokeColor(a.kind == .magnify ? CGColor(gray: 1, alpha: 1) : a.color.cgColor.copy(alpha: 0.9)!)
                ctx.setLineWidth(a.kind == .magnify ? lw : lw * 0.6)
                ctx.addPath(CGPath(roundedRect: rr, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.strokePath()
            }
        }
    }

    /// A rounded "key cap" label for the keystroke overlay.
    static func keyBadge(_ text: String, height: Double) -> CGImage? {
        let font = height * 0.5
        let w = textWidth(text, size: font) + height * 0.8
        let bounds = CGRect(x: 0, y: 0, width: max(w, height), height: height)
        return draw(bounds: bounds.insetBy(dx: -height * 0.3, dy: -height * 0.3)) { ctx, o in
            let b = bounds.offsetBy(dx: -o.x, dy: -o.y)
            ctx.setShadow(offset: CGSize(width: 0, height: -height * 0.05), blur: height * 0.25, color: CGColor(gray: 0, alpha: 0.4))
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 0.82))
            ctx.addPath(CGPath(roundedRect: b, cornerWidth: height * 0.25, cornerHeight: height * 0.25, transform: nil))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0)
            drawText(text, in: ctx, center: CGPoint(x: b.midX, y: b.midY), size: font, color: .white, bold: true)
        }?.image
    }

    /// A white ring used for the click effect, drawn once and scaled.
    static let clickRing: CGImage? = {
        let size = 256.0
        return draw(bounds: CGRect(x: 0, y: 0, width: size, height: size)) { ctx, _ in
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(14)
            ctx.setShadow(offset: .zero, blur: 10, color: CGColor(gray: 0, alpha: 0.35))
            ctx.strokeEllipse(in: CGRect(x: 20, y: 20, width: size - 40, height: size - 40))
        }?.image
    }()

    static let cursorImage: (image: CGImage, hotspot: CGPoint, pointSize: CGSize)? = {
        let cursor = NSCursor.arrow
        let image = cursor.image
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil,
                                     hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: 4))]) else { return nil }
        return (cg, cursor.hotSpot, image.size)
    }()

    // MARK: Helpers

    private static func draw(bounds: CGRect, _ body: (CGContext, CGPoint) -> Void) -> Sprite? {
        let b = bounds.integral
        guard b.width >= 1, b.height >= 1, b.width < 10000, b.height < 10000,
              let ctx = CGContext(data: nil, width: Int(b.width), height: Int(b.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        body(ctx, b.origin)
        guard let image = ctx.makeImage() else { return nil }
        return Sprite(image: image, origin: b.origin)
    }

    private static func attributed(_ text: String, size: Double, color: NSColor, bold: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .medium)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    private static func textWidth(_ text: String, size: Double) -> Double {
        let line = CTLineCreateWithAttributedString(attributed(text, size: size, color: .white, bold: true))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    private static func drawText(_ text: String, in ctx: CGContext, center: CGPoint, size: Double, color: NSColor, bold: Bool) {
        let line = CTLineCreateWithAttributedString(attributed(text, size: size, color: color, bold: bold))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        ctx.textPosition = CGPoint(x: center.x - width / 2, y: center.y - (ascent - descent) / 2)
        CTLineDraw(line, ctx)
    }
}
