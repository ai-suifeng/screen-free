import SwiftUI

/// Output-time timeline (like 剪映): clips sit back to back, and cutting or trimming closes the gap.
/// Zooms, annotations and blurs are stored in source time and mapped onto it.
struct EditorTimeline: View {
    @Bindable var model: EditorModel
    private let labelWidth: CGFloat = 92
    private let rulerHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().opacity(0.5)
            GeometryReader { geo in
                let total = max(model.duration, 0.5)
                let fit = (Double(geo.size.width) - Double(labelWidth) - 24) / total
                let pps = fit * model.timelineZoom
                HStack(spacing: 0) {
                    labels
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 6) {
                                Ruler(duration: total, pps: pps)
                                    .frame(height: rulerHeight)
                                    .contentShape(Rectangle())
                                    .gesture(scrub(pps: pps))
                                ClipsTrack(model: model, pps: pps).frame(height: 58)
                                if hasAudio {
                                    AudioTrack(model: model, pps: pps).frame(height: 34)
                                        .contentShape(Rectangle())
                                        .onTapGesture(coordinateSpace: .named("timeline")) { p in
                                            model.range = nil
                                            model.player.pause()
                                            model.seek(comp: p.x / pps)
                                        }
                                        .gesture(rangeDrag(model, pps: pps))
                                }
                                ZoomTrack(model: model, pps: pps).frame(height: 26)
                                AnnotationTrack(model: model, pps: pps).frame(height: annotationTrackHeight)
                                BlurTrack(model: model, pps: pps).frame(height: 26)
                            }
                            .padding(.vertical, 6)
                            .onContinuousHover(coordinateSpace: .named("timeline")) { phase in
                                switch phase {
                                case .active(let p): model.skim(to: p.x / pps)
                                case .ended: model.skim(to: nil)
                                }
                            }
                            if let r = model.range {
                                RangeOverlay(model: model, range: r, pps: pps,
                                             top: 6 + rulerHeight + 6, height: 58 + (hasAudio ? 6 + 34 : 0))
                            }
                            if let t = model.skimTime {
                                SkimLine(time: t, height: geo.size.height).offset(x: t * pps)
                            }
                            Playhead(height: geo.size.height)
                                .offset(x: model.currentTime * pps - 6)
                                .gesture(scrub(pps: pps))
                        }
                        .frame(width: total * pps + 12, alignment: .leading)
                        .padding(.trailing, 12)
                        .coordinateSpace(name: "timeline")
                    }
                }
            }
        }
        .background(.background.secondary)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                Button { model.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .buttonStyle(HUDButtonStyle(size: 28))
                Button(action: model.togglePlay) { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill") }
                    .buttonStyle(HUDButtonStyle(tint: Theme.coral, size: 34))
                Button { model.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .buttonStyle(HUDButtonStyle(size: 28))
            }
            HStack(spacing: 4) {
                Text(formatDuration(model.currentTime, showFraction: true))
                Text("/").foregroundStyle(.tertiary)
                Text(formatDuration(model.duration, showFraction: true)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())

            Menu {
                ForEach([0.5, 1, 1.5, 2] as [Float], id: \.self) { r in
                    Button { model.playbackRate = r } label: {
                        if model.playbackRate == r { Label(rateLabel(r), systemImage: "checkmark") } else { Text(rateLabel(r)) }
                    }
                }
            } label: {
                Text(rateLabel(model.playbackRate))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("播放速度：快速过一遍找要删的地方")

            Rectangle().fill(.separator).frame(width: 1, height: 20)

            HStack(spacing: 6) {
                editButton("分割", "scissors", help: "在播放头处分割 (S)", action: model.splitAtPlayhead)
                trimButton(left: true)
                trimButton(left: false)
                editButton("删除", "trash", help: "删除选中的片段 (⌫)") {
                    if case .clip(let id) = model.selection { model.deleteClip(id) }
                }
                .disabled(!isClipSelected)
                .opacity(isClipSelected ? 1 : 0.45)
                editButton("加缩放", "plus.magnifyingglass", help: "在播放头处加一段缩放 (Z)") {
                    model.addZoom(at: model.sourceTime)
                }
                Menu {
                    Toggle("鼠标悬停时预览画面", isOn: $model.skimEnabled)
                    Divider()
                    Button("还原所有剪辑", action: model.resetClips)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
            }

            Spacer()

            if let msg = model.statusMessage {
                Text(msg).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
            } else if model.range == nil {
                Text("在片段或声音上拖动可选中一段，按 ⌫ 删除").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .lineLimit(1).layoutPriority(-1)
            }

            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $model.timelineZoom, in: 1...12).frame(width: 120).controlSize(.small)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// 剪映-style "向左裁剪 / 向右裁剪" buttons with their own icon.
    private func trimButton(left: Bool) -> some View {
        Button {
            model.trimAtPlayhead(keepRight: left)
        } label: {
            HStack(spacing: 6) {
                TrimIcon(cutsLeft: left).frame(width: 22, height: 16)
                Text(left ? "向左裁剪" : "向右裁剪").font(.system(size: 12, weight: .medium))
            }
            .fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(left ? "向左裁剪：删掉播放头左边的部分 (Q)" : "向右裁剪：删掉播放头右边的部分 (W)")
    }

    private func rateLabel(_ r: Float) -> String {
        r == 1 ? "1×" : String(format: "%g×", r)
    }

    private var hasAudio: Bool { model.meta.hasMic || model.meta.hasSystemAudio }

    private var isClipSelected: Bool {
        if case .clip = model.selection { return true }
        return false
    }

    private func editButton(_ title: String, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var annotationTrackHeight: CGFloat {
        CGFloat(min(3, max(1, Lanes.assign(model.edit.annotations.map { ($0.start, $0.end) }).count))) * 22 + 4
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.frame(height: rulerHeight)
            label("片段", "film.stack", height: 58)
            if hasAudio { label("声音", "waveform", height: 34) }
            label("缩放", "plus.magnifyingglass", height: 26)
            label("标注", "pencil.and.outline", height: annotationTrackHeight)
            label("打码", "eye.slash", height: 26)
        }
        .padding(.vertical, 6)
        .frame(width: labelWidth, alignment: .leading)
        .padding(.leading, 14)
    }

    private func label(_ text: String, _ symbol: String, height: CGFloat) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(height: height)
    }

    private func scrub(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
            .onChanged { v in
                model.player.pause()
                model.seek(comp: max(0, v.location.x / pps))
            }
    }
}

private struct Ruler: View {
    let duration: Double
    let pps: Double

    var body: some View {
        Canvas { ctx, size in
            let step = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300].first { $0 * pps >= 70 } ?? 600
            var t = 0.0
            while t <= duration + 0.001 {
                let x = CGFloat(t * pps)
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: size.height - 7)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                ctx.draw(Text(formatDuration(t, showFraction: step < 1)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 3, y: size.height / 2 - 2), anchor: .leading)
                let minor = step / 5
                for i in 1..<5 {
                    guard t + Double(i) * minor <= duration else { break }
                    let mx = CGFloat((t + Double(i) * minor) * pps)
                    ctx.stroke(Path { p in p.move(to: CGPoint(x: mx, y: size.height - 3)); p.addLine(to: CGPoint(x: mx, y: size.height)) },
                               with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                }
                t += step
            }
        }
    }
}

private struct Playhead: View {
    let height: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.coral)
                .frame(width: 12, height: 12)
            Rectangle().fill(Theme.coral).frame(width: 1.5)
        }
        .frame(width: 12, height: height)
        .contentShape(Rectangle())
        .shadow(color: Theme.coral.opacity(0.5), radius: 3)
    }
}

