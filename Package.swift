// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AsciiCamera",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AsciiCameraCore", targets: ["AsciiCameraCore"]),
        .executable(name: "ascii-camera-core-tests", targets: ["AsciiCameraCoreTests"]),
    ],
    targets: [
        .target(name: "AsciiCameraCore"),
        .executableTarget(
            name: "AsciiCameraCoreTests",
            dependencies: ["AsciiCameraCore"],
            path: "Tests/AsciiCameraCoreTests"
        ),
    ]
)
