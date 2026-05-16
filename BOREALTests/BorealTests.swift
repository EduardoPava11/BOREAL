import XCTest
@testable import BOREAL

/// Round-trip tests for `DNGCropTagEditor`.
///
/// `testCropTagPatchRoundTrip` builds a tiny synthetic **little-endian** TIFF and asserts
/// the editor patches all three crop tags. `testCropTagPatchRoundTripBigEndian` does the
/// same with a **big-endian** synthetic TIFF — this matches real iPhone Bayer RAW DNGs,
/// which ship as `MM 00 2A` magic. The BE variant was added after a real-device run on
/// iPhone 17 Pro revealed the editor was silently broken for BE files (logs:
/// `magic=4D4D002A` → `crop-tag rewrite failed: big-endian byte order not supported`).
final class BorealTests: XCTestCase {

    // MARK: - Little-endian round trip

    func testCropTagPatchRoundTrip() throws {
        let original = makeSyntheticDNG(byteOrder: .little)
        let srcURL = try writeTemp(original, name: "in_le.dng")
        let dstURL = srcURL.deletingLastPathComponent().appendingPathComponent("out_le.dng")

        try DNGCropTagEditor.writePortraitSquareCrop(source: srcURL, dest: dstURL)

        try assertCropTagsPatched(at: dstURL, expectedByteOrder: .little)
    }

    // MARK: - Big-endian round trip (matches real iPhone DNGs)

    func testCropTagPatchRoundTripBigEndian() throws {
        let original = makeSyntheticDNG(byteOrder: .big)
        let srcURL = try writeTemp(original, name: "in_be.dng")
        let dstURL = srcURL.deletingLastPathComponent().appendingPathComponent("out_be.dng")

        try DNGCropTagEditor.writePortraitSquareCrop(source: srcURL, dest: dstURL)

        try assertCropTagsPatched(at: dstURL, expectedByteOrder: .big)
    }

    // MARK: - Apple-style layout (raw mosaic in IFD0, no SubIFD)
    //
    // iPhone 17 Pro Bayer RAW DNGs put PhotometricInterpretation=32803 directly on IFD0,
    // not in a SubIFD. The crop tags live alongside it on IFD0. This test exercises the
    // candidate-list search that has to find IFD0 (not just SubIFDs).

    func testCropTagPatchAppleLayoutIFD0() throws {
        let original = makeSyntheticDNGAppleLayout(byteOrder: .big)
        let srcURL = try writeTemp(original, name: "in_apple.dng")
        let dstURL = srcURL.deletingLastPathComponent().appendingPathComponent("out_apple.dng")

        try DNGCropTagEditor.writePortraitSquareCrop(source: srcURL, dest: dstURL)

        // Re-parse and verify crop tags now read the patched values on IFD0 itself.
        let patched = try Data(contentsOf: dstURL)
        let header = try DNGCropTagEditor.readTIFFHeader(patched)
        let ifd0 = try DNGCropTagEditor.readIFD(patched, at: header.firstIFDOffset)
        let order = header.byteOrder

        let dco = try XCTUnwrap(ifd0.first { $0.tag == 50719 })
        XCTAssertEqual(DNGCropTagEditor.readUInt32(patched, at: Int(dco.valueOffset),     byteOrder: order), 544)
        XCTAssertEqual(DNGCropTagEditor.readUInt32(patched, at: Int(dco.valueOffset) + 4, byteOrder: order), 40)

        let dcs = try XCTUnwrap(ifd0.first { $0.tag == 50720 })
        XCTAssertEqual(DNGCropTagEditor.readUInt32(patched, at: Int(dcs.valueOffset),     byteOrder: order), 2944)
        XCTAssertEqual(DNGCropTagEditor.readUInt32(patched, at: Int(dcs.valueOffset) + 4, byteOrder: order), 2944)

        let aa = try XCTUnwrap(ifd0.first { $0.tag == 50829 })
        XCTAssertEqual(DNGCropTagEditor.readUInt32(patched, at: Int(aa.valueOffset),      byteOrder: order), 40)
        XCTAssertEqual(DNGCropTagEditor.readUInt32(patched, at: Int(aa.valueOffset) + 4,  byteOrder: order), 544)
        XCTAssertEqual(DNGCropTagEditor.readUInt32(patched, at: Int(aa.valueOffset) + 8,  byteOrder: order), 2984)
        XCTAssertEqual(DNGCropTagEditor.readUInt32(patched, at: Int(aa.valueOffset) + 12, byteOrder: order), 3488)
    }