/// A clip with the playhead through it: the side that gets cut is dashed and faded, the kept side is solid.
struct TrimIcon: View {
    var cutsLeft: Bool

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let mid = w / 2
            let cut = CGRect(x: cutsLeft ? 1 : mid + 1.5, y: 2, width: mid - 2.5, height: h - 4)
            let kept = CGRect(x: cutsLeft ? mid + 1.5 : 1, y: 2, width: mid - 2.5, height: h - 4)
            let ink = GraphicsContext.Shading.color(.primary)
            ctx.fill(Path(roundedRect: kept, cornerRadius: 2), with: ink)
            ctx.stroke(Path(roundedRect: cut, cornerRadius: 2), with: .color(.primary.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.5]))
            // Small cross on the part that goes away.
            let c = CGPoint(x: cut.midX, y: cut.midY), r: CGFloat = 2.2
            var x = Path()
            x.move(to: CGPoint(x: c.x - r, y: c.y - r)); x.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
            x.move(to: CGPoint(x: c.x + r, y: c.y - r)); x.addLine(to: CGPoint(x: c.x - r, y: c.y + r))
            ctx.stroke(x, with: .color(.primary.opacity(0.6)), lineWidth: 1.2)
            // Playhead.
            ctx.fill(Path(CGRect(x: mid - 0.75, y: 0, width: 1.5, height: h)), with: .color(Theme.coral))
            ctx.fill(Path { p in
                p.move(to: CGPoint(x: mid - 3, y: 0)); p.addLine(to: CGPoint(x: mid + 3, y: 0)); p.addLine(to: CGPoint(x: mid, y: 3.5))
            }, with: .color(Theme.coral))
        }
    }
}

