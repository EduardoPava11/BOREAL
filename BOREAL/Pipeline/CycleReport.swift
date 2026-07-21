import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The on-device ground-truth artifact (BOREAL-16LAB-DESIGN.md verification):
/// capture ONE 4-DNG cycle, run the full L2 chain on the phone, and package
/// everything needed for Mac-side analysis into an AirDrop-able bundle:
///
///   report.json   biases, σ grid, the seed palette (Q16 + display sRGB8),
///                 the full L/a/b band buffers (every rung is a prefix), and
///                 the GIF-target INDEX MAP at each rung 16…256
///   rung_N.png    palette-mapped renders (index map × palette — literally
///                 a preview of the GIF frames this ISP targets)
///   frame_N.dng   the 4 source DNGs, so the Mac oracle can replay the
///                 exact same pipeline from the exact same photons
enum CycleReport {

    static let rungs = [16, 32, 64, 128, 256, 512]   // 512 = render ceiling (2026-07-19)

    struct BuildError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Everything the preview surface and the AirDrop bundle need.
    struct Report: Sendable {
        let urls: [URL]                  // report.json + rung PNGs + source DNGs
        let side: Int                    // ceiling rung
        let paletteRGB: [UInt8]          // 256 × RGB — the seed, display-encoded
        let indexMaps: [Int: [UInt8]]    // rung → GIF index map
        let frameIndices: [[UInt8]]      // the cycle's 4 per-frame ceiling maps (THE GIF)
        let sigma: [Float]               // 256-cell dither budget
    }

