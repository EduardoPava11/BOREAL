import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// ════════════════════════════════════════════════════════════════
// tools/replay — the Mac verdict CLI (TF0, BOREAL-TEST-FRAMEWORKS-
// WORKFLOW.md). One command per analysis that used to be an ad-hoc
// scratchpad harness. Compiled against BOREAL/Kernels (the app's own
// gate-verified kernel core):
//
//   replay verify  <bundle-dir>       bit-exact Mac replay vs report.json
//   replay render  <dng×4> [prefix]   current-pipeline portrait render
//   replay noise   <dng×4>            mean-variance envelope vs NoiseProfile
//   replay abfuse  <dng×4>            classic vs MLE fuse deltas by decile
//
// (E1 lives at scripts/e1-crossover — not duplicated here.)
// Build: make replay ARGS="verify ~/Downloads/BOREAL-…"
// ════════════════════════════════════════════════════════════════

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(("replay: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

// ── shared: load one cycle of DNGs ─────────────────────────────────────────

struct CycleData {
    var frames: [[UInt16]] = []          // cropped 2048²
    var ets: [Float] = [], isos: [Float] = [], fns: [Float] = []
    var profiles: [(s: Double, o: Double)] = []
    var camToPP: [Float] = []
    var asn: (Double, Double, Double) = (1, 1, 1)
    var cfa: UInt32 = 1
    var hasColor = false
    var black: Float = 528, white: Float = 4095
    let side = 2048
}

func loadCycle(_ paths: [String]) -> CycleData {
    guard paths.count == 4 else { die("need exactly 4 DNG paths, got \(paths.count)") }
    var c = CycleData()
    for (i, p) in paths.enumerated() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else {
            die("cannot read \(p)")
        }
        let (mo, st) = BorealKernels.decodeDNG(d)
        guard let m = mo else { die("frame \(i + 1) decode failed: status \(st)") }
        let x0 = ((m.width - c.side) / 2) & ~1, y0 = ((m.height - c.side) / 2) & ~1
        var s = [UInt16](); s.reserveCapacity(c.side * c.side)
        for y in 0..<c.side {
            s.append(contentsOf: m.samples[(y0 + y) * m.width + x0
                                           ..< (y0 + y) * m.width + x0 + c.side])
        }
        c.frames.append(s)
        c.ets.append(m.exposureTime); c.isos.append(m.iso); c.fns.append(m.fNumber)
        c.profiles.append((m.noiseS, m.noiseO))
        c.camToPP = m.camToPP; c.asn = m.asn; c.cfa = m.cfa
        c.hasColor = m.hasColor; c.black = m.black; c.white = m.white
        print(String(format: "  frame %d: %dx%d iso %.0f et 1/%.0f S=%.4e O=%.3e",
                     i + 1, m.width, m.height, m.iso,
                     m.exposureTime > 0 ? 1 / m.exposureTime : 0, m.noiseS, m.noiseO))
    }
    return c
}

func fuseCycle(_ c: CycleData) -> (fused: [Float], ev: [Float], mle: Bool) {
    let ev = BorealKernels.relativeExposures(et: c.ets, iso: c.isos, fnum: c.fns)
    let mle = c.profiles.allSatisfy { $0.s > 0 && $0.o > 0 }
    let fused: [Float]?
    if mle {
        fused = BorealKernels.fuseMLE(frames: c.frames, black: c.black, white: c.white,
                                      exposures: ev, profiles: c.profiles, clip: 0.98)
    } else {
        fused = BorealKernels.fuse(frames: c.frames, black: c.black, white: c.white,
                                   exposures: ev, knee: 0.90, clip: 0.98)
    }
    guard let f = fused else { die("fuse failed") }
    return (f, ev, mle)
}

func writePNG(_ path: String, indices: [UInt8], side: Int, rgb: [UInt8]) {
    var px = [UInt8](repeating: 255, count: side * side * 4)
    for i in 0..<(side * side) {
        let p = Int(indices[i]) * 3
        px[4 * i] = rgb[p]; px[4 * i + 1] = rgb[p + 1]; px[4 * i + 2] = rgb[p + 2]
    }
    guard let ctx = CGContext(data: &px, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: side * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: path) as CFURL,
              UTType.png.identifier as CFString, 1, nil)
    else { die("PNG write failed: \(path)") }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("  wrote \(path)")
}

// ── verify <bundle-dir> ─────────────────────────────────────────────────────

