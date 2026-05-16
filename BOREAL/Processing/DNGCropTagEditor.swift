import Foundation
import os

/// Edits the `DefaultCropOrigin`, `DefaultCropSize`, and `ActiveArea` TIFF/DNG tags on
/// a DNG file so every DNG reader (CIRAWFilter, libraw, dcraw, Lightroom, Preview.app)
/// presents the image as a centered 2944×2944 square crop of the original 4032×3024
/// mosaic — Bayer-aligned for a clean 64×64 downsample (block size B=46, 23 RGGB cells
/// per output pixel; see BayerExplore/notes.md).
///
/// Raw mosaic strip bytes are NEVER touched — this is a metadata-only crop. The full
/// sensor data remains in the file and is recoverable by ignoring the crop tags. The
/// portrait orientation is provided by Apple's pre-existing `Orientation=6` EXIF tag,
/// which we leave intact.
///
/// Handles BOTH endianness — iPhone Bayer RAW DNGs are big-endian (magic `4D 4D 00 2A`).
///
/// Reference: Adobe DNG Specification 1.4.0.0, §4 "DNG Tags".
enum DNGCropTagEditor {

    // MARK: - Public API

    /// Crop tags we want to write for a 4032×3024 mosaic → 2944×2944 centered portrait square.
    ///
    /// Math (BayerExplore/notes.md, B=46 recipe):
    ///   - Origin (544, 40): both even → RGGB phase preserved
    ///   - Size 2944 × 2944: equals 64·46, so a 64×64 output downsample tiles cleanly
    ///     with one whole 46×46 Bayer block (= 23² = 529 RGGB cells = 2116 photodetectors)
    ///     per output pixel
    ///   - x extent: 544 + 2944 = 3488  ≤ 4032 ✓
    ///   - y extent:  40 + 2944 = 2984  ≤ 3024 ✓
    struct CropPlan {
        var defaultCropOrigin: (x: UInt32, y: UInt32) = (544, 40)
        var defaultCropSize:   (w: UInt32, h: UInt32) = (2944, 2944)
        var activeArea:        (top: UInt32, left: UInt32, bottom: UInt32, right: UInt32)
                              = (40, 544, 2984, 3488)
    }

    enum EditError: Error, CustomStringConvertible {
        case fileUnreadable(URL)
        case notTIFF(magic: String)
        case unsupportedByteOrder
        case noRawSubIFD
        case missingTag(UInt16)
        case typeMismatch(tag: UInt16, found: UInt16)
        case writeFailed(URL)

        var description: String {
            switch self {
            case .fileUnreadable(let u):     "cannot read \(u.lastPathComponent)"
            case .notTIFF(let m):            "not a TIFF/DNG file (first 4 bytes: \(m)) — JPEG=FFD8, TIFF=4949/4D4D"
            case .unsupportedByteOrder:      "unsupported TIFF byte order (must be II little-endian or MM big-endian)"
            case .noRawSubIFD:               "no SubIFD with PhotometricInterpretation=32803 (CFA)"
            case .missingTag(let t):         "raw SubIFD missing required tag \(t) — first-cut editor requires Apple's pre-set crop tags"
            case .typeMismatch(let t, let f):"tag \(t) has unexpected type \(f)"
            case .writeFailed(let u):        "could not write \(u.lastPathComponent)"
            }
        }
    }

