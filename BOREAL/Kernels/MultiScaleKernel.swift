import Foundation

/// Multi-scale demosaic — the custom ISP (spec/Boreal/MultiScale.hs, MS laws).
/// Each rung is its OWN demosaic; the latent is the residual stack; a prefix
/// decodes to THE rung-r demosaic. Pure Swift port (Phase 5 M1), verified
/// bit-exact against fixtures/multiscale_golden.json.
extension BorealKernels {

    static let allRungs = [16, 32, 64, 128, 256]

    static func msRungs(side: Int) -> [Int] {
        allRungs.filter { side % $0 == 0 && side / $0 >= 2 && (side / $0) % 2 == 0 }
    }

    static func msStackLen(side: Int) -> Int {
        msRungs(side: side).reduce(0) { $0 + $1 * $1 }
    }

    static func msLevelOffset(side: Int, rung: Int) -> Int {
        var off = 0
        for r in msRungs(side: side) {
            if r == rung { return off }
            off += r * r
        }
        return off
    }

    /// One rung's demosaic: per-CFA-channel f64 means (y-outer x-inner within
    /// each cell), camera→ProPhoto, OKLab Q16 planes.
    static func msComputeRung(mosaic: [Float], side: Int, cfa: UInt32, m: [Double],
                              rung: Int,
                              outL: inout [Int32], outA: inout [Int32],
                              outB: inout [Int32], at offset: Int) {
        let k = side / rung
        let isRGGB = cfa == 0
        let quarter = Double((k / 2) * (k / 2))
        for cy in 0..<rung {
            for cx in 0..<rung {
                var sr = 0.0, sg = 0.0, sb = 0.0
                for y in (cy * k)..<((cy + 1) * k) {
                    let py = y & 1
                    let row = y * side
                    for x in (cx * k)..<((cx + 1) * k) {
                        let v = Double(mosaic[row + x])
                        let px = x & 1
                        if py == 0 && px == 0 {
                            if isRGGB { sr += v } else { sb += v }
                        } else if py == 1 && px == 1 {
                            if isRGGB { sb += v } else { sr += v }
                        } else {
                            sg += v
                        }
                    }
                }
                let rr = sr / quarter
                let gg = sg / (2 * quarter)
                let bb = sb / quarter
                let pp = apply3(m, rr, gg, bb)
                let lab = oklabFromProPhoto(pp.0, pp.1, pp.2)
                let idx = offset + cy * rung + cx
                outL[idx] = q16(lab.0)
                outA[idx] = q16(lab.1)
                outB[idx] = q16(lab.2)
            }
        }
    }

    /// Full residual-stack encode: pass 1 writes ABSOLUTE rungs at their
    /// offsets; pass 2 residualizes fine → coarse (coarser still absolute).
    static func msEncode(mosaic: [Float], side: Int, cfa: UInt32,
                         camToPP: [Float], hasColor: Bool)
        -> (L: [Int32], a: [Int32], b: [Int32])? {
        let rungs = msRungs(side: side)
        guard !rungs.isEmpty, mosaic.count >= side * side else { return nil }
        let m: [Double] = hasColor && camToPP.count == 9
            ? camToPP.map(Double.init)
            : [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let total = msStackLen(side: side)
        var L = [Int32](repeating: 0, count: total)
        var A = [Int32](repeating: 0, count: total)
        var B = [Int32](repeating: 0, count: total)

        var off = 0
        for r in rungs {
            msComputeRung(mosaic: mosaic, side: side, cfa: cfa, m: m, rung: r,
                          outL: &L, outA: &A, outB: &B, at: off)
            off += r * r
        }

        for i in stride(from: rungs.count - 1, through: 1, by: -1) {
            let r = rungs[i], rp = rungs[i - 1]
            guard r == 2 * rp else { return nil }
            let offR = msLevelOffset(side: side, rung: r)
            let offP = msLevelOffset(side: side, rung: rp)
            for ch in 0..<3 {
                withChannel(ch, &L, &A, &B) { buf in
                    for y in 0..<r {
                        let py = y / 2
                        for x in 0..<r {
                            buf[offR + y * r + x] &-= buf[offP + py * rp + x / 2]
                        }
                    }
                }
            }
        }
        return (L, A, B)
    }

    /// Decode one channel's prefix back to the rung demosaic — in-place
    /// doubling with a DESCENDING index walk (write at row y touches source
    /// rows ≥ 2y; remaining reads need ≤ (y−1)/2 — never collides).
    static func msDecode(_ bands: [Int32], mosaicSide: Int, rung: Int) -> [Int32]? {
        let rungs = msRungs(side: mosaicSide)
        guard rungs.contains(rung), let base = rungs.first else { return nil }
        var out = [Int32](repeating: 0, count: rung * rung)
        for i in 0..<(base * base) { out[i] = bands[i] }
        var cur = base
        while cur < rung {
            let next = 2 * cur
            let det = msLevelOffset(side: mosaicSide, rung: next)
            for y in stride(from: next - 1, through: 0, by: -1) {
                let py = y / 2
                for x in stride(from: next - 1, through: 0, by: -1) {
                    out[y * next + x] = out[py * cur + x / 2] &+ bands[det + y * next + x]
                }
            }
            cur = next
        }
        return out
    }

    /// Per-frame normalization onto the common scene scale (CQ6/EV4):
    /// (raw − black)/(white − black) · invE, clamped ≥ 0 — f32 arithmetic.
    static func normalizeMosaic(samples: [UInt16], black: Float, white: Float,
                                invE: Float) -> [Float] {
        let scale = invE / max(white - black, 1)
        var out = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            out[i] = max((Float(samples[i]) - black) * scale, 0)
        }
        return out
    }

    /// Borrow one of three channel buffers mutably by index.
    private static func withChannel(_ ch: Int, _ l: inout [Int32],
                                    _ a: inout [Int32], _ b: inout [Int32],
                                    _ body: (inout [Int32]) -> Void) {
        switch ch {
        case 0: body(&l)
        case 1: body(&a)
        default: body(&b)
        }
    }
}
