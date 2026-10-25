import AVFoundation
import CoreMedia

/// Writes one take: screen video plus optional system and microphone audio tracks.
/// All methods must be called on the capture queue.
final class SegmentWriter {
    let url: URL
    let startTime: CMTime
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let systemAudio: AVAssetWriterInput?
    private let mic: AVAssetWriterInput?
    private(set) var lastVideoTime: CMTime
    private var lastFrame: CVPixelBuffer?

    init(url: URL, width: Int, height: Int, fps: Int, systemAudio hasSystem: Bool, mic hasMic: Bool, startTime: CMTime) throws {
        self.url = url
        self.startTime = startTime
        lastVideoTime = startTime
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        let bitrate = max(4_000_000, Int(Double(width * height) * Double(fps) * 0.07))
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        func audioInput(channels: Int) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels * 96_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        if hasSystem {
            let input = audioInput(channels: 2)
            writer.add(input)
            systemAudio = input
        } else {
            systemAudio = nil
        }
        if hasMic {
            let input = audioInput(channels: 1)
            writer.add(input)
            mic = input
        } else {
            mic = nil
        }

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: startTime)
    }

    func appendVideo(_ buffer: CMSampleBuffer) {
        let pts = buffer.presentationTimeStamp
        guard pts >= startTime, writer.status == .writing, video.isReadyForMoreMediaData else { return }
        if video.append(buffer) {
            lastVideoTime = pts
            lastFrame = buffer.imageBuffer
        }
    }

    func appendSystemAudio(_ buffer: CMSampleBuffer) { append(buffer, to: systemAudio) }
    func appendMic(_ buffer: CMSampleBuffer) { append(buffer, to: mic) }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, buffer.presentationTimeStamp >= startTime,
              writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    /// Finishes the file. The take ends at `endTime` so a static screen still has its full length.
    func finish(at endTime: CMTime) async -> Double {
        let end = max(endTime, lastVideoTime)
        guard writer.status == .writing else { return 0 }
        // A static screen produces no new frames; repeat the last one so the video track spans the whole take.
        let tail = end - CMTime(value: 1, timescale: 60)
        if let frame = lastFrame, tail > lastVideoTime, video.isReadyForMoreMediaData {
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame, formatDescriptionOut: &format)
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: tail, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            if let format {
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame, formatDescription: format,
                                                         sampleTiming: &timing, sampleBufferOut: &sample)
            }
            if let sample, video.append(sample) { lastVideoTime = tail }
        }
        writer.endSession(atSourceTime: end)
        [video, systemAudio, mic].compactMap { $0 }.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        return (end - startTime).seconds
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Writes the webcam track of one take.
final class CameraWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let startTime: CMTime

    init(url: URL, width: Int, height: Int, startTime: CMTime) throws {
        self.url = url
        self.startTime = startTime
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: startTime)
    }

    func append(_ buffer: CMSampleBuffer) {
        guard buffer.presentationTimeStamp >= startTime, writer.status == .writing,
              input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    func finish(at endTime: CMTime) async {
        guard writer.status == .writing else { return }
        writer.endSession(atSourceTime: endTime)
        input.markAsFinished()
        await writer.finishWriting()
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
