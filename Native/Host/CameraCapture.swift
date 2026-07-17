@preconcurrency import AVFoundation
import AsciiCameraCore
import AsciiCameraOBSBridge
import CoreMedia
import OSLog

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
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
    private let renderer: AsciiRenderer
    private let modernSink: OBSModernCameraSink
    private var lastRenderedTime = CMTime.invalid
    private var transportFrames: [CVPixelBuffer] = []
    private var transportFrameIndex = 0

    init(modernSink: OBSModernCameraSink) {
        self.modernSink = modernSink
        renderer = AsciiRenderer(
            settings: RenderSettings(mode: Self.storedMode(), columns: Self.storedColumns(), mirrored: false),
            outputWidth: 1920,
            outputHeight: 1080
        )
        super.init()
    }

    func start() throws {
        guard !session.isRunning else { return }
        guard let camera = physicalCamera() else { throw CaptureError.noPhysicalCamera }
        let input = try AVCaptureDeviceInput(device: camera)

        session.beginConfiguration()
        do {
            session.sessionPreset = .hd1280x720
            guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
            session.addInput(input)

            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
            session.addOutput(output)

            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                // Camera clients such as Meet, Slack, Zoom, and Photo Booth mirror
                // their local self-view. Publish camera-native orientation so the
                // client applies exactly one mirror instead of undoing ours.
                connection.isVideoMirrored = false
            }
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            throw error
        }

        queue.async { [weak self] in self?.session.startRunning() }
        logger.notice("Capturing from \(camera.localizedName, privacy: .public)")
        logger.notice("Renderer configured for \(self.renderer.settings.mode.rawValue, privacy: .public) mode at \(self.renderer.settings.columns) columns in camera-native orientation")
        if #available(macOS 15.0, *) {
            logger.notice("Background Replacement for ASCII Camera: \(AVCaptureDevice.isBackgroundReplacementEnabled ? "enabled" : "disabled", privacy: .public)")
        }
    }

    func stop() {
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
    }

    func setColumns(_ columns: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            var settings = self.renderer.settings
            settings.columns = max(48, min(240, columns))
            settings.mirrored = false
            guard settings != self.renderer.settings else { return }
            self.renderer.settings = settings
            self.logger.notice("Live renderer update: \(settings.columns) columns")
        }
    }

    func setMode(_ mode: RenderMode) {
        queue.async { [weak self] in
            guard let self else { return }
            var settings = self.renderer.settings
            settings.mode = mode
            settings.mirrored = false
            guard settings != self.renderer.settings else { return }
            self.renderer.settings = settings
            self.logger.notice("Live renderer mode: \(mode.rawValue, privacy: .public)")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lastRenderedTime.isValid, CMTimeGetSeconds(timestamp - lastRenderedTime) < 1.0 / 30.0 { return }
        lastRenderedTime = timestamp

        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer),
              let rendered = renderer.render(source),
              let sharedFrame = copyToTransportSurface(rendered) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        modernSink.send(sharedFrame, timestamp: now)
    }

    private func copyToTransportSurface(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        if transportFrames.isEmpty {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: CVPixelBufferGetWidth(source),
                kCVPixelBufferHeightKey: CVPixelBufferGetHeight(source),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            for _ in 0..<3 {
                var frame: CVPixelBuffer?
                guard CVPixelBufferCreate(
                    kCFAllocatorDefault,
                    CVPixelBufferGetWidth(source),
                    CVPixelBufferGetHeight(source),
                    kCVPixelFormatType_32BGRA,
                    attributes as CFDictionary,
                    &frame
                ) == kCVReturnSuccess, let frame else {
                    logger.error("Could not allocate an IOSurface transport frame")
                    transportFrames.removeAll()
                    return nil
                }
                transportFrames.append(frame)
            }
        }

        let destination = transportFrames[transportFrameIndex]
        transportFrameIndex = (transportFrameIndex + 1) % transportFrames.count
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceBase = CVPixelBufferGetBaseAddress(source),
              let destinationBase = CVPixelBufferGetBaseAddress(destination) else { return nil }

        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        let copiedBytes = min(sourceStride, destinationStride)
        for row in 0..<CVPixelBufferGetHeight(source) {
            memcpy(destinationBase.advanced(by: row * destinationStride),
                   sourceBase.advanced(by: row * sourceStride),
                   copiedBytes)
        }
        return destination
    }

    private func physicalCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first { device in
            device.localizedName != "ASCII Camera" && device.localizedName != "OBS Virtual Camera"
        }
    }

    static func storedColumns() -> Int {
        let value = (UserDefaults.standard.object(forKey: "columns") as? NSNumber)?.intValue ?? 240
        return max(48, min(240, value))
    }

    static func storedMode() -> RenderMode {
        let value = UserDefaults.standard.string(forKey: "mode") ?? RenderMode.ascii.rawValue
        return RenderMode(rawValue: value) ?? .ascii
    }
}
