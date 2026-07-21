import Foundation

/// FuseMLEKernel — the maximum-likelihood bracket fuse (Boreal.FuseMLE,
/// MF laws; D11 answered by BOREAL-RAW-LIKELIHOOD-RESEARCH.md §6).
///
/// Weights are the physics: w_i = e_i²/(S_i·max(y_i,0) + O_i) — the
/// inverse variance of each frame's scene estimate under the sensor's
/// own Poisson-Gaussian model, with (S_i, O_i) read per frame from the
/// DNG NoiseProfile tag (Apple calibrates it per capture, including the
/// dual-conversion-gain break at high ISO). Samples at/above `clip`
/// are CENSORED (weight zero — a likelihood statement, not a rolloff);
/// an all-censored sample falls back to the darkest frame's estimate.
///
/// Relation to the shipped knee/clip fuse: for a fixed pixel the old
/// w = lin is proportional to the SHOT-LIMITED MLE weight (MF2), so the
/// two agree in midtones; the MLE fuse corrects exactly where the
/// physics differs — deep shadows (read floor: w ∝ e², MF3), per-frame
/// gain breaks, and censoring semantics. The classic fuse remains the
/// gated fallback when any frame lacks a NoiseProfile (circuit A2).
///
/// Op shapes pinned to the spec (f64, frame-order accumulation);
/// verified bitwise against mlefuse_golden.json by the gate.
extension BorealKernels {

    /// One sample's fused scene value from per-frame observations
    /// (y = DNG-normalized value, e = relative exposure, S/O = profile).
    static func fuseSampleMLE(clip: Double,
                              obs: [(y: Double, e: Double, s: Double, o: Double)])
        -> Double {
        var num = 0.0, den = 0.0
        for ob in obs {
            let w = ob.y >= clip ? 0.0 : ob.e * ob.e / (ob.s * max(ob.y, 0) + ob.o)
            num += w * (ob.y / ob.e)
            den += w
        }
        if den > 0 { return num / den }
        guard !obs.isEmpty else { return 0 }
        var eMin = obs[0].e
        for ob in obs { eMin = min(eMin, ob.e) }
        for ob in obs where ob.e == eMin { return ob.y / ob.e }
        return 0
    }

    /// Fuse 4 raw frames into one scene-linear f32 buffer by per-sample
    /// inverse-variance MLE. Same contract as `fuse` (nil unless 4
    /// same-length frames); `profiles` are per-frame (S, O) from the
    /// DNG NoiseProfile — every S must be > 0 and O > 0 (callers route
    /// to the classic fuse otherwise).
    static func fuseMLE(frames: [[UInt16]], black: Float, white: Float,
                        exposures: [Float], profiles: [(s: Double, o: Double)],
                        clip: Double) -> [Float]? {
        guard frames.count == 4, exposures.count == 4, profiles.count == 4,
              profiles.allSatisfy({ $0.s > 0 && $0.o > 0 }) else { return nil }
        let n = frames[0].count
        for t in 1..<4 { if frames[t].count != n { return nil } }

        let blackD = Double(black)
        let invRange = 1.0 / (Double(white) - blackD)
        let e = exposures.map(Double.init)

        var out = [Float](repeating: 0, count: n)
        frames[0].withUnsafeBufferPointer { f0 in
            frames[1].withUnsafeBufferPointer { f1 in
                frames[2].withUnsafeBufferPointer { f2 in
                    frames[3].withUnsafeBufferPointer { f3 in
                        let fs = [f0, f1, f2, f3]
                        out.withUnsafeMutableBufferPointer { op in
                            for i in 0..<n {
                                var num = 0.0, den = 0.0
                                for t in 0..<4 {
                                    let y = (Double(fs[t][i]) - blackD) * invRange
                                    let w = y >= clip
                                        ? 0.0
                                        : e[t] * e[t] / (profiles[t].s * max(y, 0) + profiles[t].o)
                                    num += w * (y / e[t])
                                    den += w
                                }
                                if den > 0 {
                                    op[i] = Float(num / den)
                                } else {
                                    // all censored → darkest frame's estimate
                                    var eMin = e[0]
                                    var tMin = 0
                                    for t in 1..<4 where e[t] < eMin { eMin = e[t]; tMin = t }
                                    let y = (Double(fs[tMin][i]) - blackD) * invRange
                                    op[i] = Float(y / e[tMin])
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}
