import XCTest
@testable import BOREAL

/// Round-trips a synthetic uncompressed BGGR DNG through the Zig kernel's
/// `bk_decode_dng_to_mosaic` ABI and the Swift `BorealKernel.decodeDNG`
/// wrapper. Confirms the C ABI surface, the Swift bridging, and the
/// memory ownership are all correct without needing a real iPhone DNG.
///
/// The LJPEG decode path (Compression=7) is tested in zig/borealkernel/src/ljpeg.zig
/// — those tests don't require iOS; they run against synthetic LJPEG fragments.
/// This test exercises the OTHER half of dng.parse (Compression=1, raw u16 strip)
/// plus the entire C-to-Swift handoff.
final class DecoderTests: XCTestCase {

    func testDecodeUncompressedBGGRRoundTrip() throws {
        // Build: 4×4 BGGR mosaic with samples that encode position
        // (high byte = row, low byte = col). Verifies dims, CFA, levels,
        // and that the samples buffer arrives intact in Swift.
        let dng = makeSyntheticUncompressedBGGRDNG(width: 4, height: 4)
        let mosaic = try BorealKernel.decodeDNG(dng)

        XCTAssertEqual(mosaic.width, 4)
        XCTAssertEqual(mosaic.height, 4)
        XCTAssertEqual(mosaic.cfaPattern, .bggr)
        XCTAssertEqual(mosaic.bitsPerSample, 14)
        XCTAssertEqual(mosaic.blackLevel, 528)
        XCTAssertEqual(mosaic.whiteLevel, 4095)
        XCTAssertEqual(mosaic.samples.count, 16)

        // Verify each sample carried through correctly.
        for r in 0..<4 {
            for c in 0..<4 {
                let expected = UInt16((r << 8) | c)
                XCTAssertEqual(mosaic.sample(row: r, col: c), expected,
                               "(\(r),\(c)) mismatch")
            }
        }
    }

    func testDecodeRejectsInvalidBytes() {
        // Random non-TIFF bytes → kernel should reject with non-zero status.
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertThrowsError(try BorealKernel.decodeDNG(garbage)) { err in
            guard case BorealKernel.KernelError.nonZeroStatus = err else {
                return XCTFail("expected nonZeroStatus, got \(err)")
            }
        }
    }

    func testDecodeEmptyDataRejected() {
        let empty = Data()
        XCTAssertThrowsError(try BorealKernel.decodeDNG(empty))
    }

    // MARK: - Synthetic DNG builder

