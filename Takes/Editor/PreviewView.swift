import AVFoundation
import AppKit
import SwiftUI

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = .clear
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The video preview plus an interactive overlay for placing and editing annotations, blur and zoom focus.
struct PreviewCanvas: View {
    @Bindable var model: EditorModel
    @State private var draft: CGRect?
    @State private var dragStart: CGPoint?
    @State private var editing: (id: UUID, original: NormRect, handle: Handle)?
    @State private var liveRect: CGRect?
    @State private var editingText: UUID?
    @State private var hovering = false
    @State private var zoomDrag: (center: NormPoint, scale: Double)?

    enum Handle { case move, topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { geo in
            let canvas = fittedSize(in: geo.size)
            ZStack {
                PlayerLayerView(player: model.player)
                    .frame(width: canvas.width, height: canvas.height)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                overlay(canvas: canvas)
                    .frame(width: canvas.width, height: canvas.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func fittedSize(in size: CGSize) -> CGSize {
        let a = model.renderState.canvasAspect
        var w = size.width, h = size.width / a
        if h > size.height { h = size.height; w = h * a }
        return CGSize(width: max(1, w), height: max(1, h))
    }

    @ViewBuilder
    private func overlay(canvas: CGSize) -> some View {
        let state = model.renderState
        let t = model.sourceTime
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())

            if hovering, model.tool == .select, model.selection == .none, !model.isPlaying {
                sizeGuide(canvas: canvas)
            }

            if case .zoom(let zid) = model.selection, let z = model.edit.zooms.first(where: { $0.id == zid }) {
                zoomEditor(z, canvas: canvas)
            }

            // Selected item outline and handles.
            if let sel = selectedRect(state: state, canvas: canvas, t: t) {
                let id = sel.1, color = sel.2
                let r = (editing?.id == id ? liveRect : nil) ?? sel.0
                selectionBox(r, color: color)
                    .gesture(editGesture(id: id, handle: .move, canvas: canvas))
                ForEach([Handle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { h in
                    handleDot
                        .position(corner(h, of: r))
                        .gesture(editGesture(id: id, handle: h, canvas: canvas))
                }
                if case .annotation(let aid) = model.selection,
                   let a = model.edit.annotations.first(where: { $0.id == aid }), a.kind == .text {
                    textEditor(for: a, rect: r)
                }
            }

            if let draft {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.coral, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Theme.coral.opacity(0.08))
                    .frame(width: draft.width, height: draft.height)
                    .offset(x: draft.minX, y: draft.minY)
            }

            if model.tool != .select {
                Text("在画面上拖拽来添加\(model.tool.label)")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .gesture(model.tool == .select ? nil : drawGesture(canvas: canvas))
        .onHover { hovering = $0 }
        .onTapGesture {
            if model.tool == .select { model.selection = .none }
        }
    }

    // MARK: - Size guide

    /// Explains the layers on hover: where the recorded screen sits, its real size, and the padding fill.
    private func sizeGuide(canvas: CGSize) -> some View {
        let state = model.renderState
        let r = state.contentRect(canvas: canvas)
        let meta = model.meta
        let points = "\(Int(Double(meta.width) / meta.scale))×\(Int(Double(meta.height) / meta.scale))"
        let source = meta.scale > 1 ? "\(meta.width)×\(meta.height) 像素（\(points) @\(Int(meta.scale))x）" : "\(meta.width)×\(meta.height) 像素"
        let framed = model.edit.style.background.kind != .none
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .shadow(color: .black.opacity(0.5), radius: 2)
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
            guideTag("录制画面 · \(source)", symbol: "display")
                .offset(x: r.minX + 8, y: r.minY + 8)
            if framed {
                guideTag("背景填充（边距 \(Int(model.edit.style.padding * 100))%）· 在右侧「画面」中修改", symbol: "square.dashed")
                    .offset(x: 8, y: max(4, r.minY / 2 - 11))
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func guideTag(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.65), in: Capsule())
            .fixedSize()
    }

    // MARK: - Zoom area

    /// Box showing what a zoom will fill the frame with; drag to move, drag corners to change the scale.
    @ViewBuilder
    private func zoomEditor(_ z: ZoomRegion, canvas: CGSize) -> some View {
        let state = model.renderState
        let t = model.sourceTime
        let content = state.contentRect(canvas: canvas)
        let scale = zoomDrag?.scale ?? z.scale
        let size = 1 / scale
        let base: NormPoint = z.mode == .fixed ? z.center : (model.cursorPosition(atSource: t) ?? z.center)
        let c = zoomDrag?.center ?? base
        let n = NormRect(x: (c.x - size / 2).clamped(0, 1 - size), y: (c.y - size / 2).clamped(0, 1 - size), w: size, h: size)
        let r = state.canvasRect(n, canvas: canvas, at: t)

        ZStack(alignment: .topLeading) {
            // Dim what will be cropped away.
            Path { p in
                p.addRect(content)
                p.addRect(r)
            }
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 4)
                .stroke(Theme.violet, lineWidth: 2)
                .background(Color.white.opacity(0.001))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    let dx = v.translation.width / content.width, dy = v.translation.height / content.height
                    zoomDrag = (NormPoint(x: (base.x + dx).clamped(size / 2, 1 - size / 2),
                                          y: (base.y + dy).clamped(size / 2, 1 - size / 2)), scale)
                }
                .onEnded { _ in commitZoom(z.id) })

            ForEach([Handle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { h in
                Circle().fill(.white).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.violet, lineWidth: 2))
                    .shadow(radius: 2)
                    .position(corner(h, of: r))
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                        // Corner distance from the center sets the zoom factor; the aspect stays the frame's.
                        let center = CGPoint(x: r.midX, y: r.midY)
                        let half = max(abs(v.location.x - center.x) / content.width, abs(v.location.y - center.y) / content.height)
                        let newScale = (1 / max(half * 2, 0.01)).clamped(1.1, 5)
                        zoomDrag = (c, newScale)
                    }
                    .onEnded { _ in commitZoom(z.id) })
            }

