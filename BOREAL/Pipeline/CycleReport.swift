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

    static let rungs = [16, 32, 64, 128, 256]

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
        let sigma: [Float]               // 256-cell dither budget
    }

    /// Run the chain and write the bundle. Returns the report (previewable
    /// in-app AND shareable — the same decode, no second rendering path).
    nonisolated static func build(dngs: [Data], biases: [Float]) -> Result<Report, BuildError> {
        let cycle = BurstController.Cycle(index: 0, biases: biases, dngs: dngs)
        let outcome = BurstController.reduce(cycle)
        guard outcome.ok, let bands = outcome.bands else {
            return .failure(BuildError(message: "reduction failed: \(outcome.note)"))
        }

        // The seed 16×16 IS the palette: band0 of each channel, verbatim.
        let palL = Array(bands.L[0..<256])
        let palA = Array(bands.a[0..<256])
        let palB = Array(bands.b[0..<256])
        let palRGB = Kernel.oklabQ16ToSRGB8(L: palL, a: palA, b: palB)

        // Per rung: decode THE rung-r demosaic from the multi-scale stack
        // (MS3), then the GIF-target index map.
        var indexMaps: [Int: [UInt8]] = [:]
        for r in Kernel.msRungs(side: bands.mosaicSide) {
            guard let iL = Kernel.msDecode(bands.L, mosaicSide: bands.mosaicSide, rung: r),
                  let iA = Kernel.msDecode(bands.a, mosaicSide: bands.mosaicSide, rung: r),
                  let iB = Kernel.msDecode(bands.b, mosaicSide: bands.mosaicSide, rung: r)
            else { return .failure(BuildError(message: "prefix decode failed at rung \(r)")) }
            indexMaps[r] = Kernel.indexMap(L: iL, a: iA, b: iB,
                                           palL: palL, palA: palA, palB: palB)
        }

        // ── Write the bundle ────────────────────────────────────────────
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BOREAL-16LAB-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var urls: [URL] = []

            var json: [String: Any] = [
                "design": "BOREAL-16LAB-DESIGN.md",
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
                "bands": [
                    "L": bands.L.map(Int.init),
                    "a": bands.a.map(Int.init),
                    "b": bands.b.map(Int.init),
                ],
            ]
            json["indexMaps"] = Dictionary(uniqueKeysWithValues:
                indexMaps.map { (String($0.key), $0.value.map(Int.init)) })

            let jsonURL = dir.appendingPathComponent("report.json")
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try data.write(to: jsonURL)
            urls.append(jsonURL)

            for (r, indices) in indexMaps.sorted(by: { $0.key < $1.key }) {
                if let png = renderPNG(indices: indices, side: r, paletteRGB: palRGB) {
                    let u = dir.appendingPathComponent("rung_\(r).png")
                    try png.write(to: u)
                    urls.append(u)
                }
            }

            for (i, dng) in dngs.enumerated() {
                let u = dir.appendingPathComponent("frame_\(i + 1).dng")
                try dng.write(to: u)
                urls.append(u)
            }
            return .success(Report(urls: urls, side: bands.side, paletteRGB: palRGB,
                                   indexMaps: indexMaps, sigma: bands.sigma))
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
