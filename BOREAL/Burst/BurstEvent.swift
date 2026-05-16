import Foundation
import CoreMedia

/// Reasons a slot can be skipped. Stored in the sidecar JSON for downstream analysis.
enum SkipReason: String, Codable, Sendable, Equatable {
    case timeout              // 5s elapsed without didFinishCaptureFor
    case ispNotReady          // ReadinessCoordinator never reached .ready within budget
    case captureError         // didFinishCaptureFor(error:) was non-nil
    case writeFailed          // staging-disk write failed
    case unknown
}

/// A successfully delivered raw capture, before any post-processing.
struct CapturedRaw: Sendable {
    let slot: Int
    let dngBytes: Data
    let hardwareTimestamp: CMTime    // photo.timestamp — sensor-readout instant
    let wallClock: Date              // CMTime mapped through session reference
}

/// All events the state machine accepts. Pure data; no side effects.
enum BurstEvent: Sendable {
    case tapCapture
    case prepared                                     // CaptureService finished prepare()
    case frameDelivered(CapturedRaw)
    case frameSkipped(slot: Int, reason: SkipReason)
    case postProcessFinished(slot: Int, success: Bool)
    case userReset
    case failed(String)
}
