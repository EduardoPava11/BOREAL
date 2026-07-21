import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// ═══ E1: the crossover experiment (BOREAL-DEBAYER-MATH-RESEARCH.md, open Q2)
// Product path:   per-channel CFA box means per rung (msEncode/msDecode)
// Reference path: Hamilton-Adams demosaic at full res (directional green with
//                 alias-cancelling co-sited Laplacian, US 5,629,734 unit-weight
//                 classifiers; chroma = bilinear color-difference interpolation)
//                 → exact k×k box downsample → same matrix→OKLab→Q16 tail.
// Question: how much baseband luma above the cell Nyquist do box means discard,
// per rung, on (a) a real device scene, (b) a gray zone plate (worst case)?
//
// Run (from repo root):
//   swiftc -O BOREAL/Kernels/*.swift scripts/e1-crossover/main.swift -o /tmp/e1
//   /tmp/e1 cycle1.dng cycle2.dng cycle3.dng cycle4.dng   # 4 DNGs = one EV cycle
//   /tmp/e1                                               # zone plate only
// First run 2026-07-19 (device cycle + zone plate): results recorded in
// BOREAL-DEBAYER-MATH-RESEARCH.md §E1.

let SIDE = 2048

// ── Hamilton-Adams green (cfa: 0=RGGB, 1=BGGR — green sites identical) ──────
func haGreen(_ m: [Float], side: Int) -> [Float] {
    var g = [Float](repeating: 0, count: side * side)
    for y in 0..<side {
        for x in 0..<side where ((y & 1) ^ (x & 1)) == 1 {   // green sites
            g[y * side + x] = m[y * side + x]
        }
    }
    let idx = { (y: Int, x: Int) in
        min(max(y, 0), side - 1) * side + min(max(x, 0), side - 1)
    }
    for y in 0..<side {
        for x in 0..<side where ((y & 1) ^ (x & 1)) == 0 {   // R/B sites
            let c0 = m[y * side + x]
            let gw = m[idx(y, x - 1)], ge = m[idx(y, x + 1)]
            let gn = m[idx(y - 1, x)], gs = m[idx(y + 1, x)]
            let cw = m[idx(y, x - 2)], ce = m[idx(y, x + 2)]
            let cn = m[idx(y - 2, x)], cs = m[idx(y + 2, x)]
            let dH = abs(gw - ge) + abs(2 * c0 - cw - ce)
            let dV = abs(gn - gs) + abs(2 * c0 - cn - cs)
            let v: Float
            if dH < dV      { v = (gw + ge) / 2 + (2 * c0 - cw - ce) / 4 }
            else if dV < dH { v = (gn + gs) / 2 + (2 * c0 - cn - cs) / 4 }
            else { v = (gw + ge + gn + gs) / 4 + (4 * c0 - cw - ce - cn - cs) / 8 }
            g[y * side + x] = v
        }
    }
    return g
}

// ── Chroma via color-difference interpolation on the C lattice ─────────────
// phase: (py,px) of the channel's sites, step 2 both axes.
func colorDiff(_ m: [Float], _ g: [Float], side: Int, py: Int, px: Int) -> [Float] {
    var d = [Float](repeating: .nan, count: side * side)
    var y = py
    while y < side {
        var x = px
        while x < side { d[y * side + x] = m[y * side + x] - g[y * side + x]; x += 2 }
        y += 2
    }
    let at = { (yy: Int, xx: Int) -> Float in
        let cy = min(max(yy, py), py + ((side - 1 - py) / 2) * 2)
        let cx = min(max(xx, px), px + ((side - 1 - px) / 2) * 2)
        return d[cy * side + cx]
    }
    var out = [Float](repeating: 0, count: side * side)
    for yy in 0..<side {
        let onRow = (yy & 1) == (py & 1)
        for xx in 0..<side {
            let onCol = (xx & 1) == (px & 1)
            if onRow && onCol { out[yy * side + xx] = d[yy * side + xx] }
            else if onRow     { out[yy * side + xx] = (at(yy, xx - 1) + at(yy, xx + 1)) / 2 }
            else if onCol     { out[yy * side + xx] = (at(yy - 1, xx) + at(yy + 1, xx)) / 2 }
            else { out[yy * side + xx] = (at(yy - 1, xx - 1) + at(yy - 1, xx + 1)
                                        + at(yy + 1, xx - 1) + at(yy + 1, xx + 1)) / 4 }
        }
    }
    for i in 0..<(side * side) { out[i] += g[i] }
    return out
}

// ── Reference rung: box-mean the demosaiced planes, matrix→OKLab→Q16 ───────
func refRung(_ r: [Float], _ g: [Float], _ b: [Float], side: Int, rung: Int,
             m: [Double]) -> (L: [Int32], a: [Int32], bb: [Int32]) {
    let k = side / rung
    let inv = 1.0 / Double(k * k)
    var L = [Int32](repeating: 0, count: rung * rung)
    var A = L, B = L
    for cy in 0..<rung {
        for cx in 0..<rung {
            var sr = 0.0, sg = 0.0, sb = 0.0
            for y in (cy * k)..<((cy + 1) * k) {
                let row = y * side
                for x in (cx * k)..<((cx + 1) * k) {
                    sr += Double(r[row + x]); sg += Double(g[row + x]); sb += Double(b[row + x])
                }
            }
            let pp = BorealKernels.apply3d(m, (sr * inv, sg * inv, sb * inv))
            let lab = BorealKernels.oklabFromProPhoto(pp.0, pp.1, pp.2)
            let i = cy * rung + cx
            L[i] = BorealKernels.q16(lab.0); A[i] = BorealKernels.q16(lab.1)
            B[i] = BorealKernels.q16(lab.2)
        }
    }
    return (L, A, B)
}

