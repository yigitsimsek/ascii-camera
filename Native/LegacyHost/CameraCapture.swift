@preconcurrency import AVFoundation
import AsciiCameraCore
import AsciiCameraLegacyTransport
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
    private let renderer = AsciiRenderer(settings: RenderSettings(columns: 240))
    private let transport: LegacyVirtualCameraServer
    private var lastRenderedTime = CMTime.invalid
    private var transportFrames: [CVPixelBuffer] = []
    private var transportFrameIndex = 0

    init(transport: LegacyVirtualCameraServer) {
        self.transport = transport
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
                connection.isVideoMirrored = false
            }
            session.commitConfiguration()
        } catch {
            session.commitConfiguration()
            throw error
        }

        queue.async { [weak self] in self?.session.startRunning() }
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

        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer),
              let rendered = renderer.render(source),
              let sharedFrame = copyToTransportSurface(rendered) else { return }
        transport.send(
            sharedFrame,
            timestamp: DispatchTime.now().uptimeNanoseconds,
            fpsNumerator: 30,
            fpsDenominator: 1
        )
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
}
