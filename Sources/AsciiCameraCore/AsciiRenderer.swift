import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import VideoToolbox

// The shape-vector renderer design is inspired by Alex Harri's article
// "ASCII characters are not pixels: a deep dive into ASCII rendering":
// https://alexharri.com/blog/ascii-rendering
//
// This is an independent Swift/CoreVideo adaptation for live camera frames.
public final class AsciiRenderer: @unchecked Sendable {
    private struct MatrixStream {
        let length: Double
        let speed: Double
        let phase: Double
        let cycle: Double
    }

    private struct MatrixColor {
        let blue: UInt16
        let green: UInt16
        let red: UInt16
    }

    private struct Tap {
        let x: Int
        let y: Int
        let weight: Float
    }

    private struct Kernel {
        let taps: [Tap]
    }

    private static let tileWidth = 6
    private static let tileHeight = 9
    private static let sampleRadius: Float = 1.65
    private static let cacheRange = 9
    private static let matrixBrightnessBuckets = 12
    private static let matrixOldColors: [MatrixColor] = {
        var colors: [MatrixColor] = []
        for bucket in 0..<matrixBrightnessBuckets {
            let progress = Double(bucket) / Double(matrixBrightnessBuckets - 1)
            let green = 0.55 + 0.40 * progress
            colors.append(MatrixColor(
                blue: UInt16(round(255 * 0.12 * green)),
                green: UInt16(round(255 * green)),
                red: UInt16(round(255 * 0.04 * green))
            ))
        }
        colors.append(MatrixColor(blue: 140, green: 255, red: 100))
        return colors
    }()
    private static let characters = (32...126).compactMap(UnicodeScalar.init).map(Character.init)
    private static let internalCenters: [(Float, Float)] = [
        (1.80, 2.15), (4.20, 1.65),
        (1.80, 4.55), (4.20, 4.05),
        (1.80, 6.95), (4.20, 6.45),
    ]
    private static let externalCenters: [(Float, Float)] = [
        (1.80, -0.55), (4.20, -0.55),
        (-0.85, 2.15), (6.85, 1.65),
        (-0.85, 4.55), (6.85, 4.05),
        (-0.85, 6.95), (6.85, 6.45),
        (1.80, 9.55), (4.20, 9.55),
    ]
    private static let affectingExternalIndices = [
        [0, 1, 2, 4], [0, 1, 3, 5], [2, 4, 6],
        [3, 5, 7], [4, 6, 8, 9], [5, 7, 8, 9],
    ]

    public var settings: RenderSettings {
        didSet {
            settings.columns = max(48, min(240, settings.columns))
            if oldValue.columns != settings.columns { invalidateGrid() }
        }
    }

    public private(set) var rows = 0

    private let outputWidth: Int
    private let outputHeight: Int
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let internalKernels: [Kernel]
    private let externalKernels: [Kernel]
    private let glyphVectors: [SIMD8<Float>]
    private let fontName: CFString = "Menlo" as CFString

    private var sampler: CVPixelBuffer?
    private var output: CVPixelBuffer?
    private var currentColumns = 0
    private var grayBuffer: [Float] = []
    private var internalBuffer: [Float] = []
    private var externalBuffer: [Float] = []
    private var lookupCache = [Int16](repeating: -1, count: 531_441)
    private var matrixStreams: [MatrixStream] = []
    private var matrixLuminanceBuffer: [Float] = []
    private var matrixEdgeBuffer: [Float] = []

    public init(
        settings: RenderSettings = RenderSettings(),
        outputWidth: Int = AsciiCameraConstants.outputWidth,
        outputHeight: Int = AsciiCameraConstants.outputHeight
    ) {
        self.settings = settings
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        internalKernels = Self.internalCenters.map { Self.makeKernel(centerX: $0.0, centerY: $0.1) }
        externalKernels = Self.externalCenters.map { Self.makeKernel(centerX: $0.0, centerY: $0.1) }
        glyphVectors = Self.buildGlyphDatabase(fontName: "Menlo" as CFString)
    }

