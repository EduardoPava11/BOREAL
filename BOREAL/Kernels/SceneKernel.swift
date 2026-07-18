import Foundation

/// SceneKernel — faithful 1:1 Swift port of zig/borealkernel/src/scene.zig
/// (Stage A scene analysis + Stage B exposure planning for the RGBT → HDR
/// pivot; see BOREAL-RGBT-HDR-WORKFLOW.md §1). SCALAR reference semantics —
/// the Zig SIMD scanChannel is a perf-only companion and is not ported.
///
/// ANALYZE: per-channel histograms of a RAW mosaic (or BGRA preview) locate
/// each channel's bright tail. PLAN: those tails become 4 exposure offsets so
/// each of R/G/B gets its own ETTR frame, plus a shadow-floor frame for DR.
/// Values are normalized so 1.0 == sensor white.
extension BorealKernels {

    // ── Tunable constants (the ETTR policy) — values verbatim from scene.zig ──

    /// Bins across the normalized [0,1] range (~10 bits of tonal precision).
    static let sceneNBins: Int = 1024
    /// ETTR aim point: push a channel's bright tail to 95% of clip.
    static let ettrTarget: Float = 0.95
    /// Quantile used as the "bright tail" (top 0.5% = tolerated speculars).
    static let qBright: Float = 0.995
    /// Quantile used as the "shadow level" when sizing the shadow-floor frame.
    static let qShadow: Float = 0.02
    /// A channel whose bright tail is below this is essentially absent.
    static let presenceFloor: Float = 0.02
    /// Where the shadow-floor frame aims to lift the darkest real tones.
    static let shadowAim: Float = 0.25
    /// Clamp on how far any single ETTR push may go, both directions (stops).
    static let maxPush: Float = 5.0
    /// Shadow frame is at least/at most this many stops beyond the green frame.
    static let shadowAddMin: Float = 1.0
    static let shadowAddMax: Float = 4.0

    // ── Histogram primitive (Zig: Histogram) ─────────────────────────────────

    /// A fixed-bin histogram over normalized [0,1]. One per color channel.
    struct SceneHistogram {
        var bins = [UInt32](repeating: 0, count: BorealKernels.sceneNBins)
        var count: UInt64 = 0

        /// Add one normalized sample. Out-of-range values are clamped into the
        /// end bins (negatives → bin 0, ≥1 → top bin).
        mutating func add(_ valueNorm: Float) {
            let v = max(0.0, min(valueNorm, 1.0))
            var idx = Int(v * Float(BorealKernels.sceneNBins)) // trunc, as Zig @intFromFloat
            if idx >= BorealKernels.sceneNBins { idx = BorealKernels.sceneNBins - 1 }
            bins[idx] += 1
            count += 1
        }

        /// Value (normalized) at cumulative fraction q ∈ [0,1]. Walks the CDF
        /// and returns the center of the bin where the quantile is crossed.
        /// f64 cumulant keeps it exact for large pixel counts. Empty → 0.
        func percentile(_ q: Float) -> Float {
            if count == 0 { return 0 }
            let target = Double(count) * Double(q)
            var cum: Double = 0
            for i in 0..<BorealKernels.sceneNBins {
                cum += Double(bins[i])
                if cum >= target { return BorealKernels.sceneBinCenter(i) }
            }
            return BorealKernels.sceneBinCenter(BorealKernels.sceneNBins - 1)
        }
    }

    private static func sceneBinCenter(_ i: Int) -> Float {
        return (Float(i) + 0.5) / Float(sceneNBins)
    }

    /// Stops of exposure change to bring a bright tail at `pHi` up to `target`.
    /// Positive = channel is dark, needs more light; negative = near clip, pull
    /// down. Clamped to ±maxPush. A floor on `pHi` avoids log of zero.
    static func roomStops(_ pHi: Float, _ target: Float) -> Float {
        let p = max(pHi, 1.0e-4)
        return max(-maxPush, min(log2(target / p), maxPush))
    }

    // ── Stage A output (Zig: SceneClips) ─────────────────────────────────────

    /// Per-channel ETTR headroom for the current scene + shadow-frame depth.
    struct SceneClips: Sendable {
        var roomR: Float; var roomG: Float; var roomB: Float
        var shadowDepth: Float
        var presentR: Bool; var presentG: Bool; var presentB: Bool
    }

