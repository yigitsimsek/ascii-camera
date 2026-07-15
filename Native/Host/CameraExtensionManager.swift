import Foundation
import OSLog
import SystemExtensions

final class CameraExtensionManager: NSObject, OSSystemExtensionRequestDelegate {
    private let logger = Logger(subsystem: "com.yigit.asciicamera", category: "extension-manager")

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: AsciiCameraConstants.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        logger.notice("Camera Extension activation finished (result \(result.rawValue))")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        logger.error("Camera Extension activation failed: \(error.localizedDescription, privacy: .public)")
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        logger.notice("Camera Extension needs one-time approval in System Settings > Privacy & Security")
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension extension: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}
