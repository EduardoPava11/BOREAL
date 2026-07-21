import Foundation

/// Multi-scale demosaic — the custom ISP (spec/Boreal/MultiScale.hs, MS laws).
/// Each rung is its OWN demosaic; the latent is the residual stack; a prefix
/// decodes to THE rung-r demosaic. Pure Swift port (Phase 5 M1), verified
/// bit-exact against fixtures/multiscale_golden.json.
extension BorealKernels {

    // 512 added 2026-07-19 (E1-extension: k=4 box means sub-JND on real
    // scenes; k=2 rejected). 512 = RENDER ceiling (the GIF); 256 stays the
    // MODEL ceiling (H2/N0/bell — the 256 rung is a stack prefix).
    static let allRungs = [16, 32, 64, 128, 256, 512]

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
    ///
    /// Cell rows are distributed across cores (M2): every cell's arithmetic
    /// is fully independent and unchanged, so the result is bit-identical to
    /// the serial walk regardless of scheduling — the gate proves it against
    /// the goldens on every run.
    static func msComputeRung(mosaic: [Float], side: Int, cfa: UInt32, m: [Double],
                              rung: Int,
                              outL: inout [Int32], outA: inout [Int32],
                              outB: inout [Int32], at offset: Int) {
        mosaic.withUnsafeBufferPointer { mosaicP in
            outL.withUnsafeMutableBufferPointer { lP in
                outA.withUnsafeMutableBufferPointer { aP in
                    outB.withUnsafeMutableBufferPointer { bP in
                        DispatchQueue.concurrentPerform(iterations: rung) { cy in
                            computeRungRow(mosaic: mosaicP, side: side, cfa: cfa,
                                           m: m, rung: rung, cy: cy,
                                           outL: lP, outA: aP, outB: bP,
                                           at: offset)
                        }
                    }
                }
            }
        }
    }

    /// One row of rung cells (disjoint output indices per row — safe to run
    /// rows concurrently).
    private static func computeRungRow(mosaic: UnsafeBufferPointer<Float>,
                                       side: Int, cfa: UInt32, m: [Double],
                                       rung: Int, cy: Int,
                                       outL: UnsafeMutableBufferPointer<Int32>,
                                       outA: UnsafeMutableBufferPointer<Int32>,
                                       outB: UnsafeMutableBufferPointer<Int32>,
                                       at offset: Int) {
        let k = side / rung
        let isRGGB = cfa == 0
        let quarter = Double((k / 2) * (k / 2))
        do {
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

    /// Per-frame fast path (BOREAL-METAL-PRECISION-WORKFLOW.md, latency):
    /// the 64-frame render consumes ONLY the absolute seed rung (16², the
    /// palette/fractal seed) and the absolute ceiling rung (the GIF frame).
    /// msEncode's residual stack telescopes away exactly under msDecode
    /// (MS3: prefix decode == THE rung demosaic; &- then &+ cancel mod 2³²),
    /// so computing the two rungs directly is bit-identical to
    /// encode→decode while skipping the middle rungs, the residual pass,
    /// and the decode walks — 5 full mosaic passes become 2. Parity is
    /// gate-checked against msEncode+msDecode on the multiscale fixture.
    static func msSeedAndCeiling(mosaic: [Float], side: Int, cfa: UInt32,
                                 camToPP: [Float], hasColor: Bool)
        -> (rung: Int,
            seedL: [Int32], seedA: [Int32], seedB: [Int32],
            ceilL: [Int32], ceilA: [Int32], ceilB: [Int32])? {
        let rungs = msRungs(side: side)
        guard let seed = rungs.first, let ceil = rungs.last,
              let planes = msDirect(mosaic: mosaic, side: side, cfa: cfa,
                                    camToPP: camToPP, hasColor: hasColor,
                                    rungs: [seed, ceil]),
              let s = planes[seed], let c = planes[ceil] else { return nil }
        return (ceil, s.L, s.a, s.b, c.L, c.a, c.b)
    }

    /// Direct computation of ARBITRARY ladder rungs (absolute planes) — the
    /// generalized per-frame fast path. Each requested rung is its own
    /// demosaic pass; by the MS3 telescope every rung is bit-identical to
    /// msEncode→msDecode at that rung (gate-checked via msSeedAndCeiling,
    /// which delegates here). The per-frame render requests
    /// {seed, model 256, render ceiling} — 3 passes instead of the full
    /// ladder + residualize + decode.
    static func msDirect(mosaic: [Float], side: Int, cfa: UInt32,
                         camToPP: [Float], hasColor: Bool, rungs req: [Int])
        -> [Int: (L: [Int32], a: [Int32], b: [Int32])]? {
        let ladder = msRungs(side: side)
        guard !req.isEmpty, mosaic.count >= side * side,
              req.allSatisfy({ ladder.contains($0) }) else { return nil }
        let m: [Double] = hasColor && camToPP.count == 9
            ? camToPP.map(Double.init)
            : [1, 0, 0, 0, 1, 0, 0, 0, 1]
        var out: [Int: (L: [Int32], a: [Int32], b: [Int32])] = [:]
        for r in Set(req) {
            var L = [Int32](repeating: 0, count: r * r)
            var a = L, b = L
            msComputeRung(mosaic: mosaic, side: side, cfa: cfa, m: m, rung: r,
                          outL: &L, outA: &a, outB: &b, at: 0)
            out[r] = (L, a, b)
        }
        return out
    }

    /// Nearest-neighbor plane upscale (Int32 twin of upscaleIndices, same
    /// convention) — the RENDER-CHROMA split's transport: chroma decoded at
    /// a coarse rung rides up to the render rung. replicate ≠ resample: no
    /// new values are invented (block-constant; BOREALTests pins it).
    static func upscalePlane(_ plane: [Int32], from r: Int, to target: Int) -> [Int32] {
        guard target % r == 0, plane.count == r * r else { return plane }
        let k = target / r
        var out = [Int32](repeating: 0, count: target * target)
        for y in 0..<target {
            let sy = y / k
            for x in 0..<target {
                out[y * target + x] = plane[sy * r + x / k]
            }
        }
        return out
    }

    /// The RENDER-CHROMA rung (2026-07-19, bundle-5 verdict): luma renders
    /// at the render ceiling; a/b render from THIS rung, nearest-upscaled.
    ///
    /// Why (BOREAL-DEBAYER-MATH-RESEARCH.md): chroma is low-bandwidth
    /// (Alleysson demultiplexing; all video ships subsampled chroma), and
    /// each rung is its OWN demosaic, so the 128 rung's chroma comes from
    /// 16× larger cells with exact carrier nulling — E1 measured its
    /// worst-case chroma error ~10× below the 512 rung's. Measured on the
    /// bundle-5 screen-moiré scene: HF chroma energy 840 → 237 (3.5×).
    /// At phone distance 128-rung chroma sits below the Mullen chromatic
    /// acuity cutoff — the split is perceptually transparent. Residual
    /// fully-folded alias is the σ_time-gated suppressor's job (T4-judged,
    /// not this constant).
    static let renderChromaRung = 128

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

    /// σ head: per 16×16 latent cell, the summed |residual| over every
    /// multi-scale level and channel landing in that cell — how much the
    /// finer demosaics disagree with the coarser view there. This is the
    /// dither budget / resolution gate.
    static func sigmaGrid(mosaicSide: Int, channels: [[Int32]]) -> [Float] {
        var acc = [Int64](repeating: 0, count: 16 * 16)
        var offset = 0
        for (levelIdx, r) in msRungs(side: mosaicSide).enumerated() {
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