    /// Core Stage A: three per-channel histograms → SceneClips. Pure.
    static func solveClips(hr: SceneHistogram, hg: SceneHistogram, hb: SceneHistogram) -> SceneClips {
        let hiR = hr.percentile(qBright)
        let hiG = hg.percentile(qBright)
        let hiB = hb.percentile(qBright)

        let presentR = hiR >= presenceFloor
        let presentG = hiG >= presenceFloor
        let presentB = hiB >= presenceFloor

        let roomG: Float = presentG ? roomStops(hiG, ettrTarget) : 0.0

        // Shadow-floor frame: lift the dark tail (green = luminance proxy)
        // toward shadowAim, measured BEYOND the green-ETTR push of f1.
        let loG = hg.percentile(qShadow)
        let wantTotal = roomStops(max(loG, 1.0e-4), shadowAim)
        let shadowDepth = max(shadowAddMin, min(wantTotal - roomG, shadowAddMax))

        return SceneClips(
            roomR: presentR ? roomStops(hiR, ettrTarget) : 0.0,
            roomG: roomG,
            roomB: presentB ? roomStops(hiB, ettrTarget) : 0.0,
            shadowDepth: shadowDepth,
            presentR: presentR,
            presentG: presentG,
            presentB: presentB
        )
    }

    // ── Stage B (Zig: planExposures) ─────────────────────────────────────────

    /// SceneClips → the 4-frame plan as [green, red, blue, shadow] EV offsets
    /// (stops from the base exposure). For a present channel, its frame sits
    /// at that channel's own measured room. For an ABSENT channel, fall back
    /// to the white-balance prior: log2(wb_c/wb_g) more stops than green.
    /// `extraShadow` adds to the shadow frame (caller knob; 0 = use clips).
    static func planExposures(clips: SceneClips, wb: (r: Float, g: Float, b: Float),
                              extraShadow: Float) -> [Float] {
        let wbG = max(wb.g, 1.0e-4)
        let evG = clips.roomG

        let evR: Float = clips.presentR
            ? clips.roomR
            : evG + max(-maxPush, min(log2(max(wb.r, 1.0e-4) / wbG), maxPush))

        let evB: Float = clips.presentB
            ? clips.roomB
            : evG + max(-maxPush, min(log2(max(wb.b, 1.0e-4) / wbG), maxPush))

        return [evG, evR, evB, evG + clips.shadowDepth + extraShadow]
    }

    // ── Buffer drivers ───────────────────────────────────────────────────────

    /// Analyze a RAW Bayer mosaic directly → ETTR clips. CFA walk: green at
    /// the off-diagonal sites, red/blue at the corners (swapped for BGGR) —
    /// normalized by the sensor's black/white (NO white balance, so tails
    /// read TRUE per-channel exposure). (Zig: analyzeMosaic)
    static func analyzeMosaic(samples: [UInt16], width: Int, height: Int,
                              cfa: UInt32, black: Float, white: Float) -> SceneClips {
        var hr = SceneHistogram()
        var hg = SceneHistogram()
        var hb = SceneHistogram()
        let range = max(white - black, 1.0)
        let inv: Float = 1.0 / range
        let isRGGB = cfa == 0

        for y in 0..<height {
            let py = y & 1
            let row = y * width
            for x in 0..<width {
                let s = Float(samples[row + x])
                let v = max(0.0, min((s - black) * inv, 1.0))
                let px = x & 1
                if py == 0 && px == 0 {
                    if isRGGB { hr.add(v) } else { hb.add(v) }
                } else if py == 1 && px == 1 {
                    if isRGGB { hb.add(v) } else { hr.add(v) }
                } else {
                    hg.add(v)
                }
            }
        }
        return solveClips(hr: hr, hg: hg, hb: hb)
    }

    /// Map a normalized [0,1] value to a bin index, clamping ≥1 (and the top
    /// bin) so a clipped (255) sample piles into the last bin. (Zig: binIdx)
    private static func sceneBinIdx(_ v: Float, _ scale: Float, _ nb: Int) -> Int {
        let cl = max(0.0, min(v, 1.0))
        var idx = Int(cl * scale)
        if idx >= nb { idx = nb - 1 }
        return idx
    }

