import AVFoundation
import Vision

/// Samples frames from takes and runs on-device OCR.
enum TextScanner {
    struct Line {
        var text: String
        /// Normalized, top-left origin.
        var rect: NormRect
        var observation: VNRecognizedText
    }

    static func frames(of asset: AVURLAsset, every interval: Double, maxSide: Double = 2400) async -> [(t: Double, image: CGImage)] {
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var result: [(Double, CGImage)] = []
        var t = 0.0
        while t < duration {
            if Task.isCancelled { break }
            if let (image, actual) = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                result.append((actual.seconds, image))
            }
            t += interval
        }
        return result
    }

    static func recognize(_ image: CGImage, fast: Bool = false) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return Line(text: top.string, rect: NormRect(vision: obs.boundingBox), observation: top)
        }
    }
}

extension NormRect {
    /// From a Vision rect (normalized, bottom-left origin).
    init(vision r: CGRect) {
        self.init(x: r.minX, y: 1 - r.maxY, w: r.width, h: r.height)
    }

    var visionRect: CGRect { CGRect(x: x, y: 1 - y - h, width: w, height: h) }

    func union(_ o: NormRect) -> NormRect {
        let x0 = min(x, o.x), y0 = min(y, o.y)
        return NormRect(x: x0, y: y0, w: max(x + w, o.x + o.w) - x0, h: max(y + h, o.y + o.h) - y0)
    }

    func iou(_ o: NormRect) -> Double {
        let ix = max(0, min(x + w, o.x + o.w) - max(x, o.x))
        let iy = max(0, min(y + h, o.y + o.h) - max(y, o.y))
        let inter = ix * iy
        let uni = w * h + o.w * o.h - inter
        return uni > 0 ? inter / uni : 0
    }
}

struct ScreenTextIndex: Codable {
    var text: String
}

/// Indexes on-screen text after a recording so the library can be searched by content.
enum ScreenTextIndexer {
    static func indexInBackground(_ bundle: ProjectBundle) {
        Task.detached(priority: .background) {
            guard let meta = try? bundle.readMeta() else { return }
            var seen = Set<String>()
            var lines: [String] = []
            for seg in meta.segments {
                let asset = AVURLAsset(url: bundle.segmentURL(seg.file))
                let interval = max(3, seg.duration / 40)
                for (_, image) in await TextScanner.frames(of: asset, every: interval, maxSide: 1800) {
                    for line in TextScanner.recognize(image) {
                        let text = line.text.trimmingCharacters(in: .whitespaces)
                        guard text.count >= 2, seen.insert(text).inserted else { continue }
                        lines.append(text)
                    }
                }
            }
            let index = ScreenTextIndex(text: lines.joined(separator: "\n"))
            try? JSONEncoder().encode(index).write(to: bundle.ocrURL)
            await MainActor.run { LibraryStore.shared.setScreenText(index.text, for: bundle.url) }
        }
    }
}
