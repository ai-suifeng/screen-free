import CoreImage
import CoreImage.CIFilterBuiltins

/// Builds the final frame: privacy blur → annotations → cursor → zoom → framing → background → webcam.
final class FrameRenderer {
    private let lock = NSLock()
    private var spriteCache: [String: AnnotationPainter.Sprite] = [:]
    private var keyCache: [String: CGImage] = [:]

    func render(screen: CIImage, camera: CIImage?, compTime: Double, canvas C: CGSize, state: RenderState) -> CIImage {
        let edit = state.edit
        let t = state.timeline.sourceTime(compTime)
        let S = screen.extent.size
        // Pixels per capture point, so line widths look the same at any resolution.
        let pt = S.width / max(Double(state.meta.width) / state.meta.scale, 1)

        var img = screen
        img = applyBlurs(img, size: S, t: t, state: state)
        img = applyAnnotations(img, size: S, pt: pt, t: t, state: state)
        if edit.cursor.visible { img = applyCursor(img, size: S, pt: pt, t: t, state: state) }

        // Zoom.
        let v = state.viewport(at: t)
        if v.w < 0.999 {
            let vr = v.ciRect(in: S)
            img = img.clampedToExtent().cropped(to: vr)
                .transformed(by: CGAffineTransform(translationX: -vr.minX, y: -vr.minY))
                .transformed(by: CGAffineTransform(scaleX: S.width / vr.width, y: S.height / vr.height))
                .cropped(to: CGRect(origin: .zero, size: S))
        }

        // Place the screen inside the canvas (Core Image space is bottom-up).
        let top = state.contentRect(canvas: C)
        let R = CGRect(x: top.minX, y: C.height - top.maxY, width: top.width, height: top.height)
        img = img.transformed(by: CGAffineTransform(scaleX: R.width / S.width, y: R.height / S.height))
            .transformed(by: CGAffineTransform(translationX: R.minX, y: R.minY))

        let style = edit.style
        let framed = style.background.kind != .none
        let minC = min(C.width, C.height)
        var contentAlpha = 1.0
        if style.transition == .fade {
            for cut in state.timeline.cuts {
                let d = abs(compTime - cut)
                if d < 0.22 { contentAlpha = min(contentAlpha, ease(d / 0.22)) }
            }
        }

        var layer = img
        if framed && style.cornerRadius > 0 {
            let radius = style.cornerRadius * min(R.width, R.height)
            layer = layer.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: roundedRect(R, radius: radius, color: .white),
            ])
        }
        if contentAlpha < 1 { layer = layer.withAlpha(contentAlpha) }

        var out: CIImage
        if framed {
            out = background(style.background, canvas: C)
            if style.shadow > 0 {
                let radius = style.cornerRadius * min(R.width, R.height)
                let shadow = roundedRect(R, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.75 * style.shadow * contentAlpha))
                    .applyingGaussianBlur(sigma: minC * 0.022)
                    .transformed(by: CGAffineTransform(translationX: 0, y: -minC * 0.012))
                out = shadow.composited(over: out)
            }
            out = layer.composited(over: out)
        } else {
            out = layer.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: C)))
        }

        if edit.showKeystrokes { out = applyKeystrokes(out, canvas: C, t: t, state: state) }
        if let camera, state.meta.hasCamera, edit.camera.visible {
            out = applyCamera(camera, over: out, canvas: C, settings: edit.camera)
        }
        return out.cropped(to: CGRect(origin: .zero, size: C))
    }

    // MARK: - Layers

    private func applyBlurs(_ img: CIImage, size S: CGSize, t: Double, state: RenderState) -> CIImage {
        var img = img
        for b in state.edit.blurs where t >= b.start && t <= b.end && !state.hiddenIDs.contains(b.id) {
            let r = b.rect(at: t).ciRect(in: S).intersection(CGRect(origin: .zero, size: S))
            guard r.width > 1, r.height > 1 else { continue }
            let patch: CIImage
            switch b.style {
            case .mosaic:
                patch = img.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(10, S.width / 90),
                                                                kCIInputCenterKey: CIVector(x: r.minX, y: r.minY)])
            case .blur:
                patch = img.clampedToExtent().applyingGaussianBlur(sigma: max(12, S.width / 110))
            case .solid:
                patch = CIImage(color: CIColor(red: 0.13, green: 0.13, blue: 0.15))
            }
            img = patch.cropped(to: r).composited(over: img)
        }
        return img
    }

    private func applyAnnotations(_ img: CIImage, size S: CGSize, pt: Double, t: Double, state: RenderState) -> CIImage {
        var img = img
        for a in state.edit.annotations where t >= a.start && t <= a.end && !state.hiddenIDs.contains(a.id) {
            let local = t - a.start
            let fadeIn = a.kind == .pen || a.kind == .highlighter ? 1 : ease(local / 0.18)
            let fadeOut = ease((a.end - t) / (a.fades ? 0.45 : 0.25))
            let alpha = min(fadeIn, fadeOut)
            guard alpha > 0.01 else { continue }

            switch a.kind {
            case .spotlight:
                let r = a.rect.ciRect(in: S)
                let radius = min(12 * pt, r.height / 3)
                let dim = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.38, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.38, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.38, w: 0),
                ]).applyingGaussianBlur(sigma: 2 * pt).cropped(to: img.extent)
                let hole = roundedRect(r, radius: radius, color: .white)
                    .composited(over: CIImage(color: .black).cropped(to: img.extent))
                let spot = img.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: dim, kCIInputMaskImageKey: hole,
                ])
                img = spot.withAlpha(alpha).composited(over: img)
            case .magnify:
                let r = a.rect.ciRect(in: S)
                let zoom = 1.6
                let grow = 1 + 0.5 * ease(local / 0.25)
                let center = CGPoint(x: r.midX, y: r.midY)
                let target = CGRect(x: center.x - r.width * grow / 2, y: center.y - r.height * grow / 2,
                                    width: r.width * grow, height: r.height * grow)
                let lens = img.clampedToExtent()
                    .transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
                        .concatenating(CGAffineTransform(scaleX: zoom * grow / 1.5, y: zoom * grow / 1.5))
                        .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
                let radius = min(14 * pt, target.height / 3)
                let masked = lens.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: roundedRect(target, radius: radius, color: .white),
                ])
                let shadow = roundedRect(target, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5))
                    .applyingGaussianBlur(sigma: 10 * pt)
                    .transformed(by: CGAffineTransform(translationX: 0, y: -4 * pt))
                img = masked.withAlpha(alpha).composited(over: shadow.withAlpha(alpha).composited(over: img))
                var border = a
                border.rect = NormRect(x: target.minX / S.width, y: 1 - target.maxY / S.height,
                                       w: target.width / S.width, h: target.height / S.height)
                if let s = AnnotationPainter.sprite(for: border, size: S, pt: pt, progress: local) {
                    img = CIImage(cgImage: s.image).transformed(by: CGAffineTransform(translationX: s.origin.x, y: s.origin.y))
                        .withAlpha(alpha).composited(over: img)
                }
                continue
            default:
                break
            }

            guard let sprite = cachedSprite(a, size: S, pt: pt, progress: local) else { continue }
            var layer = CIImage(cgImage: sprite.image)
                .transformed(by: CGAffineTransform(translationX: sprite.origin.x, y: sprite.origin.y))
            if a.kind == .box || a.kind == .text {
                // Small pop when the box appears.
                let s = 1 + 0.12 * (1 - easeOutCubic(local / 0.28))
                let c = CGPoint(x: layer.extent.midX, y: layer.extent.midY)
                layer = layer.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                    .concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            }
            img = layer.withAlpha(alpha).composited(over: img)
        }
        return img
    }

    private func cachedSprite(_ a: Annotation, size S: CGSize, pt: Double, progress: Double) -> AnnotationPainter.Sprite? {
        let isStroke = a.kind == .pen || a.kind == .highlighter
        let visible = isStroke ? a.points.lastIndex { $0.t <= progress } ?? -1 : 0
        let key = "\(a.hashValue)-\(Int(S.width))-\(visible)"
        lock.lock()
        if let s = spriteCache[key] { lock.unlock(); return s }
        lock.unlock()
        guard let sprite = AnnotationPainter.sprite(for: a, size: S, pt: pt, progress: progress) else { return nil }
        lock.lock()
        if spriteCache.count > 400 { spriteCache.removeAll() }
        spriteCache[key] = sprite
        lock.unlock()
        return sprite
    }

    private func applyCursor(_ img: CIImage, size S: CGSize, pt: Double, t: Double, state: RenderState) -> CIImage {
        guard let p = state.cursor.position(at: t), let cursor = AnnotationPainter.cursorImage else { return img }
        let settings = state.edit.cursor
        var alpha = 1.0
        if settings.hideWhenIdle {
            let idle = state.cursor.idleTime(at: t)
            alpha = 1 - ((idle - 1.6) / 0.35).clamped(0, 1)
        }
        var img = img
        let at = p.ciPoint(in: S)

        // Click ripples, and a slight press-down of the cursor.
        var press = 1.0
        if settings.clickEffect {
            for c in state.clicks where c.t <= t && t - c.t < 0.5 {
                let k = (t - c.t) / 0.5
                press = min(press, 0.82 + 0.18 * easeOutCubic(k * 2.5))
                guard let ring = AnnotationPainter.clickRing else { continue }
                let cp = c.p.ciPoint(in: S)
                let d = (14 + 34 * easeOutCubic(k)) * pt * settings.scale / 1.6
                let ringImage = CIImage(cgImage: ring)
                let scale = d / ringImage.extent.width
                img = ringImage
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(translationX: cp.x - d / 2, y: cp.y - d / 2))
                    .withAlpha((1 - k) * 0.9)
                    .composited(over: img)
            }
        }
        guard alpha > 0.01 else { return img }

        let heightPx = cursor.pointSize.height * pt * settings.scale * press
        let scale = heightPx / Double(cursor.image.height)
        let hot = CGPoint(x: cursor.hotspot.x / cursor.pointSize.width * Double(cursor.image.width) * scale,
                          y: cursor.hotspot.y / cursor.pointSize.height * Double(cursor.image.height) * scale)
        let layer = CIImage(cgImage: cursor.image)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = layer.transformed(by: CGAffineTransform(translationX: at.x - hot.x, y: at.y - (layer.extent.height - hot.y)))
        return placed.withAlpha(alpha).composited(over: img)
    }

    private func applyKeystrokes(_ img: CIImage, canvas C: CGSize, t: Double, state: RenderState) -> CIImage {
        guard let key = state.keys.last(where: { $0.t <= t && t - $0.t < 1.4 }) else { return img }
        let local = t - key.t
        let alpha = min(ease(local / 0.12), ease((1.4 - local) / 0.3))
        let h = min(C.width, C.height) * 0.06
        let cacheKey = "\(key.key)-\(Int(h))"
        lock.lock()
        var badge = keyCache[cacheKey]
        lock.unlock()
        if badge == nil {
            badge = AnnotationPainter.keyBadge(key.key, height: h)
            lock.lock(); keyCache[cacheKey] = badge; lock.unlock()
        }
        guard let badge else { return img }
        let b = CIImage(cgImage: badge)
        let x = (C.width - b.extent.width) / 2
        let y = C.height * 0.06 - 6 * (1 - ease(local / 0.15))
        return b.transformed(by: CGAffineTransform(translationX: x, y: y)).withAlpha(alpha).composited(over: img)
    }

    private func applyCamera(_ cam: CIImage, over img: CIImage, canvas C: CGSize, settings: CameraSettings) -> CIImage {
        let minC = min(C.width, C.height)
        let d = settings.size * minC
        let e = cam.extent
        let side = min(e.width, e.height)
        // Square crop, mirrored like a selfie view.
        let square = cam.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -(e.midX - side / 2), y: -(e.midY - side / 2)))
            .transformed(by: CGAffineTransform(scaleX: -d / side, y: d / side))
            .transformed(by: CGAffineTransform(translationX: d, y: 0))
        let margin = minC * 0.035
        let x: Double, y: Double
        switch settings.corner {
        case .bottomRight: x = C.width - d - margin; y = margin
        case .bottomLeft: x = margin; y = margin
        case .topRight: x = C.width - d - margin; y = C.height - d - margin
        case .topLeft: x = margin; y = C.height - d - margin
        }
        let frame = CGRect(x: x, y: y, width: d, height: d)
        let radius = settings.shape == .circle ? d / 2 : d * 0.18
        let placed = square.transformed(by: CGAffineTransform(translationX: x, y: y))
        let masked = placed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: roundedRect(frame, radius: radius, color: .white),
        ])
        let ring = roundedRect(frame.insetBy(dx: -d * 0.02, dy: -d * 0.02), radius: radius + d * 0.02,
                               color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        let shadow = roundedRect(frame, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            .applyingGaussianBlur(sigma: d * 0.06)
            .transformed(by: CGAffineTransform(translationX: 0, y: -d * 0.03))
        return masked.composited(over: ring.composited(over: shadow.composited(over: img)))
    }

    // MARK: - Helpers

    private func background(_ bg: BackgroundStyle, canvas C: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: C)
        switch bg.kind {
        case .gradient:
            let g = BackgroundStyle.gradients[min(bg.gradient, BackgroundStyle.gradients.count - 1)]
            let f = CIFilter.linearGradient()
            f.point0 = CGPoint(x: 0, y: C.height)
            f.point1 = CGPoint(x: C.width, y: 0)
            f.color0 = CIColor(red: g.a.r, green: g.a.g, blue: g.a.b)
            f.color1 = CIColor(red: g.b.r, green: g.b.g, blue: g.b.b)
            return f.outputImage!.cropped(to: rect)
        case .solid:
            return CIImage(color: CIColor(red: bg.solid.r, green: bg.solid.g, blue: bg.solid.b)).cropped(to: rect)
        case .none:
            return CIImage(color: .black).cropped(to: rect)
        }
    }

    private func roundedRect(_ r: CGRect, radius: Double, color: CIColor) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = r
        f.radius = Float(max(0, min(radius, min(r.width, r.height) / 2)))
        f.color = color
        return f.outputImage ?? CIImage.empty()
    }
}

extension CIImage {
    func withAlpha(_ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return self }
        return applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
        ])
    }
}
