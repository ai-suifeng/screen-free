import AppKit
import ScreenCaptureKit

/// What to record. Rects are in global "CG" coordinates: points, origin top-left of the primary display.
enum CaptureTarget {
    case display(SCDisplay)
    case window(SCWindow)
    /// `rect` is relative to the display, in points, origin top-left.
    case area(SCDisplay, CGRect)

    var kind: CaptureKind {
        switch self {
        case .display: .display
        case .window: .window
        case .area: .area
        }
    }

    var title: String {
        switch self {
        case .display(let d): NSScreen.screen(for: d.displayID)?.localizedName ?? "屏幕"
        case .window(let w): w.owningApplication?.applicationName ?? w.title ?? "窗口"
        case .area: "选定区域"
        }
    }

    var globalRect: CGRect {
        switch self {
        case .display(let d): d.frame
        case .window(let w): w.frame
        case .area(let d, let r): r.offsetBy(dx: d.frame.minX, dy: d.frame.minY)
        }
    }

    var displayID: CGDirectDisplayID {
        switch self {
        case .display(let d), .area(let d, _): d.displayID
        case .window(let w):
            NSScreen.screens.first { $0.cgFrame.intersects(w.frame) }?.displayID ?? CGMainDisplayID()
        }
    }

    var scale: Double {
        Double(NSScreen.screen(for: displayID)?.backingScaleFactor ?? 2)
    }

    /// Output pixel size, rounded to even numbers for the encoder.
    var pixelSize: (width: Int, height: Int) {
        let r = globalRect
        func even(_ v: Double) -> Int { max(2, Int(v * scale) / 2 * 2) }
        return (even(r.width), even(r.height))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }

    /// The screen's frame in CG global coordinates (origin top-left of the primary display).
    var cgFrame: CGRect { CGRect.fromCocoa(frame) }
}

extension CGRect {
    static var primaryScreenHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Converts a Cocoa (bottom-left origin) global rect to CG (top-left origin).
    static func fromCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Converts a CG (top-left origin) global rect to Cocoa (bottom-left origin).
    var toCocoa: CGRect {
        CGRect(x: minX, y: CGRect.primaryScreenHeight - maxY, width: width, height: height)
    }
}

extension CGPoint {
    /// Converts a Cocoa global point (e.g. `NSEvent.mouseLocation`) to CG global coordinates.
    var cocoaToCG: CGPoint { CGPoint(x: x, y: CGRect.primaryScreenHeight - y) }
}

enum ShareableContent {
    static func fetch() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    /// Windows worth offering in the picker.
    static func pickableWindows(_ content: SCShareableContent) -> [SCWindow] {
        let me = Bundle.main.bundleIdentifier
        let hidden: Set<String> = ["com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
                                   "com.apple.WindowManager", "com.apple.systemuiserver"]
        return content.windows.filter { w in
            guard let app = w.owningApplication, w.windowLayer == 0, w.isOnScreen,
                  w.frame.width > 120, w.frame.height > 80 else { return false }
            return app.bundleIdentifier != me && !hidden.contains(app.bundleIdentifier)
        }
    }
}
