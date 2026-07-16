import AppKit
import AVFoundation
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.yigit.asciicamera", category: "host")
    private let extensionManager = CameraExtensionManager()
    private var capture: CameraCapture?

    func applicationDidFinishLaunching(_ notification: Notification) {
        extensionManager.activate()
        requestCameraAndStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture?.stop()
    }

    private func requestCameraAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard allowed else {
                    self?.logger.error("Camera permission was denied")
                    return
                }
                self?.startCapture()
            }
        case .denied, .restricted:
            logger.error("Camera permission is unavailable. Enable ASCII Camera in System Settings > Privacy & Security > Camera.")
        @unknown default:
            logger.error("Unknown camera authorization state")
        }
    }

    private func startCapture() {
        do {
            let frameStore = try SharedFrameStore()
            let capture = CameraCapture(frameStore: frameStore)
            try capture.start()
            self.capture = capture
            logger.notice("ASCII Camera is running at 240 columns")
        } catch {
            logger.fault("Could not start ASCII Camera: \(error.localizedDescription, privacy: .public)")
        }
    }
}
