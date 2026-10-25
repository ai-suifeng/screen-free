import CoreGraphics
import Foundation

/// Everything needed to draw a frame. Immutable, so the compositor can read it from any thread.
final class RenderState {
    let edit: EditDocument
    let meta: ProjectMeta
    let timeline: Timeline
    let cursor: CursorTrack
    let camera: CameraPath
    /// Click times (source) and positions.
    let clicks: [(t: Double, p: NormPoint)]
    let keys: [(t: Double, key: String)]
    /// Hide these while the user is editing them on the canvas.
    let hiddenIDs: Set<UUID>

    init(edit: EditDocument, meta: ProjectMeta, timeline: Timeline, cursor: CursorTrack, camera: CameraPath,
         clicks: [(t: Double, p: NormPoint)], keys: [(t: Double, key: String)], hiddenIDs: Set<UUID> = []) {
        self.edit = edit
        self.meta = meta
        self.timeline = timeline
        self.cursor = cursor
        self.camera = camera
        self.clicks = clicks
        self.keys = keys
        self.hiddenIDs = hiddenIDs
    }

    var sourceAspect: Double { meta.aspect }

    var canvasAspect: Double {
        edit.style.background.kind == .none && edit.style.aspect == .auto
            ? sourceAspect : edit.style.aspect.value(source: sourceAspect)
    }

    /// Output size whose longer side is `longSide` pixels.
    func canvasSize(longSide: Double) -> CGSize {
        let a = canvasAspect
        let w = a >= 1 ? longSide : longSide * a
        let h = a >= 1 ? longSide / a : longSide
        return CGSize(width: Double(Int(w) / 2 * 2), height: Double(Int(h) / 2 * 2))
    }

    /// Native output size: the source resolution, extended to the chosen aspect.
    var nativeLongSide: Double {
        let a = canvasAspect
        let w = Double(meta.width), h = Double(meta.height)
        let base = a >= sourceAspect ? max(w, h * a) : max(h, w / a)
        return min(base, 3840)
    }

    /// Where the screen sits inside the canvas, in a top-left-origin space of `canvas` size.
    func contentRect(canvas: CGSize) -> CGRect {
        let style = edit.style
        let pad = style.background.kind == .none ? 0 : style.padding * min(canvas.width, canvas.height)
        let avail = CGSize(width: canvas.width - 2 * pad, height: canvas.height - 2 * pad)
        let a = sourceAspect
        var size = CGSize(width: avail.width, height: avail.width / a)
        if size.height > avail.height { size = CGSize(width: avail.height * a, height: avail.height) }
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func viewport(at source: Double) -> NormRect {
        camera.viewport(at: source)
    }

    /// Maps a point in a top-left canvas space to normalized source coordinates at time `source`.
    func sourcePoint(canvasPoint p: CGPoint, canvas: CGSize, at source: Double) -> NormPoint {
        let r = contentRect(canvas: canvas)
        let v = viewport(at: source)
        let u = (p.x - r.minX) / r.width
        let w = (p.y - r.minY) / r.height
        return NormPoint(x: v.x + u * v.w, y: v.y + w * v.h)
    }

    /// Maps a normalized source rect to the top-left canvas space at time `source`.
    func canvasRect(_ n: NormRect, canvas: CGSize, at source: Double) -> CGRect {
        let r = contentRect(canvas: canvas)
        let v = viewport(at: source)
        return CGRect(x: r.minX + (n.x - v.x) / v.w * r.width,
                      y: r.minY + (n.y - v.y) / v.h * r.height,
                      width: n.w / v.w * r.width, height: n.h / v.h * r.height)
    }
}

/// Lets the compositor pick up edits without rebuilding the player item.
final class RenderStateBox {
    private let lock = NSLock()
    private var _state: RenderState

    init(_ state: RenderState) { _state = state }

    var state: RenderState {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); _state = newValue; lock.unlock() }
    }
}
