// Swift kernel parity harness — compiles the app's pure-Swift kernels
// (BOREAL/Kernels/*.swift) against the SAME golden fixtures the Haskell
// contract emitted and the Python oracle re-derived (parity club since
// M5: Haskell = Python = Swift, + the nn/v1 numpy pipeline via the ga
// leg). Run from spec/:  see the Makefile `swift-verify` target.

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

// ── geometry: the crop derivation vs the fixture's case table ──────────────
// (CS1/CS6/CS7 — the app's canonicalSide/cropOrigin, device mosaic included)
let geo = loadJSON("\(dir)/geometry.json")
let geoSensor = (geo["sensor"] as! [Any]).map { Int(truncating: $0 as! NSNumber) }
if geoSensor != [4032, 3024] { die("geometry sensor is not the device-verified mosaic") }
let geoCanonical = Int(truncating: geo["canonicalSide"] as! NSNumber)
if BorealKernels.canonicalSideCap != geoCanonical { die("canonical cap drift") }
if BorealKernels.canonicalSide(width: geoSensor[0], height: geoSensor[1]) != geoCanonical {
    die("device mosaic does not derive the canonical side")
}
for c in geo["cropCases"] as! [[String: Any]] {
    let w = Int(truncating: c["w"] as! NSNumber)
    let h = Int(truncating: c["h"] as! NSNumber)
    let want = (c["side"] as? NSNumber).map { Int(truncating: $0) }  // null → nil
    let got = BorealKernels.canonicalSide(width: w, height: h)
    if got != want { die("crop side drift at \(w)x\(h): \(String(describing: got)) vs \(String(describing: want))") }
    if let s = got {
        let x0 = BorealKernels.cropOrigin(w, side: s)
        let y0 = BorealKernels.cropOrigin(h, side: s)
        if x0 != Int(truncating: c["x0"] as! NSNumber) { die("x0 drift at \(w)x\(h)") }
        if y0 != Int(truncating: c["y0"] as! NSNumber) { die("y0 drift at \(w)x\(h)") }
        if x0 % 2 != 0 || y0 % 2 != 0 { die("odd crop origin at \(w)x\(h)") }
    }
}
let geoRungs = (geo["rungs"] as! [Any]).map { Int(truncating: $0 as! NSNumber) }
if BorealKernels.msRungs(side: geoCanonical) != geoRungs {
    die("msRungs(\(geoCanonical)) does not reproduce the spec ladder")
}

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

// Binomial statistic (the V1 objective) — bit-exact vs the golden.
// Fixtures with stored indices verify histogram + χ²; the large LCG
// fixture (indices not stored; Haskell Integer LCG is unbounded)
// verifies the statistic from its stored counts.
let bn = loadJSON("\(dir)/binomial_golden.json")
for f in bn["fixtures"] as! [[String: Any]] {
    let goldenCounts = (f["counts"] as! [Any]).map { Int(truncating: $0 as! NSNumber) }
    let wantChi2 = (f["chi2F64"] as! NSNumber).doubleValue
    if let arr = f["indices"] as? [Any] {
        let idx = arr.map { UInt8(truncating: $0 as! NSNumber) }
        if BorealKernels.usageHistogram(idx) != goldenCounts {
            die("binomial counts drift: \(f["name"] ?? "?")")
        }
    }
    if BorealKernels.chiSquare(counts: goldenCounts) != wantChi2 {
        die("binomial chi2 drift: \(f["name"] ?? "?")")
    }
}

// Cycleset (N laws): positional phase decomposition, Q16-exact vs the
// golden, exactly as the oracle consumes it. The fixture mosaic is dyadic
// /16384 — exact in f32, and q16 lands on integers with no rounding, so
// scaling frame f by 2^f scales its golden Q16 planes exactly: the scaled
// 4-frame tensor pins the frame-major channel order c = 4*frame + phase.
let csAll = loadJSON("\(dir)/cycleset_golden.json")["fixture"] as! [String: Any]
let cside = (csAll["side"] as! NSNumber).intValue
let cmos = doubles(csAll["mosaicF64"]).map { Float($0) }
let csGolden = (csAll["phases"] as! [Any]).map { ints32($0) }
guard let cplanes = BorealKernels.csPhasePlanes(mosaic: cmos, side: cside)
else { die("csPhasePlanes returned nil") }
if cplanes.count != 4 { die("cycleset plane count") }
for p in 0 ..< 4 {
    if cplanes[p].map({ BorealKernels.q16(Double($0)) }) != csGolden[p] {
        die("cycleset phase \(p) drift")
    }
}
guard let creassembled = BorealKernels.csAssemble(planes: cplanes, side: cside)
else { die("csAssemble returned nil") }
if creassembled != cmos { die("cycleset bijection (N1) drift") }
let cframes = (0 ..< 4).map { f in cmos.map { $0 * Float(1 << f) } }
guard let ctensor = BorealKernels.csCycleTensor(frames: cframes, side: cside)
else { die("csCycleTensor returned nil") }
if ctensor.count != 16 { die("cycleset tensor is not 16 channels") }
for f in 0 ..< 4 {
    for p in 0 ..< 4 {
        let c = BorealKernels.csChannelIndex(frame: f, phase: p)
        let want = csGolden[p].map { $0 * Int32(1 << f) }
        if ctensor[c].map({ BorealKernels.q16(Double($0)) }) != want {
            die("cycleset tensor channel \(c) (frame \(f), phase \(p)) drift")
        }
    }
}

