import Foundation

/// The FS walk loop — THE product decode (spec/Boreal/DitherWalk.hs, DW laws).
/// Serpentine path over the s×s frame; per pixel the CORRECTED value
/// (target + carry, Q16 ints, never clamped) is quantized by a windowed
/// strict-less argmin over the (2r+1)² palette-grid neighborhood of the
/// pixel's HOME cell; the exact integer error is diffused with FS shares
/// (7,3,5,1)/16 (floor division, remainder joins the EAST share) to the
/// walk-order neighbors east,(sw,s,se) — kernel mirrored horizontally on
/// odd rows; out-of-frame shares are dropped and summed per channel (DW8).
/// Pure Swift port, verified bit-exact against fixtures/walk_golden.json.
extension BorealKernels {

    /// Floor division (Haskell `div`): Swift `/` truncates toward zero,
    /// which is wrong for negative FS shares.
    @inline(__always)
    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    /// The full carry-buffer FS walk. Returns ROW-MAJOR palette indices
    /// plus the per-channel dropped-share sums. Carries and distances are
    /// Int64 (target + accumulated carry can exceed Int32).
    static func fsWalk(targetL: [Int32], targetA: [Int32], targetB: [Int32],
                       palL: [Int32], palA: [Int32], palB: [Int32],
                       side: Int, r: Int)
        -> (indices: [UInt8], dropped: (Int64, Int64, Int64)) {
        let n = side * side
        var carryL = [Int64](repeating: 0, count: n)
        var carryA = [Int64](repeating: 0, count: n)
        var carryB = [Int64](repeating: 0, count: n)
        var out = [UInt8](repeating: 0, count: n)
        var dropL: Int64 = 0, dropA: Int64 = 0, dropB: Int64 = 0

        for y in 0..<side {
            let even = y % 2 == 0
            for step in 0..<side {
                let x = even ? step : side - 1 - step
                let i = y * side + x
                let cL = Int64(targetL[i]) + carryL[i]
                let cA = Int64(targetA[i]) + carryA[i]
                let cB = Int64(targetB[i]) + carryB[i]

                // windowed strict-less argmin around the home cell,
                // dv-outer / du-ascending, grid coords clamped to [0,15]
                let hv = y * 16 / side, hu = x * 16 / side
                var best = 0
                var bestD = Int64.max
                for dv in -r...r {
                    let v = max(0, min(15, hv + dv))
                    for du in -r...r {
                        let u = max(0, min(15, hu + du))
                        let j = v * 16 + u
                        let dl = Int64(palL[j]) - cL
                        let da = Int64(palA[j]) - cA
                        let db = Int64(palB[j]) - cB
                        let d = dl * dl + da * da + db * db
                        if d < bestD { bestD = d; best = j }
                    }
                }
                out[i] = UInt8(best)

                // neighbors in WALK order: east,(sw,s,se); mirrored on odd rows
                let dx = even ? 1 : -1
                let nbrs = [(y, x + dx), (y + 1, x - dx),
                            (y + 1, x), (y + 1, x + dx)]

                func diffuse(_ e: Int64, _ carry: inout [Int64],
                             _ dropped: inout Int64) {
                    let e7 = floorDiv(7 * e, 16)
                    let e3 = floorDiv(3 * e, 16)
                    let e5 = floorDiv(5 * e, 16)
                    let e1 = floorDiv(e, 16)
                    let shares = [e7 + (e - (e7 + e3 + e5 + e1)), e3, e5, e1]
                    for (p, share) in zip(nbrs, shares) {
                        if p.0 >= 0 && p.0 < side && p.1 >= 0 && p.1 < side {
                            carry[p.0 * side + p.1] += share
                        } else {
                            dropped += share
                        }
                    }
                }
                diffuse(cL - Int64(palL[best]), &carryL, &dropL)
                diffuse(cA - Int64(palA[best]), &carryA, &dropA)
                diffuse(cB - Int64(palB[best]), &carryB, &dropB)
            }
        }
        return (out, (dropL, dropA, dropB))
    }
}
