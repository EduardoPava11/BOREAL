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

    /// The cycle's temporal statistics (TB laws — the pivot): the noise
    /// meter ĝ, σ_time (D aggregated to the seed grid — the temporal twin
    /// of σ), and the D decile sketch. Full-resolution D stays on device;
    /// the seed grid + deciles are the bundle-sized summary.
    struct TemporalSummary: Sendable {
        let gain: Double
        let sigmaTime: [Double]      // seed² (16×16), row-major
        let dDeciles: [Double]       // 11 points: min, 10%…90%, max
    }

    /// Per-frame device facts for the bundle ("more precision"): the EXIF
    /// triple, the calibrated noise model, the maker's display-lift hint,
    /// and the censoring fractions at both rails (clipHi = y ≥ 0.98,
    /// subBlack = DN < black — the clamp-bias magnitude, per frame).
    struct FrameFact: Sendable {
        let width: Int, height: Int
        let iso: Float, exposureTime: Float, fNumber: Float
        let noiseS: Double, noiseO: Double
        let baselineExposure: Double
        let clipHiFrac: Double, subBlackFrac: Double
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
        let biases: [Float]              // the bracket the cycle was SHOT with
        let bands: Bands?
        let plan: [Float]?
        let actualEV: [Float]
        let frameIndices: [[UInt8]]
        let frameL: [FrameL]
        let temporal: TemporalSummary?
        let fusedMLE: Bool               // which fuse ran (MF laws vs classic)
        let frameFacts: [FrameFact]
        let ntSpread: Double             // NT self-check: neutral→ProPhoto
                                         //   relative channel spread (< 1e-5
                                         //   = the magenta law holding)
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
    /// G6: the burst report bundle (burst.json + frames.bin + fractal.bin +
    /// the GIF) — the corpus valve and the Mac-side judge's food. Published
    /// alongside `gifURL`.
    private(set) var reportURLs: [URL] = []
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
        reportURLs = []
        governingPalette = nil
        Perf.shared.reset()              // P0: this burst owns the perf record
        Diag.shared.reset()              // and its own narrative (log.txt)

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
                let tCap = ContinuousClock.now
                let dngs = try await camera.captureBracket()
                let capMs = Perf.msSince(tCap)
                Perf.shared.note("captureBracket", ms: capMs)
                Diag.shared.log("capture", String(format:
                    "cycle %d: 4 DNGs (%.1f MB) in %.0f ms, biases %@",
                    i + 1, Double(dngs.reduce(0) { $0 + $1.count }) / 1_048_576.0,
                    capMs, "\(biases)"))
                if (i + 1) % 4 == 0 { Perf.shared.sampleThermal("cycle-\(i + 1)") }
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
        Perf.shared.sampleThermal("burst-end")
        blog.info("burst: done — \(Self.cycleCount - dropped)/\(Self.cycleCount) cycles, \(self.outcomes.filter(\.ok).count) reduced ok")

        // Assemble the product bundle (G6): the GIF (one frame per captured
        // frame, D1 global table) + burst.json (EV traces, binomial stats,
        // churn, perf) + frames.bin/fractal.bin (the N0 corpus record).
        let snapshot = outcomes
        let bundle = await Task.detached(priority: .userInitiated) {
            Self.assembleBundle(from: snapshot)
        }.value
        gifURL = bundle.gif
        reportURLs = bundle.urls
    }

    /// Burst → GIF89a + report bundle (G6). The GIF keeps the 64-frame
    /// contract — every captured frame is its own GIF frame (EV-normalized,
    /// multi-scale demosaiced, indexed against the first cycle's seed) at
    /// 5 cs. Around it, the bundle packages what the Mac side needs:
    ///
    ///   burst.json   per-cycle EV traces (shot biases, EXIF-actual ratios,
    ///                next ETTR plan), per-frame χ²/homeShare, inter-frame
    ///                churn, seed palette, σ grids, per-frame seed-L, and
    ///                the P0 perf block (stage ms, GPU ms, thermal,
    ///                peak footprint)
    ///   frames.bin   the 64 ceiling-rung GIF index maps, raw u8, GIF frame
    ///                order — deltas/χ² are recomputable exactly from this
    ///   fractal.bin  per-frame patch-major L planes (H2), Int32 native-LE
    ///                — with seedL in the JSON this is the N0 record
    ///   burst.gif    the product itself
    ///
    /// The 64 source DNGs stay OUT (the ~1.6 GB cliff); the single-cycle
    /// bundle remains the photon-exact replay artifact.
    nonisolated private static func assembleBundle(from outcomes: [Outcome])
        -> (gif: URL?, urls: [URL]) {
        let ok = outcomes.filter { $0.ok && $0.bands != nil }.sorted { $0.index < $1.index }
        guard let first = ok.first?.bands else { return (nil, []) }
        let palL = BorealKernels.rotateCW(Array(first.L[0..<256]), side: 16)
        let palA = BorealKernels.rotateCW(Array(first.a[0..<256]), side: 16)
        let palB = BorealKernels.rotateCW(Array(first.b[0..<256]), side: 16)
        let palRGB = Kernel.oklabQ16ToSRGB8(L: palL, a: palA, b: palB)

        let side = first.side
        let frames = ok.flatMap(\.frameIndices)
        guard !frames.isEmpty,
              frames.allSatisfy({ $0.count == side * side }),
              let gif = Kernel.gifEncode(frames: frames, side: side,
                                         paletteRGB: palRGB, delayCs: 5)
        else { return (nil, []) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(BundleStamp.bundleName("BOREAL-burst"))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var urls: [URL] = []

            let gifURL = dir.appendingPathComponent("burst.gif")
            try gif.write(to: gifURL)

            // frames.bin — the exact GIF frame payloads; everything derived
            // from index maps (deltas, χ², homeShare) is recomputable from
            // this, so burst.json carries summaries, not lists.
            var framesBin = Data(capacity: frames.count * side * side)
            for f in frames { framesBin.append(contentsOf: f) }
            let framesURL = dir.appendingPathComponent("frames.bin")
            try framesBin.write(to: framesURL)

            // fractal.bin — patch-major L planes (H2), one 65,536×Int32
            // plane per frame, cycles ascending, frames in capture order.
            let fractalFrames = ok.flatMap(\.frameL)
            var fractalURL: URL?
            if !fractalFrames.isEmpty {
                var bin = Data(capacity: fractalFrames.count * 65536 * 4)
                for f in fractalFrames {
                    f.patchesL.withUnsafeBufferPointer {
                        bin.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self))
                    }
                }
                let u = dir.appendingPathComponent("fractal.bin")
                try bin.write(to: u)
                fractalURL = u
            }

            // Inter-frame churn across the whole burst (within AND across
            // cycles) — counts only; frames.bin holds the exact lists.
            var churn: [Int] = []
            churn.reserveCapacity(max(0, frames.count - 1))
            for t in 0..<max(0, frames.count - 1) {
                churn.append(Kernel.frameDelta(frames[t], frames[t + 1]).pos.count)
            }

            var json: [String: Any] = [
                "design": "BOREAL-METAL-PRECISION-WORKFLOW.md P0 (G6 closure); frames indexed against D1's global seed (cycle 0)",
                "side": side,
                "mosaicSide": first.mosaicSide,
                "frameCount": frames.count,
                "cyclesOK": ok.count,
                "cyclesTotal": outcomes.count,
                "palette": [
                    "q16L": palL.map(Int.init), "q16a": palA.map(Int.init),
                    "q16b": palB.map(Int.init), "rgb8": palRGB.map(Int.init),
                ],
                "files": [
                    "frames.bin": "u8 index maps, \(frames.count) × \(side)×\(side), GIF frame order (ok cycles ascending, 4 frames per cycle)",
                    "fractal.bin": fractalFrames.isEmpty
                        ? "ABSENT (ceiling < 256 — fractal record undefined)"
                        : "Int32 little-endian patch-major L planes (H2), \(fractalFrames.count) × 65536, same frame order",
                ],
                "churn": ["note": "BA5 defection counts between consecutive burst frames (t → t+1); exact lists recomputable from frames.bin",
                          "counts": churn],
                "cycles": ok.map { oc -> [String: Any] in
                    var entry: [String: Any] = [
                        "index": oc.index,
                        "note": oc.note,
                        "fuse": oc.fusedMLE ? "mle" : "classic",
                        "ntSpread": oc.ntSpread,
                        "frames": oc.frameFacts.map { ff -> [String: Any] in
                            ["iso": Double(ff.iso),
                             "exposureTime": Double(ff.exposureTime),
                             "fNumber": Double(ff.fNumber),
                             "noiseS": ff.noiseS, "noiseO": ff.noiseO,
                             "baselineExposure": ff.baselineExposure,
                             "clipHiFrac": ff.clipHiFrac,
                             "subBlackFrac": ff.subBlackFrac]
                        },
                        "shotBiases": oc.biases.map { Double($0) },
                        "actualRatios": oc.actualEV.map { Double($0) },
                        "nextPlan": (oc.plan ?? []).map { Double($0) },
                        "seedL": oc.frameL.map { $0.seedL.map(Int.init) },
                    ]
                    if let bands = oc.bands {
                        entry["sigma"] = bands.sigma.map { Double($0) }
                    }
                    if let t = oc.temporal {
                        entry["temporal"] = ["gain": t.gain,
                                             "sigmaTime": t.sigmaTime,
                                             "dDeciles": t.dDeciles]
                    }
                    return entry
                },
                "dropped": outcomes.filter { !$0.ok }.map {
                    ["index": $0.index, "note": $0.note] as [String: Any]
                },
                // The binomial readout per frame — the judge's headline
                // numbers (chi² balance + H-structure at the ceiling).
                "binomial": frames.enumerated().map { t, f -> [String: Any] in
                    var entry: [String: Any] = [
                        "frame": t,
                        "chi2": BorealKernels.indexChiSquare(f),
                    ]
                    if let hs = BorealKernels.homeShare(f) { entry["homeShare"] = hs }
                    return entry
                },
                "perf": Perf.shared.reportBlock(),
            ]
            json["ev"] = ["note": "per-cycle traces live in cycles[]; shotBiases = the bracket sent to AVFoundation, actualRatios = EXIF-derived, nextPlan = raw ETTR solve (pre-clamp)"]
            for (k, v) in BundleStamp.dict() { json[k] = v }

            let logURL = dir.appendingPathComponent("log.txt")
            try Diag.shared.drain().write(to: logURL, atomically: true, encoding: .utf8)

            let jsonURL = dir.appendingPathComponent("burst.json")
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try data.write(to: jsonURL)

            // THE PREVIEW (TF1.1), then the integrity manifest (TF1.4).
            let previewURL = dir.appendingPathComponent("preview.html")
            try PreviewHTML.burstPage(json: json, dir: dir)
                .write(to: previewURL, atomically: true, encoding: .utf8)

            urls = [previewURL, jsonURL, logURL, framesURL]
            if let f = fractalURL { urls.append(f) }
            urls.append(gifURL)

            let manifestURL = dir.appendingPathComponent("manifest.json")
            try JSONSerialization.data(
                withJSONObject: BundleStamp.manifest(of: urls),
                options: [.sortedKeys]).write(to: manifestURL)
            urls.append(manifestURL)
            return (gifURL, urls)
        } catch {
            blog.error("burst: bundle write failed: \(error.localizedDescription, privacy: .public)")
            return (nil, [])
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
            let outcome = Perf.shared.time("cycleReduce") {
                Self.reduce(cycle, governing: governing)
            }
            await MainActor.run { self?.finish(outcome) }
        }
        reductionTasks[cycle.index] = task
        chainTail = task
    }

    private func finish(_ outcome: Outcome) {
        outcomes.append(outcome)
        if governingPalette == nil, outcome.ok, let bands = outcome.bands {
            governingPalette = PaletteQ16(
                L: BorealKernels.rotateCW(Array(bands.L[0..<256]), side: 16),
                a: BorealKernels.rotateCW(Array(bands.a[0..<256]), side: 16),
                b: BorealKernels.rotateCW(Array(bands.b[0..<256]), side: 16))
        }
        blog.info("burst: cycle \(outcome.index + 1) reduced ok=\(outcome.ok) \(outcome.note, privacy: .public)")
    }

    /// The full L2 chain per cycle (BOREAL-16LAB-DESIGN.md):
    /// decode ×4 → crop S² → EV-aware fuse → demosaic → ProPhoto → linear
    /// box S²→256² → OKLab Q16 → pyramid ×3 → σ head.
    nonisolated static func reduce(_ cycle: Cycle,
                                   governing: PaletteQ16? = nil) -> Outcome {
        func fail(_ note: String) -> Outcome {
            Outcome(index: cycle.index, ok: false, note: note,
                    biases: cycle.biases, bands: nil,
                    plan: nil, actualEV: [1, 1, 1, 1], frameIndices: [],
                    frameL: [], temporal: nil, fusedMLE: false,
                    frameFacts: [], ntSpread: 0)
        }

        // 1. Decode (pure-Swift DNG kernel; EXIF rides along for fuse).
        //    The 4 decodes are independent — run them CONCURRENTLY
        //    (bundle-6 timeline: serial decode was 11.5 s of a 23.2 s
        //    cycle; the Gantt in the next bundle shows the overlap).
        //    Distinct output indices → data-race-free (the msComputeRung
        //    pattern); Diag/Perf are lock-protected. Footprint note: up to
        //    4 decode working sets overlap — the bundle's footprint chip
        //    polices the 350 MB law in the field; dial to 2-way if it
        //    ever trips.
        guard cycle.dngs.count == 4 else {
            return fail("expected 4 DNGs, got \(cycle.dngs.count)")
        }
        let dngs = cycle.dngs
        var decoded = [(frame: Kernel.Frame?, status: Int32)](repeating: (nil, 0),
                                                              count: 4)
        decoded.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: 4) { j in
                buf[j] = Kernel.decodeDNG(dngs[j])
            }
        }
        var frames: [Kernel.Frame] = []
        frames.reserveCapacity(4)
        for j in 0..<4 {
            guard let frame = decoded[j].frame else {
                let status = decoded[j].status
                Diag.shared.log("decode", "cycle \(cycle.index + 1) frame \(j + 1) FAILED: \(Kernel.statusName(status))")
                return fail("frame \(j + 1) undecodable: \(Kernel.statusName(status))")
            }
            Diag.shared.log("decode", String(format:
                "cycle %d frame %d: %dx%d cfa=%d iso=%.0f et=1/%.0f f=%.2f S=%.4e O=%.3e blExp=%.3f",
                cycle.index + 1, j + 1, frame.width, frame.height, frame.cfa,
                frame.iso, frame.exposureTime > 0 ? 1 / frame.exposureTime : 0,
                frame.fNumber, frame.noiseS, frame.noiseO, frame.baselineExposure))
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
        Diag.shared.log("ev", "cycle \(cycle.index + 1) actual=\(actualEV) plan=\(plan)")

        // Per-frame device facts ("more precision"): rail censoring
        // fractions on the CROPPED mosaic + the calibrated metadata.
        let clipDN = UInt16((Double(ref.black) + 0.98 * (Double(ref.white) - Double(ref.black))).rounded())
        let blackDN = UInt16(ref.black)
        let frameFacts: [FrameFact] = cropped.map { f in
            var hi = 0, lo = 0
            f.samples.withUnsafeBufferPointer { p in
                for v in p {
                    if v >= clipDN { hi += 1 } else if v < blackDN { lo += 1 }
                }
            }
            let n = Double(f.samples.count)
            return FrameFact(width: f.width, height: f.height,
                             iso: f.iso, exposureTime: f.exposureTime,
                             fNumber: f.fNumber,
                             noiseS: f.noiseS, noiseO: f.noiseO,
                             baselineExposure: f.baselineExposure,
                             clipHiFrac: Double(hi) / n,
                             subBlackFrac: Double(lo) / n)
        }
        for (j, ff) in frameFacts.enumerated() {
            Diag.shared.log("rails", String(format:
                "cycle %d frame %d: clipHi %.5f subBlack %.5f",
                cycle.index + 1, j + 1, ff.clipHiFrac, ff.subBlackFrac))
        }

        // NT self-check (the magenta law, on device, every cycle): the
        // composed matrix must map AsShotNeutral to gray.
        var ntSpread = 0.0
        if ref.hasColor {
            let n = BorealKernels.apply3d(ref.camToPP.map(Double.init), ref.asn)
            let mx = max(n.0, max(n.1, n.2)), mn = min(n.0, min(n.1, n.2))
            if mx > 0 { ntSpread = (mx - mn) / mx }
            Diag.shared.log("nt", String(format: "cycle %d neutral spread %.3e %@",
                                         cycle.index + 1, ntSpread,
                                         ntSpread < 1e-5 ? "OK" : "VIOLATED"))
        }

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
        // σ head rotated to portrait with the render (the stack itself
        // stays sensor-native — prefix-decoders rotate after decode).
        let bands = Bands(mosaicSide: side, side: ceiling,
                          L: stacks.L, a: stacks.a, b: stacks.b,
                          sigma: BorealKernels.rotateCW(
                              sigmaGrid(mosaicSide: side,
                                        channels: [stacks.L, stacks.a, stacks.b]),
                              side: 16))

        // PER-FRAME rendering (the 64-frame GIF contract): each frame
        // EV-normalized by its OWN e_t → multi-scale encode → ceiling-rung
        // decode → indexed against the governing palette (D1: the first
        // cycle's seed; cycle 0 governs itself).
        // Palette ORDER rotates with the render (same colors): homeShare
        // pairs spatial patch p with palette entry p, so the seed grid and
        // the frames must share one orientation — portrait.
        let pal = governing ?? PaletteQ16(
            L: BorealKernels.rotateCW(Array(bands.L[0..<256]), side: 16),
            a: BorealKernels.rotateCW(Array(bands.a[0..<256]), side: 16),
            b: BorealKernels.rotateCW(Array(bands.b[0..<256]), side: 16))
        var frameIndices: [[UInt8]] = []
        frameIndices.reserveCapacity(4)
        var frameL: [FrameL] = []
        frameL.reserveCapacity(4)
        var tbMeans: [(r: [Double], g: [Double], b: [Double])] = []
        tbMeans.reserveCapacity(4)
        // Render ceiling = the ladder top (512 at canonical 2048 — the GIF
        // frame); MODEL rung = 256 when present (H2/N0/bell domain — the
        // fractal record's home, a prefix of the stack).
        let model = Kernel.msRungs(side: side).contains(256) ? 256 : ceiling
        for (j, frame) in cropped.enumerated() {
            let invE = actualEV[j] > 0 ? 1 / actualEV[j] : 1
            let mosaic = Kernel.normalizeMosaic(frame, invE: invE)
            // TB (the pivot): per-frame render-ceiling channel means, taken
            // while THIS frame's mosaic is alive — the cycle statistics
            // need all 4 but never 4 mosaics at once.
            tbMeans.append(Kernel.tbChannelMeans(mosaic, side: side,
                                                 rung: ceiling, cfa: ref.cfa))
            // Fast path: direct {seed, model, ceiling} rungs — each
            // bit-identical to the full encode→decode (MS3 corollary,
            // gate-checked), 3 mosaic passes instead of the full ladder.
            let chromaRung = min(BorealKernels.renderChromaRung, ceiling)
            guard let planes = Kernel.msDirect(mosaic: mosaic, side: side,
                                               cfa: ref.cfa, camToPP: ref.camToPP,
                                               hasColor: ref.hasColor,
                                               rungs: [16, chromaRung, model, ceiling]),
                  let ceil = planes[ceiling], let seedP = planes[16],
                  let modelP = planes[model], let chromaP = planes[chromaRung]
            else { return fail("per-frame render failed at frame \(j + 1)") }
            // RENDER-CHROMA split (bundle-5 verdict): luma at the ceiling,
            // a/b from the coarse chroma rung (its own demosaic — larger
            // cells, exact carrier nulling → screen-moiré false color cut
            // 3.5×), nearest-upscaled. Then PORTRAIT rotation (2026-07-19):
            // every product artifact downstream is portrait-consistent.
            let cL = BorealKernels.rotateCW(ceil.L, side: ceiling)
            let cA = BorealKernels.rotateCW(
                BorealKernels.upscalePlane(chromaP.a, from: chromaRung, to: ceiling),
                side: ceiling)
            let cB = BorealKernels.rotateCW(
                BorealKernels.upscalePlane(chromaP.b, from: chromaRung, to: ceiling),
                side: ceiling)
            frameIndices.append(Kernel.indexMap(L: cL, a: cA, b: cB,
                                                palL: pal.L, palA: pal.a, palB: pal.b))
            // N0 fractal record: this frame's OWN 16² seed-L + its MODEL-rung
            // L in the H2 patch-major structure (defined at 256² only) —
            // rotated with the render so the record matches frames.bin.
            if model == 256 {
                frameL.append(FrameL(seedL: BorealKernels.rotateCW(seedP.L, side: 16),
                                     patchesL: Kernel.patchMajor(
                                        BorealKernels.rotateCW(modelP.L, side: 256))))
            }
        }

        // TB (the pivot): the cycle's noise meter + alias discriminator +
        // σ_time, from the per-frame means (gate-verified kernel).
        var temporal: TemporalSummary?
        if ceiling % 16 == 0,
           let ts = Kernel.temporalStats(perFrameMeans: tbMeans,
                                         cellSide: side / ceiling,
                                         exposures: actualEV.map(Double.init),
                                         rung: ceiling, seed: 16) {
            let sorted = ts.d.sorted()
            let deciles = (0...10).map {
                sorted[min(sorted.count - 1, $0 * sorted.count / 10)]
            }
            temporal = TemporalSummary(gain: ts.gain,
                                       sigmaTime: BorealKernels.rotateCW(
                                           ts.sigmaTime, side: 16),
                                       dDeciles: deciles)
        }

        let usedMLE = Kernel.fuseIsMLE(cropped)
        Diag.shared.log("reduce", String(format:
            "cycle %d done: S=%d ceiling=%d fuse=%@ ghat=%.4e",
            cycle.index + 1, side, ceiling, usedMLE ? "mle" : "classic",
            temporal?.gain ?? 0))
        return Outcome(index: cycle.index, ok: true,
                       note: "S=\(side) → multi-scale \(ceiling)² stack + 4 frames"
                           + " [fuse: \(usedMLE ? "mle" : "classic")]",
                       biases: cycle.biases,
                       bands: bands, plan: plan, actualEV: actualEV,
                       frameIndices: frameIndices, frameL: frameL,
                       temporal: temporal, fusedMLE: usedMLE,
                       frameFacts: frameFacts, ntSpread: ntSpread)
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
