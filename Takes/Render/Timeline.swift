import Foundation

/// Maps between composition time (the trimmed output) and source time (all takes end to end).
struct Timeline: Hashable {
    struct Entry: Hashable {
        var clipID: UUID?
        var segment: Int
        /// Source time where this take begins, untrimmed.
        var takeStart: Double
        var takeDuration: Double
        /// Kept range in source time.
        var sourceStart: Double
        var duration: Double
        var compStart: Double

        var sourceEnd: Double { sourceStart + duration }
        var compEnd: Double { compStart + duration }
    }

    /// Start of every take in source time, keyed by segment index, including disabled takes.
    var takeOffsets: [Int: Double] = [:]
    var takeDurations: [Int: Double] = [:]
    var entries: [Entry] = []
    var sourceDuration: Double = 0

    var duration: Double { entries.last?.compEnd ?? 0 }

    init() {}

    /// `durations` are the real take lengths; `clips` are played in order.
    init(segments: [SegmentInfo], durations: [Int: Double], clips: [Clip]) {
        var offset = 0.0
        for seg in segments {
            let full = durations[seg.index] ?? seg.duration
            takeOffsets[seg.index] = offset
            takeDurations[seg.index] = full
            offset += full
        }
        sourceDuration = offset
        var comp = 0.0
        for clip in clips {
            guard let takeStart = takeOffsets[clip.segment], let full = takeDurations[clip.segment] else { continue }
            let start = clip.start.clamped(0, full), end = clip.end.clamped(0, full)
            guard end - start > 0.02 else { continue }
            entries.append(Entry(clipID: clip.id, segment: clip.segment, takeStart: takeStart, takeDuration: full,
                                 sourceStart: takeStart + start, duration: end - start, compStart: comp))
            comp += end - start
        }
    }

    func sourceTime(_ comp: Double) -> Double {
        guard let first = entries.first else { return 0 }
        if comp <= 0 { return first.sourceStart }
        for e in entries where comp < e.compEnd {
            return e.sourceStart + (comp - e.compStart)
        }
        return entries.last!.sourceEnd
    }

    /// Composition time for a source time, or nil if that moment was cut out.
    func compTimeIfKept(_ source: Double) -> Double? {
        for e in entries where source >= e.sourceStart - 0.0005 && source <= e.sourceEnd + 0.0005 {
            return e.compStart + (source - e.sourceStart)
        }
        return nil
    }

    /// Composition time for a source time, or the nearest following kept time if it was cut out.
    func compTime(_ source: Double) -> Double {
        if let t = compTimeIfKept(source) { return t }
        // Clips may be reordered relative to source time, so pick the closest later start.
        let later = entries.filter { $0.sourceStart >= source }.min { $0.sourceStart < $1.sourceStart }
        return later?.compStart ?? duration
    }

    /// Output-time span covered by a source range (start and end, clamped to kept material).
    func compRange(start: Double, end: Double) -> (Double, Double)? {
        let a = compTime(start)
        var b = compTimeIfKept(end) ?? a
        if b < a { b = a }
        if compTimeIfKept(end) == nil {
            // End falls in a cut: extend to the end of the last kept piece inside the range.
            for e in entries where e.sourceEnd <= end && e.sourceEnd >= start { b = max(b, e.compEnd) }
        }
        return b - a > 0.01 ? (a, b) : nil
    }

    func isKept(_ source: Double) -> Bool {
        entries.contains { source >= $0.sourceStart && source <= $0.sourceEnd }
    }

    /// Composition times where one take hands over to the next.
    var cuts: [Double] { entries.dropFirst().map(\.compStart) }

    func sourceTime(segment: Int, local: Double) -> Double {
        (takeOffsets[segment] ?? 0) + local
    }
}

/// Cursor positions resampled at a fixed rate, optionally spring-smoothed.
struct CursorTrack {
    static let rate = 60.0

    var xs: [Double] = []
    var ys: [Double] = []
    /// Seconds since the cursor last moved, per sample.
    var idle: [Double] = []
    var firstTime: Double = .infinity

    init() {}

    init(moves: [(t: Double, x: Double, y: Double)], duration: Double, smoothing: Double) {
        guard let first = moves.first, duration > 0 else { return }
        firstTime = first.t
        let count = Int(duration * Self.rate) + 2
        xs.reserveCapacity(count)
        ys.reserveCapacity(count)
        idle.reserveCapacity(count)

        var j = 0
        var lastMove = first.t
        var prev = (x: first.x, y: first.y)
        for i in 0..<count {
            let t = Double(i) / Self.rate
            while j + 1 < moves.count, moves[j + 1].t <= t { j += 1 }
            var x = moves[j].x, y = moves[j].y
            if j + 1 < moves.count, moves[j].t <= t {
                let a = moves[j], b = moves[j + 1]
                // Only interpolate across short gaps; long gaps mean the cursor was resting.
                if b.t - a.t < 0.25 {
                    let f = (t - a.t) / max(b.t - a.t, 1e-6)
                    x = a.x + (b.x - a.x) * f
                    y = a.y + (b.y - a.y) * f
                }
            }
            if abs(x - prev.x) > 0.0004 || abs(y - prev.y) > 0.0004 { lastMove = t }
            prev = (x, y)
            xs.append(x)
            ys.append(y)
            idle.append(max(0, t - lastMove))
        }

        if smoothing > 0.01 {
            // Critically damped spring; lower stiffness = smoother, laggier.
            let stiffness = 900 * pow(1 - smoothing * 0.92, 2) + 40
            let damping = 2 * sqrt(stiffness)
            let dt = 1 / Self.rate
            var px = xs[0], py = ys[0], vx = 0.0, vy = 0.0
            for i in 0..<xs.count {
                for _ in 0..<4 {
                    let h = dt / 4
                    vx += (stiffness * (xs[i] - px) - damping * vx) * h
                    vy += (stiffness * (ys[i] - py) - damping * vy) * h
                    px += vx * h
                    py += vy * h
                }
                xs[i] = px
                ys[i] = py
            }
        }
    }

