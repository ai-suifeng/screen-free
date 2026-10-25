import AppKit
import Observation
import SwiftUI

/// Handles annotations made while recording: smart click highlights and the drawing overlay.
/// Annotations are stored as data and rendered at export time; the on-screen overlays are only
/// feedback for the presenter and are excluded from the capture.
@Observable
final class LiveAnnotationController {
    enum Tool: String, CaseIterable {
        case pen, highlighter, arrow, rect

        var kind: Annotation.Kind {
            switch self {
            case .pen: .pen
            case .highlighter: .highlighter
            case .arrow: .arrow
            case .rect: .rect
            }
        }
    }

    struct LiveStroke: Identifiable {
        let id = UUID()
        var tool: Tool
        var color: RGBA
        /// Points in overlay view coordinates.
        var points: [CGPoint]
        var times: [TimeInterval]
        var laser: Bool
        var finishedAt: TimeInterval?
    }

    private(set) var isDrawing = false
    var tool: Tool = .pen
    var color: RGBA = .red
    var laser = true
    private(set) var strokes: [LiveStroke] = []
    /// Highlight boxes currently flashing on screen, in global CG coordinates.
    private(set) var flashes: [(id: UUID, rect: CGRect, step: Int?)] = []

    @ObservationIgnored private let session: RecordingSession
    @ObservationIgnored private let settings = AppSettings.shared
    @ObservationIgnored private var drawWindow: OverlayWindow?
    @ObservationIgnored private var paletteWindow: FloatingPanel?
    @ObservationIgnored private var flashWindows: [CGDirectDisplayID: OverlayWindow] = [:]
    @ObservationIgnored private var drawScreen: NSScreen?
    @ObservationIgnored private var fadeTimer: Timer?

    init(session: RecordingSession) {
        self.session = session
    }

    // MARK: - Smart highlight

