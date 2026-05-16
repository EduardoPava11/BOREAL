import XCTest
@testable import BOREAL

/// Round-trip tests for the .bvox v2 columnar file format.
///
/// The KEY invariant: `decode(encode(x)) == x` for any valid Columns +
/// Certificate input. This guarantees the file format preserves all data
/// without precision loss, byte mis-ordering, or layout drift. The
/// checksum mismatch test confirms tampering is detected.
final class VoxelPackTests: XCTestCase {

    private static let binCount = 4096

    // MARK: - Header sanity

    func testTotalSizeMatchesPlan() {
        // 96 B header + 163,840 B body + 64 B trailer = 164,000 B
        XCTAssertEqual(VoxelPack.totalBytes, 164_000)
        XCTAssertEqual(VoxelPack.headerSize, 96)
        XCTAssertEqual(VoxelPack.bodyBytes, 163_840)
        XCTAssertEqual(VoxelPack.trailerSize, 64)
    }

    func testEncodedFileHasExpectedSize() {
        let cols = makeRandomColumns(seed: 42)
        let data = VoxelPack.encode(setIdx: 0, codeBudget: 1, pyramidHash: 0,
                                    columns: cols)
        XCTAssertEqual(data.count, VoxelPack.totalBytes)
    }

    func testHeaderMagicAndVersion() {
        let cols = makeRandomColumns(seed: 1)
        let data = VoxelPack.encode(setIdx: 7, codeBudget: 64, pyramidHash: 0xDEADBEEF,
                                    columns: cols)
        XCTAssertEqual(Array(data[0..<4]), [0x42, 0x56, 0x4F, 0x58])
        XCTAssertEqual(data[4], 0x02)   // version low byte
        XCTAssertEqual(data[5], 0x00)
    }

    // MARK: - Round-trip

    func testRoundTripPreservesAllColumnData() throws {
        let cols = makeRandomColumns(seed: 12345)
        let cert = makeCertificate()
        let encoded = VoxelPack.encode(setIdx: 7, codeBudget: 64,
                                       pyramidHash: 0xDEADBEEF_CAFEBABE,
                                       columns: cols, certificate: cert)
        let decoded = try VoxelPack.decode(encoded)

        XCTAssertEqual(decoded.setIdx, 7)
        XCTAssertEqual(decoded.codeBudget, 64)
        XCTAssertEqual(decoded.pyramidHash, 0xDEADBEEF_CAFEBABE)

        // Each column byte-identical.
        XCTAssertEqual(decoded.columns.L_min,  cols.L_min)
        XCTAssertEqual(decoded.columns.L_max,  cols.L_max)
        XCTAssertEqual(decoded.columns.L_mean, cols.L_mean)
        XCTAssertEqual(decoded.columns.a_min,  cols.a_min)
        XCTAssertEqual(decoded.columns.a_max,  cols.a_max)
        XCTAssertEqual(decoded.columns.a_mean, cols.a_mean)
        XCTAssertEqual(decoded.columns.b_min,  cols.b_min)
        XCTAssertEqual(decoded.columns.b_max,  cols.b_max)
        XCTAssertEqual(decoded.columns.b_mean, cols.b_mean)
        XCTAssertEqual(decoded.columns.codesFlags, cols.codesFlags)

        // Certificate preserved.
        XCTAssertEqual(decoded.certificate, cert)
    }

    func testWriteThenReadFromDisk() throws {
        let cols = makeRandomColumns(seed: 999)
        let encoded = VoxelPack.encode(setIdx: 3, codeBudget: 4, pyramidHash: 0xABCD,
                                       columns: cols)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-test-\(UUID().uuidString).bvox")
        defer { try? FileManager.default.removeItem(at: url) }
        try VoxelPack.write(encoded, to: url)
        let decoded = try VoxelPack.read(from: url)
        XCTAssertEqual(decoded.columns.codesFlags, cols.codesFlags)
        XCTAssertEqual(decoded.columns.L_mean, cols.L_mean)
    }

    // MARK: - Error paths

    func testTruncatedDataRejected() {
        let cols = makeRandomColumns(seed: 1)
        let encoded = VoxelPack.encode(setIdx: 0, codeBudget: 1, pyramidHash: 0,
                                       columns: cols)
        let truncated = encoded.prefix(100)
        XCTAssertThrowsError(try VoxelPack.decode(truncated)) { err in
            guard case VoxelPack.PackError.shortFile = err else {
                return XCTFail("expected shortFile, got \(err)")
            }
        }
    }

    func testBadMagicRejected() {
        let cols = makeRandomColumns(seed: 1)
        var encoded = VoxelPack.encode(setIdx: 0, codeBudget: 1, pyramidHash: 0,
                                       columns: cols)
        encoded[0] = 0x00   // corrupt magic
        XCTAssertThrowsError(try VoxelPack.decode(encoded)) { err in
            guard case VoxelPack.PackError.badMagic = err else {
                return XCTFail("expected badMagic, got \(err)")
            }
        }
    }

    func testTamperedBodyDetectedByChecksum() {
        let cols = makeRandomColumns(seed: 1)
        var encoded = VoxelPack.encode(setIdx: 0, codeBudget: 1, pyramidHash: 0,
                                       columns: cols)
        // Flip a byte in the body.
        encoded[VoxelPack.headerSize + 100] ^= 0xFF
        XCTAssertThrowsError(try VoxelPack.decode(encoded)) { err in
            guard case VoxelPack.PackError.checksumMismatch = err else {
                return XCTFail("expected checksumMismatch, got \(err)")
            }
        }
    }

    // MARK: - Helpers

    /// Deterministic synthetic columns based on a seed. Generates floats
    /// that span the LAB range and codesFlags that exercise all 32 bits.
    private func makeRandomColumns(seed: UInt32) -> BinomialEncoder.Columns {
        var rng = SimpleRng(seed: seed)
        var cols = BinomialEncoder.Columns()
        for i in 0..<Self.binCount {
            // L* in [0, 100], a*/b* in [-100, 100]
            cols.L_min[i]  = rng.nextFloat() * 100
            cols.L_max[i]  = rng.nextFloat() * 100
            cols.L_mean[i] = rng.nextFloat() * 100
            cols.a_min[i]  = (rng.nextFloat() - 0.5) * 200
            cols.a_max[i]  = (rng.nextFloat() - 0.5) * 200
            cols.a_mean[i] = (rng.nextFloat() - 0.5) * 200
            cols.b_min[i]  = (rng.nextFloat() - 0.5) * 200
            cols.b_max[i]  = (rng.nextFloat() - 0.5) * 200
            cols.b_mean[i] = (rng.nextFloat() - 0.5) * 200
            cols.codesFlags[i] = rng.next()
        }
        return cols
    }

    private func makeCertificate() -> VoxelPack.Certificate {
        var c = VoxelPack.Certificate()
        c.duration_ms = 100.5
        c.decode_ms = 80.25
        c.bin_ms = 1.0
        c.encode_ms = 5.5
        c.write_ms = 10.0
        c.kl_divergence = [0.1, 0.2, 0.15]
        c.codebook_utilization = 0.75
        return c
    }

    /// Tiny LCG for deterministic test data; not cryptographic.
    private struct SimpleRng {
        var state: UInt32
        init(seed: UInt32) { self.state = seed == 0 ? 1 : seed }
        mutating func next() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state
        }
        mutating func nextFloat() -> Float {
            Float(next()) / Float(UInt32.max)
        }
    }
}
