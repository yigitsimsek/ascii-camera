import CoreMedia
import CoreMediaIO
import CoreVideo
import Darwin
import Foundation
import OSLog

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource {
    let deviceSource = CameraDeviceSource()
    lazy var provider = CMIOExtensionProvider(source: self, clientQueue: nil)

    override init() {
        super.init()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Could not publish ASCII Camera device: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [] }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        CMIOExtensionProviderProperties(dictionary: [:])
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private static let deviceID = UUID(uuidString: "A5C11CA0-40F0-4B32-BC41-52C155CA4E01")!
    let streamSource = CameraStreamSource()
    lazy var device = CMIOExtensionDevice(
        localizedName: "ASCII Camera",
        deviceID: Self.deviceID,
        legacyDeviceID: "com.yigit.asciicamera.device",
        source: self
    )

    override init() {
        super.init()
        do {
            try device.addStream(streamSource.stream)
        } catch {
            fatalError("Could not publish ASCII Camera stream: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        CMIOExtensionDeviceProperties(dictionary: [:])
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

final class CameraStreamSource: NSObject, CMIOExtensionStreamSource {
    private static let streamID = UUID(uuidString: "A5C11CA0-40F0-4B32-BC41-52C155CA4E02")!
    private let logger = Logger(subsystem: "com.yigit.asciicamera.extension", category: "stream")
    private let queue = DispatchQueue(label: "com.yigit.asciicamera.extension.frames", qos: .userInteractive)
    private let frameDuration = CMTime(value: 1, timescale: AsciiCameraConstants.framesPerSecond)
    private let formatDescription: CMFormatDescription
    private let frameStore: SharedFrameStore?
    private var timer: DispatchSourceTimer?
    private var lastSequence: UInt64 = 0
    private var lastFrame: CVPixelBuffer?

    lazy var stream = CMIOExtensionStream(
        localizedName: "ASCII Camera 1280×720",
        streamID: Self.streamID,
        direction: .source,
        clockType: .hostTime,
        source: self
    )

    let formats: [CMIOExtensionStreamFormat]

    override init() {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(AsciiCameraConstants.outputWidth),
            height: Int32(AsciiCameraConstants.outputHeight),
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard let description else { fatalError("Could not create ASCII Camera format") }
        formatDescription = description
        formats = [CMIOExtensionStreamFormat(
            formatDescription: description,
            maxFrameDuration: CMTime(value: 1, timescale: 15),
            minFrameDuration: CMTime(value: 1, timescale: 60),
            validFrameDurations: nil
        )]
        frameStore = try? SharedFrameStore()
        super.init()
        lastFrame = Self.makePixelBuffer(filledWith: 0)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        CMIOExtensionStreamProperties(dictionary: [:])
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(AsciiCameraConstants.framesPerSecond), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sendFrame() }
        self.timer = timer
        timer.resume()
        logger.notice("ASCII Camera stream started")
    }

    func stopStream() throws {
        timer?.cancel()
        timer = nil
        logger.notice("ASCII Camera stream stopped")
    }

    private func sendFrame() {
        guard let destination = Self.makePixelBuffer(filledWith: 0) else { return }
        if let metadata = frameStore?.copyLatest(into: destination) {
            if metadata.sequence != lastSequence {
                lastSequence = metadata.sequence
                lastFrame = destination
            }
        }
        guard let frame = lastFrame else { return }

        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }
        stream.send(
            sampleBuffer,
            discontinuity: lastSequence == 0 ? [.time] : [],
            hostTimeInNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        )
    }

    private static func makePixelBuffer(filledWith value: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            AsciiCameraConstants.outputWidth,
            AsciiCameraConstants.outputHeight,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(value), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
