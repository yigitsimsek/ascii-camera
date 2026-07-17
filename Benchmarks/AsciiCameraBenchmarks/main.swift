import AsciiCameraCore
import CoreVideo
import Foundation

let source = makeSource(width: 1280, height: 720)
let columnCounts = [48, 96, 120, 180, 240]
let modes: [RenderMode] = [.ascii, .matrixOld, .matrix]
let iterations = 3

print("ASCII Camera release benchmark (1920x1080 output, \(iterations) measured frames)")
print("mode,columns,rows,median_ms")

for mode in modes {
    for columns in columnCounts {
        let renderer = AsciiRenderer(
            settings: RenderSettings(mode: mode, columns: columns, mirrored: false),
            outputWidth: 1920,
            outputHeight: 1080
        )

        _ = renderer.render(source)
        var measurements: [Double] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = renderer.render(source)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            measurements.append(Double(elapsed) / 1_000_000)
        }
        measurements.sort()
        print("\(mode.rawValue),\(columns),\(renderer.rows),\(String(format: "%.1f", measurements[measurements.count / 2]))")
    }
}

func makeSource(width: Int, height: Int) -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ] as CFDictionary
    precondition(CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        attributes,
        &created
    ) == kCVReturnSuccess)
    let buffer = created!

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let checker = ((x / 32) + (y / 24)) % 2 == 0 ? 48 : 0
            let value = UInt8(min(255, (x * 159 / max(1, width - 1)) + (y * 48 / max(1, height - 1)) + checker))
            let pixel = base.advanced(by: y * stride + x * 4)
            pixel[0] = value
            pixel[1] = UInt8(255 - Int(value) / 3)
            pixel[2] = UInt8((Int(value) * 5) % 256)
            pixel[3] = 255
        }
    }
    return buffer
}
