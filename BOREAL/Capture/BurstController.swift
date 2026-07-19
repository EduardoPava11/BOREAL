import Foundation

/// The 64-frame burst: 16 EV cycles × 4 RAW frames (BOREAL-16LAB-DESIGN.md L1).
///
/// The device-proven 4-frame hardware bracket stays the atomic capture unit
/// (`CameraController.captureBracket`); this controller grafts 6teen3's burst
/// mechanics AROUND it, adapted to cycle granularity:
///   • fire-next-before-processing — cycle k+1's bracket captures while cycle
///     k reduces on a background chain (overlaps ISP with the kernels)
///   • bounded in-flight — at most 2 cycles of DNG data alive (~250 MB) so the
///     burst never approaches the 64-full-frames (~1.6 GB) cliff
///   • cycle-granular failure — a failed bracket drops that CYCLE (fuse is
///     4-ary); the burst succeeds with ≥ 14/16 cycles (6teen3's 60/64 rule)
///   • watchdog — a stuck AVFoundation capture can't wedge the app silently
///
/// Slice-1 reduction is decode + EV-aware fuse + free (proves the seam and the
/// memory discipline); the full L2 chain (demosaic → ProPhoto → 256² box →
/// OKLab Q16 → pyramid) plugs into `reduce(_:)` next. The inter-cycle ETTR
/// planner plugs into `planBiases(after:)`.
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

    /// The 256-color seed palette as planar Q16 planes (the governing
    /// palette for per-frame indexing — D1: the FIRST cycle's seed).
    struct PaletteQ16: Sendable {
        let L: [Int32]
        let a: [Int32]
        let b: [Int32]
    }

    /// Per-frame L fractal record (N0): the frame's own 16² seed-L —
    /// the 256 options — plus its ceiling-rung L reordered into the
    /// (16×16)×(16×16) patch-major structure (H2: each option's home
    /// patch is one contiguous 256-run). L plane FIRST-CLASS; a/b ride
    /// only inside the index maps until the chroma nets (N2).
    struct FrameL: Sendable {
        let seedL: [Int32]                   // 256, Q16
        let patchesL: [Int32]                // 65536, patch-major (H2)
    }

    /// Per-cycle reduction outcome. `plan` is the ETTR solver's suggested EV
    /// vector for a FUTURE cycle (raw, unclamped — the loop applies the
    /// P1-P4 mapping); `actualEV` is the cycle's EXIF-derived exposure
    /// ratios; `frameIndices` are the cycle's 4 PER-FRAME ceiling-rung GIF
    /// index maps (each frame EV-normalized by its own e_t, multi-scale
    /// demosaiced, indexed against the governing palette); `frameL` is the
    /// cycle's 4 fractal L records (adds ~1 MB/cycle).
    struct Outcome: Sendable {
        let index: Int
        let ok: Bool
        let note: String
        let bands: Bands?
        let plan: [Float]?
        let actualEV: [Float]
        let frameIndices: [[UInt8]]
        let frameL: [FrameL]
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
    /// D1: the burst's ONE global palette — the first completed cycle's
    /// seed. Later cycles' per-frame indexing reads it off the serial chain.
    private var governingPalette: PaletteQ16?

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
        governingPalette = nil

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

    /// Burst → GIF89a: the 64-frame contract — every captured frame is its
    /// own GIF frame (EV-normalized, multi-scale demosaiced, indexed against
    /// the first cycle's seed) at 5 cs, so the loop replays the burst at
    /// capture speed.
    nonisolated private static func assembleGIF(from outcomes: [Outcome]) -> URL? {
        let ok = outcomes.filter { $0.ok && $0.bands != nil }.sorted { $0.index < $1.index }
        guard let first = ok.first?.bands else { return nil }
        let palRGB = Kernel.oklabQ16ToSRGB8(L: Array(first.L[0..<256]),
                                            a: Array(first.a[0..<256]),
                                            b: Array(first.b[0..<256]))

        let side = first.side
        let frames = ok.flatMap(\.frameIndices)
        guard !frames.isEmpty,
              frames.allSatisfy({ $0.count == side * side }),
              let gif = Kernel.gifEncode(frames: frames, side: side,
                                         paletteRGB: palRGB, delayCs: 5)
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
            // The governing palette exists once cycle 0 has finished — the
            // chain is serial, so any later cycle sees it here.
            let governing = await MainActor.run { self?.governingPalette }
            let outcome = Self.reduce(cycle, governing: governing)
            await MainActor.run { self?.finish(outcome) }
        }
        reductionTasks[cycle.index] = task
        chainTail = task
    }

    private func finish(_ outcome: Outcome) {
        outcomes.append(outcome)
        if governingPalette == nil, outcome.ok, let bands = outcome.bands {
            governingPalette = PaletteQ16(L: Array(bands.L[0..<256]),
                                          a: Array(bands.a[0..<256]),
                                          b: Array(bands.b[0..<256]))
        }
        blog.info("burst: cycle \(outcome.index + 1) reduced ok=\(outcome.ok) \(outcome.note, privacy: .public)")
    }

    /// The full L2 chain per cycle (BOREAL-16LAB-DESIGN.md):
    /// decode ×4 → crop S² → EV-aware fuse → demosaic → ProPhoto → linear
    /// box S²→256² → OKLab Q16 → pyramid ×3 → σ head.
    nonisolated static func reduce(_ cycle: Cycle,
                                   governing: PaletteQ16? = nil) -> Outcome {
        func fail(_ note: String) -> Outcome {
            Outcome(index: cycle.index, ok: false, note: note, bands: nil,
                    plan: nil, actualEV: [1, 1, 1, 1], frameIndices: [],
                    frameL: [])
        }

        // 1. Decode (pure-Swift DNG kernel; EXIF rides along for fuse).
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
        // The fused mosaic is scene-linear normalized; msEncode produces
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

        // PER-FRAME rendering (the 64-frame GIF contract): each frame
        // EV-normalized by its OWN e_t → multi-scale encode → ceiling-rung
        // decode → indexed against the governing palette (D1: the first
        // cycle's seed; cycle 0 governs itself).
        let pal = governing ?? PaletteQ16(L: Array(bands.L[0..<256]),
                                          a: Array(bands.a[0..<256]),
                                          b: Array(bands.b[0..<256]))
        var frameIndices: [[UInt8]] = []
        frameIndices.reserveCapacity(4)
        var frameL: [FrameL] = []
        frameL.reserveCapacity(4)
        for (j, frame) in cropped.enumerated() {
            let invE = actualEV[j] > 0 ? 1 / actualEV[j] : 1
            let mosaic = Kernel.normalizeMosaic(frame, invE: invE)
            guard let fs = Kernel.msEncode(mosaic: mosaic, side: side,
                                           cfa: ref.cfa, camToPP: ref.camToPP,
                                           hasColor: ref.hasColor),
                  let iL = Kernel.msDecode(fs.L, mosaicSide: side, rung: ceiling),
                  let iA = Kernel.msDecode(fs.a, mosaicSide: side, rung: ceiling),
                  let iB = Kernel.msDecode(fs.b, mosaicSide: side, rung: ceiling)
            else { return fail("per-frame render failed at frame \(j + 1)") }
            frameIndices.append(Kernel.indexMap(L: iL, a: iA, b: iB,
                                                palL: pal.L, palA: pal.a, palB: pal.b))
            // N0 fractal record: this frame's OWN 16² seed-L + its ceiling
            // L in the H2 patch-major structure (only defined at 256²).
            if ceiling == 256 {
                frameL.append(FrameL(seedL: Array(fs.L[0..<256]),
                                     patchesL: Kernel.patchMajor(iL)))
            }
        }

        return Outcome(index: cycle.index, ok: true,
                       note: "S=\(side) → multi-scale \(ceiling)² stack + 4 frames",
                       bands: bands, plan: plan, actualEV: actualEV,
                       frameIndices: frameIndices, frameL: frameL)
    }

    /// Largest 256·2^j ≤ min(width, height), capped at the spec canonical
    /// 2048 (CS1). nil when the sensor can't cover even the 256² ceiling.
    /// The math lives in GeometryKernel and is gate-verified against the
    /// geometry.json crop-case table.
    nonisolated private static func canonicalSide(width: Int, height: Int) -> Int? {
        Kernel.canonicalSide(width: width, height: height)
    }

    /// Center crop to side², origin snapped to EVEN coordinates so the CFA
    /// phase (and therefore frame.cfa) is preserved (CS7).
    nonisolated private static func cropCenter(_ f: Kernel.Frame, side: Int) -> Kernel.Frame {
        guard f.width != side || f.height != side else { return f }
        let x0 = Kernel.cropOrigin(f.width, side: side)
        let y0 = Kernel.cropOrigin(f.height, side: side)
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
    /// dither budget / resolution gate. The math lives in MultiScaleKernel
    /// (gate compile surface).
    nonisolated private static func sigmaGrid(mosaicSide: Int,
                                              channels: [[Int32]]) -> [Float] {
        Kernel.sigmaGrid(mosaicSide: mosaicSide, channels: channels)
    }
}