// Battle (BA5): the temporal delta primitive vs the golden, exact.
let btAll = loadJSON("\(dir)/battle_golden.json")
let bt = btAll["fixture"] as! [String: Any]
let btA = bytes(bt["a"]), btB = bytes(bt["b"])
let d = BorealKernels.frameDelta(btA, btB)
if d.pos != ints32(bt["deltaPos"]) { die("battle deltaPos drift") }
if d.new != bytes(bt["deltaNew"]) { die("battle deltaNew drift") }
if BorealKernels.churn(btA, btB) != Int(truncating: bt["churn"] as! NSNumber) { die("battle churn drift") }
if BorealKernels.applyDelta(btA, pos: d.pos, new: d.new) != btB { die("BA5 round-trip drift") }
if !BorealKernels.fractalSelfTest() { die("fractal ordering self-test failed") }

// Patch-major spot goldens: verify positions DIRECTLY against the emitted
// Haskell ordering. Identity Int32 frame (values = positions, injective)
// plus a UInt8 frame with value = position % 251 (prime, coprime to the
// 256-periodic patch structure, so any ordering error shows).
let pmSpots = btAll["patchMajorSpots"] as! [[String: Any]]
if pmSpots.count < 16 { die("patchMajorSpots fixture too small") }
let pmIdent = (0 ..< 65536).map { Int32($0) }
let pmIdentOut = BorealKernels.patchMajor(pmIdent)
let pmMod = (0 ..< 65536).map { UInt8($0 % 251) }
let pmModOut = BorealKernels.patchMajor(pmMod)
for s in pmSpots {
    let v = (s["v"] as! NSNumber).intValue, u = (s["u"] as! NSNumber).intValue
    let j = (s["j"] as! NSNumber).intValue, i = (s["i"] as! NSNumber).intValue
    let pos = (s["pos"] as! NSNumber).intValue
    let y = 16 * v + j, x = 16 * u + i
    if pmIdentOut[pos] != Int32(y * 256 + x) {
        die("patchMajor spot drift (identity) at (\(v),\(u),\(j),\(i))")
    }
    if pmModOut[pos] != pmMod[y * 256 + x] {
        die("patchMajor spot drift (mod-251) at (\(v),\(u),\(j),\(i))")
    }
}

// homeShare linking golden: regenerate the index stream per the fixture's
// baLcg convention (wrapping u64 == the unbounded Integer's bits 16..23),
// run the kernel, exact f64 (own/65536, power-of-two denominator).
let hsFix = btAll["homeShare"] as! [String: Any]
let hsN = (hsFix["n"] as! NSNumber).intValue
var hsState = UInt64(truncating: hsFix["seed"] as! NSNumber)
var hsIdx = [UInt8](repeating: 0, count: hsN)
for k in 0 ..< hsN {
    hsIdx[k] = UInt8((hsState >> 16) & 0xFF)
    hsState = hsState &* 6364136223846793005 &+ 1442695040888963407
}
guard let hsGot = BorealKernels.homeShare(hsIdx) else { die("homeShare returned nil") }
if hsGot != (hsFix["expected"] as! NSNumber).doubleValue {
    die("homeShare drift: \(hsGot)")
}

// Ditherwalk (P1): the FS walk loop vs the golden — indices byte-exact,
// dropped sums exact, and DW8 conservation re-asserted from the Swift
// outputs themselves (sum(target) − sum(palette[emitted]) == dropped).
let wk = loadJSON("\(dir)/walk_golden.json")
let wSide = (wk["side"] as! NSNumber).intValue
let wR = (wk["r"] as! NSNumber).intValue
let wTL = ints32(wk["targetL"]), wTA = ints32(wk["targetA"]), wTB = ints32(wk["targetB"])
let wPL = ints32(wk["paletteL"]), wPA = ints32(wk["paletteA"]), wPB = ints32(wk["paletteB"])
let wGot = BorealKernels.fsWalk(targetL: wTL, targetA: wTA, targetB: wTB,
                                palL: wPL, palA: wPA, palB: wPB,
                                side: wSide, r: wR)
if wGot.indices != bytes(wk["indices"]) { die("walk indices drift") }
let wDrop = (wk["dropped"] as! [Any]).map { Int64(truncating: $0 as! NSNumber) }
if wGot.dropped.0 != wDrop[0] || wGot.dropped.1 != wDrop[1]
    || wGot.dropped.2 != wDrop[2] { die("walk dropped drift") }
for (ch, target, pal) in [(0, wTL, wPL), (1, wTA, wPA), (2, wTB, wPB)] {
    let tSum = target.reduce(Int64(0)) { $0 + Int64($1) }
    let eSum = wGot.indices.reduce(Int64(0)) { $0 + Int64(pal[Int($1)]) }
    let drop = [wGot.dropped.0, wGot.dropped.1, wGot.dropped.2][ch]
    if tSum - eSum != drop { die("DW8 conservation broken on channel \(ch)") }
}

if !BorealKernels.fuseSelfTest() { die("fuse self-test failed") }
if !BorealKernels.sceneSelfTest() { die("scene self-test failed") }
if !BorealKernels.dngSelfTest() { die("DNG self-test failed") }

print("SWIFT KERNELS GREEN: bit/byte-exact against all goldens + ported self-tests")