    public func render(
        _ source: CVPixelBuffer,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> CVPixelBuffer? {
        configureGrid()
        guard let sampler, let output else { return nil }
        drawSource(source, into: sampler)
        buildGrayBuffer(from: sampler)
        collectVectors()
        drawAscii(into: output)
        if settings.mode != .ascii {
            applyMatrixEffect(to: output, at: time)
        }
        return output
    }

    private func invalidateGrid() {
        currentColumns = 0
        rows = 0
        sampler = nil
        output = nil
    }

    private func configureGrid() {
        let columns = settings.columns
        let calculatedRows = max(14, Int(round(Double(columns) * Double(outputHeight) / Double(outputWidth) * 0.58)))
        guard columns != currentColumns || calculatedRows != rows else { return }

        currentColumns = columns
        rows = calculatedRows
        sampler = Self.makePixelBuffer(width: columns * Self.tileWidth, height: rows * Self.tileHeight)
        output = Self.makePixelBuffer(width: outputWidth, height: outputHeight)
        grayBuffer = [Float](repeating: 0, count: columns * Self.tileWidth * rows * Self.tileHeight)
        internalBuffer = [Float](repeating: 0, count: columns * rows * 6)
        externalBuffer = [Float](repeating: 0, count: columns * rows * 10)
    }

    private static func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }

    private func drawSource(_ source: CVPixelBuffer, into target: CVPixelBuffer) {
        var sourceImage: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(source, options: nil, imageOut: &sourceImage) == noErr,
              let sourceImage else { return }
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(source))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
        let targetWidth = CGFloat(CVPixelBufferGetWidth(target))
        let targetHeight = CGFloat(CVPixelBufferGetHeight(target))
        let scale = max(targetWidth / sourceWidth, targetHeight / sourceHeight)
        let scaledWidth = sourceWidth * scale
        let scaledHeight = sourceHeight * scale
        let offsetX = (targetWidth - scaledWidth) / 2
        let offsetY = (targetHeight - scaledHeight) / 2

        CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        guard let base = CVPixelBufferGetBaseAddress(target), let context = CGContext(
            data: base,
            width: Int(targetWidth),
            height: Int(targetHeight),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(target),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.interpolationQuality = .high
        if settings.mirrored {
            context.translateBy(x: targetWidth, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.draw(sourceImage, in: CGRect(x: offsetX, y: offsetY, width: scaledWidth, height: scaledHeight))
    }

    private func buildGrayBuffer(from pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let pixel = row.advanced(by: x * 4)
                var luminance = (0.2126 * Float(pixel[2]) + 0.7152 * Float(pixel[1]) + 0.0722 * Float(pixel[0])) / 255
                luminance = pow(luminance, settings.gamma)
                grayBuffer[y * width + x] = settings.inverted ? 1 - luminance : luminance
            }
        }
    }

    private func collectVectors() {
        let samplerWidth = currentColumns * Self.tileWidth
        let samplerHeight = rows * Self.tileHeight
        var internalOffset = 0
        var externalOffset = 0
        for row in 0..<rows {
            for column in 0..<currentColumns {
                let baseX = column * Self.tileWidth
                let baseY = row * Self.tileHeight
                for kernel in internalKernels {
                    internalBuffer[internalOffset] = sample(baseX: baseX, baseY: baseY, kernel: kernel, width: samplerWidth, height: samplerHeight)
                    internalOffset += 1
                }
                for kernel in externalKernels {
                    externalBuffer[externalOffset] = sample(baseX: baseX, baseY: baseY, kernel: kernel, width: samplerWidth, height: samplerHeight)
                    externalOffset += 1
                }
            }
        }
    }

    private func sample(baseX: Int, baseY: Int, kernel: Kernel, width: Int, height: Int) -> Float {
        var sum: Float = 0
        var total: Float = 0
        for tap in kernel.taps {
            let x = max(0, min(width - 1, baseX + tap.x))
            let y = max(0, min(height - 1, baseY + tap.y))
            sum += grayBuffer[y * width + x] * tap.weight
            total += tap.weight
        }
        return total > 0 ? sum / total : 0
    }