    /// Run the chain and write the bundle. Returns the report (previewable
    /// in-app AND shareable — the same decode, no second rendering path).
    nonisolated static func build(dngs: [Data], biases: [Float]) -> Result<Report, BuildError> {
        Perf.shared.reset()              // P0: this cycle owns the perf record
        Diag.shared.reset()              // and its own narrative (log.txt)
        let cycle = BurstController.Cycle(index: 0, biases: biases, dngs: dngs)
        let outcome = Perf.shared.time("cycleReduce") {
            BurstController.reduce(cycle)
        }
        guard outcome.ok, let bands = outcome.bands else {
            return .failure(BuildError(message: "reduction failed: \(outcome.note)"))
        }

        // The seed 16×16 IS the palette: band0 of each channel — ORDER
        // rotated to portrait with the render (same colors; homeShare's
        // patch↔option pairing needs one shared orientation).
        let palL = BorealKernels.rotateCW(Array(bands.L[0..<256]), side: 16)
        let palA = BorealKernels.rotateCW(Array(bands.a[0..<256]), side: 16)
        let palB = BorealKernels.rotateCW(Array(bands.b[0..<256]), side: 16)
        let palRGB = Kernel.oklabQ16ToSRGB8(L: palL, a: palA, b: palB)

        // Per rung: decode THE rung-r demosaic from the multi-scale stack
        // (MS3), then the GIF-target index map.
        var indexMaps: [Int: [UInt8]] = [:]
        let chromaRung = BorealKernels.renderChromaRung
        for r in Kernel.msRungs(side: bands.mosaicSide) {
            guard let iL = Kernel.msDecode(bands.L, mosaicSide: bands.mosaicSide, rung: r),
                  var iA = Kernel.msDecode(bands.a, mosaicSide: bands.mosaicSide, rung: r),
                  var iB = Kernel.msDecode(bands.b, mosaicSide: bands.mosaicSide, rung: r)
            else { return .failure(BuildError(message: "prefix decode failed at rung \(r)")) }
            // RENDER-CHROMA split: rungs above the chroma rung take a/b
            // from the chroma rung's own demosaic, nearest-upscaled.
            if r > chromaRung,
               let ca = Kernel.msDecode(bands.a, mosaicSide: bands.mosaicSide, rung: chromaRung),
               let cb = Kernel.msDecode(bands.b, mosaicSide: bands.mosaicSide, rung: chromaRung) {
                iA = BorealKernels.upscalePlane(ca, from: chromaRung, to: r)
                iB = BorealKernels.upscalePlane(cb, from: chromaRung, to: r)
            }
            // PORTRAIT: rotate decoded planes 90° CW before indexing (the
            // sensor is landscape; bands stay sensor-native).
            indexMaps[r] = Kernel.indexMap(L: BorealKernels.rotateCW(iL, side: r),
                                           a: BorealKernels.rotateCW(iA, side: r),
                                           b: BorealKernels.rotateCW(iB, side: r),
                                           palL: palL, palA: palA, palB: palB)
        }

        // ── Write the bundle ────────────────────────────────────────────
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(BundleStamp.bundleName("BOREAL-cycle"))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var urls: [URL] = []

            var json: [String: Any] = [
                "design": "BOREAL-16LAB-DESIGN.md",
                // Device-testing observability: which fuse ran (MF laws —
                // MLE when all 4 frames carried a NoiseProfile).
                "fuse": outcome.fusedMLE ? "mle" : "classic",
                // Per-frame device facts: EXIF triple, calibrated noise
                // model, maker's display-lift hint, rail censoring
                // fractions — everything a Mac session previously had to
                // re-decode the DNGs to learn.
                "frames": outcome.frameFacts.map { ff -> [String: Any] in
                    ["width": ff.width, "height": ff.height,
                     "iso": Double(ff.iso),
                     "exposureTime": Double(ff.exposureTime),
                     "fNumber": Double(ff.fNumber),
                     "noiseS": ff.noiseS, "noiseO": ff.noiseO,
                     "baselineExposure": ff.baselineExposure,
                     "clipHiFrac": ff.clipHiFrac,
                     "subBlackFrac": ff.subBlackFrac]
                },
                // NT self-check: the magenta law, verified on THIS capture.
                "ntSpread": outcome.ntSpread,
                // Render composition: luma at the render ceiling, chroma
                // from this rung (its own demosaic, nearest-upscaled) —
                // the anti-moiré chroma-bandwidth split.
                "renderChromaRung": BorealKernels.renderChromaRung,
                "note2": "bands are MULTI-SCALE residual stacks (MS laws): rung16 ++ (rung2s - nearest-up(rungS)) coarse->fine; prefix through rung r = sum of r'^2 and decodes to THE rung-r demosaic; palette = bands[0..256) (the seed, absolute)",
                "mosaicSide": bands.mosaicSide,
                "rungs": Kernel.msRungs(side: bands.mosaicSide),
                "ev": [
                    "plannedBiases": biases.map { Double($0) },
                    "actualRatios": outcome.actualEV.map { Double($0) },
                    "nextPlan": (outcome.plan ?? []).map { Double($0) },
                ],
                "note": "bands are prefix-layout Q16 OKLab; bands[0..r*r] decodes rung r exactly; palette = band0 (seed 16x16); indices via i64 argmin ties-lowest",
                "biases": biases.map { Double($0) },
                "ceiling": bands.side,
                "sigma": bands.sigma.map { Double($0) },
                "palette": [
                    "q16L": palL.map(Int.init), "q16a": palA.map(Int.init),
                    "q16b": palB.map(Int.init),
                    "rgb8": palRGB.map(Int.init),
                ],
                // TF1.2 (schema 3): the stack moved OUT of the JSON — see
                // bands.bin (report.json drops ~10 MB of number text).
                // Trainer note: nn/v1 readers of json["bands"] must switch
                // to the binary (registered T3 follow-up).
                "bandsFile": "bands.bin: L then a then b, each \(bands.L.count) Int32 little-endian, prefix layout per the MS laws (sensor orientation)",
            ]
            for (k, v) in BundleStamp.dict() { json[k] = v }
            // TF1.2 (schema 3): index maps ride maps.bin (u8, rungs
            // ascending, r² bytes each), not JSON text — the PNGs render
            // them, the binary carries them exactly.
            json["mapsFile"] = "maps.bin: u8 index maps, rungs ascending "
                + "\(indexMaps.keys.sorted().map(String.init).joined(separator: ",")) "
                + "(r² bytes each, row-major, portrait orientation)"

            // TB (the pivot): the cycle's temporal statistics — noise meter
            // ĝ, σ_time (D on the seed grid), D deciles. TB laws + golden
            // gate the kernel; this is its device record.
            if let t = outcome.temporal {
                json["temporal"] = [
                    "note": "TB laws (spec/Boreal/TemporalBayer.hs): gain = robust (uncalibrated) shot-noise meter from the 4-frame EV stack; sigmaTime = alias-discriminator D aggregated to the 16x16 seed grid (noise-only ~ 1, alias/chroma-motion >> 1); dDeciles = 11-point D sketch at the ceiling rung",
                    "gain": t.gain,
                    "sigmaTime": t.sigmaTime,
                    "dDeciles": t.dDeciles,
                ]
            }

            // The binomial readout (V1's objective, live): per rung, how
            // close this scene + seed sit to balanced usage. χ² = 0 is the
            // A2 permutation; 255·n is one-color collapse.
            json["binomial"] = Dictionary(uniqueKeysWithValues:
                indexMaps.map { rung, indices in
                    var entry: [String: Any] = [
                        "counts": BorealKernels.usageHistogram(indices),
                        "chi2": BorealKernels.indexChiSquare(indices),
                    ]
                    // At the ceiling, the (16×16)×(16×16) factorization
                    // adds the H statistic: how much each patch already
                    // speaks its own cell's color (1 = perfect H).
                    if let hs = BorealKernels.homeShare(indices) {
                        entry["homeShare"] = hs
                    }
                    return (String(rung), entry)
                })

            // ── N0: the training record ─────────────────────────────────
            // The (16×16)×(16×16) fractal structure per frame (L plane
            // first-class: this frame's own 16² seed-L options + its
            // ceiling L in the H2 patch-major ordering), and the BA5
            // temporal deltas between the batch's consecutive frames.
            // {L fractal structure, deltas, EV trace} — identical shape
            // from synth and device (the "ev" section above is the trace).
            if !outcome.frameL.isEmpty {
                json["fractal"] = [
                    "ordering": "patch-major: patch (v,u) outer row-major, inner (j,i) row-major (H2/PatchGrid); pos=(v*16+u)*256+(j*16+i)",
                    "note": "patchesL rides fractal.bin (Int32 LE, one 65536-plane per frame, capture order); seedL below",
                    "frames": outcome.frameL.map { f in
                        ["seedL": f.seedL.map(Int.init)]
                    },
                ]
            }
            if outcome.frameIndices.count == 4 {
                var churn: [Int] = []
                for t in 0..<3 {
                    let a = outcome.frameIndices[t], b = outcome.frameIndices[t + 1]
                    let d = Kernel.frameDelta(a, b)
                    guard Kernel.applyDelta(a, pos: d.pos, new: d.new) == b else {
                        return .failure(BuildError(message: "BA5 round-trip failed at t=\(t)"))
                    }
                    churn.append(d.pos.count)
                }
                json["deltas"] = [
                    "note": "BA5 churn counts between consecutive per-frame maps (round-trip verified at write time); exact lists recompute from frames.bin",
                    "churn": churn,
                ]
            }

            for (r, indices) in indexMaps.sorted(by: { $0.key < $1.key }) {
                if let png = renderPNG(indices: indices, side: r, paletteRGB: palRGB) {
                    let u = dir.appendingPathComponent("rung_\(r).png")
                    try png.write(to: u)
                    urls.append(u)
                }
            }

            // The rung LADDER as an actual GIF89a — the ISP's native format
            // animating coarse → fine (each rung nearest-upscaled to the
            // ceiling so all frames share the canvas).
            let ceiling = indexMaps.keys.max() ?? 16
            let ladderFrames = indexMaps.sorted(by: { $0.key < $1.key }).map {
                Kernel.upscaleIndices($0.value, from: $0.key, to: ceiling)
            }
            if let gif = Kernel.gifEncode(frames: ladderFrames, side: ceiling,
                                          paletteRGB: palRGB, delayCs: 50) {
                let u = dir.appendingPathComponent("ladder.gif")
                try gif.write(to: u)
                urls.append(u)
            }

            // The cycle's 4 PER-FRAME renders as a GIF (each frame
            // EV-normalized by its own e_t — the temporal unit at 5 cs).
            // The same maps ride the Report so the preview can animate them.
            let cycleFrames = outcome.frameIndices.allSatisfy({ $0.count == ceiling * ceiling })
                ? outcome.frameIndices : []
            if !cycleFrames.isEmpty,
               let gif = Kernel.gifEncode(frames: cycleFrames, side: ceiling,
                                          paletteRGB: palRGB, delayCs: 5) {
                let u = dir.appendingPathComponent("cycle.gif")
                try gif.write(to: u)
                urls.append(u)
            }

            for (i, dng) in dngs.enumerated() {
                let u = dir.appendingPathComponent("frame_\(i + 1).dng")
                try dng.write(to: u)
                urls.append(u)
            }

            // TF1.2: the binary planes (single-cycle mirrors the burst
            // bundle's philosophy — JSON carries facts, binaries carry
            // planes). maps.bin: fused per-rung maps; frames.bin: the 4
            // per-frame ceiling maps; fractal.bin: patch-major L planes.
            var mapsBin = Data()
            for r in indexMaps.keys.sorted() { mapsBin.append(contentsOf: indexMaps[r]!) }
            let mapsURL = dir.appendingPathComponent("maps.bin")
            try mapsBin.write(to: mapsURL)
            urls.append(mapsURL)
            if outcome.frameIndices.count == 4 {
                var framesBin = Data()
                for f in outcome.frameIndices { framesBin.append(contentsOf: f) }
                let framesURL = dir.appendingPathComponent("frames.bin")
                try framesBin.write(to: framesURL)
                urls.append(framesURL)
                json["framesFile"] = "frames.bin: the 4 per-frame ceiling index maps, u8, capture order (portrait)"
            }
            if !outcome.frameL.isEmpty {
                var bin = Data(capacity: outcome.frameL.count * 65536 * 4)
                for f in outcome.frameL {
                    f.patchesL.withUnsafeBufferPointer {
                        bin.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self))
                    }
                }
                let u = dir.appendingPathComponent("fractal.bin")
                try bin.write(to: u)
                urls.append(u)
            }

            // TF1.2: the stack as binary (L ++ a ++ b, Int32 LE).
            var bandsBin = Data(capacity: bands.L.count * 12)
            for plane in [bands.L, bands.a, bands.b] {
                plane.withUnsafeBufferPointer {
                    bandsBin.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self))
                }
            }
            let bandsURL = dir.appendingPathComponent("bands.bin")
            try bandsBin.write(to: bandsURL)
            urls.append(bandsURL)

            // The device narrative for the Mac session: log.txt.
            let logURL = dir.appendingPathComponent("log.txt")
            try Diag.shared.drain().write(to: logURL, atomically: true, encoding: .utf8)
            urls.append(logURL)

            // report.json goes LAST so the perf block covers every stage of
            // this build (including the PNG/GIF encodes above) — but rides
            // FIRST in the share list, the bundle's front page.
            Perf.shared.sampleThermal("end")
            json["perf"] = Perf.shared.reportBlock()
            let jsonURL = dir.appendingPathComponent("report.json")
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try data.write(to: jsonURL)
            urls.insert(jsonURL, at: 0)

            // THE PREVIEW (TF1.1): the bundle's front door, first in the
            // share list.
            let previewURL = dir.appendingPathComponent("preview.html")
            try PreviewHTML.cyclePage(json: json, dir: dir)
                .write(to: previewURL, atomically: true, encoding: .utf8)
            urls.insert(previewURL, at: 0)

            // manifest.json (TF1.4): integrity, written last.
            let manifestURL = dir.appendingPathComponent("manifest.json")
            try JSONSerialization.data(
                withJSONObject: BundleStamp.manifest(of: urls),
                options: [.sortedKeys]).write(to: manifestURL)
            urls.append(manifestURL)

            return .success(Report(urls: urls, side: bands.side, paletteRGB: palRGB,
                                   indexMaps: indexMaps, frameIndices: cycleFrames,
                                   sigma: bands.sigma))
        } catch {
            return .failure(BuildError(message: "write failed: \(error.localizedDescription)"))
        }
    }

    /// Palette-mapped CGImage from an index map — the preview IS the product
    /// decode. Callers upscale with interpolation .none (nearest neighbor).
    nonisolated static func cgImage(indices: [UInt8], side: Int,
                                    paletteRGB: [UInt8]) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            let p = Int(indices[i]) * 3
            pixels[4 * i] = paletteRGB[p]
            pixels[4 * i + 1] = paletteRGB[p + 1]
            pixels[4 * i + 2] = paletteRGB[p + 2]
        }
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    /// PNG for the AirDrop bundle, via the same cgImage decode.
    nonisolated private static func renderPNG(indices: [UInt8], side: Int,
                                              paletteRGB: [UInt8]) -> Data? {
        guard let img = cgImage(indices: indices, side: side, paletteRGB: paletteRGB)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString,
                                                          1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
