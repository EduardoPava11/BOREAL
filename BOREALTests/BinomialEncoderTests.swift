import XCTest
@testable import BOREAL

/// Verifies BinomialEncoder roundtrip Swift↔Zig with synthetic LAB tensors.
/// The Zig SIMD math itself is tested in zig/borealkernel/src/binomial.zig;
/// these tests confirm the C ABI + Swift wrapper plumbing is correct.
final class BinomialEncoderTests: XCTestCase {

    private static let binCount = 64 * 64                        // 4096
    private static let floatsPerFrame = binCount * 3             // 12,288
    private static let totalFloats = floatsPerFrame * 4          // 49,152

    // MARK: - Smoke tests

    func testEncodeSetShape() {
        let lab = [Float](repeating: 0, count: Self.totalFloats)
        let cols = BinomialEncoder.encodeSet(lab)
        XCTAssertEqual(cols.L_min.count, Self.binCount)
        XCTAssertEqual(cols.L_max.count, Self.binCount)
        XCTAssertEqual(cols.L_mean.count, Self.binCount)
        XCTAssertEqual(cols.codesFlags.count, Self.binCount)
    }

    func testAllZeroInputProducesStaticLowLumaFlags() {
        let lab = [Float](repeating: 0, count: Self.totalFloats)
        let cols = BinomialEncoder.encodeSet(lab)
        let expected: UInt8 = 0b0100_0001  // FLAG_STATIC | FLAG_LOW_LUMA
        for i in 0..<Self.binCount {
            XCTAssertEqual(cols.L_mean[i], 0)
            XCTAssertEqual(cols.flags(at: i), expected,
                           "bin \(i) flags mismatch")
            XCTAssertEqual(cols.lCode(at: i), 0)
            XCTAssertEqual(cols.aCode(at: i), 0)
            XCTAssertEqual(cols.bCode(at: i), 0)
        }
    }

    // MARK: - Per-bin trajectory codes

    /// Bin 0 has a monotonic-increasing L* trajectory (q=0,1,2,3 → code 0xE4).
    /// All other bins are zero.
    func testMonotonicIncreasingCodeAtBinZero() {
        var lab = [Float](repeating: 0, count: Self.totalFloats)
        // Frame f, bin 0, L channel at offset (f * floatsPerFrame) + 0.
        // Set L = f * 25.0 across the 4 frames so the q quantization is (0,1,2,3).
        for f in 0..<4 {
            lab[f * Self.floatsPerFrame + 0] = Float(f) * 25.0
        }
        let cols = BinomialEncoder.encodeSet(lab)

        XCTAssertEqual(cols.L_min[0], 0)
        XCTAssertEqual(cols.L_max[0], 75.0, accuracy: 1e-3)
        XCTAssertEqual(cols.L_mean[0], 37.5, accuracy: 1e-3)
        XCTAssertEqual(cols.lCode(at: 0), 0xE4, "monotonic ↑ should encode 0xE4")
        let f = cols.flags(at: 0)
        XCTAssertNotEqual(f & 0b0000_0010, 0, "FLAG_MONOTONIC_INCREASING should be set")
        XCTAssertEqual(f & 0b0000_0100, 0, "FLAG_MONOTONIC_DECREASING should NOT be set")
        XCTAssertEqual(f & 0b0000_0001, 0, "FLAG_STATIC should NOT be set (range > 1)")

        // Other bins still all-zero.
        XCTAssertEqual(cols.L_mean[1], 0)
    }

    /// High-luma bin (L*=90 across all 4 frames) → FLAG_HIGH_LUMA + FLAG_STATIC.
    func testHighLumaFlagFires() {
        var lab = [Float](repeating: 0, count: Self.totalFloats)
        for f in 0..<4 {
            lab[f * Self.floatsPerFrame + 0] = 90.0       // L* = 90 in bin 0
        }
        let cols = BinomialEncoder.encodeSet(lab)
        let f = cols.flags(at: 0)
        XCTAssertNotEqual(f & 0b0010_0000, 0, "FLAG_HIGH_LUMA should fire (L*_mean=90)")
        XCTAssertNotEqual(f & 0b0000_0001, 0, "FLAG_STATIC should fire (constant L*)")
        XCTAssertEqual(f & 0b0100_0000, 0, "FLAG_LOW_LUMA should NOT fire")
    }

    /// High-chroma bin (a*=30, b*=30 → magnitude ≈ 42 > 25).
    func testHighChromaFlagFires() {
        var lab = [Float](repeating: 0, count: Self.totalFloats)
        for f in 0..<4 {
            // Bin 0: L=50, a=30, b=30
            lab[f * Self.floatsPerFrame + 0] = 50.0
            lab[f * Self.floatsPerFrame + 1] = 30.0
            lab[f * Self.floatsPerFrame + 2] = 30.0
        }
        let cols = BinomialEncoder.encodeSet(lab)
        let f = cols.flags(at: 0)
        XCTAssertNotEqual(f & 0b0001_0000, 0, "FLAG_HIGH_CHROMA should fire")
    }

    // MARK: - Channel independence

    /// Verifies the 3 channels are encoded independently. Set L*_max ≠ a*_max ≠ b*_max
    /// in the same bin and confirm each column reports its own per-channel value.
    func testChannelIndependence() {
        var lab = [Float](repeating: 0, count: Self.totalFloats)
        // Bin 0 across 4 frames:
        //   frame 0: (10, 20, 30)
        //   frame 1: (40, 50, 60)
        //   frame 2: (70, 80, 90)
        //   frame 3: (10, 20, 30)
        let trajectoryL: [Float] = [10, 40, 70, 10]
        let trajectoryA: [Float] = [20, 50, 80, 20]
        let trajectoryB: [Float] = [30, 60, 90, 30]
        for f in 0..<4 {
            lab[f * Self.floatsPerFrame + 0] = trajectoryL[f]
            lab[f * Self.floatsPerFrame + 1] = trajectoryA[f]
            lab[f * Self.floatsPerFrame + 2] = trajectoryB[f]
        }
        let cols = BinomialEncoder.encodeSet(lab)

        XCTAssertEqual(cols.L_min[0], 10); XCTAssertEqual(cols.L_max[0], 70)
        XCTAssertEqual(cols.a_min[0], 20); XCTAssertEqual(cols.a_max[0], 80)
        XCTAssertEqual(cols.b_min[0], 30); XCTAssertEqual(cols.b_max[0], 90)
        XCTAssertEqual(cols.L_mean[0], 32.5, accuracy: 1e-3)
        XCTAssertEqual(cols.a_mean[0], 42.5, accuracy: 1e-3)
        XCTAssertEqual(cols.b_mean[0], 52.5, accuracy: 1e-3)
    }
}
