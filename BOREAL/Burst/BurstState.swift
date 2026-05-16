import Foundation

/// All legal states of a single burst capture session.
///
/// Transitions are driven by `BurstReducer.reduce(_:_:)`. Every (state, event)
/// pair has a defined next state; no state is left implicit.
enum BurstState: Equatable, Sendable {
    /// Initial state. Preview is running, no burst in progress.
    case idle

    /// User tapped capture; CaptureService is configuring + starting.
    case preparing

    /// Burst in progress. `slot` is the index of the NEXT capture to attempt.
    /// `captured` and `skipped` count completed attempts.
    case capturing(slot: Int, captured: Int, skipped: [Int], startedAt: Date)

    /// All 64 capture attempts dispatched; waiting for outstanding post-process work.
    /// `postProcessLeft` decrements as `.postProcessFinished` events arrive.
    case draining(captured: Int, skipped: [Int], postProcessLeft: Int, startedAt: Date)

    /// Burst complete. Sidecar has been written; folder is ready to inspect.
    case done(captured: Int, skipped: [Int], folder: URL, durationSec: Double)

    /// Unrecoverable error (no Bayer fmt, camera denied, etc.).
    case failed(message: String)
}
