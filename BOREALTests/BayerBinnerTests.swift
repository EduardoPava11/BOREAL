import XCTest
import Metal
@testable import BOREAL

/// Verifies BayerBinner end-to-end on synthetic 2944² BGGR mosaics. Runs
/// on the iPhone 17 Pro simulator (Apple Silicon Metal). If Metal is
/// unavailable (e.g., on Intel hosts running Rosetta), tests skip-not-fail.
///
/// Reference math:
///   - sRGB primaries → CIE XYZ via BT.709 matrix (D65)
///   - Pure mid-gray RGB(0.5, 0.5, 0.5) → XYZ ≈ (0.4754, 0.5000, 0.5444)
///     → LAB ≈ (76.07, 0.0, 0.0)  [L*=76.07 because Y=0.5 with f(t) cube-root]
///   - Pure white RGB(1, 1, 1) → LAB (100, ~0, ~0)
///   - Pure red RGB(1, 0, 0) → LAB (53.24, 80.09, 67.20) approximately
///   - Pure green RGB(0, 1, 0) → LAB (87.74, -86.18, 83.18) approximately
///   - Pure blue RGB(0, 0, 1) → LAB (32.30, 79.20, -107.86) approximately
final class BayerBinnerTests: XCTestCase {

    private var binner: BayerBinner?

    override func setUp() async throws {
        do {
            binner = try BayerBinner()
        } catch {
            // No Metal device available (e.g., headless CI). Skip via nil binner;
            // each test's guard handles this without failing the run.
            binner = nil
            print("BayerBinnerTests: skipping — \(error)")
        }
    }

    // MARK: - Output shape + dispatch

    func testOutputShape() throws {
        guard let binner else { throw XCTSkip("Metal unavailable") }
        let mosaic = makeUniformMosaic(value: 2048)   // mid-gray-ish raw
        let lab = try binner.binToLAB(mosaic)
        XCTAssertEqual(lab.count, 64 * 64 * 3)
        XCTAssertEqual(lab.count, BayerBinner.outputCount)
    }

    // MARK: - Color correctness

    /// All-white mosaic (raw == whiteLevel) → LAB ≈ (100, 0, 0) per pixel.
    func testWhiteMosaicGivesL100() throws {
        guard let binner else { throw XCTSkip("Metal unavailable") }
        let mosaic = makeUniformMosaic(value: 4095)
        let lab = try binner.binToLAB(mosaic)

        // Sample pixel (32, 32) — middle of grid.
        let (l, a, b) = readBin(lab, x: 32, y: 32)
        XCTAssertEqual(l, 100.0, accuracy: 0.5, "L* should be ~100 for white")
        XCTAssertEqual(a, 0.0,   accuracy: 0.5, "a* should be ~0 for white")
        XCTAssertEqual(b, 0.0,   accuracy: 0.5, "b* should be ~0 for white")
    }

    /// All-black mosaic (raw == blackLevel) → LAB (0, 0, 0).
    func testBlackMosaicGivesL0() throws {
        guard let binner else { throw XCTSkip("Metal unavailable") }
        let mosaic = makeUniformMosaic(value: 528)   // = blackLevel
        let lab = try binner.binToLAB(mosaic)

        let (l, a, b) = readBin(lab, x: 0, y: 0)
        XCTAssertEqual(l, 0.0, accuracy: 0.5, "L* should be ~0 for black")
        XCTAssertEqual(a, 0.0, accuracy: 0.5, "a* should be ~0 for black")
        XCTAssertEqual(b, 0.0, accuracy: 0.5, "b* should be ~0 for black")
    }

    /// Pure-R mosaic (only R photosites lit; B and G black). Expected LAB
    /// approximately (53.24, 80.09, 67.20). Tolerance ±2 on each component
    /// to account for the approximate mid-Y predictability of LAB.
    func testPureRedMosaic() throws {
        guard let binner else { throw XCTSkip("Metal unavailable") }
        let mosaic = makePureChannelMosaic(channel: .r)
        let lab = try binner.binToLAB(mosaic)

        let (l, a, b) = readBin(lab, x: 32, y: 32)
        XCTAssertEqual(l, 53.24, accuracy: 2.0, "L* of pure red ≈ 53.24")
        XCTAssertEqual(a, 80.09, accuracy: 2.0, "a* of pure red ≈ 80.09")
        XCTAssertEqual(b, 67.20, accuracy: 2.0, "b* of pure red ≈ 67.20")
    }