func compare(_ name: String, mosaic: [Float], cfa: UInt32, camToPP: [Float],
             hasColor: Bool, pngPrefix: String?) {
    let mD: [Double] = hasColor && camToPP.count == 9
        ? camToPP.map(Double.init) : [1, 0, 0, 0, 1, 0, 0, 0, 1]
    guard let s = BorealKernels.msEncode(mosaic: mosaic, side: SIDE, cfa: cfa,
                                         camToPP: camToPP, hasColor: hasColor)
    else { fatalError("msEncode failed") }

    // Reference demosaic. Phases for RGGB: R=(0,0), B=(1,1); BGGR swaps.
    let g = haGreen(mosaic, side: SIDE)
    let rPhase = cfa == 0 ? (0, 0) : (1, 1)
    let bPhase = cfa == 0 ? (1, 1) : (0, 0)
    let rF = colorDiff(mosaic, g, side: SIDE, py: rPhase.0, px: rPhase.1)
    let bF = colorDiff(mosaic, g, side: SIDE, py: bPhase.0, px: bPhase.1)

    print("\n═══ \(name)")
    print("rung |   mean ΔE |    p95 ΔE |    max ΔE |  L-RMS(Q16) | box-vs-ref")
    for rung in BorealKernels.msRungs(side: SIDE) {
        guard let pL = BorealKernels.msDecode(s.L, mosaicSide: SIDE, rung: rung),
              let pA = BorealKernels.msDecode(s.a, mosaicSide: SIDE, rung: rung),
              let pB = BorealKernels.msDecode(s.b, mosaicSide: SIDE, rung: rung)
        else { fatalError("decode failed") }
        let ref = refRung(rF, g, bF, side: SIDE, rung: rung, m: mD)
        var des = [Double](); des.reserveCapacity(rung * rung)
        var lsq = 0.0
        for i in 0..<(rung * rung) {
            let dl = Double(pL[i] - ref.L[i]), da = Double(pA[i] - ref.a[i])
            let db = Double(pB[i] - ref.bb[i])
            des.append((dl * dl + da * da + db * db).squareRoot() / 65536)
            lsq += dl * dl
        }
        des.sort()
        let mean = des.reduce(0, +) / Double(des.count)
        let p95 = des[Int(Double(des.count) * 0.95)]
        let lrms = (lsq / Double(rung * rung)).squareRoot()
        print(String(format: "%4d | %9.5f | %9.5f | %9.5f | %11.1f |", rung,
                     mean, p95, des.last ?? 0, lrms))
        if rung == 256, let prefix = pngPrefix {
            writePNG("\(prefix)_box.png", pL, pA, pB, side: rung)
            writePNG("\(prefix)_ref.png", ref.L, ref.a, ref.bb, side: rung)
        }
    }
}

func writePNG(_ path: String, _ L: [Int32], _ a: [Int32], _ b: [Int32], side: Int) {
    let rgb = BorealKernels.oklabQ16ToSRGB8(L: L, a: a, b: b)
    var px = [UInt8](repeating: 255, count: side * side * 4)
    for i in 0..<(side * side) {
        px[4 * i] = rgb[3 * i]; px[4 * i + 1] = rgb[3 * i + 1]; px[4 * i + 2] = rgb[3 * i + 2]
    }
    guard let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("  wrote \(path)")
}

// ── Input 1: a real device cycle (4 DNG paths on the command line) ─────────
let dngPaths = Array(CommandLine.arguments.dropFirst())
if dngPaths.count == 4 {
    var frames: [[UInt16]] = []
    var ets: [Float] = [], isos: [Float] = [], fns: [Float] = []
    var camToPP: [Float] = []
    var cfa: UInt32 = 1
    for (i, p) in dngPaths.enumerated() {
        let d = try Data(contentsOf: URL(fileURLWithPath: p))
        guard let m = BorealKernels.decodeDNG(d).mosaic else { fatalError("decode \(i + 1)") }
        let x0 = ((m.width - SIDE) / 2) & ~1, y0 = ((m.height - SIDE) / 2) & ~1
        var s = [UInt16](); s.reserveCapacity(SIDE * SIDE)
        for y in 0..<SIDE { s.append(contentsOf: m.samples[(y0 + y) * m.width + x0..<(y0 + y) * m.width + x0 + SIDE]) }
        frames.append(s)
        ets.append(m.exposureTime); isos.append(m.iso); fns.append(m.fNumber)
        camToPP = m.camToPP; cfa = m.cfa
    }
    let ev = BorealKernels.relativeExposures(et: ets, iso: isos, fnum: fns)
    guard let fused = BorealKernels.fuse(frames: frames, black: 528, white: 4095,
                                         exposures: ev, knee: 0.90, clip: 0.98)
    else { fatalError("fuse") }
    compare("REAL DEVICE SCENE (fused cycle)", mosaic: fused, cfa: cfa,
            camToPP: camToPP, hasColor: true, pngPrefix: "e1_scene")
} else if !dngPaths.isEmpty {
    print("need exactly 4 DNGs (one EV cycle) — got \(dngPaths.count); running zone plate only")
}

// ── Input 2: gray zone plate (worst-case luma; every frequency present) ────
var zp = [Float](repeating: 0, count: SIDE * SIDE)
let kmax = Double.pi                     // sweep to full mosaic Nyquist at corner
for y in 0..<SIDE {
    for x in 0..<SIDE {
        let r2 = Double(x * x + y * y)
        zp[y * SIDE + x] = Float(0.5 + 0.45 * cos(kmax * r2 / Double(2 * SIDE)))
    }
}
compare("GRAY ZONE PLATE (synthetic worst case)", mosaic: zp, cfa: 0,
        camToPP: [], hasColor: false, pngPrefix: "e1_zone")