func cmdVerify(_ args: [String]) {
    guard let dir = args.first else { die("verify needs a bundle directory") }
    let base = URL(fileURLWithPath: dir)
    guard let repData = try? Data(contentsOf: base.appendingPathComponent("report.json")),
          let rep = (try? JSONSerialization.jsonObject(with: repData)) as? [String: Any]
    else { die("no readable report.json in \(dir)") }

    let dngs = (1...4).map { base.appendingPathComponent("frame_\($0).dng").path }
    guard dngs.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
        die("bundle has no frame_N.dng (only single-cycle bundles carry DNGs)")
    }
    print("decoding…")
    let c = loadCycle(dngs)
    var verdicts: [(String, Bool, String)] = []

    // fuse path
    let (fused, _, mle) = fuseCycle(c)
    let repFuse = rep["fuse"] as? String ?? "?"
    verdicts.append(("fuse path", (mle ? "mle" : "classic") == repFuse,
                     "mac=\(mle ? "mle" : "classic") device=\(repFuse)"))

    // NT
    var nt = 0.0
    if c.hasColor {
        let n = BorealKernels.apply3d(c.camToPP.map(Double.init), c.asn)
        let mx = max(n.0, max(n.1, n.2)), mn = min(n.0, min(n.1, n.2))
        if mx > 0 { nt = (mx - mn) / mx }
    }
    let repNT = (rep["ntSpread"] as? NSNumber)?.doubleValue ?? -1
    verdicts.append(("NT law", nt < 1e-5,
                     String(format: "mac %.2e device %.2e", nt, repNT)))

    // palette: replay the stack, rotate the seed, compare bitwise
    guard let s = BorealKernels.msEncode(mosaic: fused, side: c.side, cfa: c.cfa,
                                         camToPP: c.camToPP, hasColor: c.hasColor)
    else { die("msEncode failed") }
    let palL = BorealKernels.rotateCW(Array(s.L[0..<256]), side: 16)
    let palA = BorealKernels.rotateCW(Array(s.a[0..<256]), side: 16)
    let palB = BorealKernels.rotateCW(Array(s.b[0..<256]), side: 16)
    if let pal = rep["palette"] as? [String: Any] {
        func ints(_ v: Any?) -> [Int32] {
            (v as? [Any])?.compactMap { Int32(truncating: $0 as! NSNumber) } ?? []
        }
        let dL = ints(pal["q16L"]), dA = ints(pal["q16a"]), dB = ints(pal["q16b"])
        var same = 0
        // Pre-rotation bundles (schema < 3) carry the sensor-order seed.
        let candidates = [(palL, palA, palB),
                          (Array(s.L[0..<256]), Array(s.a[0..<256]), Array(s.b[0..<256]))]
        var best = 0
        for (cl, ca, cb) in candidates {
            same = 0
            for i in 0..<256 where dL[i] == cl[i] && dA[i] == ca[i] && dB[i] == cb[i] {
                same += 1
            }
            best = max(best, same)
            if same == 256 { break }
        }
        verdicts.append(("seed palette bit-exact", best == 256, "\(best)/256"))
    }

    print("\nVERDICTS")
    var allOK = true
    for (name, ok, detail) in verdicts {
        print("  \(ok ? "✓" : "✗") \(name)  (\(detail))")
        allOK = allOK && ok
    }
    exit(allOK ? 0 : 2)
}

// ── render <dng×4> [prefix] ─────────────────────────────────────────────────

func cmdRender(_ args: [String]) {
    guard args.count >= 4 else { die("render needs 4 DNG paths") }
    let prefix = args.count > 4 ? args[4] : "replay"
    let c = loadCycle(Array(args[0..<4]))
    let (fused, _, mle) = fuseCycle(c)
    print("  fuse: \(mle ? "mle" : "classic")")
    guard let s = BorealKernels.msEncode(mosaic: fused, side: c.side, cfa: c.cfa,
                                         camToPP: c.camToPP, hasColor: c.hasColor)
    else { die("msEncode failed") }
    let palL = BorealKernels.rotateCW(Array(s.L[0..<256]), side: 16)
    let palA = BorealKernels.rotateCW(Array(s.a[0..<256]), side: 16)
    let palB = BorealKernels.rotateCW(Array(s.b[0..<256]), side: 16)
    let rgb = BorealKernels.oklabQ16ToSRGB8(L: palL, a: palA, b: palB)
    let ceiling = BorealKernels.msRungs(side: c.side).max() ?? 16
    let chroma = min(BorealKernels.renderChromaRung, ceiling)
    guard let iL = BorealKernels.msDecode(s.L, mosaicSide: c.side, rung: ceiling),
          let ca = BorealKernels.msDecode(s.a, mosaicSide: c.side, rung: chroma),
          let cb = BorealKernels.msDecode(s.b, mosaicSide: c.side, rung: chroma)
    else { die("decode failed") }
    let rL = BorealKernels.rotateCW(iL, side: ceiling)
    let rA = BorealKernels.rotateCW(
        BorealKernels.upscalePlane(ca, from: chroma, to: ceiling), side: ceiling)
    let rB = BorealKernels.rotateCW(
        BorealKernels.upscalePlane(cb, from: chroma, to: ceiling), side: ceiling)
    let idx = BorealKernels.indexMap(L: rL, a: rA, b: rB,
                                     palL: palL, palA: palA, palB: palB)
    writePNG("\(prefix)_\(ceiling).png", indices: idx, side: ceiling, rgb: rgb)
}