// MARK: - Range

/// Dragging across clips or the waveform picks an output-time range to cut.
@MainActor
private func rangeDrag(_ model: EditorModel, pps: Double) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
        .onChanged { v in
            model.player.pause()
            let a = max(0, v.startLocation.x / pps), b = min(model.duration, max(0, v.location.x / pps))
            model.range = min(a, b)...max(a, b)
            model.selection = .none
            // Show the frame under the moving edge, to see exactly where the cut lands.
            model.skim(to: b)
        }
        .onEnded { _ in
            if let r = model.range, r.upperBound - r.lowerBound < 0.05 { model.range = nil }
        }
}

private struct RangeOverlay: View {
    var model: EditorModel
    let range: ClosedRange<Double>
    let pps: Double
    let top: CGFloat
    let height: CGFloat

    var body: some View {
        let x = range.lowerBound * pps
        let w = max(2, (range.upperBound - range.lowerBound) * pps)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.recordRed.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.recordRed, lineWidth: 2))
                .frame(width: w, height: height)
                .offset(x: x, y: top)
                .allowsHitTesting(false)
            actions.offset(x: x, y: 5)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Text(String(format: "%.1f 秒", range.upperBound - range.lowerBound))
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .padding(.horizontal, 6)
            action("play.fill", help: "播放这一段") { model.playRange() }
            action("trash.fill", help: "删除这一段 (⌫)") { model.deleteRange() }
            action("xmark", help: "取消选择 (esc)") { model.range = nil }
        }
        .foregroundStyle(.white)
        .padding(2)
        .background(Theme.recordRed, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        .fixedSize()
    }

    private func action(_ symbol: String, help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
                .frame(width: 20, height: 18)
                .background(.white.opacity(0.18), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Thin line where the mouse is skimming, with its time.
private struct SkimLine: View {
    let time: Double
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(formatDuration(time, showFraction: true))
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.secondary, in: Capsule())
                .fixedSize()
            Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 1)
        }
        .frame(height: height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Clips

private struct ClipsTrack: View {
    @Bindable var model: EditorModel
    let pps: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.timeline.entries, id: \.clipID) { entry in
                if let id = entry.clipID {
                    ClipBlock(model: model, clipID: id, entry: entry, pps: pps)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ClipBlock: View {
    @Bindable var model: EditorModel
    let clipID: UUID
    let entry: Timeline.Entry
    let pps: Double
    @State private var dragOrigin: Clip?
    @State private var hovering = false

    var body: some View {
        let width = max(4, entry.duration * pps)
        let selected = model.selection == .clip(clipID)

        ZStack(alignment: .leading) {
            Filmstrip(images: stripImages)
                .frame(width: width, height: 58)
                .clipped()
            VStack {
                HStack(spacing: 4) {
                    Text("第 \(model.takeNumber(entry.segment)) 段").font(.system(size: 10, weight: .bold))
                    if width > 90 {
                        Text(formatDuration(entry.duration, showFraction: true)).font(.system(size: 10).monospacedDigit()).opacity(0.8)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.leading, 12).padding(.top, 4)
                Spacer()
            }
            if selected || hovering {
                trimHandle(leading: true)
                trimHandle(leading: false).offset(x: width - 10)
            }
        }
        .frame(width: width, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .stroke(selected ? Color.white : hovering ? Color.white.opacity(0.7) : Color.primary.opacity(0.15),
                    lineWidth: selected || hovering ? 2 : 0.5))
        .shadow(color: selected ? Theme.coral.opacity(0.6) : .clear, radius: 5)
        .offset(x: entry.compStart * pps)
        .onHover { inside in
            hovering = inside
            model.setHovered(.clip(clipID), inside)
        }
        .onTapGesture(coordinateSpace: .named("timeline")) { p in
            model.range = nil
            model.select(.clip(clipID))
            model.player.pause()
            model.seek(comp: p.x / pps)
        }
        .gesture(rangeDrag(model, pps: pps))
        .contextMenu {
            Button("在播放头处分割") { model.splitAtPlayhead() }
            Button { model.trimAtPlayhead(keepRight: true) } label: { Label("向左裁剪（删掉播放头左边）", systemImage: "arrow.left.to.line") }
            Button { model.trimAtPlayhead(keepRight: false) } label: { Label("向右裁剪（删掉播放头右边）", systemImage: "arrow.right.to.line") }
            Button("删除片段", role: .destructive) { model.deleteClip(clipID) }
            Divider()
            Button("还原所有剪辑", action: model.resetClips)
        }
    }

    /// Filmstrip frames for just the part of the take this clip uses.
    private var stripImages: [CGImage] {
        let all = model.filmstrips[entry.segment] ?? []
        guard !all.isEmpty, entry.takeDuration > 0 else { return all }
        let a = Int((entry.sourceStart - entry.takeStart) / entry.takeDuration * Double(all.count))
        let b = Int(ceil((entry.sourceEnd - entry.takeStart) / entry.takeDuration * Double(all.count)))
        let lo = min(max(0, a), all.count - 1), hi = min(max(lo + 1, b), all.count)
        return Array(all[lo..<hi])
    }

    private func trimHandle(leading: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 7 : 0, bottomLeadingRadius: leading ? 7 : 0,
                               bottomTrailingRadius: leading ? 0 : 7, topTrailingRadius: leading ? 0 : 7)
            .fill(.white)
            .frame(width: 10, height: 58)
            .overlay(Capsule().fill(.black.opacity(0.45)).frame(width: 2, height: 18))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                    .onChanged { v in
                        if dragOrigin == nil {
                            dragOrigin = model.edit.clips.first { $0.id == clipID }
                            model.select(.clip(clipID))
                            model.player.pause()
                        }
                        guard let o = dragOrigin else { return }
                        let delta = v.translation.width / pps
                        if leading {
                            model.trimClip(clipID, start: o.start + delta)
                            model.seek(comp: entry.compStart)
                        } else {
                            model.trimClip(clipID, end: o.end + delta)
                            if let e = model.timeline.entries.first(where: { $0.clipID == clipID }) {
                                model.seek(comp: e.compEnd - 0.02)
                            }
                        }
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }
}

private struct Filmstrip: View {
    let images: [CGImage]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.2)))
            guard let first = images.first else { return }
            let tileW = size.height * Double(first.width) / Double(max(first.height, 1))
            let count = Int(ceil(size.width / tileW))
            for i in 0..<count {
                let idx = min(images.count - 1, Int(Double(i) / Double(max(count, 1)) * Double(images.count)))
                ctx.draw(Image(decorative: images[idx], scale: 1),
                         in: CGRect(x: Double(i) * tileW, y: 0, width: tileW, height: size.height))
            }
        }
    }
}

