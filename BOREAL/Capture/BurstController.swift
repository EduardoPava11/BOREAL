import Foundation

/// The 64-frame burst: 16 EV cycles × 4 RAW frames (BOREAL-16LAB-DESIGN.md L1).
///
/// The device-proven 4-frame hardware bracket stays the atomic capture unit
/// (`CameraController.captureBracket`); this controller grafts 6teen3's burst
/// mechanics AROUND it, adapted to cycle granularity:
///   • fire-next-before-processing — cycle k+1's bracket captures while cycle
///     k reduces on a background chain (overlaps ISP with the Zig kernels)
///   • bounded in-flight — at most 2 cycles of DNG data alive (~250 MB) so the
///     burst never approaches the 64-full-frames (~1.6 GB) cliff
///   • cycle-granular failure — a failed bracket drops that CYCLE (fuse is
///     4-ary); the burst succeeds with ≥ 14/16 cycles (6teen3's 60/64 rule)
///   • watchdog — a stuck AVFoundation capture can't wedge the app silently
///
/// Slice-1 reduction is decode + EV-aware fuse + free (proves the seam and the
/// memory discipline); the full L2 chain (demosaic → ProPhoto → 256² box →
/// OKLab Q16 → pyramid) plugs into `reduce(_:)` next. The inter-cycle ETTR
/// planner (scene.zig) plugs into `planBiases(after:)`.
///
/// Capture is DEVICE-ONLY (compile-check on the simulator, per house rule).
@MainActor
@Observable
final class BurstController {

    static let cycleCount = 16
    static let maxDroppedCycles = 2          // burst needs ≥ 14/16 cycles
    static let maxInFlight = 2               // cycles of DNG data alive at once
    static let watchdogSeconds: UInt64 = 90  // whole-burst ceiling (~3.2s nominal)

    /// One captured EV cycle — the burst's atomic unit.
    struct Cycle: Sendable {
        let index: Int
        let biases: [Float]
        let dngs: [Data]
    }

    /// The per-cycle latent product: three band buffers in prefix layout
    /// (bands[0..256) of each = the 16×16 latent frame) plus the σ head
    /// (per-cell subtree detail energy across L,a,b — the dither budget).
    /// ~768 KB per cycle at the 256² ceiling; 16 cycles ≈ 12.3 MB per burst.
    struct Bands: Sendable {
        let side: Int                        // ceiling rung actually used
        let L: [Int32]
        let a: [Int32]
        let b: [Int32]
        let sigma: [Float]                   // 256 cells, row-major
    }

    /// Per-cycle reduction outcome.
    struct Outcome: Sendable {
        let index: Int
        let ok: Bool
        let note: String
        let bands: Bands?
    }

