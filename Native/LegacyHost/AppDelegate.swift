import AppKit
import AsciiCameraLegacyTransport
@preconcurrency import AVFoundation
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.yigit.asciicamera", category: "host")
    private let transport = LegacyVirtualCameraServer()
    private var capture: CameraCapture?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try transport.start()
        } catch {
            logger.fault("Could not start virtual-camera transport: \(error.localizedDescription, privacy: .public)")
            NSApplication.shared.terminate(nil)
            return
        }
        requestCameraAndStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture?.stop()
        transport.stop()
    }

    private func requestCameraAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                Task { @MainActor in
                    guard allowed else {
                        self?.logger.error("Camera permission was denied")
                        return
                    }
                    self?.startCapture()
                }
            }
        case .denied, .restricted:
            logger.error("Camera permission is unavailable. Enable ASCII Camera in System Settings > Privacy & Security > Camera.")
        @unknown default:
            logger.error("Unknown camera authorization state")
        }
    }

    private func startCapture() {
        do {
            let capture = CameraCapture(transport: transport)
            try capture.start()
            self.capture = capture
            logger.notice("ASCII Camera is running at 240 columns through the free legacy driver")
        } catch {
            logger.fault("Could not start ASCII Camera: \(error.localizedDescription, privacy: .public)")
        }
    }
}