            guideTag(String(format: "放大 %.1f× · 拖动方框选择放大区域", scale), symbol: "plus.magnifyingglass")
                .offset(x: r.minX, y: max(2, r.minY - 26))
                .allowsHitTesting(false)
        }
    }

    private func commitZoom(_ id: UUID) {
        guard let d = zoomDrag, let i = model.edit.zooms.firstIndex(where: { $0.id == id }) else { return }
        model.edit.zooms[i].center = d.center
        model.edit.zooms[i].scale = d.scale
        model.edit.zooms[i].mode = .fixed
        model.edit.zooms[i].isAuto = false
        zoomDrag = nil
    }

    private var handleDot: some View {
        Circle().fill(.white).frame(width: 11, height: 11)
            .overlay(Circle().stroke(Theme.coral, lineWidth: 2))
            .shadow(radius: 2)
    }

    private func selectionBox(_ r: CGRect, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .background(color.opacity(0.06))
            .contentShape(Rectangle())
            .frame(width: max(r.width, 6), height: max(r.height, 6))
            .position(x: r.midX, y: r.midY)
    }

    private func textEditor(for a: Annotation, rect: CGRect) -> some View {
        TextField("文字", text: Binding(
            get: { a.text },
            set: { v in if let i = model.edit.annotations.firstIndex(where: { $0.id == a.id }) { model.edit.annotations[i].text = v } }
        ))
        .textFieldStyle(.roundedBorder)
        .frame(width: 220)
        .position(x: rect.midX, y: rect.maxY + 22)
    }

    private func corner(_ h: Handle, of r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight, .move: CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    /// The selected item's rect in canvas coordinates, if it is visible right now.
    private func selectedRect(state: RenderState, canvas: CGSize, t: Double) -> (CGRect, UUID, Color)? {
        switch model.selection {
        case .annotation(let id):
            guard let a = model.edit.annotations.first(where: { $0.id == id }) else { return nil }
            if a.kind.isRectBased {
                return (state.canvasRect(a.rect, canvas: canvas, at: t), id, Theme.coral)
            }
            let xs = a.points.map(\.x), ys = a.points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
            return (state.canvasRect(NormRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY), canvas: canvas, at: t), id, Theme.coral)
        case .blur(let id):
            guard let b = model.edit.blurs.first(where: { $0.id == id }) else { return nil }
            return (state.canvasRect(b.rect(at: t), canvas: canvas, at: t), id, .cyan)
        default:
            return nil
        }
    }

    private func normRect(_ r: CGRect, canvas: CGSize) -> NormRect {
        let state = model.renderState
        let t = model.sourceTime
        let a = state.sourcePoint(canvasPoint: CGPoint(x: r.minX, y: r.minY), canvas: canvas, at: t)
        let b = state.sourcePoint(canvasPoint: CGPoint(x: r.maxX, y: r.maxY), canvas: canvas, at: t)
        return NormRect(x: a.x, y: a.y, w: b.x - a.x, h: b.y - a.y)
    }

