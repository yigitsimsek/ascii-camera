import AppKit
import AsciiCameraLegacyTransport
@preconcurrency import AVFoundation
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "com.yigit.asciicamera", category: "host")
    private let modernSink = OBSModernCameraSink()
    private var capture: CameraCapture?
    private var commandTimer: Timer?
    private var lastColumns = 240

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCommandPolling()
        do {
            try modernSink.start()
            logger.notice("Publishing through the modern OBS Camera Extension")
        } catch {
            logger.fault("OBS Camera Extension is unavailable: \(error.localizedDescription, privacy: .public)")
            NSApplication.shared.terminate(nil)
            return
        }
        requestCameraAndStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture?.stop()
        modernSink.stop()
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
                        NSApplication.shared.terminate(nil)
                        return
                    }
                    self?.startCapture()
                }
            }
        case .denied, .restricted:
            logger.error("Camera permission is unavailable. Enable ASCII Camera in System Settings > Privacy & Security > Camera.")
            NSApplication.shared.terminate(nil)
        @unknown default:
            logger.error("Unknown camera authorization state")
        }
    }

    private func startCapture() {
        do {
            let capture = CameraCapture(modernSink: modernSink)
            try capture.start()
            self.capture = capture
            logger.notice("ASCII Camera is running through the modern OBS Camera Extension")
        } catch {
            logger.fault("Could not start ASCII Camera: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func installCommandPolling() {
        UserDefaults.standard.synchronize()
        lastColumns = CameraCapture.storedColumns()
        commandTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(pollCommands),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func pollCommands() {
        UserDefaults.standard.synchronize()

        let columns = CameraCapture.storedColumns()
        if columns != lastColumns {
            lastColumns = columns
            capture?.setColumns(columns)
        }

        let request = UserDefaults.standard.string(forKey: "effectsRequest") ?? ""
        let handled = UserDefaults.standard.string(forKey: "effectsRequestHandled") ?? ""
        if !request.isEmpty, request != handled {
            UserDefaults.standard.set(request, forKey: "effectsRequestHandled")
            logger.notice("Opening macOS Video Effects for ASCII Camera")
            AVCaptureDevice.showSystemUserInterface(.videoEffects)
        }
    }
}
