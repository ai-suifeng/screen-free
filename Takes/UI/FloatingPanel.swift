import AppKit
import SwiftUI

/// Borderless, transparent panel that hosts SwiftUI and floats above other apps.
final class FloatingPanel: NSPanel {
    private var keyable = false

    init<Content: View>(level: NSWindow.Level = .floating, keyable: Bool = false, movable: Bool = false,
                        @ViewBuilder content: () -> Content) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.keyable = keyable
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = movable
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        contentView = hosting
    }

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    /// Sizes the panel to its SwiftUI content and centers it horizontally on `screen` at `y` from the top.
    func place(on screen: NSScreen, fromTop y: CGFloat? = nil, fromBottom bottom: CGFloat? = nil) {
        guard let view = contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let vf = screen.visibleFrame
        let originY: CGFloat
        if let y { originY = vf.maxY - y - size.height }
        else { originY = vf.minY + (bottom ?? 80) }
        setFrame(CGRect(x: vf.midX - size.width / 2, y: originY, width: size.width, height: size.height), display: true)
    }
}

/// Full-screen transparent panel for overlays such as the countdown or the area selector.
final class OverlayWindow: NSPanel {
    private var keyable: Bool

    init<Content: View>(screenFrame: CGRect, interactive: Bool, keyable: Bool = false, @ViewBuilder content: () -> Content) {
        self.keyable = keyable
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = !interactive
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = NSHostingView(rootView: content())
        setFrame(screenFrame, display: true)
    }

    override var canBecomeKey: Bool { keyable }
}
