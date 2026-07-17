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
    try expect(RenderSettings().mode == .ascii, "ASCII should remain the default render mode")
    try expect(RenderMode(rawValue: "matrix-old") == .matrixOld, "legacy Matrix mode should remain addressable by its CLI value")
    try expect(RenderSettings().columns == 240, "default columns should be 240")
    try expect(RenderSettings().shapeContrast == 2.2, "shape contrast default changed")
    try expect(RenderSettings().mirrored, "preview should default to mirrored")

    let source = try makeGradient(width: 320, height: 180)
    let defaultAsciiRenderer = AsciiRenderer(settings: RenderSettings(columns: 48))
    let explicitAsciiRenderer = AsciiRenderer(settings: RenderSettings(mode: .ascii, columns: 48))
    guard let defaultAscii = defaultAsciiRenderer.render(source, at: 12.5),
          let explicitAscii = explicitAsciiRenderer.render(source, at: 99.0) else {
        throw TestFailure.failed("ASCII regression render returned nil")
    }
    try expect(buffersEqual(defaultAscii, explicitAscii), "explicit ASCII mode must preserve the default renderer pixel-for-pixel")

    let renderer = AsciiRenderer(settings: RenderSettings(columns: 48))
    guard let result = renderer.render(source) else { throw TestFailure.failed("renderer returned nil") }
    try expect(CVPixelBufferGetWidth(result) == 1280, "output width should be 1280")
    try expect(CVPixelBufferGetHeight(result) == 720, "output height should be 720")
    try expect(renderer.rows == 16, "48 columns at 16:9 should produce 16 rows")
    try expect(bufferContainsBothBlackAndWhite(result), "rendered gradient should contain glyph and background pixels")

    let matrixRenderer = AsciiRenderer(settings: RenderSettings(mode: .matrix, columns: 48))
    guard let matrixAtStart = matrixRenderer.render(source, at: 0) else {
        throw TestFailure.failed("Matrix renderer returned nil")
    }
    let firstMatrixSignature = bufferSignature(matrixAtStart)
    try expect(bufferContainsMatrixGreen(matrixAtStart), "Matrix mode should tint the existing ASCII glyphs green")
    try expect(matrixPreservesAsciiMask(ascii: explicitAscii, matrix: matrixAtStart), "Matrix mode must not create or replace ASCII glyph shapes")

    let matrixOldRenderer = AsciiRenderer(settings: RenderSettings(mode: .matrixOld, columns: 48))
    guard let matrixOld = matrixOldRenderer.render(source, at: 0) else {
        throw TestFailure.failed("legacy Matrix renderer returned nil")
    }
    try expect(bufferContainsMatrixGreen(matrixOld), "legacy Matrix mode should retain its green treatment")
    try expect(matrixPreservesAsciiMask(ascii: explicitAscii, matrix: matrixOld), "legacy Matrix mode must preserve ASCII glyph shapes")
    try expect(bufferSignature(matrixOld) != firstMatrixSignature, "portrait and legacy Matrix modes should remain visually distinct")

    guard let matrixLater = matrixRenderer.render(source, at: 1.0) else {
        throw TestFailure.failed("animated Matrix renderer returned nil")
    }
    try expect(bufferSignature(matrixLater) != firstMatrixSignature, "Matrix trails should move over time")

    matrixRenderer.settings.mode = .ascii
    guard let asciiAfterMatrix = matrixRenderer.render(source, at: 1.0) else {
        throw TestFailure.failed("ASCII render after live mode switch returned nil")
    }
    try expect(buffersEqual(explicitAscii, asciiAfterMatrix), "switching through Matrix mode must not alter subsequent ASCII output")

    renderer.settings = RenderSettings()
    let defaultRenderStart = DispatchTime.now().uptimeNanoseconds
    guard let defaultResult = renderer.render(source) else { throw TestFailure.failed("240-column renderer returned nil") }
    let defaultRenderMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - defaultRenderStart) / 1_000_000
    try expect(renderer.rows == 78, "240 columns at 16:9 should produce 78 rows")
    try expect(bufferContainsBothBlackAndWhite(defaultResult), "240-column output should contain glyph and background pixels")
    print(String(format: "240-column render: %.1f ms", defaultRenderMilliseconds))

    renderer.settings.columns = 96
    guard renderer.render(source) != nil else { throw TestFailure.failed("live column update returned nil") }
    try expect(renderer.rows == 31, "live 96-column update should rebuild a 31-row grid")

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

