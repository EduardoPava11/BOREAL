import Foundation

/// FuseKernel — faithful 1:1 Swift port of zig/borealkernel/src/fuse.zig
/// (the device-proven RGBT scene-linear fusion core, Phase 2 of the pivot;
/// see BOREAL-RGBT-HDR-WORKFLOW.md §2). SCALAR reference semantics only —
/// the Zig SIMD path computes the identical values (gated by the
/// "SIMD ≡ scalar" parity test); a Metal port replaces it later.
///
/// Per sample, frame t:
///   lin   = (raw − black) / (white − black)          normalized [0,1]
///   scene = lin / e_t                                 radiometric align
///   w     = lin · rolloff(lin)                        SNR-preference × saturation rolloff
///   rolloff(lin) = clamp((clip − lin)/(clip − knee), 0, 1)
///   out   = Σ w·scene / Σ w   (fallback to the darkest aligned sample if Σw≈0)
extension BorealKernels {

    /// Bracket spread below this ratio (~0.05 stop = 2^0.05) is treated as
    /// sensor shutter jitter → snap to equal exposure (pure temporal denoise).
    /// (Zig: EQUAL_EXPOSURE_RATIO)
    static let equalExposureRatio: Float = 1.0353

    /// Maximum relative exposure ratio (2^8 = 8 stops). Corruption guard, NOT
    /// a bracket limit — must sit ABOVE any realistic photographic bracket.
    /// (Zig: MAX_EXPOSURE_RATIO)
    static let maxExposureRatio: Float = 256.0

    /// SINGLE source of truth for per-frame relative exposure ratios e_t.
    ///
    /// Direction: DIVIDE, reference = the DARKEST frame (min photometric
    /// exposure), so every e_t >= 1 and the darkest frame → 1.0. Photometric
    /// exposure per frame: E = ISO * ExposureTime / FNumber^2. Ratio =
    /// E_t / min_k(E_k). NEVER inverted, NEVER normalized to frame 0.
    ///
    /// Three independent fallbacks each return EXACTLY {1,1,1,1}:
    ///   (1) any frame's ExposureTime absent/<=0 (sentinel 0 from the decoder),
    ///   (2) min photometric exposure <=0 / non-finite,
    ///   (3) bracket spread <= equalExposureRatio (~0.05 stop).
    /// ISO/FNumber absent (0) are treated as constant (1.0) so they cancel.
    /// Every returned e_t is clamped to [1.0, maxExposureRatio] and finite.
    static func relativeExposures(et: [Float], iso: [Float], fnum: [Float]) -> [Float] {
        guard et.count == 4, iso.count == 4, fnum.count == 4 else { return [1, 1, 1, 1] }
        var E = [Float](repeating: 0, count: 4)
        for t in 0..<4 {
            if !(et[t] > 0) { return [1, 1, 1, 1] } // absent/unreadable EXIF
            let s: Float = iso[t] > 0 ? iso[t] : 1.0
            let f2: Float = fnum[t] > 0 ? fnum[t] * fnum[t] : 1.0
            E[t] = et[t] * s / f2
        }

        var emin = E[0]
        for t in 1..<4 { emin = min(emin, E[t]) }
        if !(emin > 0) { return [1, 1, 1, 1] } // defensive: garbage rationals

        var out = [Float](repeating: 0, count: 4)
        var emax: Float = 1.0
        for t in 0..<4 {
            // Zig std.math.clamp(val, lo, hi) == @max(lo, @min(val, hi)).
            out[t] = max(1.0, min(E[t] / emin, maxExposureRatio))
            emax = max(emax, out[t])
        }
        if emax <= equalExposureRatio { return [1, 1, 1, 1] } // equal-exposure snap
        return out
    }

    /// Scalar per-sample weight — the reference the Zig SIMD path is tested
    /// against. SNR-preference (∝ lin) × saturation rolloff. (Zig: weightScalar)
    private static func fuseWeightScalar(_ lin: Float, _ knee: Float, _ clip: Float) -> Float {
        let span = clip - knee
        let roll = max(0.0, min((clip - lin) / span, 1.0))
        return max(lin, 0.0) * roll
    }

    /// Fuse 4 raw frames into one scene-linear f32 buffer. Faithful port of
    /// the Zig scalar-remainder loop (identical math to the SIMD main loop).
    /// Returns nil unless exactly 4 same-length frames (and 4 exposures) —
    /// the Swift-safe mapping of the Zig fixed [4][]const u16 + assert.
    static func fuse(frames: [[UInt16]], black: Float, white: Float,
                     exposures: [Float], knee: Float, clip: Float) -> [Float]? {
        guard frames.count == 4, exposures.count == 4 else { return nil }
        let n = frames[0].count
        for t in 1..<4 { if frames[t].count != n { return nil } }

        let blackS = black
        let invRangeS: Float = 1.0 / (white - black)
        var invES = [Float](repeating: 0, count: 4)
        for t in 0..<4 { invES[t] = 1.0 / exposures[t] }

        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var num: Float = 0
            var den: Float = 0
            var sceneMin = Float.greatestFiniteMagnitude
            for t in 0..<4 {
                let lin = (Float(frames[t][i]) - blackS) * invRangeS
                let scene = lin * invES[t]
                let w = fuseWeightScalar(lin, knee, clip)
                num += w * scene
                den += w
                sceneMin = min(sceneMin, scene)
            }
            // Defensive: if every frame was clipped or black here (Σw≈0),
            // fall back to the darkest aligned sample — finite, never NaN.
            out[i] = den > 1.0e-8 ? num / den : sceneMin
        }
        return out
    }

    /// Key test vectors ported from fuse.zig's own test blocks.
    static func fuseSelfTest() -> Bool {
        func approx(_ a: Float, _ b: Float, _ tol: Float) -> Bool { abs(a - b) <= tol }

        // "denoise identity: 4 equal frames at same exposure → that scene value"
        do {
            let f = [[UInt16]](repeating: [UInt16](repeating: 30000, count: 20), count: 4)
            guard let out = fuse(frames: f, black: 0, white: 65535,
                                 exposures: [1, 1, 1, 1], knee: 0.90, clip: 0.98) else { return false }
            let expect: Float = 30000.0 / 65535.0
            for v in out { if !approx(expect, v, 1e-4) { return false } }
        }

        // "clip rejection: a blown frame must not pollute the merge"
        do {
            let good = [UInt16](repeating: 30000, count: 8)
            let blown = [UInt16](repeating: 65535, count: 8)
            guard let out = fuse(frames: [good, blown, good, good], black: 0, white: 65535,
                                 exposures: [1, 1, 1, 1], knee: 0.90, clip: 0.98) else { return false }
            let expect: Float = 30000.0 / 65535.0
            for v in out { if !approx(expect, v, 1e-4) { return false } }
        }

        // "exposure: shutter-only 1-stop bracket" → {1,2,4,8}, min == 1
        do {
            let e = relativeExposures(et: [0.004, 0.008, 0.016, 0.032],
                                      iso: [0, 0, 0, 0], fnum: [0, 0, 0, 0])
            let want: [Float] = [1, 2, 4, 8]
            for t in 0..<4 {
                if !approx(want[t], e[t], 1e-4) { return false }
                if e[t] < 1.0 { return false }
            }
        }

        // "exposure: missing ExposureTime forces equal" → exactly {1,1,1,1}
        do {
            let e = relativeExposures(et: [0.004, 0, 0.016, 0.032],
                                      iso: [0, 0, 0, 0], fnum: [0, 0, 0, 0])
            if e != [1, 1, 1, 1] { return false }
        }

        return true
    }
}
