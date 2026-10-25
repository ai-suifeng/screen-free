import AVFoundation

/// Runs the webcam and hands frames to a sink on its own queue.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "takes.camera")
    private(set) var dimensions: (width: Int, height: Int) = (1280, 720)

    /// Called on the camera queue.
    var onFrame: ((CMSampleBuffer) -> Void)?

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    func start(deviceID: String?) throws {
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video) else {
            throw CocoaError(.featureUnsupported)
        }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        dimensions = (Int(dims.width) / 2 * 2, Int(dims.height) / 2 * 2)
        queue.async { self.session.startRunning() }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
