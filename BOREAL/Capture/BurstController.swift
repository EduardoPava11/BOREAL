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

    /// The per-cycle latent product: three MULTI-SCALE residual stacks
    /// (Phase 3 — each rung its own demosaic; bands[0..256) of each = the
    /// 16×16 latent frame; a prefix decodes to THE rung-r demosaic) plus
    /// the σ head (per-cell |residual| energy across L,a,b — the dither
    /// budget). ~1 MB per cycle at the 2048→256 shape; 16 cycles ≈ 17 MB.
    struct Bands: Sendable {
        let mosaicSide: Int                  // crop side S (derives the rungs)
        let side: Int                        // ceiling rung actually used
        let L: [Int32]
        let a: [Int32]
        let b: [Int32]
        let sigma: [Float]                   // 256 cells, row-major
    }

    /// Per-cycle reduction outcome. `plan` is the ETTR solver's suggested EV
    /// vector for a FUTURE cycle (raw, unclamped — the loop applies the
    /// P1-P4 mapping); `actualEV` is the cycle's EXIF-derived exposure ratios
    /// (planned-vs-actual is the Phase 2 exit gate).
    struct Outcome: Sendable {
        let index: Int
        let ok: Bool
        let note: String
        let bands: Bands?
        let plan: [Float]?
        let actualEV: [Float]
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
    /// The burst's product: an animated GIF89a (one frame per completed
    /// cycle, GCT = the first cycle's seed palette — D1 default). Published
    /// after .done when assembly succeeds.
    private(set) var gifURL: URL?

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
        gifURL = nil

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
        let bounds = camera.biasBounds

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
            biases = planBiases(seed: savedBiases, bounds: bounds)
        }

        phase = .draining
        await chainTail?.value
        phase = .done(completed: Self.cycleCount - dropped, dropped: dropped)
        blog.info("burst: done — \(Self.cycleCount - dropped)/\(Self.cycleCount) cycles, \(self.outcomes.filter(\.ok).count) reduced ok")

        // Assemble the product: one GIF frame per completed cycle, indexed
        // against the FIRST cycle's seed palette (D1: one global table).
        let snapshot = outcomes
        gifURL = await Task.detached(priority: .userInitiated) {
            Self.assembleGIF(from: snapshot)
        }.value
    }

    /// Burst → GIF89a: decode each cycle's ceiling rung, index against the
    /// governing palette, encode. 20 cs per cycle frame (16 cycles ≈ the
    /// burst's own ~3.2 s duration); the 64-frame/5 cs contract arrives
    /// with the per-frame rendering slice.
    nonisolated private static func assembleGIF(from outcomes: [Outcome]) -> URL? {
        let ok = outcomes.filter { $0.ok && $0.bands != nil }.sorted { $0.index < $1.index }
        guard let first = ok.first?.bands else { return nil }
        let palL = Array(first.L[0..<256])
        let palA = Array(first.a[0..<256])
        let palB = Array(first.b[0..<256])
        let palRGB = Kernel.oklabQ16ToSRGB8(L: palL, a: palA, b: palB)

        var frames: [[UInt8]] = []
        var side = 0
        for outcome in ok {
            guard let bands = outcome.bands else { continue }
            let r = bands.side
            guard let iL = Kernel.msDecode(bands.L, mosaicSide: bands.mosaicSide, rung: r),
                  let iA = Kernel.msDecode(bands.a, mosaicSide: bands.mosaicSide, rung: r),
                  let iB = Kernel.msDecode(bands.b, mosaicSide: bands.mosaicSide, rung: r)
            else { continue }
            side = max(side, r)
            frames.append(Kernel.indexMap(L: iL, a: iA, b: iB,
                                          palL: palL, palA: palA, palB: palB))
        }
        guard !frames.isEmpty, side > 0,
              frames.allSatisfy({ $0.count == side * side }),
              let gif = Kernel.gifEncode(frames: frames, side: side,
                                         paletteRGB: palRGB, delayCs: 20)
        else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BOREAL-burst-\(Int(Date().timeIntervalSince1970)).gif")
        do {
            try gif.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// The Phase 2 mapping under the P1-P4 laws (spec/exposure/EvPlan.hs):
    /// the latest completed cycle's ETTR plan, clamped to device bias bounds;
    /// no plan yet (first cycles, failed reductions) → the seed bracket.
    /// The reduction chain lags capture by up to `maxInFlight` cycles, so
    /// this is a control loop with 1-2 cycles of latency — by design.
    private func planBiases(seed: [Float], bounds: ClosedRange<Float>) -> [Float] {
        guard let plan = outcomes.last(where: { $0.ok && $0.plan != nil })?.plan else {
            return seed                          // P2 fallback
        }
        return plan.map { min(bounds.upperBound, max(bounds.lowerBound, $0)) }  // P1
    }

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
            Outcome(index: cycle.index, ok: false, note: note, bands: nil,
                    plan: nil, actualEV: [1, 1, 1, 1])
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

        // Phase 2 analysis: clips from the base frame's mosaic (the bias
        // closest to 0) → the ETTR solver's plan for a future cycle; actual
        // EV ratios from EXIF for the planned-vs-actual record.
        let baseIdx = cycle.biases.isEmpty
            ? 0
            : cycle.biases.enumerated().min(by: { abs($0.element) < abs($1.element) })!.offset
        let clips = Kernel.analyzeMosaicClips(cropped[baseIdx])
        let plan = Kernel.solveETTR(clips: clips, wb: ref.wb)
        let actualEV = Kernel.relativeExposures(cropped)

        // 3-4. Fuse (EV-aware) → the custom ISP: demosaic at EVERY scale.
        // The fused mosaic is scene-linear normalized; bk_ms_encode produces
        // the per-channel residual stacks directly (rung r = its own
        // demosaic → camera→ProPhoto → OKLab Q16; MS laws).
        guard let fused = Kernel.fuse(cropped) else { return fail("fuse failed") }
        guard let stacks = Kernel.msEncode(mosaic: fused, side: side, cfa: ref.cfa,
                                           camToPP: ref.camToPP,
                                           hasColor: ref.hasColor)
        else { return fail("multi-scale encode failed") }

        let ceiling = Kernel.msRungs(side: side).max() ?? 16
        let bands = Bands(mosaicSide: side, side: ceiling,
                          L: stacks.L, a: stacks.a, b: stacks.b,
                          sigma: sigmaGrid(mosaicSide: side,
                                           channels: [stacks.L, stacks.a, stacks.b]))
        return Outcome(index: cycle.index, ok: true,
                       note: "S=\(side) → multi-scale \(ceiling)² stack", bands: bands,
                       plan: plan, actualEV: actualEV)
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

    /// σ head: per 16×16 latent cell, the summed |residual| over every
    /// multi-scale level and channel landing in that cell — how much the
    /// finer demosaics disagree with the coarser view there. This is the
    /// dither budget / resolution gate.
    nonisolated private static func sigmaGrid(mosaicSide: Int,
                                              channels: [[Int32]]) -> [Float] {
        var acc = [Int64](repeating: 0, count: 16 * 16)
        var offset = 0
        for (levelIdx, r) in Kernel.msRungs(side: mosaicSide).enumerated() {
            let n = r * r
            if levelIdx > 0 {                // residual levels only (base is absolute)
                for bands in channels {
                    for p in 0..<n {
                        let row = p / r, col = p % r
                        let cell = (row * 16 / r) * 16 + (col * 16 / r)
                        acc[cell] += Int64(abs(bands[offset + p]))
                    }
                }
            }
            offset += n
        }
        return acc.map { Float($0) }
    }
}