    /// Three per-channel display histograms straight from an interleaved 8-bit
    /// BGRA video frame (live preview feed). Each channel normalized by /255 —
    /// NO sensor black/white and NO white balance (display/gamma space); this
    /// is a relative pre-shutter exposure guide. Do NOT "fix" it to use
    /// black/white levels. `rowStride` is bytesPerRow IN BYTES — CVPixelBuffer
    /// pads rows past width*4, so we MUST stride by rowStride, not width*4.
    /// Byte order BGRA: B=o, G=o+1, R=o+2, A=o+3 (alpha skipped).
    /// bins == 0 → three empty arrays (Zig: no-op). (Zig: rgbHistograms)
    static func rgbHistograms(bgra: UnsafePointer<UInt8>, width: Int, height: Int,
                              rowStride: Int, bins: Int) -> (r: [UInt32], g: [UInt32], b: [UInt32]) {
        if bins == 0 { return ([], [], []) }
        var outR = [UInt32](repeating: 0, count: bins)
        var outG = [UInt32](repeating: 0, count: bins)
        var outB = [UInt32](repeating: 0, count: bins)

        let inv255: Float = 1.0 / 255.0
        let scale = Float(bins)

        for y in 0..<height {
            let rowBase = y * rowStride // BYTES — honors CVPixelBuffer row padding
            for x in 0..<width {
                let o = rowBase + x * 4
                let b = Float(bgra[o + 0]) * inv255
                let g = Float(bgra[o + 1]) * inv255
                let r = Float(bgra[o + 2]) * inv255
                // A = bgra[o + 3] — skipped.
                outB[sceneBinIdx(b, scale, bins)] += 1
                outG[sceneBinIdx(g, scale, bins)] += 1
                outR[sceneBinIdx(r, scale, bins)] += 1
            }
        }
        return (outR, outG, outB)
    }

    /// Key test vectors ported from scene.zig's own test blocks.
    static func sceneSelfTest() -> Bool {
        func approx(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

        // "roomStops: mid-gray 0.5 → ~+0.926 stops" (and the at-target anchor)
        if !approx(0.926, roomStops(0.5, ettrTarget), 0.02) { return false }
        if !approx(0.0, roomStops(ettrTarget, ettrTarget), 1e-4) { return false }

        // "analyzeMosaic: flat mid-gray mosaic → all channels present, room > 0"
        do {
            let m = [UInt16](repeating: 8000, count: 64 * 64)
            let clips = analyzeMosaic(samples: m, width: 64, height: 64,
                                      cfa: 0, black: 512, white: 16383)
            if !(clips.presentR && clips.presentG && clips.presentB) { return false }
            if !(clips.roomG > 0) { return false }
            if !approx(clips.roomR, clips.roomG, 1e-4) { return false }
        }

        // "analyzeMosaic: clipped green pulls its room negative"
        do {
            var m = [UInt16](repeating: 0, count: 64 * 64)
            for y in 0..<64 {
                for x in 0..<64 {
                    let green = ((y & 1) + (x & 1)) == 1
                    m[y * 64 + x] = green ? 16383 : 8000
                }
            }
            let clips = analyzeMosaic(samples: m, width: 64, height: 64,
                                      cfa: 0, black: 512, white: 16383)
            if !(clips.roomG < 0) { return false }
            if !(clips.roomR > 0) { return false }
        }

        // "plan: green frame at room_g, shadow frame beyond it"
        do {
            let c = SceneClips(roomR: 1.0, roomG: 0.2, roomB: 0.6, shadowDepth: 2.0,
                               presentR: true, presentG: true, presentB: true)
            let p = planExposures(clips: c, wb: (r: 2.0, g: 1.0, b: 1.5), extraShadow: 0)
            if !approx(0.2, p[0], 1e-5) { return false }
            if !approx(1.0, p[1], 1e-5) { return false }
            if !approx(0.6, p[2], 1e-5) { return false }
            if !approx(2.2, p[3], 1e-5) { return false } // room_g + shadow_depth
            if !(p[3] > p[0]) { return false }
        }

        return true
    }
}