    private func drawGesture(canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                let s = v.startLocation
                draft = CGRect(x: min(s.x, v.location.x), y: min(s.y, v.location.y),
                               width: abs(v.location.x - s.x), height: abs(v.location.y - s.y))
            }
            .onEnded { v in
                defer { draft = nil }
                guard let d = draft, d.width > 6 || d.height > 6 else { return }
                let tool = model.tool
                model.player.pause()
                if tool == .blur {
                    model.addBlur(rect: normRect(d, canvas: canvas).clamped())
                } else if tool == .arrow {
                    let a = model.renderState.sourcePoint(canvasPoint: v.startLocation, canvas: canvas, at: model.sourceTime)
                    let b = model.renderState.sourcePoint(canvasPoint: v.location, canvas: canvas, at: model.sourceTime)
                    model.addAnnotation(.arrow, rect: .zero, points: [StrokePoint(x: a.x, y: a.y, t: 0), StrokePoint(x: b.x, y: b.y, t: 0)])
                } else if let kind = tool.annotationKind {
                    var r = d
                    if kind == .text { r.size.height = max(36, min(r.height, 60)) }
                    model.addAnnotation(kind, rect: normRect(r, canvas: canvas).clamped())
                }
                model.tool = .select
            }
    }

    private func editGesture(id: UUID, handle: Handle, canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let state = model.renderState
                let t = model.sourceTime
                guard let rect = selectedRect(state: state, canvas: canvas, t: t)?.0 else { return }
                if editing == nil {
                    editing = (id, NormRect.fromView(rect, in: canvas), handle)
                    model.canvasEditingID = id
                }
                let o = editing!.original.viewRect(in: canvas)
                let dx = v.translation.width, dy = v.translation.height
                var r = o
                switch handle {
                case .move: r = o.offsetBy(dx: dx, dy: dy)
                case .topLeft: r = CGRect(x: o.minX + dx, y: o.minY + dy, width: o.width - dx, height: o.height - dy)
                case .topRight: r = CGRect(x: o.minX, y: o.minY + dy, width: o.width + dx, height: o.height - dy)
                case .bottomLeft: r = CGRect(x: o.minX + dx, y: o.minY, width: o.width - dx, height: o.height + dy)
                case .bottomRight: r = CGRect(x: o.minX, y: o.minY, width: o.width + dx, height: o.height + dy)
                }
                liveRect = r.standardized
            }
            .onEnded { _ in
                defer {
                    editing = nil
                    liveRect = nil
                    model.canvasEditingID = nil
                }
                guard let edit = editing, let r = liveRect else { return }
                apply(id: edit.id, from: edit.original.viewRect(in: canvas), to: r, canvas: canvas)
            }
    }

    private func apply(id: UUID, from old: CGRect, to new: CGRect, canvas: CGSize) {
        let n = normRect(new, canvas: canvas)
        if let i = model.edit.annotations.firstIndex(where: { $0.id == id }) {
            var a = model.edit.annotations[i]
            if a.kind.isRectBased {
                a.rect = n
            } else {
                // Map stroke points from the old bounds into the new ones.
                let o = normRect(old, canvas: canvas)
                a.points = a.points.map { p in
                    let u = o.w > 0 ? (p.x - o.x) / o.w : 0
                    let w = o.h > 0 ? (p.y - o.y) / o.h : 0
                    return StrokePoint(x: n.x + u * n.w, y: n.y + w * n.h, t: p.t)
                }
            }
            model.edit.annotations[i] = a
        } else if let i = model.edit.blurs.firstIndex(where: { $0.id == id }) {
            var b = model.edit.blurs[i]
            if b.keyframes.count > 1 {
                // Shift the whole tracked path by the same offset.
                let cur = b.rect(at: model.sourceTime)
                let dx = n.x - cur.x, dy = n.y - cur.y
                let sx = cur.w > 0 ? n.w / cur.w : 1, sy = cur.h > 0 ? n.h / cur.h : 1
                b.keyframes = b.keyframes.map { k in
                    BlurKeyframe(t: k.t, rect: NormRect(x: k.rect.x + dx, y: k.rect.y + dy, w: k.rect.w * sx, h: k.rect.h * sy))
                }
            } else {
                b.rect = n
                b.keyframes = []
            }
            model.edit.blurs[i] = b
        }
    }
}
