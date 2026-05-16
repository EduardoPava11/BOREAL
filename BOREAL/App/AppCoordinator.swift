import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Observation
import os

/// State-machine driver. Holds the burst state, exposes `handle(_:)` as the only
/// mutation API, and dispatches side-effect Tasks based on the reducer's output state.
///
/// Side effects (each fires from `runSideEffects` after a state transition):
///   - .preparing            → CaptureService.prepare(), then `handle(.prepared)`
///   - .capturing(slot:)     → CaptureService.captureOne(slot:), then either
///                              `handle(.frameDelivered(...))` or
///                              `handle(.frameSkipped(slot:reason:))`
///   - .draining             → no new captures; wait for postProcess to finish
///   - .done                 → write sidecar JSON
@MainActor
@Observable
final class AppCoordinator {

    // MARK: UI-bound state

    var state: BurstState = .idle

    /// Sized to `PyramidTable.totalFrameCount` (= 64) so `writeSidecar`'s 16-set
    /// chunking loop can always materialize 4 frames per set without index-out-
    /// of-range. In MVP scope (`BurstReducer.targetFrameCount` = 4), only the
    /// first 4 cells/frames receive real data; the remaining 60 stay empty
    /// (cells) / nil (frames → become `.placeholder` in the sidecars).
    /// `FrameGridView` already defensively iterates `0..<64` and tolerates a
    /// shorter `cells` array, so growing it to 64 is harmless for UI.
    var cells: [FrameCell] = Array(repeating: FrameCell(), count: PyramidTable.totalFrameCount)

    /// Persisted-shape frame records, populated as deliveries / skips arrive.
    private var frames: [CapturedFrame?] = Array(repeating: nil, count: PyramidTable.totalFrameCount)

    // MARK: Collaborators

    let captureService: CaptureService
    let postProcess: PostProcessQueue
    let ciContext: CIContext

    /// Capture-session reference exposed to SwiftUI preview.
    nonisolated var avSession: AVCaptureSession { captureService.session }

