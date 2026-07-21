import Foundation

/// BinKernel — β_b, per-phase box binning (Boreal.BinContract; THE
/// BIN-COMMUTATION THEOREM, BC laws). The V1 engine's input contract:
///
///   THEOREM BC2: cfaBin(S/(b·r)) ∘ β_b == cfaBin(S/r), exactly in ℚ,
///   at every rung whose binned cell is a whole even quad count — the
///   classic ladder FACTORS THROUGH binning, so β_b(mosaic) is a
///   sufficient statistic for the model rungs. At device scale
///   (2048, b = 4): the binned ladder IS the model rungs {16…256} and
///   the render rung 512 is exactly the information binning drops.
///
/// Consequence: the encoder eats phase planes of β_4(crop) with ZERO
/// geometric/radiometric skew against its classic targets — the seed
/// the model must beat is computed from the very statistic it is
/// given. (The noise level shifts ~b²-fold vs native-scale synth —
/// the documented T3 training-distribution boundary.)
///
/// β_b preserves the CFA phase: a binned Bayer mosaic is a Bayer
/// mosaic (b = 2 is quad-binned sensor readout — the hardware K).
/// f64 accumulation, j-outer i-inner, one rounding to Float at the
/// end; on dyadic fixtures every intermediate is exact, so the gate
/// checks the theorem BITWISE in f64.
extension BorealKernels {

    /// binned[Y,X] = mean of the b² same-phase photosites in the
    /// aligned 2b×2b block. Requires side % 2b == 0.
    static func binPhase(_ mosaic: [Float], side: Int, b: Int) -> [Float]? {
        guard b >= 1, side % (2 * b) == 0,
              mosaic.count == side * side else { return nil }
        let half = side / b
        let inv = 1.0 / Double(b * b)
        var out = [Float](repeating: 0, count: half * half)
        mosaic.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                for Y in 0..<half {
                    let py = Y & 1
                    let y0 = 2 * b * (Y / 2) + py
                    for X in 0..<half {
                        let px = X & 1
                        let x0 = 2 * b * (X / 2) + px
                        var acc = 0.0
                        for j in 0..<b {
                            let row = (y0 + 2 * j) * side
                            for i in 0..<b {
                                acc += Double(p[row + x0 + 2 * i])
                            }
                        }
                        o[Y * half + X] = Float(acc * inv)
                    }
                }
            }
        }
        return out
    }
}