    /// Builds the smallest big-endian TIFF that `dng.parse` will accept as
    /// an uncompressed BGGR DNG: IFD0 with all required tags + a single-strip
    /// u16 mosaic of the requested dimensions.
    ///
    /// Sample value at (row, col) = (row << 8) | col.
    private func makeSyntheticUncompressedBGGRDNG(width: Int, height: Int) -> Data {
        precondition(width % 2 == 0 && height % 2 == 0)

        var d = Data()
        // ── TIFF header: MM (big-endian), magic 42, IFD0 offset = 8.
        d.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])
        appendBE32(&d, 8)

        // ── IFD0 @ 8: 13 entries.
        // Tags we'll write (in numeric order, as required by TIFF):
        //   256 ImageWidth (LONG)
        //   257 ImageLength (LONG)
        //   258 BitsPerSample (SHORT)
        //   259 Compression (SHORT) = 1
        //   262 PhotometricInterpretation (SHORT) = 32803 (CFA)
        //   273 StripOffsets (LONG) — out-of-line value
        //   279 StripByteCounts (LONG)
        //   33422 CFAPattern (BYTE[4]) = [2, 1, 1, 0] (BGGR)
        //   50714 BlackLevel (SHORT) = 528
        //   50717 WhiteLevel (SHORT) = 4095
        //   50719 DefaultCropOrigin (LONG[2]) — out-of-line
        //   50720 DefaultCropSize (LONG[2]) — out-of-line
        //   50829 ActiveArea (LONG[4]) — out-of-line
        let entryCount: UInt16 = 13
        appendBE16(&d, entryCount)

        // Compute layout: each entry is 12 bytes; entries come right after
        // the count. After the entries comes nextIFD (4 bytes), then
        // out-of-line values, then strip data.
        let ifdEntriesOffset = d.count
        let ifdSize = Int(entryCount) * 12 + 4   // entries + nextIFD
        var oolBase = ifdEntriesOffset + ifdSize
        var oolBuffer = Data()

        // Helper closures to register out-of-line values and return the offset.
        func placeOOL2x32(_ v0: UInt32, _ v1: UInt32) -> UInt32 {
            let off = UInt32(oolBase + oolBuffer.count)
            appendBE32(&oolBuffer, v0); appendBE32(&oolBuffer, v1)
            return off
        }
        func placeOOL4x32(_ v0: UInt32, _ v1: UInt32, _ v2: UInt32, _ v3: UInt32) -> UInt32 {
            let off = UInt32(oolBase + oolBuffer.count)
            appendBE32(&oolBuffer, v0); appendBE32(&oolBuffer, v1)
            appendBE32(&oolBuffer, v2); appendBE32(&oolBuffer, v3)
            return off
        }

        // Tag entries (must be in tag-numeric order).
        // 256 ImageWidth LONG count=1 inline
        appendBE16(&d, 256); appendBE16(&d, 4); appendBE32(&d, 1); appendBE32(&d, UInt32(width))
        // 257 ImageLength LONG count=1 inline
        appendBE16(&d, 257); appendBE16(&d, 4); appendBE32(&d, 1); appendBE32(&d, UInt32(height))
        // 258 BitsPerSample SHORT count=1 inline (high half for BE)
        appendBE16(&d, 258); appendBE16(&d, 3); appendBE32(&d, 1); appendBE32(&d, UInt32(14) << 16)
        // 259 Compression SHORT count=1 = 1
        appendBE16(&d, 259); appendBE16(&d, 3); appendBE32(&d, 1); appendBE32(&d, UInt32(1) << 16)
        // 262 PhotometricInterpretation SHORT count=1 = 32803
        appendBE16(&d, 262); appendBE16(&d, 3); appendBE32(&d, 1); appendBE32(&d, UInt32(32803) << 16)
        // 273 StripOffsets LONG count=1 — fill with placeholder, patch later
        let stripOffsetsEntryValuePos = d.count + 8
        appendBE16(&d, 273); appendBE16(&d, 4); appendBE32(&d, 1); appendBE32(&d, 0)
        // 279 StripByteCounts LONG count=1
        let stripByteCount = UInt32(width * height * 2)
        appendBE16(&d, 279); appendBE16(&d, 4); appendBE32(&d, 1); appendBE32(&d, stripByteCount)
        // 33422 CFAPattern BYTE count=4 = [2,1,1,0] for BGGR. Inline; bytes
        //   sit in the high portion of the 4-byte value field for BE.
        //   dng.zig accepts both byte orders so we use the natural [2,1,1,0].
        appendBE16(&d, 33422); appendBE16(&d, 1); appendBE32(&d, 4)
        d.append(contentsOf: [0x02, 0x01, 0x01, 0x00])
        // 50714 BlackLevel SHORT count=1 = 528
        appendBE16(&d, 50714); appendBE16(&d, 3); appendBE32(&d, 1); appendBE32(&d, UInt32(528) << 16)
        // 50717 WhiteLevel SHORT count=1 = 4095
        appendBE16(&d, 50717); appendBE16(&d, 3); appendBE32(&d, 1); appendBE32(&d, UInt32(4095) << 16)
        // 50719 DefaultCropOrigin LONG count=2 — out-of-line (0, 0)
        let dcoEntryValuePos = d.count + 8
        appendBE16(&d, 50719); appendBE16(&d, 4); appendBE32(&d, 2); appendBE32(&d, 0)
        // 50720 DefaultCropSize LONG count=2 — out-of-line (width, height)
        let dcsEntryValuePos = d.count + 8
        appendBE16(&d, 50720); appendBE16(&d, 4); appendBE32(&d, 2); appendBE32(&d, 0)
        // 50829 ActiveArea LONG count=4 — out-of-line (0, 0, height, width)
        let aaEntryValuePos = d.count + 8
        appendBE16(&d, 50829); appendBE16(&d, 4); appendBE32(&d, 4); appendBE32(&d, 0)

        // nextIFDOffset = 0 (no more IFDs)
        appendBE32(&d, 0)

        // Out-of-line values block.
        let dcoOff = placeOOL2x32(0, 0)
        let dcsOff = placeOOL2x32(UInt32(width), UInt32(height))
        let aaOff = placeOOL4x32(0, 0, UInt32(height), UInt32(width))
        d.append(oolBuffer)

        // Patch the out-of-line value-offset fields in the IFD entries.
        patchBE32(&d, at: dcoEntryValuePos, with: dcoOff)
        patchBE32(&d, at: dcsEntryValuePos, with: dcsOff)
        patchBE32(&d, at: aaEntryValuePos, with: aaOff)

        // Strip data: u16 samples, BE, value = (row<<8)|col.
        let stripOff = UInt32(d.count)
        patchBE32(&d, at: stripOffsetsEntryValuePos, with: stripOff)
        for r in 0..<height {
            for c in 0..<width {
                let v = UInt16((r << 8) | c)
                appendBE16(&d, v)
            }
        }

        // Update oolBase reference (for later additions if any). Currently
        // not needed since we placed all OOL values upfront.
        _ = oolBase
        return d
    }

    // MARK: - Byte builders

    private func appendBE16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8(v & 0xFF))
    }

    private func appendBE32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8(v & 0xFF))
    }

    private func patchBE32(_ d: inout Data, at offset: Int, with v: UInt32) {
        d[offset]     = UInt8((v >> 24) & 0xFF)
        d[offset + 1] = UInt8((v >> 16) & 0xFF)
        d[offset + 2] = UInt8((v >> 8) & 0xFF)
        d[offset + 3] = UInt8(v & 0xFF)
    }
}