    private func enhancedVector(cellIndex: Int) -> SIMD8<Float> {
        var vector = SIMD8<Float>(repeating: 0)
        let internalStart = cellIndex * 6
        for index in 0..<6 { vector[index] = internalBuffer[internalStart + index] }
        let externalStart = cellIndex * 10
        for index in 0..<6 {
            var maximum = vector[index]
            for externalIndex in Self.affectingExternalIndices[index] {
                maximum = max(maximum, externalBuffer[externalStart + externalIndex])
            }
            if maximum > 0.0001 {
                vector[index] = pow(vector[index] / maximum, settings.directionalContrast) * maximum
            }
        }

        var maximum: Float = 0
        for index in 0..<6 { maximum = max(maximum, vector[index]) }
        if maximum > 0.0001 {
            for index in 0..<6 {
                vector[index] = pow(vector[index] / maximum, settings.shapeContrast) * maximum
            }
        }
        return vector
    }

    private func bestCharacter(for vector: SIMD8<Float>) -> Character {
        var key = 0
        var quantized = SIMD8<Float>(repeating: 0)
        for index in 0..<6 {
            let value = min(Self.cacheRange - 1, Int(floor(vector[index] * Float(Self.cacheRange))))
            quantized[index] = (Float(value) + 0.5) / Float(Self.cacheRange)
            key = key * Self.cacheRange + value
        }
        if lookupCache[key] >= 0 { return Self.characters[Int(lookupCache[key])] }

        var bestIndex = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (characterIndex, glyph) in glyphVectors.enumerated() {
            var distance: Float = 0
            for index in 0..<6 {
                let delta = glyph[index] - quantized[index]
                distance += delta * delta
            }
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = characterIndex
            }
        }
        lookupCache[key] = Int16(bestIndex)
        return Self.characters[bestIndex]
    }

    private func drawAscii(into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer), let context = CGContext(
            data: base,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setShouldAntialias(true)

        let cellWidth = CGFloat(outputWidth) / CGFloat(currentColumns)
        let cellHeight = CGFloat(outputHeight) / CGFloat(rows)
        let fontSize = cellHeight * 0.88
        let font = CTFontCreateWithName(fontName, fontSize, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
        let measured = CTLineGetTypographicBounds(
            CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "M" as CFString, attributes)!),
            nil,
            nil,
            nil
        )
        let xScale = cellWidth / max(CGFloat(measured), fontSize * 0.6)

        context.saveGState()
        context.scaleBy(x: xScale, y: 1)
        for row in 0..<rows {
            var line = String()
            line.reserveCapacity(currentColumns)
            for column in 0..<currentColumns {
                line.append(bestCharacter(for: enhancedVector(cellIndex: row * currentColumns + column)))
            }
            let attributed = CFAttributedStringCreate(nil, line as CFString, attributes)!
            let textLine = CTLineCreateWithAttributedString(attributed)
            let baseline = CGFloat(outputHeight) - (CGFloat(row) + 0.5) * cellHeight - fontSize * 0.35
            context.textPosition = CGPoint(x: 0, y: baseline)
            CTLineDraw(textLine, context)
        }
        context.restoreGState()
    }

    // Matrix mode is deliberately a post-process. The complete white-on-black
    // ASCII frame has already been produced by drawAscii, so glyph matching,
    // spacing, and rasterization are identical in both modes. In-place color
    // multiplication only tints existing pixels; black pixels stay black.
    private func applyMatrixEffect(to pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        if matrixStreams.count != currentColumns {
            matrixStreams = (0..<currentColumns).map { Self.makeMatrixStream(column: $0, rows: rows) }
        }
        if settings.mode == .matrix { prepareMatrixToneBuffers() }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        for row in 0..<rows {
            let yStart = row * outputHeight / rows
            let yEnd = (row + 1) * outputHeight / rows
            for column in 0..<currentColumns {
                let stream = matrixStreams[column]
                let progress = (time * stream.speed + stream.phase).truncatingRemainder(dividingBy: stream.cycle)
                let head = progress - stream.length
                let bucket = matrixBucket(row: row, head: head, length: stream.length)
                let color: MatrixColor
                switch settings.mode {
                case .matrix:
                    color = matrixColor(row: row, column: column, bucket: bucket)
                case .matrixOld:
                    color = Self.matrixOldColors[bucket]
                case .ascii:
                    return
                }
                let xStart = column * outputWidth / currentColumns
                let xEnd = (column + 1) * outputWidth / currentColumns

                for y in yStart..<yEnd {
                    var pixel = base.advanced(by: y * bytesPerRow + xStart * 4).assumingMemoryBound(to: UInt8.self)
                    for _ in xStart..<xEnd {
                        pixel[0] = UInt8((UInt16(pixel[0]) * color.blue + 127) / 255)
                        pixel[1] = UInt8((UInt16(pixel[1]) * color.green + 127) / 255)
                        pixel[2] = UInt8((UInt16(pixel[2]) * color.red + 127) / 255)
                        pixel = pixel.advanced(by: 4)
                    }
                }
            }
        }
    }

    private func prepareMatrixToneBuffers() {
        let cellCount = currentColumns * rows
        if matrixLuminanceBuffer.count != cellCount {
            matrixLuminanceBuffer = [Float](repeating: 0, count: cellCount)
            matrixEdgeBuffer = [Float](repeating: 0, count: cellCount)
        }

        for cellIndex in 0..<cellCount {
            let start = cellIndex * 6
            var luminance: Float = 0
            for sampleIndex in 0..<6 { luminance += internalBuffer[start + sampleIndex] }
            matrixLuminanceBuffer[cellIndex] = luminance / 6
        }

        for row in 0..<rows {
            let upperRow = max(0, row - 1)
            let lowerRow = min(rows - 1, row + 1)
            for column in 0..<currentColumns {
                let leftColumn = max(0, column - 1)
                let rightColumn = min(currentColumns - 1, column + 1)
                let horizontal = abs(
                    matrixLuminanceBuffer[row * currentColumns + rightColumn]
                    - matrixLuminanceBuffer[row * currentColumns + leftColumn]
                )
                let vertical = abs(
                    matrixLuminanceBuffer[lowerRow * currentColumns + column]
                    - matrixLuminanceBuffer[upperRow * currentColumns + column]
                )
                matrixEdgeBuffer[row * currentColumns + column] = min(1, (horizontal + vertical) * 1.35)
            }
        }
    }

    private func matrixColor(row: Int, column: Int, bucket: Int) -> MatrixColor {
        let cellIndex = row * currentColumns + column
        let luminance = Double(matrixLuminanceBuffer[cellIndex])
        let edge = Double(matrixEdgeBuffer[cellIndex])
        let portrait = min(0.98, 0.50 + 0.38 * pow(luminance, 0.70) + 0.28 * edge)
        let isHead = bucket == Self.matrixBrightnessBuckets
        let trail = isHead
            ? 0.12
            : 0.09 * Double(bucket) / Double(Self.matrixBrightnessBuckets - 1)
        let green = min(1, portrait + trail)
        let highlight = min(1, pow(luminance, 0.80) + 0.45 * edge + (isHead ? 0.12 : 0))

        return MatrixColor(
            blue: UInt16(round(255 * green * (0.08 + 0.55 * highlight))),
            green: UInt16(round(255 * green)),
            red: UInt16(round(255 * green * (0.03 + 0.45 * highlight)))
        )
    }

    private func matrixBucket(row: Int, head: Double, length: Double) -> Int {
        let distance = head - Double(row)
        if abs(distance) < 0.55 { return Self.matrixBrightnessBuckets }
        guard distance >= 0, distance < length else { return 0 }

        let trail = pow(1 - distance / length, 1.45)
        return max(1, min(
            Self.matrixBrightnessBuckets - 1,
            Int(round(trail * Double(Self.matrixBrightnessBuckets - 1)))
        ))
    }

    private static func makeMatrixStream(column: Int, rows: Int) -> MatrixStream {
        let seed = matrixHash(UInt64(column) ^ UInt64(rows) << 32)
        let lengthLimit = max(8, min(28, rows / 2))
        let lengthRange = max(1, lengthLimit - 7)
        let length = Double(8 + Int((seed >> 8) % UInt64(lengthRange)))
        let speed = 5 + unitInterval(seed >> 24) * 8
        let gap = 3 + unitInterval(seed >> 40) * 16
        let cycle = Double(rows) + length + gap
        let phase = unitInterval(matrixHash(seed)) * cycle
        return MatrixStream(length: length, speed: speed, phase: phase, cycle: cycle)
    }

    private static func unitInterval(_ value: UInt64) -> Double {
        Double(value & 0xffff) / Double(UInt16.max)
    }

    private static func matrixHash(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }

    private static func makeKernel(centerX: Float, centerY: Float) -> Kernel {
        var taps: [Tap] = []
        let minX = Int(floor(centerX - sampleRadius))
        let maxX = Int(ceil(centerX + sampleRadius))
        let minY = Int(floor(centerY - sampleRadius))
        let maxY = Int(ceil(centerY + sampleRadius))
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Float(x) + 0.5 - centerX
                let dy = Float(y) + 0.5 - centerY
                let distance = hypot(dx, dy)
                guard distance < sampleRadius else { continue }
                taps.append(Tap(x: x, y: y, weight: 1 - distance / sampleRadius))
            }
        }
        return Kernel(taps: taps)
    }

    private static func buildGlyphDatabase(fontName: CFString) -> [SIMD8<Float>] {
        let width = 96
        let height = 144
        let font = CTFontCreateWithName(fontName, 128, nil)
        var rawVectors: [[Float]] = []
        for character in characters {
            var pixels = [UInt8](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
                let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, String(character) as CFString, attributes)!)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
                context.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2, y: (CGFloat(height) - ascent - descent) / 2 + descent + 4)
                CTLineDraw(line, context)
            }

            rawVectors.append(internalCenters.map { center in
                sampleGlyphCircle(pixels: pixels, width: width, height: height, centerX: center.0 / Float(tileWidth) * Float(width), centerY: center.1 / Float(tileHeight) * Float(height), radius: sampleRadius / Float(tileWidth) * Float(width))
            })
        }

        var maxima = [Float](repeating: 0, count: 6)
        for vector in rawVectors {
            for index in 0..<6 { maxima[index] = max(maxima[index], vector[index]) }
        }
        return rawVectors.map { vector in
            var normalized = SIMD8<Float>(repeating: 0)
            for index in 0..<6 {
                normalized[index] = maxima[index] > 0 ? vector[index] / maxima[index] : 0
            }
            return normalized
        }
    }

    private static func sampleGlyphCircle(pixels: [UInt8], width: Int, height: Int, centerX: Float, centerY: Float, radius: Float) -> Float {
        var sum: Float = 0
        var total: Float = 0
        let minX = max(0, Int(floor(centerX - radius)))
        let maxX = min(width - 1, Int(ceil(centerX + radius)))
        let minY = max(0, Int(floor(centerY - radius)))
        let maxY = min(height - 1, Int(ceil(centerY + radius)))
        for y in minY...maxY {
            for x in minX...maxX {
                let distance = hypot(Float(x) + 0.5 - centerX, Float(y) + 0.5 - centerY)
                guard distance < radius else { continue }
                let weight = 1 - distance / radius
                sum += Float(pixels[y * width + x]) / 255 * weight
                total += weight
            }
        }
        return total > 0 ? sum / total : 0
    }
}