    enum Phase: Equatable {
        case idle
        case capturing(cycle: Int)           // 1-based, of cycleCount
        case draining                        // capture done, reduction finishing
        case done(completed: Int, dropped: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var outcomes: [Outcome] = []

    /// Reduction tasks by cycle index — the serial chain tail is the last value;
    /// awaiting tasks[i - maxInFlight] before capturing cycle i bounds memory.
    private var reductionTasks: [Int: Task<Void, Never>] = [:]
    private var chainTail: Task<Void, Never>?
    private var timedOut = false

    var isRunning: Bool {
        switch phase {
        case .capturing, .draining: return true
        default: return false
        }
    }

    // ── The burst loop ──────────────────────────────────────────────────────

    func run(camera: CameraController) async {
        guard !isRunning else { return }
        outcomes.removeAll()
        reductionTasks.removeAll()
        chainTail = nil
        timedOut = false

        let savedBiases = camera.biases
        defer { camera.biases = savedBiases }

        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.watchdogSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.timedOut = true
        }
        defer { watchdog.cancel() }

        var dropped = 0
        var biases = savedBiases                 // seed bracket for cycle 0

        for i in 0..<Self.cycleCount {
            if timedOut {
                phase = .failed("watchdog: burst exceeded \(Self.watchdogSeconds)s at cycle \(i + 1)")
                blog.error("burst: watchdog fired at cycle \(i + 1)")
                return
            }
            // Bound in-flight DNG memory: cycle i waits for cycle i-2's reduction.
            if let gate = reductionTasks[i - Self.maxInFlight] { await gate.value }

            phase = .capturing(cycle: i + 1)
            camera.biases = biases
            do {
                let dngs = try await camera.captureBracket()
                enqueueReduction(Cycle(index: i, biases: biases, dngs: dngs))
            } catch {
                dropped += 1
                blog.error("burst: cycle \(i + 1) dropped: \(error.localizedDescription, privacy: .public)")
                if dropped > Self.maxDroppedCycles {
                    phase = .failed("burst aborted: \(dropped) cycles failed")
                    return
                }
            }
            // ETTR HOOK (next slice): feed cycle stats to scene.zig's planner —
            // bk_analyze_scene → bk_solve_ettr_exposures → next cycle's biases.
            // Slice-1 keeps the seed bracket for every cycle.
            biases = planBiases(after: i, seed: savedBiases)
        }

        phase = .draining
        await chainTail?.value
        phase = .done(completed: Self.cycleCount - dropped, dropped: dropped)
        blog.info("burst: done — \(Self.cycleCount - dropped)/\(Self.cycleCount) cycles, \(self.outcomes.filter(\.ok).count) reduced ok")
    }

    /// Inter-cycle exposure planning. Slice-1: the fixed seed bracket (the
    /// fusion aligns by recorded EXIF regardless). The scene.zig ETTR solver
    /// replaces this body without touching the loop.
    private func planBiases(after _: Int, seed: [Float]) -> [Float] { seed }

    // ── Reduction chain (serial, off-main) ──────────────────────────────────

    private func enqueueReduction(_ cycle: Cycle) {
        let prev = chainTail
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await prev?.value                    // serial: one cycle reduces at a time
            let outcome = Self.reduce(cycle)     // DNG data freed when `cycle` drops here
            await MainActor.run { self?.finish(outcome) }
        }
        reductionTasks[cycle.index] = task
        chainTail = task
    }

    private func finish(_ outcome: Outcome) {
        outcomes.append(outcome)
        blog.info("burst: cycle \(outcome.index + 1) reduced ok=\(outcome.ok) \(outcome.note, privacy: .public)")
    }

