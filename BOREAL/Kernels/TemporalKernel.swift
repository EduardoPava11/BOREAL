import Foundation

/// TemporalBayer — the cycle's statistics (TB laws; THE PIVOT,
/// BOREAL-TEMPORAL-BAYER-WORKFLOW.md T1). Ported from
/// spec/Boreal/TemporalBayer.hs; verified bitwise against
/// temporalbayer_golden.json by the gate.
///
/// The 4-frame EV cycle is a per-bin experiment:
///   • noise meter — per-bin weighted mean μ̂ (weights e_j = inverse
///     variance under shot noise) and residual v̂; ĝ = UPPER MEDIAN of
///     v̂/(μ̂/N) over (bin, channel) — robust to scene motion, an
///     UNCALIBRATED constant-factor estimator (TB2 pins the window).
///   • alias discriminator D — E1's carrier-site false color is static
///     per frame and flips with tremor; true chroma is stable. Per bin,
///     chroma proxies q1 = m_R − m_G, q2 = m_B − m_G, D = noise-normalized
///     cross-frame variance: noise-only ≈ 1, alias/chroma-motion ≫ 1.
///   • σ_time — D aggregated to the seed grid: the temporal twin of the
///     σ head (cross-scale energy at cell Nyquist), and the gate for any
///     future σ-gated ceiling correction.
///
/// Op shapes pinned to the spec: f64 accumulation (f32 frames widen
/// exactly), single left-fold from 0, y-outer x-inner per cell, cells
/// row-major, frame sums j ascending, ratios bins-ascending × R,G,B,
/// median = sort ascending take index n/2. k = side/rung must be EVEN
/// (whole-Bayer-period law — msRungs' (side/r)%2==0).
extension BorealKernels {

    struct TemporalStats {
        let muR: [Double]        // rung² weighted bin means, per channel
        let muG: [Double]
        let muB: [Double]
        let gain: Double         // ĝ
        let d: [Double]          // rung² alias discriminator
        let sigmaTime: [Double]  // seed² aggregated D
    }

    /// Per-rung per-channel cell means of one EV-normalized frame.
    /// cfa: 0 = RGGB (even,even = R; odd,odd = B; else G); 1 = BGGR.
    ///
    /// Branch-free row-parity walk (flatten, 2026-07-20): within a cell,
    /// even rows contribute (evenSite, G) pairs and odd rows (G, oddSite)
    /// pairs at stride 2 — each ACCUMULATOR still sees its own sites in
    /// exactly the original raster order, so every f64 sum is bit-identical
    /// to the scalar-branch walk (the gate + BOREALTests pin it).
    static func tbChannelMeans(_ frame: [Float], side: Int, rung: Int,
                               cfa: UInt32) -> (r: [Double], g: [Double], b: [Double]) {
        let k = side / rung
        let quarter = Double((k / 2) * (k / 2))
        let isRGGB = cfa == 0
        var R = [Double](repeating: 0, count: rung * rung)
        var G = R, B = R
        frame.withUnsafeBufferPointer { p in
            R.withUnsafeMutableBufferPointer { rP in
                G.withUnsafeMutableBufferPointer { gP in
                    B.withUnsafeMutableBufferPointer { bP in
                        for cy in 0..<rung {
                            for cx in 0..<rung {
                                var sEven = 0.0, sg = 0.0, sOdd = 0.0
                                for y in (cy * k)..<((cy + 1) * k) {
                                    let row = y * side + cx * k
                                    if y & 1 == 0 {
                                        var x = 0
                                        while x < k {
                                            sEven += Double(p[row + x])
                                            sg += Double(p[row + x + 1])
                                            x += 2
                                        }
                                    } else {
                                        var x = 0
                                        while x < k {
                                            sg += Double(p[row + x])
                                            sOdd += Double(p[row + x + 1])
                                            x += 2
                                        }
                                    }
                                }
                                let i = cy * rung + cx
                                // RGGB: even-even = R; BGGR: even-even = B.
                                rP[i] = (isRGGB ? sEven : sOdd) / quarter
                                gP[i] = sg / (2 * quarter)
                                bP[i] = (isRGGB ? sOdd : sEven) / quarter
                            }
                        }
                    }
                }
            }
        }
        return (R, G, B)
    }

    /// The cycle statistics. `frames` are the EV-NORMALIZED mosaics
    /// (CQ6/EV4 upstream); `exposures` the relative EV ratios
    /// (darkest = 1). nil on malformed input.
    static func temporalStats(frames: [[Float]], side: Int, cfa: UInt32,
                              exposures: [Double], rung: Int,
                              seed: Int) -> TemporalStats? {
        guard frames.allSatisfy({ $0.count == side * side }),
              side % rung == 0 else { return nil }
        let per = frames.map { tbChannelMeans($0, side: side, rung: rung, cfa: cfa) }
        return temporalStats(perFrameMeans: per, cellSide: side / rung,
                             exposures: exposures, rung: rung, seed: seed)
    }

