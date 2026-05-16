import XCTest
@testable import BOREAL

/// Integration test: writes 4 synthetic uncompressed BGGR DNGs to a fresh
/// session's `set-00/` directory, runs `SetProcessor.process(setIdx: 0)`,
/// and verifies the resulting `lab.bvox` file is well-formed and contains
/// non-trivial column data derived from the inputs.
///
/// The DNG-decode → bin → encode → write chain is exercised end-to-end on
/// the iOS simulator. The Metal binner runs (Apple Silicon sim has working
/// Metal); if Metal is unavailable, tests skip-not-fail.
final class SetProcessorTests: XCTestCase {

    override func setUpWithError() throws {
        // Each test starts from a clean session tree.
        try Storage.prepareSessionFolder()
    }

    func testProcessSyntheticSet() async throws {
        // Skip if Metal isn't available (e.g., headless CI).
        let binner: BayerBinner
        do {
            binner = try BayerBinner()
        } catch {
            throw XCTSkip("Metal unavailable: \(error)")
        }

        // ── Set up Phase 1 disk state: 4 DNGs in set-00/. ──
        let setIdx = 0
        for f in 0..<4 {
            let dngBytes = makeSyntheticUncompressedBGGRDNG(
                width: BayerCropPlan.sensorWidth,
                height: BayerCropPlan.sensorHeight,
                fillValue: UInt16(528 + f * 800)   // varies per frame: 528, 1328, 2128, 2928
            )
            let url = Storage.frameURL(setIdx: setIdx, frameInSet: f)
            try dngBytes.write(to: url, options: .atomic)
        }

        // ── Run Phase 2. ──
        let bvoxURL = try await SetProcessor.process(setIdx: setIdx, binner: binner)

        // ── Verify output. ──
        let bvoxData = try Data(contentsOf: bvoxURL)
        XCTAssertEqual(bvoxData.count, VoxelPack.totalBytes,
                       "lab.bvox should be exactly \(VoxelPack.totalBytes) bytes")

        let decoded = try VoxelPack.decode(bvoxData)
        XCTAssertEqual(decoded.setIdx, 0)
        XCTAssertEqual(decoded.codeBudget, 1)   // pyramid[0] = 1

        // The 4 synthetic frames had varying fill values → L* should NOT be
        // constant across the 4 frames → some bins must NOT have FLAG_STATIC.
        // Actually, since each frame is uniform, EVERY bin has the same
        // 4-frame trajectory — so all bins should have IDENTICAL min/max/mean.
        let firstLMin = decoded.columns.L_min[0]
        let firstLMax = decoded.columns.L_max[0]
        let firstLMean = decoded.columns.L_mean[0]
        XCTAssertGreaterThan(firstLMax, firstLMin,
                             "L* range should be non-trivial since 4 frames had different fills")

        // All bins should have the same L_min/L_max/L_mean (uniform frames).
        for i in 1..<10 {
            XCTAssertEqual(decoded.columns.L_min[i], firstLMin, accuracy: 1e-3)
            XCTAssertEqual(decoded.columns.L_max[i], firstLMax, accuracy: 1e-3)
            XCTAssertEqual(decoded.columns.L_mean[i], firstLMean, accuracy: 1e-3)
        }

        // The fill values increased monotonically across frames → L* should
        // monotonically increase too → FLAG_MONOTONIC_INCREASING set on every bin.
        let monoIncMask: UInt8 = 0b0000_0010
        for i in 0..<10 {
            let f = decoded.columns.flags(at: i)
            XCTAssertNotEqual(f & monoIncMask, 0,
                              "bin \(i) should have FLAG_MONOTONIC_INCREASING (4 frames with rising L*)")
        }
    }

    // MARK: - Synthetic DNG builder
    //
    // Builds the smallest big-endian uncompressed BGGR DNG `dng.parse` will
    // accept, with the requested fill value uniformly across all photosites.
    // Reuses the byte-builder pattern from DecoderTests but parameterized.