    /// The full L2 chain per cycle (BOREAL-16LAB-DESIGN.md):
    /// decode ×4 → crop S² → EV-aware fuse → demosaic → ProPhoto → linear
    /// box S²→256² → OKLab Q16 → pyramid ×3 → σ head.
    nonisolated static func reduce(_ cycle: Cycle) -> Outcome {
        func fail(_ note: String) -> Outcome {
            Outcome(index: cycle.index, ok: false, note: note, bands: nil)
        }

        // 1. Decode (device-proven dng.zig path; EXIF rides along for fuse).
        var frames: [Kernel.Frame] = []
        frames.reserveCapacity(4)
        for (j, dng) in cycle.dngs.enumerated() {
            let (frame, status) = Kernel.decodeDNG(dng)
            guard let frame else {
                return fail("frame \(j + 1) undecodable: \(Kernel.statusName(status))")
            }
            frames.append(frame)
        }
        guard frames.count == 4,
              frames.allSatisfy({ $0.width == frames[0].width && $0.height == frames[0].height })
        else { return fail("dimension mismatch") }

        // 2. Crop to the canonical dyadic side (CS1: largest 256·2^j that
        //    fits, capped at 2048) BEFORE fusing — 3× less work at 12MP.
        let ref = frames[0]
        guard let side = canonicalSide(width: ref.width, height: ref.height) else {
            return fail("sensor \(ref.width)×\(ref.height) below the 256² ceiling")
        }
        let cropped = frames.map { cropCenter($0, side: side) }

        // 3-5. Fuse (EV-aware) → demosaic (MHC) → camera→ProPhoto.
        guard let fused = Kernel.fuse(cropped) else { return fail("fuse failed") }
        var rgb = Kernel.demosaic(fused, width: side, height: side, cfa: ref.cfa)
        if ref.hasColor {
            Kernel.applyColor(&rgb, width: side, height: side, matrix: ref.camToPP)
        }

        // 6-7. Linear box down to the 256² ceiling, then OKLab Q16.
        let ceiling = 256
        let small = side == ceiling
            ? rgb
            : Kernel.boxReduceRGB(rgb, width: side, height: side, factor: side / ceiling)
        let q = Kernel.oklabQ16(fromProPhoto: small)

        // 8. Deinterleave → three exact pyramids (L, a, b).
        let nPx = ceiling * ceiling
        var chL = [Int32](repeating: 0, count: nPx)
        var chA = [Int32](repeating: 0, count: nPx)
        var chB = [Int32](repeating: 0, count: nPx)
        for i in 0..<nPx {
            chL[i] = q[3 * i]
            chA[i] = q[3 * i + 1]
            chB[i] = q[3 * i + 2]
        }
        guard let bL = Kernel.pyramidAnalyze(chL, side: ceiling),
              let bA = Kernel.pyramidAnalyze(chA, side: ceiling),
              let bB = Kernel.pyramidAnalyze(chB, side: ceiling)
        else { return fail("pyramid analyze failed") }

        let bands = Bands(side: ceiling, L: bL, a: bA, b: bB,
                          sigma: sigmaGrid(side: ceiling, channels: [bL, bA, bB]))
        return Outcome(index: cycle.index, ok: true,
                       note: "S=\(side) → \(ceiling)² bands", bands: bands)
    }

    /// Largest 256·2^j ≤ min(width, height), capped at the spec canonical
    /// 2048 (CS1). nil when the sensor can't cover even the 256² ceiling.
    nonisolated private static func canonicalSide(width: Int, height: Int) -> Int? {
        let m = min(width, height)
        guard m >= 256 else { return nil }
        var s = 256
        while s * 2 <= m && s * 2 <= 2048 { s *= 2 }
        return s
    }

    /// Center crop to side², origin snapped to EVEN coordinates so the RGGB
    /// phase (and therefore frame.cfa) is preserved.
    nonisolated private static func cropCenter(_ f: Kernel.Frame, side: Int) -> Kernel.Frame {
        guard f.width != side || f.height != side else { return f }
        let x0 = ((f.width - side) / 2) & ~1
        let y0 = ((f.height - side) / 2) & ~1
        var s = [UInt16]()
        s.reserveCapacity(side * side)
        f.samples.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for y in 0..<side {
                s.append(contentsOf: UnsafeBufferPointer(start: base + (y0 + y) * f.width + x0,
                                                         count: side))
            }
        }
        var g = f
        g.width = side
        g.height = side
        g.samples = s
        return g
    }

    /// σ head: per 16×16 latent cell, the summed |detail| over every pyramid
    /// level and channel whose subtree lands in that cell (EP5: zero iff the
    /// cell's block is constant). This is the dither budget / resolution gate.
    nonisolated private static func sigmaGrid(side: Int, channels: [[Int32]]) -> [Float] {
        var acc = [Int64](repeating: 0, count: 16 * 16)
        var s = 16
        while s < side {                     // detail level with quad-grid side s
            let offset = s * s               // prefix layout: level s at [s², 4s²)
            let cellsPerQuad = s / 16        // quads per latent cell along one axis
            for bands in channels {
                for i in 0..<(s * s) {
                    let r = i / s, c = i % s
                    let cell = (r / cellsPerQuad) * 16 + (c / cellsPerQuad)
                    let q = offset + 3 * i
                    acc[cell] += Int64(abs(bands[q])) + Int64(abs(bands[q + 1]))
                        + Int64(abs(bands[q + 2]))
                }
            }
            s *= 2
        }
        return acc.map { Float($0) }
    }
}