    /// Builds the smallest TIFF where the raw Bayer IFD IS IFD0 (Apple layout).
    /// IFD0 has PhotometricInterpretation=32803 + the three crop tags. No SubIFDs.
    private func makeSyntheticDNGAppleLayout(byteOrder: DNGCropTagEditor.ByteOrder) -> Data {
        var d = Data()
        switch byteOrder {
        case .little: d.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
        case .big:    d.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])
        }
        appendUInt32(&d, 8, byteOrder: byteOrder)   // IFD0 @ offset 8

        // IFD0: 4 entries (PI, DCO, DCS, AA)
        appendUInt16(&d, 4, byteOrder: byteOrder)

        // PhotometricInterpretation (SHORT count 1, inline)
        appendUInt16(&d, 262, byteOrder: byteOrder)
        appendUInt16(&d, 3,   byteOrder: byteOrder)
        appendUInt32(&d, 1,   byteOrder: byteOrder)
        let piValueField: UInt32 = (byteOrder == .little) ? 32803 : (32803 << 16)
        appendUInt32(&d, piValueField, byteOrder: byteOrder)

        // DefaultCropOrigin (LONG count 2, out-of-line)
        appendUInt16(&d, 50719, byteOrder: byteOrder)
        appendUInt16(&d, 4,     byteOrder: byteOrder)
        appendUInt32(&d, 2,     byteOrder: byteOrder)
        appendUInt32(&d, 0,     byteOrder: byteOrder)
        let dcoSlot = d.count - 4

        // DefaultCropSize (LONG count 2, out-of-line)
        appendUInt16(&d, 50720, byteOrder: byteOrder)
        appendUInt16(&d, 4,     byteOrder: byteOrder)
        appendUInt32(&d, 2,     byteOrder: byteOrder)
        appendUInt32(&d, 0,     byteOrder: byteOrder)
        let dcsSlot = d.count - 4

        // ActiveArea (LONG count 4, out-of-line)
        appendUInt16(&d, 50829, byteOrder: byteOrder)
        appendUInt16(&d, 4,     byteOrder: byteOrder)
        appendUInt32(&d, 4,     byteOrder: byteOrder)
        appendUInt32(&d, 0,     byteOrder: byteOrder)
        let aaSlot = d.count - 4

        appendUInt32(&d, 0, byteOrder: byteOrder)   // nextIFD = 0

        // Out-of-line value blobs.
        let dcoOff = UInt32(d.count)
        appendUInt32(&d, 999, byteOrder: byteOrder); appendUInt32(&d, 999, byteOrder: byteOrder)
        d.replaceSubrange(dcoSlot..<dcoSlot+4, with: uint32Bytes(dcoOff, byteOrder: byteOrder))

        let dcsOff = UInt32(d.count)
        appendUInt32(&d, 999, byteOrder: byteOrder); appendUInt32(&d, 999, byteOrder: byteOrder)
        d.replaceSubrange(dcsSlot..<dcsSlot+4, with: uint32Bytes(dcsOff, byteOrder: byteOrder))

        let aaOff = UInt32(d.count)
        appendUInt32(&d, 999, byteOrder: byteOrder); appendUInt32(&d, 999, byteOrder: byteOrder)
        appendUInt32(&d, 999, byteOrder: byteOrder); appendUInt32(&d, 999, byteOrder: byteOrder)
        d.replaceSubrange(aaSlot..<aaSlot+4, with: uint32Bytes(aaOff, byteOrder: byteOrder))

        return d
    }

    // MARK: - Shared assertion

    /// Re-parses the patched file and verifies the three crop tags now read the values
    /// from `CropPlan` defaults: origin (544, 40), size (2944, 2944),
    /// activeArea (40, 544, 2984, 3488).
    private func assertCropTagsPatched(at url: URL,
                                       expectedByteOrder: DNGCropTagEditor.ByteOrder) throws {
        let patched = try Data(contentsOf: url)
        let header = try DNGCropTagEditor.readTIFFHeader(patched)
        XCTAssertEqual(header.byteOrder, expectedByteOrder)

        let ifd0 = try DNGCropTagEditor.readIFD(patched, at: header.firstIFDOffset)
        let subs = try DNGCropTagEditor.readSubIFDOffsets(patched, ifd0: ifd0)
        XCTAssertEqual(subs.count, 1)
        let raw = try DNGCropTagEditor.readIFD(patched, at: subs[0])
        let order = header.byteOrder

        // DefaultCropOrigin (LONG, count 2, out-of-line) -> (544, 40)
        let dco = try XCTUnwrap(raw.first { $0.tag == 50719 })
        let dcoX = DNGCropTagEditor.readUInt32(patched, at: Int(dco.valueOffset),     byteOrder: order)
        let dcoY = DNGCropTagEditor.readUInt32(patched, at: Int(dco.valueOffset) + 4, byteOrder: order)
        XCTAssertEqual(dcoX, 544)
        XCTAssertEqual(dcoY, 40)

        // DefaultCropSize (LONG, count 2, out-of-line) -> (2944, 2944)
        let dcs = try XCTUnwrap(raw.first { $0.tag == 50720 })
        let dcsW = DNGCropTagEditor.readUInt32(patched, at: Int(dcs.valueOffset),     byteOrder: order)
        let dcsH = DNGCropTagEditor.readUInt32(patched, at: Int(dcs.valueOffset) + 4, byteOrder: order)
        XCTAssertEqual(dcsW, 2944)
        XCTAssertEqual(dcsH, 2944)

        // ActiveArea (LONG, count 4, out-of-line) -> (40, 544, 2984, 3488)
        let aa = try XCTUnwrap(raw.first { $0.tag == 50829 })
        let top    = DNGCropTagEditor.readUInt32(patched, at: Int(aa.valueOffset),      byteOrder: order)
        let left   = DNGCropTagEditor.readUInt32(patched, at: Int(aa.valueOffset) + 4,  byteOrder: order)
        let bottom = DNGCropTagEditor.readUInt32(patched, at: Int(aa.valueOffset) + 8,  byteOrder: order)
        let right  = DNGCropTagEditor.readUInt32(patched, at: Int(aa.valueOffset) + 12, byteOrder: order)
        XCTAssertEqual(top,    40)
        XCTAssertEqual(left,   544)
        XCTAssertEqual(bottom, 2984)
        XCTAssertEqual(right,  3488)
    }

    // MARK: - Synthetic TIFF builder

    /// Builds the smallest TIFF (LE or BE) that:
    ///   - has IFD0 with one entry: SubIFDs (tag 330, LONG, count 1, value = offset of raw SubIFD)
    ///   - has a raw SubIFD with: PhotometricInterpretation=32803, DefaultCropOrigin(LONG[2]),
    ///     DefaultCropSize(LONG[2]), ActiveArea(LONG[4]) — all out-of-line with initial
    ///     "wrong" values that the editor must rewrite.
    private func makeSyntheticDNG(byteOrder: DNGCropTagEditor.ByteOrder) -> Data {
        var d = Data()

        // Header (8 bytes): byte order, magic 42, IFD0 offset.
        switch byteOrder {
        case .little: d.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])   // II, 42 LE
        case .big:    d.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])   // MM, 42 BE
        }
        appendUInt32(&d, 8, byteOrder: byteOrder)   // IFD0 @ offset 8

        // IFD0 @ 8: 1 entry (SubIFDs) + nextIFD=0
        appendUInt16(&d, 1, byteOrder: byteOrder)
        // Entry: tag=330 (SubIFDs), type=4 (LONG), count=1, value=offset of raw SubIFD
        let subIFDOffsetSlot = d.count + 8   // where to patch the value
        appendUInt16(&d, 330, byteOrder: byteOrder)
        appendUInt16(&d, 4,   byteOrder: byteOrder)
        appendUInt32(&d, 1,   byteOrder: byteOrder)
        appendUInt32(&d, 0,   byteOrder: byteOrder)
        appendUInt32(&d, 0,   byteOrder: byteOrder)   // nextIFD = 0

        // Raw SubIFD: 4 entries (PI, DCO, DCS, AA) + nextIFD=0
        let subIFDOffset = UInt32(d.count)
        d.replaceSubrange(subIFDOffsetSlot..<subIFDOffsetSlot+4,
                          with: uint32Bytes(subIFDOffset, byteOrder: byteOrder))

        appendUInt16(&d, 4, byteOrder: byteOrder)   // 4 entries

        // PhotometricInterpretation: tag=262, type=3 (SHORT), count=1, value=32803 inline.
        // For an inline SHORT, the value sits in the FIRST 2 bytes of the 4-byte value
        // field — that means BE writes it to bytes [0,1], LE writes it to bytes [0,1] too,
        // but `readUInt32(byteOrder:)` packs those bytes into the HIGH 16 bits for BE
        // and the LOW 16 bits for LE. `appendUInt32(32803, byteOrder:)` here writes the
        // value with full 32-bit byte semantics, which has the same effect.
        appendUInt16(&d, 262,   byteOrder: byteOrder)
        appendUInt16(&d, 3,     byteOrder: byteOrder)
        appendUInt32(&d, 1,     byteOrder: byteOrder)
        // For LE inline SHORT: bytes = [lo, hi, 0, 0]; appendUInt32 with the SHORT value
        // produces exactly that. For BE inline SHORT: bytes = [hi, lo, 0, 0]; we need to
        // place the SHORT into the high 16 bits before passing to appendUInt32.
        let piValueField: UInt32 = (byteOrder == .little) ? 32803 : (32803 << 16)
        appendUInt32(&d, piValueField, byteOrder: byteOrder)

        // DefaultCropOrigin: tag=50719, type=4 (LONG), count=2 — 8 bytes, out-of-line.
        appendUInt16(&d, 50719, byteOrder: byteOrder)
        appendUInt16(&d, 4,     byteOrder: byteOrder)
        appendUInt32(&d, 2,     byteOrder: byteOrder)
        appendUInt32(&d, 0,     byteOrder: byteOrder)
        let dcoValueOffsetSlot = d.count - 4

        // DefaultCropSize: tag=50720, type=4, count=2 — 8 bytes, out-of-line.
        appendUInt16(&d, 50720, byteOrder: byteOrder)
        appendUInt16(&d, 4,     byteOrder: byteOrder)
        appendUInt32(&d, 2,     byteOrder: byteOrder)
        appendUInt32(&d, 0,     byteOrder: byteOrder)
        let dcsValueOffsetSlot = d.count - 4

        // ActiveArea: tag=50829, type=4, count=4 — 16 bytes, out-of-line.
        appendUInt16(&d, 50829, byteOrder: byteOrder)
        appendUInt16(&d, 4,     byteOrder: byteOrder)
        appendUInt32(&d, 4,     byteOrder: byteOrder)
        appendUInt32(&d, 0,     byteOrder: byteOrder)
        let aaValueOffsetSlot = d.count - 4

        appendUInt32(&d, 0, byteOrder: byteOrder)   // nextIFD = 0

        // Out-of-line value blobs with intentionally-wrong initial values that the editor
        // must rewrite. Patch each tag's value-offset slot to point at its blob.
        let dcoOffset = UInt32(d.count)
        appendUInt32(&d, 999, byteOrder: byteOrder); appendUInt32(&d, 999, byteOrder: byteOrder)
        d.replaceSubrange(dcoValueOffsetSlot..<dcoValueOffsetSlot+4,
                          with: uint32Bytes(dcoOffset, byteOrder: byteOrder))

        let dcsOffset = UInt32(d.count)
        appendUInt32(&d, 999, byteOrder: byteOrder); appendUInt32(&d, 999, byteOrder: byteOrder)
        d.replaceSubrange(dcsValueOffsetSlot..<dcsValueOffsetSlot+4,
                          with: uint32Bytes(dcsOffset, byteOrder: byteOrder))

        let aaOffset = UInt32(d.count)
        appendUInt32(&d, 999, byteOrder: byteOrder); appendUInt32(&d, 999, byteOrder: byteOrder)
        appendUInt32(&d, 999, byteOrder: byteOrder); appendUInt32(&d, 999, byteOrder: byteOrder)
        d.replaceSubrange(aaValueOffsetSlot..<aaValueOffsetSlot+4,
                          with: uint32Bytes(aaOffset, byteOrder: byteOrder))

        return d
    }

    // MARK: - Byte builders (LE / BE)

    private func appendUInt16(_ d: inout Data,
                              _ v: UInt16,
                              byteOrder: DNGCropTagEditor.ByteOrder) {
        switch byteOrder {
        case .little:
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
        case .big:
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8(v & 0xFF))
        }
    }

    private func appendUInt32(_ d: inout Data,
                              _ v: UInt32,
                              byteOrder: DNGCropTagEditor.ByteOrder) {
        switch byteOrder {
        case .little:
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8)  & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 24) & 0xFF))
        case .big:
            d.append(UInt8((v >> 24) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 8)  & 0xFF))
            d.append(UInt8(v & 0xFF))
        }
    }

    private func uint32Bytes(_ v: UInt32,
                             byteOrder: DNGCropTagEditor.ByteOrder) -> Data {
        var d = Data(); appendUInt32(&d, v, byteOrder: byteOrder); return d
    }

    private func writeTemp(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
