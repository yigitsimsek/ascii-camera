import Foundation

public enum RenderMode: String, Sendable, Equatable, CaseIterable {
    case ascii
    case matrix
    case matrixOld = "matrix-old"
}

public struct RenderSettings: Sendable, Equatable {
    public var mode: RenderMode
    public var columns: Int
    public var shapeContrast: Float
    public var directionalContrast: Float
    public var gamma: Float
    public var mirrored: Bool
    public var inverted: Bool

    public init(
        mode: RenderMode = .ascii,
        columns: Int = 240,
        shapeContrast: Float = 2.2,
        directionalContrast: Float = 1.7,
        gamma: Float = 0.9,
        mirrored: Bool = true,
        inverted: Bool = false
    ) {
        self.mode = mode
        self.columns = max(48, min(240, columns))
        self.shapeContrast = shapeContrast
        self.directionalContrast = directionalContrast
        self.gamma = gamma
        self.mirrored = mirrored
        self.inverted = inverted
    }
}

public enum AsciiCameraConstants {
    public static let outputWidth = 1280
    public static let outputHeight = 720
    public static let framesPerSecond: Int32 = 30
    public static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "AsciiCameraAppGroupIdentifier") as? String
            ?? "group.com.yigit.asciicamera"
    }
    public static let extensionBundleIdentifier = "com.yigit.asciicamera.extension"
}
