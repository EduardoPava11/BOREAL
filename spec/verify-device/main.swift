// Device-replay harness: the Mac re-runs a LAB report bundle's DNGs through
// the SAME Swift kernels the phone ran, and asserts bit-exact agreement with
// the phone's own report.json — end-to-end parity with real photons.
// Usage: verify-device <dir containing report.json + frame_1..4.dng>

import Foundation

func die(_ msg: String) -> Never {
    print("DEVICE REPLAY FAIL: \(msg)")
    exit(1)
}

guard CommandLine.arguments.count > 1 else { die("usage: verify-device <bundle dir>") }
let dir = CommandLine.arguments[1]

guard let reportData = FileManager.default.contents(atPath: "\(dir)/report.json"),
      let report = (try? JSONSerialization.jsonObject(with: reportData)) as? [String: Any]
else { die("cannot load report.json") }

// ── Decode the four DNGs (the flagged LJPEG-on-real-iPhone risk) ───────────
var frames: [BorealKernels.DNGMosaic] = []
for i in 1...4 {
    guard let data = FileManager.default.contents(atPath: "\(dir)/frame_\(i).dng")
    else { die("missing frame_\(i).dng") }
    let (mosaic, status) = BorealKernels.decodeDNG(data)
    guard let m = mosaic else { die("frame_\(i) decode status \(status)") }
    frames.append(m)
    print("  frame_\(i): \(m.width)x\(m.height) cfa=\(m.cfa) black=\(m.black) " +
          "white=\(m.white) et=\(m.exposureTime) iso=\(m.iso)")
}

// ── Mirror BurstController.reduce's cycle path exactly ─────────────────────
let ref = frames[0]
var side = 256
while side * 2 <= min(ref.width, ref.height) && side * 2 <= 2048 { side *= 2 }

func cropCenter(_ f: BorealKernels.DNGMosaic) -> [UInt16] {
    let x0 = ((f.width - side) / 2) & ~1
    let y0 = ((f.height - side) / 2) & ~1
    var s = [UInt16]()
    s.reserveCapacity(side * side)
    f.samples.withUnsafeBufferPointer { p in
        guard let base = p.baseAddress else { return }
        for y in 0..<side {
            s.append(contentsOf: UnsafeBufferPointer(
                start: base + (y0 + y) * f.width + x0, count: side))
        }
    }
    return s
}

let cropped = frames.map(cropCenter)
let ev = BorealKernels.relativeExposures(et: frames.map(\.exposureTime),
                                         iso: frames.map(\.iso),
                                         fnum: frames.map(\.fNumber))
print("  EV ratios: \(ev)")
if let evj = (report["ev"] as? [String: Any])?["actualRatios"] as? [Any] {
    let want = evj.map { Float(truncating: $0 as! NSNumber) }
    for (g, w) in zip(ev, want) where abs(g - w) > 1e-4 * max(1, w) {
        die("EV drift: \(ev) vs \(want)")
    }
}

guard let fused = BorealKernels.fuse(frames: cropped, black: ref.black,
                                     white: ref.white, exposures: ev,
                                     knee: 0.90, clip: 0.98)
else { die("fuse failed") }

guard let stacks = BorealKernels.msEncode(mosaic: fused, side: side,
                                          cfa: ref.cfa, camToPP: ref.camToPP,
                                          hasColor: ref.hasColor)
else { die("msEncode failed") }

// ── Bit-exact: the phone's bands vs the Mac's ──────────────────────────────
let bands = report["bands"] as! [String: [Any]]
for (key, mine) in [("L", stacks.L), ("a", stacks.a), ("b", stacks.b)] {
    let want = bands[key]!.map { Int32(truncating: $0 as! NSNumber) }
    guard want.count == mine.count else { die("bands \(key) length") }
    for i in 0..<want.count where want[i] != mine[i] {
        die("bands \(key) drift at \(i): phone \(want[i]) vs mac \(mine[i])")
    }
}
print("  bands: L/a/b BIT-EXACT (\(stacks.L.count) x3 coefficients)")

// ── Index maps + statistics ────────────────────────────────────────────────
let palL = Array(stacks.L[0..<256]), palA = Array(stacks.a[0..<256]),
    palB = Array(stacks.b[0..<256])
let reportMaps = report["indexMaps"] as! [String: [Any]]
let reportBinomial = report["binomial"] as! [String: [String: Any]]

for rung in BorealKernels.msRungs(side: side) {
    guard let iL = BorealKernels.msDecode(stacks.L, mosaicSide: side, rung: rung),
          let iA = BorealKernels.msDecode(stacks.a, mosaicSide: side, rung: rung),
          let iB = BorealKernels.msDecode(stacks.b, mosaicSide: side, rung: rung)
    else { die("decode rung \(rung)") }
    let idx = BorealKernels.indexMap(L: iL, a: iA, b: iB,
                                     palL: palL, palA: palA, palB: palB)
    let want = reportMaps[String(rung)]!.map { UInt8(truncating: $0 as! NSNumber) }
    if idx != want { die("index map drift at rung \(rung)") }

    let stats = reportBinomial[String(rung)]!
    let chi2 = BorealKernels.indexChiSquare(idx)
    if chi2 != (stats["chi2"] as! NSNumber).doubleValue {
        die("chi2 drift at rung \(rung)")
    }
    if let hsWant = stats["homeShare"] as? NSNumber {
        guard let hs = BorealKernels.homeShare(idx),
              hs == hsWant.doubleValue else { die("homeShare drift") }
    }
    print("  rung \(rung): index map + chi2 EXACT" +
          (rung == 256 ? " + homeShare EXACT" : ""))
}

print("DEVICE REPLAY GREEN: Mac == iPhone, bit-exact, real photons")
