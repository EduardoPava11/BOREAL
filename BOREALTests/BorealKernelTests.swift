import CoreGraphics
import ImageIO
import XCTest

/// BOREALTests — G5 closed (2026-07-19). Kernel-core logic tests,
/// camera-free: the target compiles BOREAL/Kernels directly (no app
/// host) and replays the spec gate's parity legs against bundled
/// fixtures INSIDE Xcode's build context. `make test-xcode` is a real
/// second gate: it catches target-membership, bundling, and
/// iOS-toolchain divergences the CLI harness (macOS swiftc) cannot.
///
/// Precision classes mirror the gate: ISP legs compare BITWISE;
/// the V1 engine leg is tolerance parity (the learned path never
/// claims bit-exactness).
final class BorealKernelTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self)
            .url(forResource: name, withExtension: ext),
            "missing bundled fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    private func json(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture(name, "json")) as? [String: Any])
    }

    private func doubles(_ v: Any?) -> [Double] {
        (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
    }

    // ── Ported self-tests (the kernels' own vectors) ────────────────────

    func testKernelSelfTests() {
        XCTAssertTrue(BorealKernels.fuseSelfTest(), "fuse self-test")
        XCTAssertTrue(BorealKernels.sceneSelfTest(), "scene self-test")
        XCTAssertTrue(BorealKernels.dngSelfTest(), "DNG self-test")
    }

    // ── NT law: the camera→ProPhoto composition (the magenta law) ──────

    func testNeutralTestLaw() throws {
        let cam = try XCTUnwrap(try json("colorpath_golden")["camera"] as? [String: Any])
        func rats(_ key: String) -> [Double] {
            let xs = doubles(cam[key])
            return stride(from: 0, to: xs.count, by: 2).map { xs[$0] / xs[$0 + 1] }
        }
        let asnA = rats("deviceASNrat")
        let asn = (asnA[0], asnA[1], asnA[2])
        let m = try XCTUnwrap(BorealKernels.cameraToProPhotoCM(rats("deviceCM2rat"), asn: asn))
        for (i, w) in doubles(cam["camToPP_CM"]).enumerated() {
            XCTAssertEqual(m[i].bitPattern, w.bitPattern, "camToPP_CM[\(i)]")
        }
        let n = BorealKernels.apply3d(m, asn)
        let mx = max(n.0, max(n.1, n.2)), mn = min(n.0, min(n.1, n.2))
        XCTAssertLessThan((mx - mn) / mx, 1e-5, "NT: neutral must map to gray")
    }

    // ── Geometry: the ladder and the two ceilings ───────────────────────

    func testLadderContract() throws {
        let geo = try json("geometry")
        let rungs = (geo["rungs"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
        XCTAssertEqual(BorealKernels.msRungs(side: 2048), rungs)
        XCTAssertEqual(BorealKernels.msRungs(side: 2048).max(),
                       (geo["renderRung"] as? NSNumber)?.intValue)
        XCTAssertEqual((geo["ceilingRung"] as? NSNumber)?.intValue, 256)
    }

    // ── MleFuse (MF laws): bitwise vs the golden ────────────────────────

    func testMLEFuseGolden() throws {
        let mf = try json("mlefuse_golden")
        let clip = try XCTUnwrap(mf["clip"] as? NSNumber).doubleValue
        let ev = doubles(mf["ev"])
        let pr = doubles(mf["profiles"])
        var s = UInt64(try XCTUnwrap(mf["lcgSeed"] as? NSNumber).intValue)
        let want = doubles(mf["fused"])
        for i in 0..<256 {
            let x = Double((s >> 16) % 4096) / 4096
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let obs = (0..<4).map { t in
                (y: ev[t] * x, e: ev[t], s: pr[2 * t], o: pr[2 * t + 1])
            }
            let got = BorealKernels.fuseSampleMLE(clip: clip, obs: obs)
            XCTAssertEqual(got.bitPattern, want[i].bitPattern, "fused[\(i)]")
        }
    }

    // ── Bin-commutation theorem: bitwise in f64 on the dyadic fixture ──

    func testBinCommutationTheorem() throws {
        let bc = try json("bincontract_golden")
        let side = try XCTUnwrap(bc["side"] as? NSNumber).intValue
        let b = try XCTUnwrap(bc["b"] as? NSNumber).intValue
        var s = UInt64(try XCTUnwrap(bc["lcgSeed"] as? NSNumber).intValue)
        var mos = [Float](repeating: 0, count: side * side)
        for k in 0..<mos.count {
            mos[k] = Float((s >> 16) % 4096) / 4096
            s = s &* 6364136223846793005 &+ 1442695040888963407
        }
        let binned = try XCTUnwrap(BorealKernels.binPhase(mos, side: side, b: b))
        for (i, w) in doubles(bc["binned"]).enumerated() {
            XCTAssertEqual(Double(binned[i]).bitPattern, w.bitPattern, "binned[\(i)]")
        }
        let full = BorealKernels.tbChannelMeans(mos, side: side, rung: 16, cfa: 0)
        let bin2 = BorealKernels.tbChannelMeans(binned, side: side / b, rung: 16, cfa: 0)
        XCTAssertEqual(full.r, bin2.r, "THEOREM: R means must factor through binning")
        XCTAssertEqual(full.g, bin2.g, "THEOREM: G means must factor through binning")
        XCTAssertEqual(full.b, bin2.b, "THEOREM: B means must factor through binning")
    }

    // ── TemporalBayer (TB laws): bitwise vs the golden ──────────────────

    func testTemporalStatsGolden() throws {
        let tb = try json("temporalbayer_golden")
        let side = try XCTUnwrap(tb["side"] as? NSNumber).intValue
        let rung = try XCTUnwrap(tb["ceiling"] as? NSNumber).intValue
        let seed = try XCTUnwrap(tb["seed"] as? NSNumber).intValue
        let frames = try XCTUnwrap(tb["mosaics"] as? [Any])
            .map { doubles($0).map { Float($0) } }
        let got = try XCTUnwrap(BorealKernels.temporalStats(
            frames: frames, side: side,
            cfa: UInt32(try XCTUnwrap(tb["cfa"] as? NSNumber).intValue),
            exposures: doubles(tb["ev"]), rung: rung, seed: seed))
        XCTAssertEqual(got.gain.bitPattern,
                       (try XCTUnwrap(tb["ghat"] as? NSNumber)).doubleValue.bitPattern)
        for (i, w) in doubles(tb["D"]).enumerated() {
            XCTAssertEqual(got.d[i].bitPattern, w.bitPattern, "D[\(i)]")
        }
        for (i, w) in doubles(tb["sigmaTime"]).enumerated() {
            XCTAssertEqual(got.sigmaTime[i].bitPattern, w.bitPattern, "sigmaTime[\(i)]")
        }
    }

    // ── Orientation: the portrait rotation is a clean permutation ──────

    func testRotateCW() {
        // Hand case: 2×2 rows [1,2],[3,4] → CW → [3,1],[4,2].
        XCTAssertEqual(BorealKernels.rotateCW([1, 2, 3, 4], side: 2), [3, 1, 4, 2])
        // rotate ×4 == identity, and one rotation is a permutation
        // (same multiset) — pinned on a 16² LCG plane.
        var s: UInt64 = 99
        var plane = [Int32](repeating: 0, count: 256)
        for i in 0..<256 {
            plane[i] = Int32((s >> 16) % 4096)
            s = s &* 6364136223846793005 &+ 1442695040888963407
        }
        var r = plane
        for _ in 0..<4 { r = BorealKernels.rotateCW(r, side: 16) }
        XCTAssertEqual(r, plane, "rotate ×4 must be identity")
        XCTAssertEqual(BorealKernels.rotateCW(plane, side: 16).sorted(),
                       plane.sorted(), "rotation must be a permutation")
    }

    // ── Render-chroma transport: nearest upscale, same law as indices ──

    func testUpscalePlane() {
        let p: [Int32] = [10, 20, 30, 40]                       // 2×2
        let up = BorealKernels.upscalePlane(p, from: 2, to: 4)  // 4×4
        XCTAssertEqual(up, [10, 10, 20, 20,
                            10, 10, 20, 20,
                            30, 30, 40, 40,
                            30, 30, 40, 40], "block-constant nearest upscale")
        // convention identity with upscaleIndices on the same data
        let idx: [UInt8] = [1, 2, 3, 4]
        let upIdx = BorealKernels.upscaleIndices(idx, from: 2, to: 4)
        XCTAssertEqual(up.map { UInt8($0 / 10) }, upIdx,
                       "upscalePlane must share upscaleIndices' convention")
    }

    // ── G4 CLOSED: the round-trip exit law — decode-with-system-decoder
    // == our encode. ImageIO (the OS's own GIF decoder) must reproduce
    // every pixel of every frame we encode. ──────────────────────────────

    func testGIFSystemDecoderRoundTrip() throws {
        let side = 64
        var pal = [UInt8]()
        for i in 0..<256 {
            pal += [UInt8(i), UInt8((i &* 37) % 256), UInt8(255 - i)]
        }
        var s: UInt64 = 7
        var frames: [[UInt8]] = []
        for _ in 0..<3 {
            var f = [UInt8](repeating: 0, count: side * side)
            for k in 0..<f.count {
                f[k] = UInt8((s >> 16) % 256)
                s = s &* 6364136223846793005 &+ 1442695040888963407
            }
            frames.append(f)
        }
        let gif = try XCTUnwrap(BorealKernels.gifEncode(frames: frames, side: side,
                                                        gct: pal, delayCs: 5))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 3, "frame count through ImageIO")
        for (t, f) in frames.enumerated() {
            let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, t, nil))
            var px = [UInt8](repeating: 0, count: side * side * 4)
            let ctx = try XCTUnwrap(CGContext(
                data: &px, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
            var bad = 0
            for i in 0..<(side * side) {
                let p = Int(f[i]) * 3
                if px[4 * i] != pal[p] || px[4 * i + 1] != pal[p + 1]
                    || px[4 * i + 2] != pal[p + 2] { bad += 1 }
            }
            XCTAssertEqual(bad, 0, "frame \(t): \(bad) pixels differ via system decoder")
        }
    }

    // ── V1 engine: tolerance parity on the champion package ────────────

    func testV1ForwardParity() throws {
        let vf = try json("v1h_forward_golden")
        let side = try XCTUnwrap(vf["inSide"] as? NSNumber).intValue
        let pkg = try BorealKernels.loadV1HWeights(fixture("v1h_d96.weights", "bin"))
        var input = [Float](repeating: 0, count: side * side * 16)
        var s = UInt64(try XCTUnwrap(vf["lcgSeed"] as? NSNumber).intValue)
        for k in 0..<input.count {
            input[k] = Float((s >> 16) % 4096) / 4096
            s = s &* 6364136223846793005 &+ 1442695040888963407
        }
        let seed = try XCTUnwrap(BorealKernels.v1hSeedForward(pkg, input: input,
                                                              inSide: side))
        let want = doubles(vf["seedOut"])
        XCTAssertEqual(seed.count, want.count)
        var maxAbs = 0.0
        for (i, w) in want.enumerated() { maxAbs = max(maxAbs, abs(Double(seed[i]) - w)) }
        let tol = try XCTUnwrap(vf["maxAbsTolerance"] as? NSNumber).doubleValue
        XCTAssertLessThanOrEqual(maxAbs, tol,
            "V1 engine drifted beyond the learned path's tolerance class")
    }
}
