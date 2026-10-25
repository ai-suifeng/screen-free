import CoreGraphics
import SwiftUI

/// A rectangle in normalized capture space: origin top-left, each axis 0…1.
struct NormRect: Codable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let zero = NormRect(x: 0, y: 0, w: 0, h: 0)

    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }

    func clamped() -> NormRect {
        let w = min(max(self.w, 0), 1)
        let h = min(max(self.h, 0), 1)
        return NormRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), w: w, h: h)
    }

    func insetBy(_ dx: Double, _ dy: Double) -> NormRect {
        NormRect(x: x + dx, y: y + dy, w: w - 2 * dx, h: h - 2 * dy)
    }

    /// Converts to a Core Image rect (bottom-left origin) in a pixel space of `size`.
    func ciRect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: (1 - y - h) * size.height, width: w * size.width, height: h * size.height)
    }

    /// Converts to a top-left-origin rect in a view of `size`.
    func viewRect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height)
    }

    static func fromView(_ r: CGRect, in size: CGSize) -> NormRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return NormRect(x: r.minX / size.width, y: r.minY / size.height, w: r.width / size.width, h: r.height / size.height)
    }

    static func lerp(_ a: NormRect, _ b: NormRect, _ t: Double) -> NormRect {
        NormRect(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, w: a.w + (b.w - a.w) * t, h: a.h + (b.h - a.h) * t)
    }
}

struct NormPoint: Codable, Hashable {
    var x: Double
    var y: Double

    func ciPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: (1 - y) * size.height)
    }
}

struct RGBA: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let red = RGBA(r: 1, g: 0.27, b: 0.33)
    static let yellow = RGBA(r: 1, g: 0.8, b: 0.1)
    static let green = RGBA(r: 0.2, g: 0.82, b: 0.45)
    static let blue = RGBA(r: 0.2, g: 0.55, b: 1)
    static let purple = RGBA(r: 0.62, g: 0.38, b: 1)
    static let white = RGBA(r: 1, g: 1, b: 1)
    static let black = RGBA(r: 0, g: 0, b: 0)

    static let palette: [RGBA] = [.red, .yellow, .green, .blue, .purple, .white]

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

/// Smoothstep easing.
@inline(__always) func ease(_ t: Double) -> Double {
    let x = t.clamped(0, 1)
    return x * x * (3 - 2 * x)
}

@inline(__always) func easeOutCubic(_ t: Double) -> Double {
    let x = 1 - t.clamped(0, 1)
    return 1 - x * x * x
}

func formatDuration(_ seconds: Double, showFraction: Bool = false) -> String {
    let s = max(0, seconds)
    let m = Int(s) / 60
    let sec = Int(s) % 60
    if showFraction {
        let f = Int((s - floor(s)) * 10)
        return String(format: "%d:%02d.%d", m, sec, f)
    }
    if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, sec) }
    return String(format: "%d:%02d", m, sec)
}