    /// Rewrites the crop tags on the raw SubIFD and writes the patched DNG to `destURL`.
    /// Source file is unchanged.
    static func writePortraitSquareCrop(source: URL,
                                        dest: URL,
                                        plan: CropPlan = CropPlan()) throws {
        guard var data = try? Data(contentsOf: source) else {
            throw EditError.fileUnreadable(source)
        }

        let header = try readTIFFHeader(data)
        // Both II (little-endian) and MM (big-endian) are valid; iPhone Bayer RAW
        // DNGs ship as MM. All downstream reads/writes thread `header.byteOrder`
        // through the byte primitives, so this works for both.

        let ifd0Entries = try readIFD(data, at: header.firstIFDOffset)
        let subIFDOffsets = try readSubIFDOffsets(data, ifd0: ifd0Entries)

        // The raw Bayer IFD (PhotometricInterpretation=32803) can live in different
        // places depending on DNG flavor:
        //   - Adobe-style:  IFD0 = JPEG thumbnail, raw mosaic in a SubIFD.
        //   - Apple-style:  IFD0 IS the raw mosaic, SubIFD holds the thumbnail.
        // We search a candidate list and take the first match.
        var candidates: [(offset: UInt32, entries: [IFDEntry], label: String)] = []
        candidates.append((header.firstIFDOffset, ifd0Entries, "IFD0"))
        for (i, off) in subIFDOffsets.enumerated() {
            let entries = try readIFD(data, at: off)
            candidates.append((off, entries, "SubIFD[\(i)]"))
        }

        // Diagnostic: log each candidate's PhotometricInterpretation so any future
        // format surprise is visible in one log line.
        let piSummary = candidates.map { c in
            if let pi = c.entries.first(where: { $0.tag == DNGTag.photometricInterpretation.rawValue }) {
                return "\(c.label):PI=\(pi.valueAsInlineUInt32(byteOrder: header.byteOrder))"
            }
            return "\(c.label):PI=<absent>"
        }.joined(separator: " ")
        Log.processing.info("DNGCropTagEditor scan byteOrder=\(String(describing: header.byteOrder), privacy: .public) \(piSummary, privacy: .public)")

        var rawIFDOffset: UInt32? = nil
        var rawIFDEntries: [IFDEntry] = []
        for c in candidates {
            if let pi = c.entries.first(where: { $0.tag == DNGTag.photometricInterpretation.rawValue }),
               pi.valueAsInlineUInt32(byteOrder: header.byteOrder) == 32803 {
                rawIFDOffset = c.offset
                rawIFDEntries = c.entries
                break
            }
        }
        guard rawIFDOffset != nil else { throw EditError.noRawSubIFD }

        // Pre-flight diagnostic: log which of the three target tags Apple shipped on
        // this DNG. If any are missing, the next patchCropTag call throws missingTag —
        // the log makes it obvious which assumption broke.
        let hasDCO = rawIFDEntries.contains { $0.tag == DNGTag.defaultCropOrigin.rawValue }
        let hasDCS = rawIFDEntries.contains { $0.tag == DNGTag.defaultCropSize.rawValue }
        let hasAA  = rawIFDEntries.contains { $0.tag == DNGTag.activeArea.rawValue }
        Log.processing.info("DNGCropTagEditor: byteOrder=\(String(describing: header.byteOrder), privacy: .public) rawSubIFD entries=\(rawIFDEntries.count) DefaultCropOrigin=\(hasDCO) DefaultCropSize=\(hasDCS) ActiveArea=\(hasAA)")

        // Patch each crop tag. First-cut: all three must already exist (Apple sets them).
        try patchCropTag(in: &data,
                         entries: rawIFDEntries,
                         tag: DNGTag.defaultCropOrigin.rawValue,
                         expectedCount: 2,
                         values: [plan.defaultCropOrigin.x, plan.defaultCropOrigin.y],
                         byteOrder: header.byteOrder)
        try patchCropTag(in: &data,
                         entries: rawIFDEntries,
                         tag: DNGTag.defaultCropSize.rawValue,
                         expectedCount: 2,
                         values: [plan.defaultCropSize.w, plan.defaultCropSize.h],
                         byteOrder: header.byteOrder)
        try patchCropTag(in: &data,
                         entries: rawIFDEntries,
                         tag: DNGTag.activeArea.rawValue,
                         expectedCount: 4,
                         values: [plan.activeArea.top, plan.activeArea.left,
                                  plan.activeArea.bottom, plan.activeArea.right],
                         byteOrder: header.byteOrder)

        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            throw EditError.writeFailed(dest)
        }
    }

    // MARK: - DNG / TIFF model

    enum ByteOrder { case little, big }

    struct TIFFHeader {
        let byteOrder: ByteOrder
        let firstIFDOffset: UInt32
    }

    /// One IFD entry. `entryFileOffset` is the absolute file offset of this 12-byte entry,
    /// which we need so we can patch its value field in place.
    struct IFDEntry {
        let tag: UInt16
        let type: UInt16    // 1=BYTE, 3=SHORT, 4=LONG, 5=RATIONAL, 12=DOUBLE
        let count: UInt32
        let valueOffset: UInt32   // raw value-or-offset 4 bytes
        let entryFileOffset: Int  // absolute offset of this 12-byte entry within file

        var typeSize: Int {
            switch type { case 1,2,7: 1; case 3: 2; case 4: 4; case 5: 8; case 12: 8; default: 0 }
        }
        var totalSize: Int { typeSize * Int(count) }
        var isInline: Bool { totalSize <= 4 }

        /// Read the value as a single UInt32 when it's known to be inline (e.g. SHORT/LONG count 1).
        ///
        /// After `readUInt32(byteOrder:)` has parsed the 4-byte value field of the IFD entry,
        /// a single SHORT lives in different halves depending on byte order:
        ///   - LE:  bytes are [SHORT_lo, SHORT_hi, 0, 0] → readUInt32 packs into the low 16 bits
        ///   - BE:  bytes are [SHORT_hi, SHORT_lo, 0, 0] → readUInt32 packs into the high 16 bits
        /// A LONG (count=1) fills the whole 4 bytes either way, so no extraction needed.
        func valueAsInlineUInt32(byteOrder: ByteOrder) -> UInt32 {
            if type == 3 {   // SHORT
                return byteOrder == .little
                    ? UInt32(UInt16(truncatingIfNeeded: valueOffset))      // low 16 bits
                    : (valueOffset >> 16)                                   // high 16 bits
            }
            return valueOffset
        }
    }

    enum DNGTag: UInt16 {
        case photometricInterpretation = 262
        case subIFDs                   = 330
        case defaultCropOrigin         = 50719
        case defaultCropSize           = 50720
        case activeArea                = 50829
    }

    // MARK: - Parsing

    static func readTIFFHeader(_ data: Data) throws -> TIFFHeader {
        guard data.count >= 8 else { throw EditError.notTIFF(magic: magicHex(data)) }
        let b0 = data[0], b1 = data[1]
        let order: ByteOrder
        if b0 == 0x49 && b1 == 0x49 { order = .little }
        else if b0 == 0x4D && b1 == 0x4D { order = .big }
        else { throw EditError.notTIFF(magic: magicHex(data)) }

        let magic = readUInt16(data, at: 2, byteOrder: order)
        guard magic == 42 else { throw EditError.notTIFF(magic: magicHex(data)) }
        let firstIFD = readUInt32(data, at: 4, byteOrder: order)
        return TIFFHeader(byteOrder: order, firstIFDOffset: firstIFD)
    }

    private static func magicHex(_ data: Data) -> String {
        data.prefix(4).map { String(format: "%02X", $0) }.joined()
    }

    static func readIFD(_ data: Data, at offset: UInt32) throws -> [IFDEntry] {
        let order = try readTIFFHeader(data).byteOrder
        let base = Int(offset)
        guard data.count >= base + 2 else { throw EditError.notTIFF(magic: magicHex(data)) }
        let count = Int(readUInt16(data, at: base, byteOrder: order))
        var entries: [IFDEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let entryOff = base + 2 + i * 12
            guard data.count >= entryOff + 12 else { throw EditError.notTIFF(magic: magicHex(data)) }
            let tag   = readUInt16(data, at: entryOff,     byteOrder: order)
            let type  = readUInt16(data, at: entryOff + 2, byteOrder: order)
            let cnt   = readUInt32(data, at: entryOff + 4, byteOrder: order)
            let vOff  = readUInt32(data, at: entryOff + 8, byteOrder: order)
            entries.append(IFDEntry(tag: tag, type: type, count: cnt,
                                    valueOffset: vOff, entryFileOffset: entryOff))
        }
        return entries
    }

    static func readSubIFDOffsets(_ data: Data, ifd0: [IFDEntry]) throws -> [UInt32] {
        guard let sub = ifd0.first(where: { $0.tag == DNGTag.subIFDs.rawValue }) else {
            return []
        }
        let order = try readTIFFHeader(data).byteOrder
        if sub.count == 1 { return [sub.valueOffset] }
        var result: [UInt32] = []
        let base = Int(sub.valueOffset)
        for i in 0..<Int(sub.count) {
            result.append(readUInt32(data, at: base + i * 4, byteOrder: order))
        }
        return result
    }

    // MARK: - Patching

    /// Writes `values` into the IFD entry for `tag`, respecting the entry's existing type
    /// (SHORT/LONG/RATIONAL) and inline vs. out-of-line storage. Throws if the tag isn't
    /// present or has an unexpected type.
    static func patchCropTag(in data: inout Data,
                             entries: [IFDEntry],
                             tag: UInt16,
                             expectedCount: UInt32,
                             values: [UInt32],
                             byteOrder: ByteOrder) throws {
        guard let entry = entries.first(where: { $0.tag == tag }) else {
            throw EditError.missingTag(tag)
        }
        guard entry.count == expectedCount else {
            // First-cut requires count match. Apple normally keeps these fixed.
            throw EditError.typeMismatch(tag: tag, found: entry.type)
        }

        switch entry.type {
        case 3:   // SHORT — pack as UInt16
            try writeIntegers(into: &data, entry: entry, values: values,
                              byteOrder: byteOrder, shortMode: true)
        case 4:   // LONG — pack as UInt32
            try writeIntegers(into: &data, entry: entry, values: values,
                              byteOrder: byteOrder, shortMode: false)
        case 5:   // RATIONAL — write each as (numerator/1)
            try writeRationals(into: &data, entry: entry, numerators: values,
                               byteOrder: byteOrder)
        default:
            throw EditError.typeMismatch(tag: tag, found: entry.type)
        }
    }

    static func writeIntegers(into data: inout Data,
                              entry: IFDEntry,
                              values: [UInt32],
                              byteOrder: ByteOrder,
                              shortMode: Bool) throws {
        let elemSize = shortMode ? 2 : 4
        let total = elemSize * values.count

        if total <= 4 {
            // Inline: patch the entry's 4-byte value field directly.
            var packed = Data(repeating: 0, count: 4)
            for (i, v) in values.enumerated() {
                if shortMode {
                    writeUInt16(&packed, at: i * 2, UInt16(v), byteOrder: byteOrder)
                } else {
                    writeUInt32(&packed, at: i * 4, v, byteOrder: byteOrder)
                }
            }
            data.replaceSubrange(entry.entryFileOffset + 8 ..< entry.entryFileOffset + 12,
                                 with: packed)
        } else {
            // Out-of-line: patch the bytes at the existing value offset.
            let base = Int(entry.valueOffset)
            guard data.count >= base + total else { throw EditError.notTIFF(magic: magicHex(data)) }
            for (i, v) in values.enumerated() {
                if shortMode {
                    writeUInt16(&data, at: base + i * 2, UInt16(v), byteOrder: byteOrder)
                } else {
                    writeUInt32(&data, at: base + i * 4, v, byteOrder: byteOrder)
                }
            }
        }
    }

    static func writeRationals(into data: inout Data,
                               entry: IFDEntry,
                               numerators: [UInt32],
                               byteOrder: ByteOrder) throws {
        // RATIONAL is always 8 bytes per value -> always out-of-line for count >= 1.
        let base = Int(entry.valueOffset)
        let total = 8 * numerators.count
        guard data.count >= base + total else { throw EditError.notTIFF(magic: magicHex(data)) }
        for (i, n) in numerators.enumerated() {
            writeUInt32(&data, at: base + i * 8,     n, byteOrder: byteOrder)  // numerator
            writeUInt32(&data, at: base + i * 8 + 4, 1, byteOrder: byteOrder)  // denominator
        }
    }

    // MARK: - Byte-level primitives

    static func readUInt16(_ data: Data, at offset: Int, byteOrder: ByteOrder) -> UInt16 {
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1])
        return byteOrder == .little ? (hi << 8) | lo : (lo << 8) | hi
    }

    static func readUInt32(_ data: Data, at offset: Int, byteOrder: ByteOrder) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return byteOrder == .little
            ? (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
            : (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    static func writeUInt16(_ data: inout Data, at offset: Int, _ value: UInt16, byteOrder: ByteOrder) {
        if byteOrder == .little {
            data[offset]     = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
        } else {
            data[offset]     = UInt8((value >> 8) & 0xFF)
            data[offset + 1] = UInt8(value & 0xFF)
        }
    }

    static func writeUInt32(_ data: inout Data, at offset: Int, _ value: UInt32, byteOrder: ByteOrder) {
        if byteOrder == .little {
            data[offset]     = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
            data[offset + 2] = UInt8((value >> 16) & 0xFF)
            data[offset + 3] = UInt8((value >> 24) & 0xFF)
        } else {
            data[offset]     = UInt8((value >> 24) & 0xFF)
            data[offset + 1] = UInt8((value >> 16) & 0xFF)
            data[offset + 2] = UInt8((value >> 8) & 0xFF)
            data[offset + 3] = UInt8(value & 0xFF)
        }
    }
}