// MARK: - Audio

/// Audio waveform in output time, drawn from each clip's slice of its take, at the levels that will be heard.
private struct AudioTrack: View {
    var model: EditorModel
    let pps: Double

    var body: some View {
        let gains = model.waveformGains
        let entries = model.timeline.entries
        let waves = model.waveforms
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(.primary.opacity(0.04)))
            let mid = size.height / 2
            let barStep: CGFloat = 2
            for entry in entries {
                let x0 = entry.compStart * pps, x1 = entry.compEnd * pps
                // Clip boundary.
                ctx.fill(Path(CGRect(x: x0, y: 2, width: 1, height: size.height - 4)), with: .color(.primary.opacity(0.12)))
                guard let wave = waves[entry.segment] else { continue }
                let local0 = entry.sourceStart - entry.takeStart
                var x = x0
                var path = Path()
                while x < x1 {
                    // Each bar covers barStep points of output time.
                    let a = local0 + (x - x0) / pps
                    let b = local0 + (min(x + barStep, x1) - x0) / pps
                    let rms = Double(wave.loudness(from: a, to: b, micGain: gains.mic, systemGain: gains.system, micGate: gains.gate))
                    // Roughly perceived loudness: normal speech (~-12 dBFS RMS) fills most of the height,
                    // anything under -48 dBFS is drawn as silence.
                    let level = rms < 0.004 ? 0 : min(1, pow(rms / 0.3, 0.8))
                    let h = max(0.5, level * (mid - 2))
                    path.addRect(CGRect(x: x, y: mid - h, width: max(1, barStep - 0.6), height: h * 2))
                    x += barStep
                }
                ctx.fill(path, with: .color(Color(red: 0.18, green: 0.72, blue: 0.55)))
            }
            if waves.isEmpty {
                ctx.draw(Text("正在分析声音…").font(.system(size: 10)).foregroundStyle(.tertiary),
                         at: CGPoint(x: 120, y: mid))
            }
        }
    }
}

