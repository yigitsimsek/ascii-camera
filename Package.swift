// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AsciiCamera",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AsciiCameraCore", targets: ["AsciiCameraCore"]),
        .executable(name: "ascii-camera-host", targets: ["AsciiCameraHost"]),
        .executable(name: "ascii-camera-core-tests", targets: ["AsciiCameraCoreTests"]),
        .executable(name: "ascii-camera-benchmarks", targets: ["AsciiCameraBenchmarks"]),
    ],
    targets: [
        .target(name: "AsciiCameraCore"),
        .target(
            name: "AsciiCameraOBSBridge",
            path: "Native/OBSBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .executableTarget(
            name: "AsciiCameraHost",
            dependencies: ["AsciiCameraCore", "AsciiCameraOBSBridge"],
            path: "Native/Host",
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
        .executableTarget(
            name: "AsciiCameraBenchmarks",
            dependencies: ["AsciiCameraCore"],
            path: "Benchmarks/AsciiCameraBenchmarks"
        ),
    ]
)
