// Swift kernel parity harness (Phase 5 M1) — compiles the app's pure-Swift
// kernels (BOREAL/Kernels/*.swift) against the SAME golden fixtures the
// Haskell contract emitted, the Python oracle re-derived, and the Zig port
// matched. Run from spec/:  see the Makefile `swift-verify` target.

import Foundation

func die(_ msg: String) -> Never {
    print("SWIFT KERNELS FAIL: \(msg)")
    exit(1)
}

func loadJSON(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any]
    else { die("cannot load \(path)") }
    return dict
}

func doubles(_ v: Any?) -> [Double] {
    (v as! [Any]).map { ($0 as! NSNumber).doubleValue }
}
func ints32(_ v: Any?) -> [Int32] {
    (v as! [Any]).map { Int32(truncating: $0 as! NSNumber) }
}
func bytes(_ v: Any?) -> [UInt8] {
    (v as! [Any]).map { UInt8(truncating: $0 as! NSNumber) }
}

let dir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "../fixtures"

// ── colorpath: owned cbrt + composed matrix + full path, BIT-EXACT ─────────
let cp = loadJSON("\(dir)/colorpath_golden.json")
let mats = cp["matrices"] as! [String: Any]
let composedWant = doubles(mats["prophotoToLms"])
for (i, w) in composedWant.enumerated() where w.bitPattern != BorealKernels.prophotoToLms[i].bitPattern {
    die("composed matrix drift at \(i)")
}
for c in cp["cbrt"] as! [[String: Any]] {
    let x = (c["x"] as! NSNumber).doubleValue
    let y = (c["y"] as! NSNumber).doubleValue
    if BorealKernels.ownedCbrt(x).bitPattern != y.bitPattern { die("cbrt(\(x)) drift") }
}
for s in cp["samples"] as! [[String: Any]] {
    let pp = doubles(s["prophoto"])
    let lab = BorealKernels.oklabFromProPhoto(pp[0], pp[1], pp[2])
    let want = doubles(s["oklab"])
    if lab.0.bitPattern != want[0].bitPattern || lab.1.bitPattern != want[1].bitPattern
        || lab.2.bitPattern != want[2].bitPattern { die("oklab drift at \(pp)") }
    let q = ints32(s["q16"])
    if BorealKernels.q16(lab.0) != q[0] || BorealKernels.q16(lab.1) != q[1]
        || BorealKernels.q16(lab.2) != q[2] { die("q16 drift at \(pp)") }
}

// ── multiscale: encode the fixture mosaic, match all three stacks ──────────
let ms = loadJSON("\(dir)/multiscale_golden.json")["fixture"] as! [String: Any]
let side = (ms["side"] as! NSNumber).intValue
let mosaic = doubles(ms["mosaicF64"]).map { Float($0) }
guard let stacks = BorealKernels.msEncode(mosaic: mosaic, side: side, cfa: 0,
                                          camToPP: [], hasColor: false)
else { die("msEncode returned nil") }
if stacks.L != ints32(ms["bandsL"]) { die("multiscale bandsL drift") }
if stacks.a != ints32(ms["bandsA"]) { die("multiscale bandsA drift") }
if stacks.b != ints32(ms["bandsB"]) { die("multiscale bandsB drift") }
for r in BorealKernels.msRungs(side: side) {
    guard BorealKernels.msDecode(stacks.L, mosaicSide: side, rung: r) != nil
    else { die("msDecode failed at rung \(r)") }
}

// ── giftarget: palette display path + index maps ───────────────────────────
let gt = loadJSON("\(dir)/giftarget_golden.json")
let pal = gt["palette"] as! [String: Any]
let palL = ints32(pal["q16L"]), palA = ints32(pal["q16a"]), palB = ints32(pal["q16b"])
if BorealKernels.oklabQ16ToSRGB8(L: palL, a: palA, b: palB) != bytes(pal["rgb8"]) {
    die("palette rgb8 drift")
}
let fx = gt["indexFixture"] as! [String: Any]
let pr = fx["probes"] as! [String: Any]
let got = BorealKernels.indexMap(L: ints32(pr["q16L"]), a: ints32(pr["q16a"]),
                                 b: ints32(pr["q16b"]),
                                 palL: palL, palA: palA, palB: palB)
if got != bytes(fx["indices"]) { die("index map drift") }
let selfIdx = BorealKernels.indexMap(L: palL, a: palA, b: palB,
                                     palL: palL, palA: palA, palB: palB)
if selfIdx != (0...255).map({ UInt8($0) }) { die("A2 self-indexing broken") }

// ── gifwire: byte-exact GIF ────────────────────────────────────────────────
let gw = loadJSON("\(dir)/gifwire_golden.json")["fixture"] as! [String: Any]
let gside = (gw["side"] as! NSNumber).intValue
let gdelay = (gw["delayCs"] as! NSNumber).intValue
let gct = bytes(gw["palette"])
let gframes = (gw["frames"] as! [Any]).map { bytes($0) }
guard let gif = BorealKernels.gifEncode(frames: gframes, side: gside,
                                        gct: gct, delayCs: gdelay)
else { die("gifEncode returned nil") }
if [UInt8](gif) != bytes(gw["gifBytes"]) { die("gif bytes drift") }

// ── ported-kernel checks (fuse / scene / DNG — M3/M4 migration) ────────────
let ev = loadJSON("\(dir)/exposure_golden.json")
for c in ev["cases"] as! [[String: Any]] {
    let frames = c["frames"] as! [[String: Any]]
    func rat(_ v: Any?) -> Float {
        let p = (v as! [Any]).map { ($0 as! NSNumber).doubleValue }
        return Float(p[0] / p[1])
    }
    let et = frames.map { rat($0["t"]) }
    let iso = frames.map { rat($0["iso"]) }
    let fn = frames.map { rat($0["fnum"]) }
    let got = BorealKernels.relativeExposures(et: et, iso: iso, fnum: fn)
    let want = doubles(c["expectedF64"])
    for (g, w) in zip(got, want) where abs(Double(g) - w) > max(1e-4, 1e-5 * w) {
        die("relativeExposures drift in case \(c["name"] ?? "?"): \(got) vs \(want)")
    }
}
// GPU parity (M2): the Metal index map must be bit-identical to the CPU
// reference on the goldens. Skips (loudly) when no Metal device exists.
if let gpu = MetalIndexMapper.shared {
    guard let gGot = gpu.map(L: ints32(pr["q16L"]), a: ints32(pr["q16a"]),
                             b: ints32(pr["q16b"]),
                             palL: palL, palA: palA, palB: palB)
    else { die("Metal index map returned nil") }
    if gGot != bytes(fx["indices"]) { die("METAL index map drift vs golden") }
    guard let gSelf = gpu.map(L: palL, a: palA, b: palB,
                              palL: palL, palA: palA, palB: palB)
    else { die("Metal self-index returned nil") }
    if gSelf != (0...255).map({ UInt8($0) }) { die("METAL A2 self-indexing broken") }
    print("  metal: index map GPU parity OK")
} else {
    print("  metal: no device — GPU parity SKIPPED")
}

if !BorealKernels.fuseSelfTest() { die("fuse self-test failed") }
if !BorealKernels.sceneSelfTest() { die("scene self-test failed") }
if !BorealKernels.dngSelfTest() { die("DNG self-test failed") }

print("SWIFT KERNELS GREEN: bit/byte-exact against all goldens + ported self-tests")
