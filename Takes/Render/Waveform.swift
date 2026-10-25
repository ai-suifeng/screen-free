import AVFoundation

/// Peak levels of one take's audio tracks, binned at a fixed rate on the take's own timeline.
struct Waveform {
    static let binsPerSecond = 100.0

    /// Peak |sample| per bin, 0…1.
    var mic: [Float] = []
    var system: [Float] = []
    /// RMS per bin, 0…1. Loudness is drawn from these; the mic's also drives the noise gate, like the tap.
    var micRMS: [Float] = []
    var systemRMS: [Float] = []

    /// Reads every audio sample of the take. Bins are placed by each buffer's presentation time,
    /// so the waveform lines up with the video even when audio starts slightly after it.
    static func load(asset: AVURLAsset, hasSystem: Bool, hasMic: Bool) async -> Waveform {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return Waveform() }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let binCount = Int(ceil(duration * binsPerSecond)) + 1
        var result = Waveform()
        // The writer adds system audio first, then the mic.
        var index = 0
        if hasSystem, index < tracks.count {
            (result.system, result.systemRMS) = levels(of: tracks[index], asset: asset, bins: binCount)
            index += 1
        }
        if hasMic, index < tracks.count {
            (result.mic, result.micRMS) = levels(of: tracks[index], asset: asset, bins: binCount)
        }
        return result
    }

    private static func levels(of track: AVAssetTrack, asset: AVAsset, bins: Int) -> (peaks: [Float], rms: [Float]) {
        var peaks = [Float](repeating: 0, count: bins)
        var energy = [Float](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)
        func result() -> ([Float], [Float]) {
            (peaks, zip(energy, counts).map { $1 > 0 ? sqrt($0 / Float($1)) : 0 })
        }
        guard let reader = try? AVAssetReader(asset: asset) else { return result() }
        let sampleRate = 16_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return result() }
        reader.add(output)
        guard reader.startReading() else { return result() }

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let start = buffer.presentationTimeStamp.seconds
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            for (i, x) in samples.enumerated() {
                let bin = Int((start + Double(i) / sampleRate) * binsPerSecond)
                guard bin >= 0, bin < bins else { continue }
                let a = abs(x)
                if a > peaks[bin] { peaks[bin] = a }
                energy[bin] += x * x
                counts[bin] += 1
            }
        }
        return result()
    }

    /// Loudest RMS level in a time range of the take (seconds), after the same gain and noise gate
    /// the audio goes through, so the drawing matches what is heard. RMS rather than peaks, because
    /// loudness follows it: a faint rustle or click has high peaks but sounds like almost nothing.
    func loudness(from a: Double, to b: Double, micGain: Float, systemGain: Float, micGate: Float = 0) -> Float {
        let lo = max(0, Int(a * Self.binsPerSecond)), hi = Int(ceil(b * Self.binsPerSecond))
        var m: Float = 0
        for i in lo..<max(lo, hi) {
            let mic = i < micRMS.count ? micRMS[i] * micGain * (isGated(i, micGate) ? AudioLeveling.gateFloor : 1) : 0
            let system = i < systemRMS.count ? systemRMS[i] * systemGain : 0
            m = max(m, (mic * mic + system * system).squareRoot())
        }
        return min(m, 1)
    }

    /// Mirrors the tap's gate: closed unless the RMS rose above the threshold within the release time.
    private func isGated(_ bin: Int, _ gate: Float) -> Bool {
        guard gate > 0, bin < micRMS.count else { return false }
        let hold = Int(AudioLeveling.gateHold * Self.binsPerSecond)
        for i in max(0, bin - hold)...bin where micRMS[i] > gate { return false }
        return true
    }
}