    func testPureGreenMosaic() throws {
        guard let binner else { throw XCTSkip("Metal unavailable") }
        let mosaic = makePureChannelMosaic(channel: .g)
        let lab = try binner.binToLAB(mosaic)

        let (l, a, b) = readBin(lab, x: 32, y: 32)
        XCTAssertEqual(l, 87.74, accuracy: 2.0, "L* of pure green ≈ 87.74")
        XCTAssertEqual(a, -86.18, accuracy: 2.0, "a* of pure green ≈ -86.18")
        XCTAssertEqual(b, 83.18, accuracy: 2.0, "b* of pure green ≈ 83.18")
    }

    func testPureBlueMosaic() throws {
        guard let binner else { throw XCTSkip("Metal unavailable") }
        let mosaic = makePureChannelMosaic(channel: .b)
        let lab = try binner.binToLAB(mosaic)

        let (l, a, b) = readBin(lab, x: 32, y: 32)
        XCTAssertEqual(l, 32.30, accuracy: 2.0, "L* of pure blue ≈ 32.30")
        XCTAssertEqual(a, 79.20, accuracy: 2.0, "a* of pure blue ≈ 79.20")
        XCTAssertEqual(b, -107.86, accuracy: 2.0, "b* of pure blue ≈ -107.86")
    }

    // MARK: - Error paths

    func testRejectsWrongCFA() throws {
        guard let binner else { throw XCTSkip("Metal unavailable") }
        let cropSize = BayerCropPlan.cropSize
        let bad = BayerMosaic(
            width: cropSize, height: cropSize,
            cfaPattern: .rggb,    // wrong — kernel is BGGR-only
            bitsPerSample: 14, blackLevel: 528, whiteLevel: 4095,
            samples: [UInt16](repeating: 2048, count: cropSize * cropSize)
        )
        XCTAssertThrowsError(try binner.binToLAB(bad)) { err in
            guard case BayerBinner.BinnerError.wrongMosaicShape = err else {
                return XCTFail("expected wrongMosaicShape, got \(err)")
            }
        }
    }

    // MARK: - Helpers

    private func makeUniformMosaic(value: UInt16) -> BayerMosaic {
        let s = BayerCropPlan.cropSize
        return BayerMosaic(
            width: s, height: s,
            cfaPattern: .bggr,
            bitsPerSample: 14, blackLevel: 528, whiteLevel: 4095,
            samples: [UInt16](repeating: value, count: s * s)
        )
    }

    /// Builds a mosaic where ONLY the requested channel's photosites are at
    /// `whiteLevel`; the other channels are at `blackLevel`. After binning
    /// + linearization, this simulates an isolated R, G, or B input.
    private func makePureChannelMosaic(channel: CFAChannel) -> BayerMosaic {
        let s = BayerCropPlan.cropSize
        var samples = [UInt16](repeating: 528, count: s * s)
        // BGGR positions:
        //   B at (even, even)
        //   Gb at (even, odd) — both Gs combined for "G"
        //   Gr at (odd,  even)
        //   R at (odd,  odd)
        for r in 0..<s {
            let yEven = r % 2 == 0
            for c in 0..<s {
                let xEven = c % 2 == 0
                let isB  =  yEven &&  xEven
                let isGb =  yEven && !xEven
                let isGr = !yEven &&  xEven
                let isR  = !yEven && !xEven
                let lit: Bool
                switch channel {
                case .r: lit = isR
                case .g: lit = isGb || isGr
                case .b: lit = isB
                }
                if lit { samples[r * s + c] = 4095 }
            }
        }
        return BayerMosaic(
            width: s, height: s,
            cfaPattern: .bggr,
            bitsPerSample: 14, blackLevel: 528, whiteLevel: 4095,
            samples: samples
        )
    }

    private func readBin(_ lab: [Float], x: Int, y: Int) -> (Float, Float, Float) {
        let i = (y * BayerCropPlan.binCount + x) * 3
        return (lab[i], lab[i + 1], lab[i + 2])
    }
}
