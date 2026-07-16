import AsciiCameraCore
import CoreVideo
import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): message }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.failed(message) }
}

func runTests() throws {
    try expect(RenderSettings().columns == 240, "default columns should be 240")
    try expect(RenderSettings().shapeContrast == 2.2, "shape contrast default changed")
    try expect(RenderSettings().mirrored, "preview should default to mirrored")

    let source = try makeGradient(width: 320, height: 180)
    let renderer = AsciiRenderer(settings: RenderSettings(columns: 48))
    guard let result = renderer.render(source) else { throw TestFailure.failed("renderer returned nil") }
    try expect(CVPixelBufferGetWidth(result) == 1280, "output width should be 1280")
    try expect(CVPixelBufferGetHeight(result) == 720, "output height should be 720")
    try expect(renderer.rows == 16, "48 columns at 16:9 should produce 16 rows")
    try expect(bufferContainsBothBlackAndWhite(result), "rendered gradient should contain glyph and background pixels")

    renderer.settings = RenderSettings()
    let defaultRenderStart = DispatchTime.now().uptimeNanoseconds
    guard let defaultResult = renderer.render(source) else { throw TestFailure.failed("240-column renderer returned nil") }
    let defaultRenderMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - defaultRenderStart) / 1_000_000
    try expect(renderer.rows == 78, "240 columns at 16:9 should produce 78 rows")
    try expect(bufferContainsBothBlackAndWhite(defaultResult), "240-column output should contain glyph and background pixels")
    print(String(format: "240-column render: %.1f ms", defaultRenderMilliseconds))

    let obsRenderer = AsciiRenderer(settings: RenderSettings(columns: 48), outputWidth: 1920, outputHeight: 1080)
    guard let obsResult = obsRenderer.render(source) else { throw TestFailure.failed("OBS-sized renderer returned nil") }
    try expect(CVPixelBufferGetWidth(obsResult) == 1920, "OBS extension output width should be 1920")
    try expect(CVPixelBufferGetHeight(obsResult) == 1080, "OBS extension output height should be 1080")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = directory.appendingPathComponent("frames")
    let writer = try SharedFrameStore(url: url, width: 8, height: 4)
    let reader = try SharedFrameStore(url: url, width: 8, height: 4)
    let frame = try makeSolid(width: 8, height: 4, blue: 12, green: 34, red: 56)
    let destination = try makeSolid(width: 8, height: 4, blue: 0, green: 0, red: 0)
    let firstSequence = try writer.publish(frame, hostTime: 1234)
    try expect(firstSequence == 1, "first frame sequence should be 1")
    guard let metadata = reader.copyLatest(into: destination) else { throw TestFailure.failed("reader found no published frame") }
    try expect(metadata.sequence == 1 && metadata.hostTime == 1234, "shared metadata was corrupted")

    CVPixelBufferLockBaseAddress(destination, .readOnly)
    let bytes = CVPixelBufferGetBaseAddress(destination)!.assumingMemoryBound(to: UInt8.self)
    let copied = bytes[0] == 12 && bytes[1] == 34 && bytes[2] == 56
    CVPixelBufferUnlockBaseAddress(destination, .readOnly)
    try expect(copied, "shared BGRA frame bytes were corrupted")
}

func makeGradient(width: Int, height: Int) throws -> CVPixelBuffer {
    let buffer = try makePixelBuffer(width: width, height: height)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let value = UInt8((x * 255) / max(1, width - 1))
            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
            pixel[0] = value; pixel[1] = value; pixel[2] = value; pixel[3] = 255
        }
    }
    return buffer
}

func makeSolid(width: Int, height: Int, blue: UInt8, green: UInt8, red: UInt8) throws -> CVPixelBuffer {
    let buffer = try makePixelBuffer(width: width, height: height)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
            pixel[0] = blue; pixel[1] = green; pixel[2] = red; pixel[3] = 255
        }
    }
    return buffer
}

func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ] as CFDictionary
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw TestFailure.failed("CVPixelBufferCreate failed: \(status)") }
    return buffer
}

func bufferContainsBothBlackAndWhite(_ buffer: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
    let size = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var foundDark = false
    var foundLight = false
    for index in stride(from: 0, to: size, by: 4) {
        foundDark = foundDark || bytes[index] < 10
        foundLight = foundLight || bytes[index] > 200
        if foundDark && foundLight { return true }
    }
    return false
}

do {
    try runTests()
    print("ASCII Camera core tests passed")
} catch {
    FileHandle.standardError.write(Data("ASCII Camera core tests failed: \(error)\n".utf8))
    exit(1)
}
