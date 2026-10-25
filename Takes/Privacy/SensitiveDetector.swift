import AVFoundation
import Vision

/// Finds personal data on screen (emails, phone numbers, keys…) so it can be blurred in one go.
enum SensitiveDetector {
    enum Kind: String, CaseIterable {
        case email, phone, idCard, bankCard, secret, ip

        var label: String {
            switch self {
            case .email: "邮箱"
            case .phone: "手机号"
            case .idCard: "身份证号"
            case .bankCard: "银行卡号"
            case .secret: "密钥 / Token"
            case .ip: "IP 地址"
            }
        }

        var symbol: String {
            switch self {
            case .email: "envelope"
            case .phone: "phone"
            case .idCard: "person.text.rectangle"
            case .bankCard: "creditcard"
            case .secret: "key"
            case .ip: "network"
            }
        }

        var pattern: String {
            switch self {
            case .email: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
            case .phone: #"(?<!\d)(?:\+?86[ \-]?)?1[3-9]\d[ \-]?\d{4}[ \-]?\d{4}(?!\d)"#
            case .idCard: #"(?<!\d)\d{6}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx](?!\d)"#
            case .bankCard: #"(?<!\d)(?:\d{4}[ \-]?){3}\d{4}(?:\d{0,3})(?!\d)"#
            case .secret: #"(?:sk-[A-Za-z0-9_\-]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9\-]{10,}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}|(?<![A-Za-z0-9])[A-Za-z0-9_\-]{32,}(?![A-Za-z0-9]))"#
            case .ip: #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])"#
            }
        }
    }

    struct Finding: Identifiable, Hashable {
        let id = UUID()
        var kind: Kind
        var text: String
        var start: Double
        var end: Double
        var rect: NormRect
        var selected = true

        var masked: String {
            guard text.count > 4 else { return String(repeating: "•", count: text.count) }
            return String(text.prefix(2)) + String(repeating: "•", count: min(8, text.count - 4)) + String(text.suffix(2))
        }
    }

    static let interval = 0.75

    /// Scans all kept parts of the recording. `progress` is called on the main actor with 0…1.
    static func scan(model: EditorModel, progress: @escaping @MainActor (Double) -> Void) async -> [Finding] {
        let timeline = model.timeline
        let entries = timeline.entries
        let regexes = Kind.allCases.compactMap { k in (try? NSRegularExpression(pattern: k.pattern)).map { (k, $0) } }
        let total = max(entries.reduce(0) { $0 + $1.duration }, 0.1)
        var done = 0.0
        var hits: [Finding] = []

        for entry in entries {
            guard let asset = model.assets[entry.segment] else { continue }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 2600, height: 2600)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            var local = entry.sourceStart - entry.takeStart
            let localEnd = local + entry.duration
            while local < localEnd {
                if Task.isCancelled { return [] }
                if let (image, _) = try? await generator.image(at: CMTime(seconds: local, preferredTimescale: 600)) {
                    let source = entry.takeStart + local
                    let found = await Task.detached(priority: .userInitiated) {
                        matches(in: TextScanner.recognize(image), regexes: regexes, at: source)
                    }.value
                    hits.append(contentsOf: found)
                }
                done += interval
                await progress(min(1, done / total))
                local += interval
            }
        }
        return merge(hits)
    }

    private static func matches(in lines: [TextScanner.Line], regexes: [(Kind, NSRegularExpression)], at t: Double) -> [Finding] {
        var result: [Finding] = []
        for line in lines {
            let ns = line.text as NSString
            var taken: [NSRange] = []
            for (kind, regex) in regexes {
                for m in regex.matches(in: line.text, range: NSRange(location: 0, length: ns.length)) {
                    // Skip spans already claimed by a more specific pattern (e.g. an ID card is not a bank card).
                    if taken.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
                    let text = ns.substring(with: m.range)
                    if kind == .secret && !looksLikeSecret(text) { continue }
                    taken.append(m.range)
                    var rect = line.rect
                    if let range = Range(m.range, in: line.text),
                       let box = try? line.observation.boundingBox(for: range) {
                        rect = NormRect(vision: box.boundingBox)
                    }
                    let padded = rect.insetBy(-rect.h * 0.25, -rect.h * 0.2).clamped()
                    result.append(Finding(kind: kind, text: text, start: t, end: t, rect: padded))
                }
            }
        }
        return result
    }

    /// Long tokens must mix letters and digits to count as secrets, so plain words and paths are ignored.
    private static func looksLikeSecret(_ s: String) -> Bool {
        if s.hasPrefix("sk-") || s.hasPrefix("ghp_") || s.hasPrefix("AKIA") || s.hasPrefix("xox") || s.hasPrefix("eyJ") { return true }
        let digits = s.filter(\.isNumber).count
        let letters = s.filter(\.isLetter).count
        return digits >= 6 && letters >= 6
    }

    /// Joins sightings of the same text at the same place into one time range.
    private static func merge(_ hits: [Finding]) -> [Finding] {
        var merged: [Finding] = []
        for h in hits.sorted(by: { $0.start < $1.start }) {
            if let i = merged.lastIndex(where: { $0.text == h.text && h.start - $0.end <= interval * 1.6 && $0.rect.iou(h.rect) > 0.3 }) {
                merged[i].end = h.end
                merged[i].rect = merged[i].rect.union(h.rect)
            } else {
                merged.append(h)
            }
        }
        // Cover the gap before the first and after the last sighting.
        return merged.map { f in
            var f = f
            f.start = max(0, f.start - interval / 2)
            f.end += interval / 2 + 0.2
            return f
        }
    }
}

/// Follows a blurred region as the content moves (scrolling, dragging windows).
enum BlurTracker {
    static func track(_ region: BlurRegion, model: EditorModel, progress: @escaping @MainActor (Double) -> Void) async -> [BlurKeyframe]? {
        let timeline = model.timeline
        guard let entry = timeline.entries.first(where: { region.start >= $0.takeStart && region.start < $0.takeStart + $0.takeDuration }),
              let asset = model.assets[entry.segment] else { return nil }
        let fps = 15.0
        let localStart = region.start - entry.takeStart
        let localEnd = min(region.end - entry.takeStart, entry.takeDuration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1 / fps, preferredTimescale: 600)

        let handler = VNSequenceRequestHandler()
        var observation = VNDetectedObjectObservation(boundingBox: region.rect.visionRect)
        var keyframes = [BlurKeyframe(t: 0, rect: region.rect)]
        var t = localStart + 1 / fps
        while t < localEnd {
            if Task.isCancelled { return nil }
            guard let (image, _) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { break }
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            let current = observation
            let next: VNDetectedObjectObservation? = await Task.detached(priority: .userInitiated) {
                try? handler.perform([request], on: image)
                guard let r = request.results?.first as? VNDetectedObjectObservation, r.confidence > 0.3 else { return nil }
                return r
            }.value
            observation = next ?? current
            keyframes.append(BlurKeyframe(t: t - localStart, rect: NormRect(vision: observation.boundingBox).clamped()))
            await progress((t - localStart) / max(localEnd - localStart, 0.01))
            t += 1 / fps
        }
        return keyframes
    }
}
