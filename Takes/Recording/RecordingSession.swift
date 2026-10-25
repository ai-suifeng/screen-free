import AVFoundation
import AppKit
import CoreImage
import Observation
import ScreenCaptureKit

/// Drives one recording: a single ScreenCaptureKit stream that is split into takes on pause.
///
/// Threading: observable state lives on the main thread; writers and pixel buffers live on `queue`,
/// which is also the stream's sample handler queue.
@Observable
final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Phase: Equatable { case idle, preparing, countdown, recording, paused, finishing }

    private(set) var phase: Phase = .idle
    private(set) var countdownValue = 0
    private(set) var completedDuration: Double = 0
    private(set) var takeCount = 0
    /// Uptime at which the current take started; nil unless recording.
    private(set) var takeStartUptime: TimeInterval?
    private(set) var target: CaptureTarget?
    private(set) var captureRect: CGRect = .zero
    private(set) var bundle: ProjectBundle?
    /// Shown translucently over the capture area before a take starts, to help line things up again.
    private(set) var ghostImage: CGImage?
    private(set) var currentSegment = 0
    var lastError: String?

    var onFinished: ((ProjectBundle) -> Void)?
    /// Overrides for automated runs, so they don't touch the user's settings.
    @ObservationIgnored var folderOverride: URL?
    @ObservationIgnored var countdownOverride: Int?
    /// Called for clicks made while recording, so annotation features can react.
    var onClick: ((InputRecorder.Click) -> Void)?

    var isActive: Bool { phase != .idle }

    var elapsed: Double {
        guard let start = takeStartUptime else { return completedDuration }
        return completedDuration + max(0, ProcessInfo.processInfo.systemUptime - start)
    }

    @ObservationIgnored private let settings = AppSettings.shared
    @ObservationIgnored private var meta: ProjectMeta?
    @ObservationIgnored private var nextSegment = 0
    @ObservationIgnored private var events: [InputEvent] = []
    @ObservationIgnored private var pendingEventLines = ""
    @ObservationIgnored private var liveAnnotations: [LiveAnnotation] = []
    @ObservationIgnored private var takeStartGhosts: [Int: CGImage] = [:]
    @ObservationIgnored private let input = InputRecorder()
    @ObservationIgnored private var camera: CameraCapture?
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFinishes: [Task<Void, Never>] = []

    // Capture queue state.
    @ObservationIgnored private let queue = DispatchQueue(label: "takes.capture", qos: .userInteractive)
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var writer: SegmentWriter?
    @ObservationIgnored private var cameraWriter: CameraWriter?
    @ObservationIgnored private var lastPixelBuffer: CVPixelBuffer?
    @ObservationIgnored private var pendingTake: (index: Int, url: URL, cameraURL: URL?)?
    @ObservationIgnored private let ciContext = CIContext()

    // MARK: - Lifecycle

    @MainActor
    func start(_ target: CaptureTarget) async {
        guard phase == .idle else { return }
        phase = .preparing
        lastError = nil
        do {
            try await prepare(target)
            runCountdown(ghost: nil)
        } catch {
            lastError = "无法开始录制：\(error.localizedDescription)"
            await teardown(discard: true)
        }
    }

    @MainActor
    private func prepare(_ target: CaptureTarget) async throws {
        self.target = target
        captureRect = target.globalRect
        let (width, height) = target.pixelSize

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let name = "\(formatter.string(from: Date())) \(target.title)"
        let bundle = try ProjectBundle.create(in: folderOverride ?? settings.libraryFolder, name: name)
        self.bundle = bundle
        FileManager.default.createFile(atPath: bundle.eventsURL.path, contents: nil)

        let wantsMic = settings.recordMic && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let wantsCamera = settings.recordCamera && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        meta = ProjectMeta(name: name, kind: target.kind, sourceTitle: target.title, width: width, height: height,
                           scale: target.scale, hasMic: wantsMic, hasSystemAudio: settings.recordSystemAudio,
                           hasCamera: wantsCamera)
        saveMeta()

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 8
        config.capturesAudio = settings.recordSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = wantsMic
        if wantsMic, let mic = settings.micDeviceID { config.microphoneCaptureDeviceID = mic }

        let filter: SCContentFilter
        switch target {
        case .window(let w):
            filter = SCContentFilter(desktopIndependentWindow: w)
        case .display(let d), .area(let d, _):
            let content = try await ShareableContent.fetch()
            var hidden = Set(settings.excludedApps.map(\.bundleID))
            hidden.insert(Bundle.main.bundleIdentifier ?? "")
            if settings.hideNotifications { hidden.insert("com.apple.notificationcenterui") }
            let apps = content.applications.filter { hidden.contains($0.bundleIdentifier) }
            filter = SCContentFilter(display: d, excludingApplications: apps, exceptingWindows: [])
            if case .area(_, let r) = target { config.sourceRect = r }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.recordSystemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if wantsMic { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        queue.sync { self.stream = stream }

        if wantsCamera {
            let camera = CameraCapture()
            camera.onFrame = { [weak self] buffer in
                self?.queue.async { self?.cameraWriter?.append(buffer) }
            }
            do {
                try camera.start(deviceID: settings.cameraDeviceID)
                self.camera = camera
            } catch {
                meta?.hasCamera = false
            }
        }

        startInput()
        if case .window(let w) = target { trackWindow(w.windowID) }
        let flush = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.flushEvents() }
        RunLoop.main.add(flush, forMode: .common)
        timers.append(flush)
    }

    func pause() {
        guard phase == .recording else { return }
        finishCurrentTake()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        runCountdown(ghost: settings.showGhostOnResume ? ghostImage : nil)
    }

    func togglePause() {
        if phase == .recording { pause() } else if phase == .paused { resume() }
    }

    /// Throws away the take in progress (or the last finished take when paused).
    func redoTake() {
        switch phase {
        case .recording:
            let index = currentSegment
            takeStartUptime = nil
            queue.sync {
                writer?.cancel(); writer = nil
                cameraWriter?.cancel(); cameraWriter = nil
                pendingTake = nil
            }
            dropData(forSegment: index)
            nextSegment = index
            ghostImage = takeStartGhosts[index] ?? ghostImage
            runCountdown(ghost: settings.showGhostOnResume ? ghostImage : nil)
        case .paused:
            Task { @MainActor in
                await self.waitForPendingFinishes()
                guard var meta = self.meta, let last = meta.segments.popLast(), let bundle = self.bundle else { return }
                try? FileManager.default.removeItem(at: bundle.segmentURL(last.file))
                if let cam = last.cameraFile { try? FileManager.default.removeItem(at: bundle.segmentURL(cam)) }
                self.meta = meta
                self.completedDuration = meta.duration
                self.takeCount = meta.segments.count
                self.dropData(forSegment: last.index)
                self.nextSegment = last.index
                self.ghostImage = self.takeStartGhosts[last.index] ?? self.ghostImage
                self.saveMeta()
            }
        case .countdown:
            break
        default:
            break
        }
    }

    func stop() {
        guard phase == .recording || phase == .paused || phase == .countdown else { return }
        countdownTask?.cancel()
        if phase == .recording { finishCurrentTake() }
        phase = .finishing
        Task { @MainActor in
            await self.teardown(discard: false)
        }
    }

    func discard() {
        guard isActive else { return }
        countdownTask?.cancel()
        if phase == .recording { finishCurrentTake() }
        phase = .finishing
        Task { @MainActor in await self.teardown(discard: true) }
    }

    @MainActor
    private func teardown(discard: Bool) async {
        await waitForPendingFinishes()
        let stream = queue.sync { () -> SCStream? in
            let s = self.stream
            self.stream = nil
            self.lastPixelBuffer = nil
            return s
        }
        try? await stream?.stopCapture()
        camera?.stop()
        camera = nil
        input.stop()
        timers.forEach { $0.invalidate() }
        timers = []
        flushEvents()

        if let bundle {
            if discard || (meta?.segments.isEmpty ?? true) {
                try? FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
            } else {
                meta?.status = .ready
                saveMeta()
                await Thumbnailer.generate(for: bundle)
                onFinished?(bundle)
            }
        }
        reset()
    }

    private func reset() {
        phase = .idle
        bundle = nil
        meta = nil
        target = nil
        ghostImage = nil
        takeStartGhosts = [:]
        events = []
        liveAnnotations = []
        completedDuration = 0
        takeCount = 0
        nextSegment = 0
        takeStartUptime = nil
    }

    // MARK: - Takes

    private func runCountdown(ghost: CGImage?) {
        ghostImage = ghost
        countdownTask?.cancel()
        let seconds = countdownOverride ?? settings.countdown
        guard seconds > 0 else {
            beginTake()
            return
        }
        phase = .countdown
        countdownTask = Task { @MainActor in
            for n in stride(from: seconds, through: 1, by: -1) {
                self.countdownValue = n
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self.countdownValue = 0
            self.beginTake()
        }
    }

    private func beginTake() {
        guard let bundle else { return }
        let index = nextSegment
        nextSegment += 1
        currentSegment = index
        let file = String(format: "take-%03d.mov", index + 1)
        let cameraFile = camera != nil ? String(format: "camera-%03d.mov", index + 1) : nil
        queue.async {
            self.pendingTake = (index, bundle.segmentURL(file), cameraFile.map(bundle.segmentURL))
            // Start right away from the last frame, so a static screen does not delay the take.
            if let pb = self.lastPixelBuffer {
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if let sb = Self.makeSampleBuffer(pb, pts: now) { self.startPendingTake(with: sb) }
            }
        }
        phase = .recording
    }

    /// Runs on `queue`.
    private func startPendingTake(with first: CMSampleBuffer) {
        guard let take = pendingTake, let meta else { return }
        pendingTake = nil
        let start = first.presentationTimeStamp
        do {
            let w = try SegmentWriter(url: take.url, width: meta.width, height: meta.height, fps: settings.fps,
                                      systemAudio: meta.hasSystemAudio, mic: meta.hasMic, startTime: start)
            w.appendVideo(first)
            writer = w
            if let camURL = take.cameraURL, let camera {
                cameraWriter = try? CameraWriter(url: camURL, width: camera.dimensions.width,
                                                 height: camera.dimensions.height, startTime: start)
            }
        } catch {
            DispatchQueue.main.async { self.lastError = "写入失败：\(error.localizedDescription)" }
            return
        }
        let ghost = first.imageBuffer.flatMap(makeImage)
        DispatchQueue.main.async {
            self.takeStartUptime = start.seconds
            if let ghost { self.takeStartGhosts[take.index] = ghost }
        }
    }

    private func finishCurrentTake() {
        let index = currentSegment
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        let (w, cw, ghost) = queue.sync { () -> (SegmentWriter?, CameraWriter?, CGImage?) in
            let result = (writer, cameraWriter, lastPixelBuffer.flatMap(makeImage))
            writer = nil
            cameraWriter = nil
            pendingTake = nil
            return result
        }
        takeStartUptime = nil
        if let ghost { ghostImage = ghost }
        guard let w else { return }
        let task = Task { @MainActor in
            let duration = await w.finish(at: end)
            await cw?.finish(at: end)
            guard duration > 0.05 else {
                w.cancel()
                return
            }
            let info = SegmentInfo(index: index, file: w.url.lastPathComponent,
                                   cameraFile: cw?.url.lastPathComponent, duration: duration)
            self.meta?.segments.append(info)
            self.meta?.segments.sort { $0.index < $1.index }
            self.completedDuration = self.meta?.duration ?? 0
            self.takeCount = self.meta?.segments.count ?? 0
            self.saveMeta()
        }
        pendingFinishes.append(task)
        // Keep the elapsed clock steady until the real duration is known.
        completedDuration += max(0, end.seconds - (w.startTime.seconds))
    }

    @MainActor
    private func waitForPendingFinishes() async {
        let tasks = pendingFinishes
        pendingFinishes = []
        for t in tasks { await t.value }
    }

    // MARK: - SCStream

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let pb = sampleBuffer.imageBuffer else { return }
            lastPixelBuffer = pb
            if pendingTake != nil {
                startPendingTake(with: sampleBuffer)
            } else {
                writer?.appendVideo(sampleBuffer)
            }
        case .audio:
            writer?.appendSystemAudio(sampleBuffer)
        case .microphone:
            writer?.appendMic(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.lastError = "录制中断：\(error.localizedDescription)"
            self.stop()
        }
    }

    private static func makeSampleBuffer(_ pb: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }

    private func makeImage(_ pb: CVPixelBuffer) -> CGImage? {
        ciContext.createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0,
            width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)))
    }

    // MARK: - Input events

    private func startInput() {
        input.recordAllKeys = settings.recordAllKeys
        input.onMove = { [weak self] time, p in self?.record(.move, time: time, at: p) }
        input.onMouseUp = { [weak self] time, p in self?.record(.up, time: time, at: p) }
        input.onClick = { [weak self] click in
            guard let self else { return }
            self.record(click.right ? .rightDown : .down, time: click.time, at: click.location)
            if self.phase == .recording { self.onClick?(click) }
        }
        input.onKey = { [weak self] time, key in
            guard let self else { return }
            self.record(.key, time: time, at: NSEvent.mouseLocation.cocoaToCG, key: key)
        }
        input.onFrontApp = { [weak self] name in
            guard let self, self.meta?.apps.contains(name) == false else { return }
            self.meta?.apps.append(name)
        }
        input.start()
    }

    /// Converts a CG global point into normalized capture coordinates.
    func normalize(_ p: CGPoint) -> NormPoint {
        let r = captureRect
        guard r.width > 0, r.height > 0 else { return NormPoint(x: 0, y: 0) }
        return NormPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
    }

    func normalize(_ rect: CGRect) -> NormRect {
        let a = normalize(rect.origin)
        return NormRect(x: a.x, y: a.y, w: rect.width / captureRect.width, h: rect.height / captureRect.height)
    }

    /// Seconds into the current take for an uptime timestamp, if recording.
    func takeTime(for uptime: TimeInterval) -> Double? {
        guard phase == .recording, let start = takeStartUptime else { return nil }
        return max(0, uptime - start)
    }

    private func record(_ kind: InputEvent.Kind, time: TimeInterval, at p: CGPoint, key: String? = nil) {
        guard let t = takeTime(for: time) else { return }
        let n = normalize(p)
        let event = InputEvent(seg: currentSegment, t: (t * 1000).rounded() / 1000, kind: kind,
                               x: (n.x * 10000).rounded() / 10000, y: (n.y * 10000).rounded() / 10000, key: key)
        events.append(event)
        if let data = try? JSONEncoder().encode(event), let line = String(data: data, encoding: .utf8) {
            pendingEventLines += line + "\n"
        }
    }

    private func flushEvents() {
        guard !pendingEventLines.isEmpty, let bundle,
              let handle = try? FileHandle(forWritingTo: bundle.eventsURL) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(pendingEventLines.utf8))
        try? handle.close()
        pendingEventLines = ""
    }

    func addLiveAnnotation(_ annotation: Annotation, uptime: TimeInterval) {
        guard let t = takeTime(for: uptime), let bundle else { return }
        liveAnnotations.append(LiveAnnotation(seg: currentSegment, t: t, annotation: annotation))
        try? JSONEncoder.takes.encode(liveAnnotations).write(to: bundle.liveAnnotationsURL, options: .atomic)
    }

    /// Number of step-badged highlights so far, for numbering the next one.
    var stepCount: Int { liveAnnotations.filter { $0.annotation.step != nil }.count }

    private func dropData(forSegment index: Int) {
        events.removeAll { $0.seg == index }
        liveAnnotations.removeAll { $0.seg == index }
        pendingEventLines = ""
        guard let bundle else { return }
        let encoder = JSONEncoder()
        let text = events.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")
        try? (text.isEmpty ? "" : text + "\n").write(to: bundle.eventsURL, atomically: true, encoding: .utf8)
        try? JSONEncoder.takes.encode(liveAnnotations).write(to: bundle.liveAnnotationsURL, options: .atomic)
    }

    private func trackWindow(_ id: CGWindowID) {
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self,
                  let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
                  let dict = list.first?[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { return }
            if rect != self.captureRect { self.captureRect = rect }
        }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func saveMeta() {
        guard let meta, let bundle else { return }
        try? bundle.writeMeta(meta)
    }
}