func buffersEqual(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer) -> Bool {
    guard CVPixelBufferGetWidth(lhs) == CVPixelBufferGetWidth(rhs),
          CVPixelBufferGetHeight(lhs) == CVPixelBufferGetHeight(rhs),
          CVPixelBufferGetBytesPerRow(lhs) == CVPixelBufferGetBytesPerRow(rhs) else { return false }
    CVPixelBufferLockBaseAddress(lhs, .readOnly)
    CVPixelBufferLockBaseAddress(rhs, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(rhs, .readOnly)
        CVPixelBufferUnlockBaseAddress(lhs, .readOnly)
    }
    guard let lhsBase = CVPixelBufferGetBaseAddress(lhs), let rhsBase = CVPixelBufferGetBaseAddress(rhs) else { return false }
    let size = CVPixelBufferGetBytesPerRow(lhs) * CVPixelBufferGetHeight(lhs)
    return memcmp(lhsBase, rhsBase, size) == 0
}

func bufferSignature(_ buffer: CVPixelBuffer) -> UInt64 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
    let size = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var hash: UInt64 = 1_469_598_103_934_665_603
    for index in 0..<size {
        hash = (hash ^ UInt64(bytes[index])) &* 1_099_511_628_211
    }
    return hash
}

func bufferContainsMatrixGreen(_ buffer: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
    let size = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    for index in stride(from: 0, to: size, by: 4) {
        let blue = Int(bytes[index])
        let green = Int(bytes[index + 1])
        let red = Int(bytes[index + 2])
        if green > 20, green > red * 3, green > blue * 2 { return true }
    }
    return false
}

func matrixPreservesAsciiMask(ascii: CVPixelBuffer, matrix: CVPixelBuffer) -> Bool {
    guard CVPixelBufferGetWidth(ascii) == CVPixelBufferGetWidth(matrix),
          CVPixelBufferGetHeight(ascii) == CVPixelBufferGetHeight(matrix),
          CVPixelBufferGetBytesPerRow(ascii) == CVPixelBufferGetBytesPerRow(matrix) else { return false }
    CVPixelBufferLockBaseAddress(ascii, .readOnly)
    CVPixelBufferLockBaseAddress(matrix, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(matrix, .readOnly)
        CVPixelBufferUnlockBaseAddress(ascii, .readOnly)
    }
    guard let asciiBase = CVPixelBufferGetBaseAddress(ascii), let matrixBase = CVPixelBufferGetBaseAddress(matrix) else { return false }
    let size = CVPixelBufferGetBytesPerRow(ascii) * CVPixelBufferGetHeight(ascii)
    let asciiBytes = asciiBase.assumingMemoryBound(to: UInt8.self)
    let matrixBytes = matrixBase.assumingMemoryBound(to: UInt8.self)
    var visibleAsciiPixels = 0
    var retainedMatrixPixels = 0

    for index in stride(from: 0, to: size, by: 4) {
        let asciiMaximum = max(asciiBytes[index], max(asciiBytes[index + 1], asciiBytes[index + 2]))
        let matrixMaximum = max(matrixBytes[index], max(matrixBytes[index + 1], matrixBytes[index + 2]))
        if asciiMaximum == 0, matrixMaximum != 0 { return false }
        if asciiMaximum >= 10 {
            visibleAsciiPixels += 1
            if matrixMaximum > 0 { retainedMatrixPixels += 1 }
        }
    }
    return visibleAsciiPixels > 0 && retainedMatrixPixels == visibleAsciiPixels
}

do {
    try runTests()
    print("ASCII Camera core tests passed")
} catch {
    FileHandle.standardError.write(Data("ASCII Camera core tests failed: \(error)\n".utf8))
    exit(1)
}