    init(captureService: CaptureService = CaptureService(),
         postProcess: PostProcessQueue = PostProcessQueue(limit: 2),
         ciContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])) {
        self.captureService = captureService
        self.postProcess = postProcess
        self.ciContext = ciContext
    }

    // MARK: Public API

    /// Single mutation API. UI calls this; side-effect tasks call this.
    ///
    /// `runSideEffects(for:)` only fires on ACTUAL state transitions. Stale
    /// events (e.g., `.frameSkipped(slot: N)` arriving while we've already
    /// advanced past slot N) leave state unchanged and must NOT re-trigger
    /// `runCaptureOne` for the current slot — otherwise duplicate capturePhoto
    /// calls avalanche (each duplicate's failure fires another stale frameSkipped,
    /// the slot-N fires grow 1 → 2 → 4 → 8…). `applyEventSideEffects` runs
    /// regardless because it captures the *event*'s payload (e.g., the delivered
    /// raw bytes) into instance state, which is independent of the FSM transition.
    func handle(_ event: BurstEvent) {
        let oldState = state
        let newState = BurstReducer.reduce(state, event)
        let stateChanged = newState != oldState
        if stateChanged {
            Log.burst.info("state \(String(describing: oldState), privacy: .public) → \(String(describing: newState), privacy: .public) via \(String(describing: event), privacy: .public)")
        }
        state = newState
        applyEventSideEffects(event)
        if stateChanged {
            runSideEffects(for: newState)
        }
    }

    // MARK: Side effects

    /// Some events carry data that needs to land in the UI/frames arrays even though
    /// the reducer's output state doesn't represent them directly (e.g., the actual
    /// CapturedFrame for a delivered slot).
    private func applyEventSideEffects(_ event: BurstEvent) {
        switch event {
        case .frameDelivered(let raw):
            postProcessFrame(raw)
            // After every 4th frameDelivered, the full set is on disk.
            // Fire .setComplete recursively; the side effect for that event
            // spawns the Phase 2 pipeline detached so capture is unblocked.
            let frameInSet = raw.slot % PyramidTable.framesPerSet
            if frameInSet == PyramidTable.framesPerSet - 1 {
                let completedSetIdx = raw.slot / PyramidTable.framesPerSet
                handle(.setComplete(setIdx: completedSetIdx))
            }
        case .frameSkipped(let slot, let reason):
            cells[slot].status = .skipped(reason)
            frames[slot] = .placeholder(slot: slot, reason: reason.rawValue)
        case .setComplete(let setIdx):
            // Phase 2 trigger: run the full set's pipeline (decode → bin →
            // encode → write .bvox) on a background task so the camera can
            // proceed with capturing the next set (when scaling back to
            // multi-set bursts). Failures land in Log.processing; no UI
            // change for now (item 10 will surface per-set progress).
            Task.detached(priority: .userInitiated) {
                do {
                    _ = try await SetProcessor.process(setIdx: setIdx)
                } catch {
                    Log.processing.error("Phase 2 set \(setIdx) failed: \(String(describing: error), privacy: .public)")
                }
            }
        case .userReset:
            cells = Array(repeating: FrameCell(), count: PyramidTable.totalFrameCount)
            frames = Array(repeating: nil, count: PyramidTable.totalFrameCount)
        default:
            break
        }
    }

    private func runSideEffects(for state: BurstState) {
        switch state {
        case .preparing:
            Task { await self.runPrepare() }
        case .capturing(let slot, _, _, _):
            Task { await self.runCaptureOne(slot: slot) }
        case .done(let captured, let skipped, let folder, let dur):
            Log.burst.info("Burst complete: captured=\(captured) skipped=\(skipped.count) duration=\(dur, format: .fixed(precision: 3))s")
            writeSidecar(folder: folder, captured: captured, skipped: skipped, startedAt: Date().addingTimeInterval(-dur))
        case .failed(let msg):
            Log.burst.error("Burst failed: \(msg, privacy: .public)")
        default:
            break
        }
    }

    // MARK: Driver actions

    private func runPrepare() async {
        do {
            // Wipe + recreate the on-disk session tree so per-frame writes have
            // their parent directory ready. Without this, `Data.write(to:)`
            // throws "The folder 'frame-N.dng' doesn't exist" because the
            // parent `set-NN/staging/` was never created. The eager preview
            // path doesn't need this — only the burst-tap path does.
            try Storage.prepareSessionFolder()
            try await captureService.prepare()
            handle(.prepared)
        } catch {
            handle(.failed(error.localizedDescription))
        }
    }

    private func runCaptureOne(slot: Int) async {
        do {
            let raw = try await captureService.captureOne(slot: slot)
            handle(.frameDelivered(raw))
        } catch let err as CaptureService.CaptureError {
            handle(.frameSkipped(slot: slot, reason: err.skipReason))
        } catch {
            Log.burst.error("Slot \(slot) unexpected error: \(error.localizedDescription, privacy: .public)")
            handle(.frameSkipped(slot: slot, reason: .unknown))
        }
    }

    /// Synchronously write the DNG bytes to disk on MainActor, then fire
    /// `.postProcessFinished` in the same call stack as the originating
    /// `frameDelivered` event.
    ///
    /// Why fully synchronous (no Task, no actor):
    ///   - `Data.write(to:)` for 10 MB on iPhone 17 Pro NVMe takes ~3-5 ms
    ///     synchronously. Four serial writes = ~20 ms total of MainActor
    ///     blocking. We're in `.draining` state during this — no captures
    ///     pending, no UI animation — so the blocking has no user-visible cost.
    ///   - Eliminates the entire "Task.detached + await MainActor.run" race
    ///     surface that was producing 1-of-4 postProcessFinished fires (slot 3
    ///     wins the scheduler race; slots 0/1/2 strand somewhere in the
    ///     scheduler/SwiftUI-rerender backpressure intersection).
    ///   - Determinism: each slot's postProcessFinished fires in the same
    ///     order as its frameDelivered, immediately, on the same call stack.
    ///     Burst progresses linearly and predictably.
    ///   - DNGProbe slot-0 dump stays as fire-and-forget `Task.detached` so
    ///     its ~15 log lines don't add to MainActor blocking.
    private func postProcessFrame(_ raw: CapturedRaw) {
        let slot = raw.slot
        let path = Storage.slotPath(slot: slot)
        let finalURL = Storage.frameURL(setIdx: path.setIdx, frameInSet: path.frameInSet)

        let succeeded: Bool
        do {
            try raw.dngBytes.write(to: finalURL, options: .atomic)
            succeeded = true
        } catch {
            Log.processing.error("slot \(slot) write to finalURL failed: \(error.localizedDescription, privacy: .public)")
            succeeded = false
        }

        // Convert hardware timestamp safely. iPhone 17 Pro / iOS 26 reports
        // synchronizationClock in 1e9 timescale; the naive `value * 1e9 /
        // timescale` overflows Int64. CMTimeConvertScale handles it.
        let nsTime = CMTimeConvertScale(raw.hardwareTimestamp,
                                        timescale: 1_000_000_000,
                                        method: .roundHalfAwayFromZero)
        let nanos = nsTime.value

        cells[slot].status = .captured(nil)
        frames[slot] = .real(slot: slot,
                             hwTimestampNanos: nanos,
                             wallClock: raw.wallClock)

        if slot == 0 && succeeded {
            // Fire-and-forget so the ~15 DNGProbe log lines don't add to
            // MainActor's per-slot blocking budget.
            let urlForProbe = finalURL
            Task.detached { DNGProbe.dump(urlForProbe) }
        }

        handle(.postProcessFinished(slot: slot, success: succeeded))
    }

    private func writeSidecar(folder: URL, captured: Int, skipped: [Int], startedAt: Date) {
        // Materialize all 64 frame entries (real or placeholder) in linear slot
        // order. Loop bound is `PyramidTable.totalFrameCount` (= 64), NOT
        // `targetFrameCount` (= 4 in MVP scope) — the per-set chunking below
        // assumes 64 entries to slice into 16 sets of 4.
        let allFrames: [CapturedFrame] = (0..<PyramidTable.totalFrameCount).map { i in
            self.frames[i] ?? .placeholder(slot: i, reason: SkipReason.unknown.rawValue)
        }

        // Per-set sidecars first: each set-NN/set.json carries its own 4 frame entries
        // and the set's pyramid budget so a Phase 2 reader can process one set folder
        // in isolation without consulting session.json.
        let framesPerSet = PyramidTable.framesPerSet
        for setIdx in 0..<PyramidTable.setCount {
            let lower = setIdx * framesPerSet
            let upper = lower + framesPerSet
            let setFrames = Array(allFrames[lower..<upper])
            let setSkipped = setFrames.enumerated()
                .compactMap { $0.element.isPlaceholder ? $0.offset : nil }
            let setCaptured = framesPerSet - setSkipped.count
            let setSidecar = SetSidecar(
                setIdx: setIdx,
                codeBudget: PyramidTable.codeBudget(setIdx: setIdx),
                captured: setCaptured,
                skipped: setSkipped,
                frames: setFrames
            )
            do {
                try setSidecar.write(to: Storage.setSidecarURL(setIdx: setIdx))
            } catch {
                Log.burst.error("set-\(setIdx) sidecar write failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Top-level session sidecar — pyramid table + ordered set folder list.
        let setFolderNames = (0..<PyramidTable.setCount).map { String(format: "set-%02d", $0) }
        let sessionSidecar = SessionSidecar(
            sessionId: UUID().uuidString,
            startedAt: startedAt,
            endedAt: Date(),
            captured: captured,
            skipped: skipped,
            crop: CropSpec.default,
            byteOrder: "MM",
            pyramid: PyramidTable.pyramid,
            setFolders: setFolderNames
        )
        do {
            try sessionSidecar.write(to: Storage.sessionSidecarURL())
            Log.burst.info("Sidecars written: 16 set.json + session.json (\(captured) real + \(PyramidTable.totalFrameCount - captured) placeholders) → \(folder.lastPathComponent, privacy: .public)")
        } catch {
            Log.burst.error("session.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Convenience for the UI

    func beginBurst() { handle(.tapCapture) }
    func reset()      { handle(.userReset) }

    /// Called from CameraView.task on first appear so the session is running.
    func preparePreviewIfNeeded() async {
        guard case .idle = state else { return }
        // Eager preview: run prepare WITHOUT entering the .preparing state. We hop
        // into .preparing only when the user taps capture. For preview, we just need
        // the AVCaptureSession running.
        do {
            try await captureService.prepare()
            Log.burst.info("Preview ready (eager prepare)")
        } catch {
            Log.burst.error("Eager prepare failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(message: error.localizedDescription)
        }
    }
}