    /// Same statistics from PRECOMPUTED per-frame channel means (the burst
    /// path computes means per frame before dropping each mosaic, keeping
    /// memory flat). Bit-identical to the frames entry point — it is the
    /// same code; the gate verifies the composition end to end.
    static func temporalStats(perFrameMeans per: [(r: [Double], g: [Double], b: [Double])],
                              cellSide k: Int, exposures: [Double], rung: Int,
                              seed: Int) -> TemporalStats? {
        let J = per.count
        guard J >= 2, exposures.count == J,
              k % 2 == 0, k > 0,
              rung % seed == 0,
              per.allSatisfy({ $0.r.count == rung * rung
                               && $0.g.count == rung * rung
                               && $0.b.count == rung * rung })
        else { return nil }
        let dof = Double(J - 1)
        var sumE = 0.0
        for e in exposures { sumE += e }
        guard sumE > 0 else { return nil }

        let nR = Double((k / 2) * (k / 2))
        let nG = 2 * nR
        let nBins = rung * rung

        // FLATTEN (2026-07-20, device: this stage was 2.1 s at rung 512):
        // one contiguous buffer — plane (c, j) lives at ((c·J)+j)·nBins —
        // pointer walks throughout, q1/q2 computed inline instead of
        // materialized. Every accumulation keeps the spec's op order
        // (j ascending; ratios bins-ascending × R,G,B; identical
        // expression shapes), so the result is BIT-IDENTICAL to the
        // nested-array form — the gate + BOREALTests pin it.
        var flat = [Double]()
        flat.reserveCapacity(3 * J * nBins)
        for c in 0..<3 {
            for j in 0..<J {
                switch c {
                case 0: flat.append(contentsOf: per[j].r)
                case 1: flat.append(contentsOf: per[j].g)
                default: flat.append(contentsOf: per[j].b)
                }
            }
        }
        let e = exposures
        var mu = [Double](repeating: 0, count: 3 * nBins)
        var ratios = [Double](repeating: 0, count: 3 * nBins)
        var d = [Double](repeating: 0, count: nBins)
        var gain = 0.0

        flat.withUnsafeBufferPointer { fp in
            let base = fp.baseAddress!
            func plane(_ c: Int, _ j: Int) -> UnsafePointer<Double> {
                base + ((c * J) + j) * nBins
            }
            var vv = [Double](repeating: 0, count: 3 * nBins)
            mu.withUnsafeMutableBufferPointer { muP in
                vv.withUnsafeMutableBufferPointer { vvP in
                    for c in 0..<3 {
                        for i in 0..<nBins {
                            var s = 0.0
                            for j in 0..<J { s += e[j] * plane(c, j)[i] }
                            let m = s / sumE
                            muP[c * nBins + i] = m
                            var r = 0.0
                            for j in 0..<J {
                                let dv = plane(c, j)[i] - m
                                r += e[j] * dv * dv
                            }
                            vvP[c * nBins + i] = r / dof
                        }
                    }
                }
            }
            // ĝ: upper median of v̂/(μ̂/N), bins ascending × R,G,B.
            ratios.withUnsafeMutableBufferPointer { rP in
                for i in 0..<nBins {
                    let mR0 = mu[i], mG0 = mu[nBins + i], mB0 = mu[2 * nBins + i]
                    rP[i * 3] = mR0 > 0 ? vv[i] / (mR0 / nR) : 0
                    rP[i * 3 + 1] = mG0 > 0 ? vv[nBins + i] / (mG0 / nG) : 0
                    rP[i * 3 + 2] = mB0 > 0 ? vv[2 * nBins + i] / (mB0 / nR) : 0
                }
            }
            gain = ratios.sorted()[ratios.count / 2]

            // D per bin: chroma proxies q1 = R−G, q2 = B−G, inline.
            d.withUnsafeMutableBufferPointer { dP in
                for i in 0..<nBins {
                    var d1 = 0.0
                    let V1 = gain * mu[i] / nR + gain * mu[nBins + i] / nG
                    if V1 > 0 {
                        var s = 0.0
                        for j in 0..<J {
                            s += e[j] * (plane(0, j)[i] - plane(1, j)[i])
                        }
                        let qbar = s / sumE
                        var num = 0.0
                        for j in 0..<J {
                            let dv = (plane(0, j)[i] - plane(1, j)[i]) - qbar
                            num += e[j] * dv * dv
                        }
                        d1 = num / (dof * V1)
                    }
                    var d2 = 0.0
                    let V2 = gain * mu[2 * nBins + i] / nR + gain * mu[nBins + i] / nG
                    if V2 > 0 {
                        var s = 0.0
                        for j in 0..<J {
                            s += e[j] * (plane(2, j)[i] - plane(1, j)[i])
                        }
                        let qbar = s / sumE
                        var num = 0.0
                        for j in 0..<J {
                            let dv = (plane(2, j)[i] - plane(1, j)[i]) - qbar
                            num += e[j] * dv * dv
                        }
                        d2 = num / (dof * V2)
                    }
                    dP[i] = (d1 + d2) / 2
                }
            }
        }

        // σ_time: mean of D over each seed cell's (rung/seed)² block.
        let f = rung / seed
        var sig = [Double](repeating: 0, count: seed * seed)
        for sy in 0..<seed {
            for sx in 0..<seed {
                var s = 0.0
                for dy in 0..<f {
                    for dx in 0..<f { s += d[(sy * f + dy) * rung + sx * f + dx] }
                }
                sig[sy * seed + sx] = s / Double(f * f)
            }
        }
        return TemporalStats(muR: Array(mu[0..<nBins]),
                             muG: Array(mu[nBins..<(2 * nBins)]),
                             muB: Array(mu[(2 * nBins)...]),
                             gain: gain, d: d, sigmaTime: sig)
    }
}