// MARK: - Item tracks

/// A draggable, resizable capsule on a track. Works in output time.
private struct TrackItem: View {
    let start: Double
    let duration: Double
    let pps: Double
    var height: CGFloat = 24
    let color: Color
    let symbol: String
    let title: String
    let selected: Bool
    var model: EditorModel
    let item: EditorSelection
    let onSelect: () -> Void
    let onChange: (Double, Double) -> Void
    @State private var origin: (start: Double, duration: Double)?
    @State private var hovering = false

    var body: some View {
        let width = max(10, duration * pps)
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            if width > 60 {
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(width: width, height: height)
        .background(color.gradient.opacity(selected ? 1 : 0.8), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(.white.opacity(selected ? 1 : 0.7), lineWidth: selected || hovering ? 1.5 : 0))
        .overlay(alignment: .leading) { edgeHandle(leading: true) }
        .overlay(alignment: .trailing) { edgeHandle(leading: false) }
        .offset(x: start * pps)
        .onHover { inside in
            hovering = inside
            model.setHovered(item, inside)
        }
        .onTapGesture(perform: onSelect)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline"))
                .onChanged { v in
                    if origin == nil { origin = (start, duration); onSelect() }
                    onChange(max(0, origin!.start + v.translation.width / pps), origin!.duration)
                }
                .onEnded { _ in origin = nil }
        )
    }

    private func edgeHandle(leading: Bool) -> some View {
        Color.white.opacity(0.001)
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                    .onChanged { v in
                        if origin == nil { origin = (start, duration); onSelect() }
                        let d = v.translation.width / pps
                        if leading {
                            let s = min(max(0, origin!.start + d), origin!.start + origin!.duration - 0.2)
                            onChange(s, origin!.duration - (s - origin!.start))
                        } else {
                            onChange(origin!.start, max(0.2, origin!.duration + d))
                        }
                    }
                    .onEnded { _ in origin = nil }
            )
    }
}

/// Maps an output-time span back to a source-time start and duration.
private func sourceSpan(_ model: EditorModel, compStart: Double, compDuration: Double) -> (Double, Double) {
    let s = model.timeline.sourceTime(compStart)
    let e = model.timeline.sourceTime(min(compStart + compDuration, model.duration))
    return (s, max(0.2, e - s))
}

private struct ZoomTrack: View {
    @Bindable var model: EditorModel
    let pps: Double
    @State private var draft: (Double, Double)?

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.04))
                .overlay {
                    if model.edit.zooms.isEmpty && draft == nil {
                        Text("在这里左右拖拽，选出要放大的时间段")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .gesture(createGesture)
            if let (a, b) = draft {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.violet.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.violet, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .frame(width: max(2, (b - a) * pps), height: 24)
                    .offset(x: a * pps)
                    .allowsHitTesting(false)
            }
            ForEach(model.edit.zooms) { z in
                if let (a, b) = model.timeline.compRange(start: z.start, end: z.end) {
                    TrackItem(start: a, duration: b - a, pps: pps, color: Theme.violet,
                              symbol: z.isAuto ? "sparkles" : "plus.magnifyingglass",
                              title: String(format: "%.1f×", z.scale),
                              selected: model.selection == .zoom(z.id),
                              model: model, item: .zoom(z.id),
                              onSelect: {
                                  model.select(.zoom(z.id))
                                  if model.sourceTime < z.start || model.sourceTime > z.end {
                                      model.seek(source: z.start + min(0.5, z.duration / 2))
                                  }
                              },
                              onChange: { s, d in
                                  guard let i = model.edit.zooms.firstIndex(where: { $0.id == z.id }) else { return }
                                  let (start, duration) = sourceSpan(model, compStart: s, compDuration: d)
                                  model.edit.zooms[i].start = start
                                  model.edit.zooms[i].duration = duration
                                  model.edit.zooms[i].isAuto = false
                              })
                }
            }
        }
        .help("在缩放轨道上左右拖拽，选出要放大的时间段")
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
            .onChanged { v in
                let a = max(0, min(v.startLocation.x, v.location.x) / pps)
                let b = min(model.duration, max(v.startLocation.x, v.location.x) / pps)
                draft = (a, b)
            }
            .onEnded { _ in
                defer { draft = nil }
                guard let (a, b) = draft, b - a > 0.15 else { return }
                let (start, duration) = sourceSpan(model, compStart: a, compDuration: b - a)
                model.addZoom(at: start, duration: duration)
                model.seek(comp: a + min(0.5, (b - a) / 2))
            }
    }
}

