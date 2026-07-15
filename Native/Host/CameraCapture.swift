import AVFoundation
import CoreMedia
import OSLog

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum CaptureError: LocalizedError {
        case noPhysicalCamera
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noPhysicalCamera: "No physical or Continuity Camera is available."
            case .cannotAddInput: "The selected camera could not be attached to the capture session."
            case .cannotAddOutput: "The video output could not be attached to the capture session."
            }
        }
    }

    private let logger = Logger(subsystem: "com.yigit.asciicamera", category: "capture")
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.yigit.asciicamera.capture", qos: .userInteractive)
    private let renderer = AsciiRenderer(settings: RenderSettings(columns: 240))
    private let frameStore: SharedFrameStore
    private var lastRenderedTime = CMTime.invalid

    init(frameStore: SharedFrameStore) {
        self.frameStore = frameStore
        super.init()
    }

    func start() throws {
        guard !session.isRunning else { return }
        guard let camera = physicalCamera() else { throw CaptureError.noPhysicalCamera }
        let input = try AVCaptureDeviceInput(device: camera)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
        session.addOutput(output)

        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            // Mirroring is performed in the renderer so its sampling orientation
            // exactly matches the browser implementation.
            connection.isVideoMirrored = false
        }
        session.startRunning()
        logger.notice("Capturing from \(camera.localizedName, privacy: .public)")
    }

    func stop() {
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastRenderedTime.isValid, CMTimeGetSeconds(timestamp - lastRenderedTime) < 1.0 / 30.0 { return }
        lastRenderedTime = timestamp
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer), let rendered = renderer.render(source) else { return }
        do {
            try frameStore.publish(rendered)
        } catch {
            logger.error("Could not publish frame: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func physicalCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first { device in
            device.localizedName != "ASCII Camera" && !device.uniqueID.contains(AsciiCameraConstants.extensionBundleIdentifier)
        }
    }
}
