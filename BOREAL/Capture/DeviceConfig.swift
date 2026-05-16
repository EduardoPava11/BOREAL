import AVFoundation
import Foundation

enum DeviceConfig {
    /// Pick the iPhone 17 Pro main (wide) camera.
    static func mainCamera() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }
}
