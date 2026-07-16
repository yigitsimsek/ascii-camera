// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AsciiCamera",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AsciiCameraCore", targets: ["AsciiCameraCore"]),
        .executable(name: "ascii-camera-host", targets: ["AsciiCameraHost"]),
        .executable(name: "ascii-camera-core-tests", targets: ["AsciiCameraCoreTests"]),
    ],
    targets: [
        .target(name: "AsciiCameraCore"),
        .target(
            name: "AsciiCameraLegacyTransport",
            path: "Native/LegacyTransport",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
            ]
        ),
        .executableTarget(
            name: "AsciiCameraHost",
            dependencies: ["AsciiCameraCore", "AsciiCameraLegacyTransport"],
            path: "Native/LegacyHost",
            exclude: ["Info.plist", "com.yigit.asciicamera.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "AsciiCameraCoreTests",
            dependencies: ["AsciiCameraCore"],
            path: "Tests/AsciiCameraCoreTests"
        ),
    ]
)