    func position(at t: Double) -> NormPoint? {
        guard !xs.isEmpty, t >= firstTime - 0.001 else { return nil }
        let f = t * Self.rate
        let i = min(max(Int(f), 0), xs.count - 1)
        let k = min(i + 1, xs.count - 1)
        let w = f - Double(i)
        return NormPoint(x: xs[i] + (xs[k] - xs[i]) * w, y: ys[i] + (ys[k] - ys[i]) * w)
    }

    func idleTime(at t: Double) -> Double {
        guard !idle.isEmpty else { return 0 }
        return idle[min(max(Int(t * Self.rate), 0), idle.count - 1)]
    }
}

/// The zoom viewport over time, precomputed so the camera glides smoothly.
struct CameraPath {
    static let rate = 60.0
    static let ramp = 0.55

    private var xs: [Double] = []
    private var ys: [Double] = []
    private var scales: [Double] = []

    init() {}

    init(zooms: [ZoomRegion], cursor: CursorTrack, duration: Double) {
        guard !zooms.isEmpty, duration > 0 else { return }
        let count = Int(duration * Self.rate) + 2
        let dt = 1 / Self.rate
        let sorted = zooms.sorted { $0.start < $1.start }

        var cx = 0.5, cy = 0.5, vx = 0.0, vy = 0.0
        var targetX = 0.5, targetY = 0.5
        let stiffness = 60.0
        let damping = 2 * sqrt(stiffness)

        xs.reserveCapacity(count); ys.reserveCapacity(count); scales.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) * dt
            var scale = 1.0
            var region: ZoomRegion?
            // The zoom-in and zoom-out happen inside the region, so it starts exactly where the timeline shows it.
            for z in sorted where t >= z.start && t <= z.end {
                let ramp = min(Self.ramp, z.duration / 3)
                let p: Double
                if t < z.start + ramp { p = ease((t - z.start) / ramp) }
                else if t > z.end - ramp { p = ease((z.end - t) / ramp) }
                else { p = 1 }
                let s = 1 + (z.scale - 1) * p
                if s > scale { scale = s; region = z }
            }

            if let z = region {
                let half = 0.5 / z.scale
                switch z.mode {
                case .fixed:
                    targetX = z.center.x; targetY = z.center.y
                case .follow:
                    if let p = cursor.position(at: t) {
                        // Dead zone: only move when the cursor nears the edge of the zoomed view.
                        let margin = half * 0.55
                        if p.x < targetX - margin { targetX = p.x + margin }
                        if p.x > targetX + margin { targetX = p.x - margin }
                        if p.y < targetY - margin { targetY = p.y + margin }
                        if p.y > targetY + margin { targetY = p.y - margin }
                        if t < z.start + 0.05 { targetX = p.x; targetY = p.y }
                    }
                }
                targetX = targetX.clamped(half, 1 - half)
                targetY = targetY.clamped(half, 1 - half)
            }
            if scale <= 1.001 {
                // Zoomed out: rest at the cursor so the next zoom starts from there.
                if let p = cursor.position(at: t) { targetX = p.x; targetY = p.y }
                cx = targetX; cy = targetY; vx = 0; vy = 0
            } else {
                vx += (stiffness * (targetX - cx) - damping * vx) * dt
                vy += (stiffness * (targetY - cy) - damping * vy) * dt
                cx += vx * dt
                cy += vy * dt
            }
            xs.append(cx); ys.append(cy); scales.append(scale)
        }
    }

    /// Visible part of the source frame at time `t`, normalized.
    func viewport(at t: Double) -> NormRect {
        guard !scales.isEmpty else { return NormRect(x: 0, y: 0, w: 1, h: 1) }
        let f = t * Self.rate
        let i = min(max(Int(f), 0), scales.count - 1)
        let k = min(i + 1, scales.count - 1)
        let w = f - Double(i)
        let s = scales[i] + (scales[k] - scales[i]) * w
        let cx = xs[i] + (xs[k] - xs[i]) * w
        let cy = ys[i] + (ys[k] - ys[i]) * w
        let size = 1 / max(s, 1)
        return NormRect(x: (cx - size / 2).clamped(0, 1 - size), y: (cy - size / 2).clamped(0, 1 - size), w: size, h: size)
    }
}

enum AutoZoom {
    /// Groups nearby clicks into zoom regions.
    static func regions(clicks: [Double], scale: Double, duration: Double) -> [ZoomRegion] {
        var result: [ZoomRegion] = []
        var groupStart: Double?
        var groupEnd = 0.0
        func flush() {
            guard let s = groupStart else { return }
            // Start early enough that the zoom-in has finished by the first click.
            let start = max(0, s - 0.7)
            let end = min(duration, max(groupEnd + 1.8, start + 2))
            result.append(ZoomRegion(start: start, duration: end - start, scale: scale))
        }
        for t in clicks.sorted() {
            if let _ = groupStart, t - groupEnd < 2.5 {
                groupEnd = t
            } else {
                flush()
                groupStart = t
                groupEnd = t
            }
        }
        flush()
        // Merge regions that ended up overlapping.
        var merged: [ZoomRegion] = []
        for r in result {
            if var last = merged.last, r.start <= last.end + 0.6 {
                last.duration = max(last.end, r.end) - last.start
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}