private struct AnnotationTrack: View {
    @Bindable var model: EditorModel
    let pps: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.04))
            let lanes = Lanes.assign(model.edit.annotations.map { ($0.start, $0.end) })
            ForEach(Array(model.edit.annotations.enumerated()), id: \.element.id) { i, a in
                if let (s, e) = model.timeline.compRange(start: a.start, end: a.end) {
                    TrackItem(start: s, duration: e - s, pps: pps, height: 20, color: Theme.coral, symbol: a.kind.symbol,
                              title: a.step.map { "\(a.kind.label) \($0)" } ?? (a.kind == .text ? a.text : a.kind.label),
                              selected: model.selection == .annotation(a.id),
                              model: model, item: .annotation(a.id),
                              onSelect: {
                                  model.select(.annotation(a.id))
                                  if model.sourceTime < a.start || model.sourceTime > a.end {
                                      model.seek(source: a.start + min(0.4, a.duration / 2))
                                  }
                              },
                              onChange: { cs, cd in
                                  guard let i = model.edit.annotations.firstIndex(where: { $0.id == a.id }) else { return }
                                  let (start, duration) = sourceSpan(model, compStart: cs, compDuration: cd)
                                  model.edit.annotations[i].start = start
                                  model.edit.annotations[i].duration = duration
                              })
                    .offset(y: CGFloat(min(2, lanes.firstIndex { $0.contains(i) } ?? 0)) * 22 + 2)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Packs overlapping time ranges into rows.
enum Lanes {
    static func assign(_ ranges: [(Double, Double)]) -> [[Int]] {
        var lanes: [[Int]] = []
        var ends: [Double] = []
        for i in ranges.indices.sorted(by: { ranges[$0].0 < ranges[$1].0 }) {
            if let l = ends.firstIndex(where: { $0 <= ranges[i].0 }) {
                lanes[l].append(i)
                ends[l] = ranges[i].1
            } else {
                lanes.append([i])
                ends.append(ranges[i].1)
            }
        }
        return lanes
    }
}

private struct BlurTrack: View {
    @Bindable var model: EditorModel
    let pps: Double

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.04))
            ForEach(model.edit.blurs) { b in
                if let (s, e) = model.timeline.compRange(start: b.start, end: b.end) {
                    TrackItem(start: s, duration: e - s, pps: pps, color: Color(red: 0.25, green: 0.6, blue: 0.75),
                              symbol: b.keyframes.count > 1 ? "scope" : "eye.slash",
                              title: b.label.isEmpty ? b.style.label : b.label,
                              selected: model.selection == .blur(b.id),
                              model: model, item: .blur(b.id),
                              onSelect: {
                                  model.select(.blur(b.id))
                                  if model.sourceTime < b.start || model.sourceTime > b.end {
                                      model.seek(source: b.start + min(0.4, b.duration / 2))
                                  }
                              },
                              onChange: { cs, cd in
                                  guard let i = model.edit.blurs.firstIndex(where: { $0.id == b.id }) else { return }
                                  let (start, duration) = sourceSpan(model, compStart: cs, compDuration: cd)
                                  model.edit.blurs[i].start = start
                                  model.edit.blurs[i].duration = duration
                              })
                }
            }
        }
    }
}