    func handleClick(_ click: InputRecorder.Click) {
        guard !click.right, settings.highlightTrigger.matches(click.flags), !isDrawing else { return }
        let capture = session.captureRect
        let maxArea = capture.width * capture.height * 0.3
        let point = click.location
        let uptime = click.time
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ElementLocator.frame(at: point, maxArea: maxArea)
            DispatchQueue.main.async {
                // Fall back to a fixed box centered on the click.
                let rect = (found ?? CGRect(x: point.x - 90, y: point.y - 28, width: 180, height: 56))
                    .insetBy(dx: -5, dy: -4)
                self.addHighlight(rect, uptime: uptime)
            }
        }
    }

    private func addHighlight(_ rect: CGRect, uptime: TimeInterval) {
        let step = settings.stepNumbers ? session.stepCount + 1 : nil
        var annotation = Annotation(kind: settings.highlightKind, start: 0, duration: 2.6)
        annotation.rect = session.normalize(rect)
        annotation.color = settings.highlightColor
        annotation.lineWidth = 3
        annotation.step = step
        session.addLiveAnnotation(annotation, uptime: uptime)
        flash(rect, step: step)
    }

    private func flash(_ rect: CGRect, step: Int?) {
        guard let screen = NSScreen.screens.first(where: { $0.cgFrame.intersects(rect) }) else { return }
        let id = UUID()
        flashes.append((id, rect, step))
        if flashWindows[screen.displayID] == nil {
            let window = OverlayWindow(screenFrame: screen.frame, interactive: false) {
                FlashOverlayView(controller: self, screenOrigin: screen.cgFrame.origin)
            }
            window.orderFrontRegardless()
            flashWindows[screen.displayID] = window
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            self.flashes.removeAll { $0.id == id }
            if self.flashes.isEmpty {
                self.flashWindows.values.forEach { $0.close() }
                self.flashWindows = [:]
            }
        }
    }

    // MARK: - Drawing

    func toggleDrawing() {
        isDrawing ? endDrawing() : beginDrawing()
    }

    func beginDrawing() {
        guard session.phase == .recording, !isDrawing else { return }
        let capture = session.captureRect
        guard let screen = NSScreen.screens.first(where: { $0.cgFrame.intersects(capture) }) ?? NSScreen.main else { return }
        drawScreen = screen
        isDrawing = true
        color = settings.highlightColor

        let window = OverlayWindow(screenFrame: screen.frame, interactive: true, keyable: true) {
            DrawingOverlayView(controller: self, captureRect: capture.offsetBy(dx: -screen.cgFrame.minX, dy: -screen.cgFrame.minY))
        }
        window.level = .statusBar
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        drawWindow = window

        let palette = FloatingPanel(level: .popUpMenu, movable: true) { DrawPaletteView(controller: self) }
        palette.place(on: screen, fromTop: 70)
        palette.orderFrontRegardless()
        paletteWindow = palette

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.pruneFadedStrokes() }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    func endDrawing() {
        guard isDrawing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Persistent strokes stay on screen until drawing ends.
        for stroke in strokes where !stroke.laser {
            commit(stroke, until: now)
        }
        strokes = []
        isDrawing = false
        drawWindow?.close(); drawWindow = nil
        paletteWindow?.close(); paletteWindow = nil
        fadeTimer?.invalidate(); fadeTimer = nil
    }

    func clear() {
        let now = ProcessInfo.processInfo.systemUptime
        for stroke in strokes where !stroke.laser { commit(stroke, until: now) }
        strokes.removeAll()
    }

    func beginStroke(at p: CGPoint) {
        strokes.append(LiveStroke(tool: tool, color: color, points: [p], times: [ProcessInfo.processInfo.systemUptime],
                                  laser: laser && (tool == .pen || tool == .highlighter || tool == .arrow)))
    }

    func extendStroke(to p: CGPoint) {
        guard var stroke = strokes.last, stroke.finishedAt == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch stroke.tool {
        case .pen, .highlighter:
            stroke.points.append(p)
            stroke.times.append(now)
        case .arrow, .rect:
            stroke.points = [stroke.points[0], p]
            stroke.times = [stroke.times[0], now]
        }
        strokes[strokes.count - 1] = stroke
    }

    func endStroke() {
        guard var stroke = strokes.last, stroke.finishedAt == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        stroke.finishedAt = now
        strokes[strokes.count - 1] = stroke
        if stroke.points.count < 2 {
            strokes.removeLast()
            return
        }
        if stroke.laser { commit(stroke, until: now + Self.laserLinger) }
    }

    static let laserLinger: TimeInterval = 1.2

    private func pruneFadedStrokes() {
        let now = ProcessInfo.processInfo.systemUptime
        strokes.removeAll { s in s.laser && (s.finishedAt.map { now - $0 > Self.laserLinger + 0.4 } ?? false) }
    }

    private func commit(_ stroke: LiveStroke, until end: TimeInterval) {
        guard let screen = drawScreen, let start = stroke.times.first else { return }
        let origin = screen.cgFrame.origin
        let global = stroke.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        var annotation = Annotation(kind: stroke.tool.kind, start: 0, duration: max(0.3, end - start))
        annotation.color = stroke.color
        annotation.fades = stroke.laser
        annotation.lineWidth = stroke.tool == .highlighter ? 18 : 5
        switch stroke.tool {
        case .rect:
            let a = global[0], b = global[global.count - 1]
            annotation.rect = session.normalize(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
        default:
            annotation.points = zip(global, stroke.times).map { p, t in
                let n = session.normalize(p)
                return StrokePoint(x: n.x, y: n.y, t: t - start)
            }
        }
        session.addLiveAnnotation(annotation, uptime: start)
    }
}

// MARK: - Views

private struct FlashOverlayView: View {
    var controller: LiveAnnotationController
    var screenOrigin: CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(controller.flashes, id: \.id) { flash in
                FlashBox(rect: flash.rect.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y), step: flash.step,
                         color: AppSettings.shared.highlightColor.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FlashBox: View {
    var rect: CGRect
    var step: Int?
    var color: Color
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color, lineWidth: 3)
                .shadow(color: color.opacity(0.6), radius: 8)
                .frame(width: rect.width, height: rect.height)
            if let step {
                Text("\(step)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(color, in: Circle())
                    .offset(x: -12, y: -12)
            }
        }
        .scaleEffect(shown ? 1 : 1.15)
        .opacity(shown ? 1 : 0)
        .offset(x: rect.minX, y: rect.minY)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { shown = true } }
    }
}