// ── noise <dng×4> ───────────────────────────────────────────────────────────

func cmdNoise(_ args: [String]) {
    guard args.count >= 4 else { die("noise needs 4 DNG paths") }
    let c = loadCycle(Array(args[0..<4]))
    print("\nsecond-difference envelope (single green phase, p10, affine fit)")
    for (t, frame) in c.frames.enumerated() {
        let W = c.side, black = Double(c.black), white = Double(c.white)
        let range = white - black
        var pts: [(mu: Double, v: Double)] = []
        frame.withUnsafeBufferPointer { p in
            var by = 0
            while by + 32 <= W {
                var bx = 0
                while bx + 32 <= W {
                    var s = 0.0, sd2 = 0.0, n = 0.0, nd = 0.0
                    for y in stride(from: by, to: by + 32, by: 2) {
                        let row = y * W
                        var x = bx + 1
                        while x < bx + 32 {
                            s += Double(p[row + x]); n += 1
                            if x + 4 < bx + 32 {
                                let d2 = Double(p[row + x]) - 2 * Double(p[row + x + 2])
                                    + Double(p[row + x + 4])
                                sd2 += d2 * d2; nd += 1
                            }
                            x += 2
                        }
                    }
                    let mu = s / n
                    if mu - black > 2, mu < white - 600, nd > 30 {
                        pts.append((mu - black, sd2 / (6 * nd)))
                    }
                    bx += 32
                }
                by += 32
            }
        }
        pts.sort { $0.mu < $1.mu }
        var env: [(Double, Double)] = []
        for bin in 0..<30 {
            let lo = pts.count * bin / 30, hi = pts.count * (bin + 1) / 30
            guard hi - lo > 20 else { continue }
            let sl = pts[lo..<hi].sorted { $0.v < $1.v }
            env.append((sl[max(0, sl.count / 10)].mu, sl[max(0, sl.count / 10)].v))
        }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for (x, y) in env { sx += x; sy += y; sxx += x * x; sxy += x * y }
        let n = Double(env.count)
        let a = (n * sxy - sx * sy) / (n * sxx - sx * sx)
        let b = (sy - a * sx) / n
        let (S, O) = c.profiles[t]
        print(String(format:
            "  frame %d iso %5.0f: measured a=%.4f b=%7.1f | tag predicts a=%.4f b=%6.1f",
            t + 1, c.isos[t], a, b, S * range, O * range * range))
    }
    print("  (2nd-diff under-reads under spatial correlation; tag sits between estimator biases)")
}

// ── abfuse <dng×4> ──────────────────────────────────────────────────────────

func cmdABFuse(_ args: [String]) {
    guard args.count >= 4 else { die("abfuse needs 4 DNG paths") }
    let c = loadCycle(Array(args[0..<4]))
    let ev = BorealKernels.relativeExposures(et: c.ets, iso: c.isos, fnum: c.fns)
    guard let classic = BorealKernels.fuse(frames: c.frames, black: c.black,
                                           white: c.white, exposures: ev,
                                           knee: 0.90, clip: 0.98),
          let mle = BorealKernels.fuseMLE(frames: c.frames, black: c.black,
                                          white: c.white, exposures: ev,
                                          profiles: c.profiles, clip: 0.98)
    else { die("fuse failed (abfuse needs NoiseProfiles for the MLE side)") }
    var pairs = zip(classic, mle).map { (Double($0), Double($1)) }
    pairs.sort { $0.0 < $1.0 }
    print("\nclassic-brightness decile | median relΔ | p95 relΔ")
    for d in 0..<10 {
        let lo = pairs.count * d / 10, hi = pairs.count * (d + 1) / 10
        var rel = pairs[lo..<hi].map { abs($0.1 - $0.0) / max(abs($0.0), 1e-6) }
        rel.sort()
        print(String(format: "  %d (y≈%8.5f)          |   %8.5f  | %8.5f",
                     d, pairs[(lo + hi) / 2].0, rel[rel.count / 2],
                     rel[Int(Double(rel.count) * 0.95)]))
    }
}

// ── main ────────────────────────────────────────────────────────────────────

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else {
    print("""
    usage: replay <command> …
      verify <bundle-dir>        bit-exact Mac replay vs report.json
      render <dng×4> [prefix]    current-pipeline portrait render
      noise  <dng×4>             mean-variance envelope vs NoiseProfile
      abfuse <dng×4>             classic vs MLE fuse deltas by decile
    (E1 crossover lives at scripts/e1-crossover)
    """)
    exit(0)
}
let rest = Array(argv.dropFirst())
switch cmd {
case "verify": cmdVerify(rest)
case "render": cmdRender(rest)
case "noise":  cmdNoise(rest)
case "abfuse": cmdABFuse(rest)
default: die("unknown command \(cmd)")
}
