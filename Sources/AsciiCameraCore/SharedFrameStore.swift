import CoreVideo
import Darwin
import Foundation

public enum SharedFrameStoreError: LocalizedError {
    case appGroupUnavailable
    case openFailed(Int32)
    case resizeFailed(Int32)
    case mapFailed(Int32)
    case unsupportedPixelFormat

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable: "The ASCII Camera App Group container is unavailable. Check code signing and App Group entitlements."
        case .openFailed(let code): "Could not open the shared frame store (errno \(code))."
        case .resizeFailed(let code): "Could not resize the shared frame store (errno \(code))."
        case .mapFailed(let code): "Could not map the shared frame store (errno \(code))."
        case .unsupportedPixelFormat: "Only 32BGRA pixel buffers can be shared."
        }
    }
}

/// A fixed-size, double-buffered mmap shared by the host app and camera extension.
/// `flock` makes publication atomic across processes; the extension never sees a
/// half-written frame and the host never waits for a camera client to consume it.
public final class SharedFrameStore: @unchecked Sendable {
    private struct Header {
        var magic: UInt64 = 0x4153_4349_4943_414D // "ASCIICAM"
        var version: UInt32 = 1
        var width: UInt32
        var height: UInt32
        var bytesPerRow: UInt32
        var activeSlot: UInt32 = 0
        var sequence: UInt64 = 0
        var hostTime: UInt64 = 0
    }

    private static let headerSize = 4096
    private let fileDescriptor: Int32
    private let mapping: UnsafeMutableRawPointer
    private let mappedSize: Int
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    private let frameSize: Int

    public static func appGroupURL() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AsciiCameraConstants.appGroup) else {
            throw SharedFrameStoreError.appGroupUnavailable
        }
        return container.appendingPathComponent("ascii-camera.frames", isDirectory: false)
    }

    public convenience init(
        appGroup: Void = (),
        width: Int = AsciiCameraConstants.outputWidth,
        height: Int = AsciiCameraConstants.outputHeight
    ) throws {
        try self.init(url: Self.appGroupURL(), width: width, height: height)
    }

    public init(url: URL, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        bytesPerRow = width * 4
        frameSize = bytesPerRow * height
        mappedSize = Self.headerSize + frameSize * 2

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileDescriptor = Darwin.open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { throw SharedFrameStoreError.openFailed(errno) }
        guard ftruncate(fileDescriptor, off_t(mappedSize)) == 0 else {
            let code = errno
            Darwin.close(fileDescriptor)
            throw SharedFrameStoreError.resizeFailed(code)
        }
        guard let address = mmap(nil, mappedSize, PROT_READ | PROT_WRITE, MAP_SHARED, fileDescriptor, 0), address != MAP_FAILED else {
            let code = errno
            Darwin.close(fileDescriptor)
            throw SharedFrameStoreError.mapFailed(code)
        }
        mapping = address

        flock(fileDescriptor, LOCK_EX)
        let header = mapping.assumingMemoryBound(to: Header.self)
        if header.pointee.magic != Header(width: UInt32(width), height: UInt32(height), bytesPerRow: UInt32(bytesPerRow)).magic ||
            header.pointee.version != 1 || header.pointee.width != width || header.pointee.height != height {
            memset(mapping, 0, mappedSize)
            header.pointee = Header(width: UInt32(width), height: UInt32(height), bytesPerRow: UInt32(bytesPerRow))
        }
        flock(fileDescriptor, LOCK_UN)
    }

    deinit {
        munmap(mapping, mappedSize)
        Darwin.close(fileDescriptor)
    }

    @discardableResult
    public func publish(_ pixelBuffer: CVPixelBuffer, hostTime: UInt64 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) throws -> UInt64 {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw SharedFrameStoreError.unsupportedPixelFormat
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }

        flock(fileDescriptor, LOCK_EX)
        defer { flock(fileDescriptor, LOCK_UN) }
        let header = mapping.assumingMemoryBound(to: Header.self)
        let nextSlot = 1 - Int(header.pointee.activeSlot)
        let destination = mapping.advanced(by: Self.headerSize + nextSlot * frameSize)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowsToCopy = min(height, CVPixelBufferGetHeight(pixelBuffer))
        let bytesToCopy = min(bytesPerRow, sourceBytesPerRow)
        for row in 0..<rowsToCopy {
            memcpy(destination.advanced(by: row * bytesPerRow), source.advanced(by: row * sourceBytesPerRow), bytesToCopy)
        }
        header.pointee.hostTime = hostTime
        header.pointee.sequence &+= 1
        header.pointee.activeSlot = UInt32(nextSlot)
        msync(mapping, mappedSize, MS_ASYNC)
        return header.pointee.sequence
    }

    /// Copies the latest complete frame into `destination` and returns its sequence.
    /// A nil result means that the host has not published a frame yet.
    public func copyLatest(into destination: CVPixelBuffer) -> (sequence: UInt64, hostTime: UInt64)? {
        guard CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let target = CVPixelBufferGetBaseAddress(destination) else { return nil }

        flock(fileDescriptor, LOCK_SH)
        defer { flock(fileDescriptor, LOCK_UN) }
        let header = mapping.assumingMemoryBound(to: Header.self).pointee
        guard header.sequence > 0 else { return nil }
        let source = mapping.advanced(by: Self.headerSize + Int(header.activeSlot) * frameSize)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
        let rowsToCopy = min(height, CVPixelBufferGetHeight(destination))
        let bytesToCopy = min(bytesPerRow, destinationBytesPerRow)
        for row in 0..<rowsToCopy {
            memcpy(target.advanced(by: row * destinationBytesPerRow), source.advanced(by: row * bytesPerRow), bytesToCopy)
        }
        return (header.sequence, header.hostTime)
    }
}
