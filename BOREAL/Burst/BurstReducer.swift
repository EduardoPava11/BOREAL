import Foundation

/// Pure, synchronous state-transition function for the burst.
///
/// Total: every (state, event) pair has a defined result (in the worst case, the input
/// state is returned unchanged — a "no-op" transition logged for debugging).
///
/// Side effects (firing the next `captureOne`, enqueuing post-process, writing the
/// sidecar) are NOT this function's job — the driver in `AppCoordinator` runs them
/// based on the resulting state.
enum BurstReducer {
    /// MVP scope: capture exactly 4 frames (one set), saved to `set-00/`. Sets
    /// 01–15 stay as empty folders ready for Phase 2 / restore-to-64. Restore
    /// the production scope by switching back to `PyramidTable.totalFrameCount`
    /// (= 64) once the on-device burst has been verified end-to-end.
    static let targetFrameCount = PyramidTable.framesPerSet   // = 4

    static func reduce(_ state: BurstState, _ event: BurstEvent) -> BurstState {
        switch event {
        case .userReset:
            return .idle

        case .failed(let msg):
            return .failed(message: msg)

        case .tapCapture:
            // Only legal from .idle. From other states, drop.
            switch state {
            case .idle: return .preparing
            default:    return state
            }

        case .prepared:
            // Only legal from .preparing.
            switch state {
            case .preparing:
                return .capturing(slot: 0, captured: 0, skipped: [], startedAt: Date())
            default:
                return state
            }

        case .frameDelivered(let raw):
            switch state {
            case .capturing(let slot, let captured, let skipped, let startedAt) where raw.slot == slot:
                let nextSlot = slot + 1
                let newCaptured = captured + 1
                if nextSlot >= targetFrameCount {
                    // Terminal transition. Synchronous postProcessFrame
                    // (AppCoordinator) means by the time applyEventSideEffects
                    // returns, this frame's bytes are on disk and frames[slot]
                    // is updated. The .draining state's purpose was to wait for
                    // ASYNC post-process to drain — under sync post-process there
                    // is nothing to wait for, so we transition directly to .done.
                    // (.draining stays in BurstState for forward compat with the
                    // eventual 64-frame async path; just unreachable in MVP.)
                    let duration = Date().timeIntervalSince(startedAt)
                    return .done(captured: newCaptured,
                                 skipped: skipped,
                                 folder: Storage.sessionRoot,
                                 durationSec: duration)
                }
                return .capturing(slot: nextSlot,
                                  captured: newCaptured,
                                  skipped: skipped,
                                  startedAt: startedAt)
            default:
                return state   // stale event for an already-finished burst
            }

        case .frameSkipped(let slotIdx, _):
            switch state {
            case .capturing(let slot, let captured, let skipped, let startedAt) where slotIdx == slot:
                let nextSlot = slot + 1
                let newSkipped = skipped + [slotIdx]
                if nextSlot >= targetFrameCount {
                    // Terminal transition. Same reasoning as frameDelivered
                    // above: synchronous post-process means no draining required.
                    let duration = Date().timeIntervalSince(startedAt)
                    return .done(captured: captured,
                                 skipped: newSkipped,
                                 folder: Storage.sessionRoot,
                                 durationSec: duration)
                }
                return .capturing(slot: nextSlot,
                                  captured: captured,
                                  skipped: newSkipped,
                                  startedAt: startedAt)
            default:
                return state
            }

        case .postProcessFinished:
            switch state {
            case .draining(let captured, let skipped, let left, let startedAt):
                let remaining = left - 1
                if remaining <= 0 {
                    let duration = Date().timeIntervalSince(startedAt)
                    return .done(captured: captured,
                                 skipped: skipped,
                                 folder: Storage.sessionRoot,
                                 durationSec: duration)
                }
                return .draining(captured: captured,
                                 skipped: skipped,
                                 postProcessLeft: remaining,
                                 startedAt: startedAt)
            default:
                return state
            }
        }
    }
}
