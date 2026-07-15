import CoreMediaIO
import Foundation

let source = CameraProviderSource()
CMIOExtensionProvider.startService(provider: source.provider)
CFRunLoopRun()