    private func makeSyntheticUncompressedBGGRDNG(width: Int, height: Int, fillValue: UInt16) -> Data {
        var d = Data()
        d.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])   // MM, magic 42
        appendBE32(&d, 8)

        let entryCount: UInt16 = 13
        appendBE16(&d, entryCount)
        let ifdEntriesOffset = d.count
        let ifdSize = Int(entryCount) * 12 + 4
        let oolBase = ifdEntriesOffset + ifdSize
        var oolBuffer = Data()

        func placeOOL2x32(_ v0: UInt32, _ v1: UInt32) -> UInt32 {
            let off = UInt32(oolBase + oolBuffer.count)
            appendBE32(&oolBuffer, v0); appendBE32(&oolBuffer, v1); return off
        }
        func placeOOL4x32(_ v0: UInt32, _ v1: UInt32, _ v2: UInt32, _ v3: UInt32) -> UInt32 {
            let off = UInt32(oolBase + oolBuffer.count)
            appendBE32(&oolBuffer, v0); appendBE32(&oolBuffer, v1)
            appendBE32(&oolBuffer, v2); appendBE32(&oolBuffer, v3); return off
        }

        // 256 ImageWidth
        appendBE16(&d, 256); appendBE16(&d, 4); appendBE32(&d, 1); appendBE32(&d, UInt32(width))
        // 257 ImageLength
        appendBE16(&d, 257); appendBE16(&d, 4); appendBE32(&d, 1); appendBE32(&d, UInt32(height))
        // 258 BitsPerSample
        appendBE16(&d, 258); appendBE16(&d, 3); appendBE32(&d, 1); appendBE32(&d, UInt32(14) << 16)
        // 259 Compression = 1
        appendBE16(&d, 259); appendBE16(&d, 3); appendBE32(&d, 1); appendBE32(&d, UInt32(1) << 16)
        // 262 PI = 32803
        appendBE16(&d, 262); appendBE16(&d, 3); appendBE32(&d, 1); appendBE32(&d, UInt32(32803) << 16)
        // 273 StripOffsets — patch later
        let stripOffsetsEntryValuePos = d.count + 8
        appendBE16(&d, 273); appendBE16(&d, 4); appendBE32(&d, 1); appendBE32(&d, 0)
        // 279 StripByteCounts
        let stripByteCount = UInt32(width * height * 2)
        appendBE16(&d, 279); appendBE16(&d, 4); appendBE32(&d, 1); appendBE32(&d, stripByteCount)
        // 33422 CFAPattern = BGGR
        appendBE16(&d, 33422); appendBE16(&d, 1); appendBE32(&d, 4)
        d.append(contentsOf: [0x02, 0x01, 0x01, 0x00])
        // 50714 BlackLevel = 528
        appendBE16(&d, 50714); appendBE16(&d, 3); appendBE32(&d, 1); appendBE32(&d, UInt32(528) << 16)
        // 50717 WhiteLevel = 4095
        appendBE16(&d, 50717); appendBE16(&d, 3); appendBE32(&d, 1); appendBE32(&d, UInt32(4095) << 16)
        // 50719 DefaultCropOrigin
        let dcoEntryValuePos = d.count + 8
        appendBE16(&d, 50719); appendBE16(&d, 4); appendBE32(&d, 2); appendBE32(&d, 0)
        // 50720 DefaultCropSize
        let dcsEntryValuePos = d.count + 8
        appendBE16(&d, 50720); appendBE16(&d, 4); appendBE32(&d, 2); appendBE32(&d, 0)
        // 50829 ActiveArea
        let aaEntryValuePos = d.count + 8
        appendBE16(&d, 50829); appendBE16(&d, 4); appendBE32(&d, 4); appendBE32(&d, 0)

        appendBE32(&d, 0)   // nextIFD = 0

        // OOL block.
        let dcoOff = placeOOL2x32(0, 0)
        let dcsOff = placeOOL2x32(UInt32(width), UInt32(height))
        let aaOff = placeOOL4x32(0, 0, UInt32(height), UInt32(width))
        d.append(oolBuffer)

        patchBE32(&d, at: dcoEntryValuePos, with: dcoOff)
        patchBE32(&d, at: dcsEntryValuePos, with: dcsOff)
        patchBE32(&d, at: aaEntryValuePos, with: aaOff)

        // Strip data: uniform fillValue.
        let stripOff = UInt32(d.count)
        patchBE32(&d, at: stripOffsetsEntryValuePos, with: stripOff)
        let totalSamples = width * height
        for _ in 0..<totalSamples {
            appendBE16(&d, fillValue)
        }
        return d
    }

    private func appendBE16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF))
    }
    private func appendBE32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xFF)); d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF));  d.append(UInt8(v & 0xFF))
    }
    private func patchBE32(_ d: inout Data, at offset: Int, with v: UInt32) {
        d[offset]     = UInt8((v >> 24) & 0xFF)
        d[offset + 1] = UInt8((v >> 16) & 0xFF)
        d[offset + 2] = UInt8((v >> 8) & 0xFF)
        d[offset + 3] = UInt8(v & 0xFF)
    }
}