private struct DrawingOverlayView: View {
    var controller: LiveAnnotationController
    var captureRect: CGRect
    @State private var dragging = false

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                // Dim outside the captured area so it's clear what will be recorded.
                var outside = Path(CGRect(origin: .zero, size: size))
                outside.addRect(captureRect)
                ctx.fill(outside, with: .color(.black.opacity(0.18)), style: FillStyle(eoFill: true))
                let now = ProcessInfo.processInfo.systemUptime
                for stroke in controller.strokes {
                    var alpha = 1.0
                    if stroke.laser, let done = stroke.finishedAt {
                        alpha = 1 - ((now - done - LiveAnnotationController.laserLinger) / 0.4).clamped(0, 1)
                    }
                    StrokeRenderer.draw(stroke.tool.kind, points: stroke.points, color: stroke.color, alpha: alpha, in: &ctx)
                }
            }
            .id(timeline.date)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !dragging {
                        dragging = true
                        controller.beginStroke(at: v.startLocation)
                    }
                    controller.extendStroke(to: v.location)
                }
                .onEnded { _ in
                    dragging = false
                    controller.endStroke()
                }
        )
        .onExitCommand { controller.endDrawing() }
        .onAppear { NSCursor.crosshair.push() }
        .onDisappear { NSCursor.pop() }
    }
}

/// Shared drawing of live strokes in SwiftUI canvases.
enum StrokeRenderer {
    static func draw(_ kind: Annotation.Kind, points: [CGPoint], color: RGBA, alpha: Double, in ctx: inout GraphicsContext) {
        guard points.count >= 2 else { return }
        let c = color.color.opacity(alpha * (kind == .highlighter ? 0.4 : 1))
        switch kind {
        case .pen, .highlighter:
            var path = Path()
            path.addLines(points)
            ctx.stroke(path, with: .color(c), style: StrokeStyle(lineWidth: kind == .highlighter ? 18 : 5, lineCap: .round, lineJoin: .round))
        case .arrow:
            let a = points[0], b = points[points.count - 1]
            ctx.stroke(arrowPath(from: a, to: b, width: 5), with: .color(c), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        case .rect:
            let a = points[0], b = points[points.count - 1]
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(c), lineWidth: 4)
        default:
            break
        }
    }

    static func arrowPath(from a: CGPoint, to b: CGPoint, width: CGFloat) -> Path {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = max(14, width * 3.5)
        for d in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x + head * cos(angle + d), y: b.y + head * sin(angle + d)))
        }
        return path
    }
}

private struct DrawPaletteView: View {
    @Bindable var controller: LiveAnnotationController

    var body: some View {
        HStack(spacing: 4) {
            ForEach(LiveAnnotationController.Tool.allCases, id: \.self) { tool in
                Button { controller.tool = tool } label: { Image(systemName: tool.kind.symbol) }
                    .buttonStyle(HUDButtonStyle(tint: controller.tool == tool ? Theme.violet : nil))
                    .help(tool.kind.label)
            }
            Rectangle().fill(.separator).frame(width: 1, height: 20).padding(.horizontal, 3)
            ForEach(RGBA.palette, id: \.self) { c in
                Button { controller.color = c } label: {
                    Circle().fill(c.color).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white, lineWidth: controller.color == c ? 2 : 0))
                        .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
                }
                .buttonStyle(HUDButtonStyle(size: 26))
            }
            Rectangle().fill(.separator).frame(width: 1, height: 20).padding(.horizontal, 3)
            Toggle(isOn: $controller.laser) {
                Label("激光笔", systemImage: "wand.and.rays")
            }
            .toggleStyle(.button)
            .help("笔迹在松开后自动淡出")
            Button(action: controller.clear) { Image(systemName: "trash") }
                .buttonStyle(HUDButtonStyle())
                .help("清除")
            Button("完成", action: controller.endDrawing)
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glass(in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(20)
    }
}
