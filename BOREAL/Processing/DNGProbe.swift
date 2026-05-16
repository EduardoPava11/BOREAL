import Foundation
import os

/// Diagnostic helper: dumps the key TIFF/DNG tags from a DNG file via Log.processing.
///
/// Use this during pre-flight on a real iPhone 17 Pro Bayer RAW DNG to verify the
/// editor's assumptions (byte order, raw IFD layout, crop tags present) AND to
/// identify the compression scheme so the Zig decoder can target it precisely.
///
/// The compression diagnosis is the load-bearing part: the Zig parser only handles
/// `Compression == 1` (uncompressed). On any other value we need to know exactly
/// what scheme to implement. The probe logs the Compression tag, BitsPerSample,
/// the strip layout, and the first 16 bytes of strip data so we can identify a
/// JPEG/JPEG-XR/proprietary stream by its magic.
enum DNGProbe {

    static func dump(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            Log.processing.error("DNGProbe: cannot read \(url.lastPathComponent, privacy: .public)")
            return
        }
        do {
            let header = try DNGCropTagEditor.readTIFFHeader(data)
            Log.processing.info("DNGProbe \(url.lastPathComponent, privacy: .public): byteOrder=\(String(describing: header.byteOrder), privacy: .public) IFD0@\(header.firstIFDOffset)")

            let ifd0 = try DNGCropTagEditor.readIFD(data, at: header.firstIFDOffset)
            logEntry("IFD0 Orientation", ifd0.first { $0.tag == 274 })

            // Apple-style: raw mosaic lives in IFD0 directly. Probe IFD0 first.
            probeRawCandidate(label: "IFD0", entries: ifd0,
                              data: data, byteOrder: header.byteOrder)

            let subs = try DNGCropTagEditor.readSubIFDOffsets(data, ifd0: ifd0)
            Log.processing.info("DNGProbe: \(subs.count) SubIFD(s)")
            for (i, off) in subs.enumerated() {
                let sub = try DNGCropTagEditor.readIFD(data, at: off)
                probeRawCandidate(label: "SubIFD[\(i)]", entries: sub,
                                  data: data, byteOrder: header.byteOrder)
            }
        } catch {
            Log.processing.error("DNGProbe failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Walk one candidate IFD's entries and log everything Phase 2 will need to
    /// decode + crop the raw mosaic.
    private static func probeRawCandidate(label: String,
                                          entries: [DNGCropTagEditor.IFDEntry],
                                          data: Data,
                                          byteOrder: DNGCropTagEditor.ByteOrder) {
        let pi = entries.first { $0.tag == 262 }
        let piVal = pi?.valueAsInlineUInt32(byteOrder: byteOrder) ?? 0
        let isRaw = piVal == 32803    // CFA
        Log.processing.info("DNGProbe \(label, privacy: .public): PI=\(piVal) isRawCFA=\(isRaw)")

        logEntry("\(label) ImageWidth (256)",  entries.first { $0.tag == 256 })
        logEntry("\(label) ImageLength (257)", entries.first { $0.tag == 257 })
        logEntry("\(label) BitsPerSample (258)", entries.first { $0.tag == 258 })

        if let comp = entries.first(where: { $0.tag == 259 }) {
            let v = comp.valueAsInlineUInt32(byteOrder: byteOrder)
            Log.processing.info("\(label, privacy: .public) Compression (259): value=\(v) scheme=\(compressionName(v), privacy: .public)")
        } else {
            Log.processing.info("\(label, privacy: .public) Compression (259): <ABSENT — assumed 1>")
        }

        logEntry("\(label) PhotometricInterpretation (262)", pi)
        logEntry("\(label) RowsPerStrip (278)",  entries.first { $0.tag == 278 })

        // Strip offsets / byte counts may be SHORT or LONG, single-strip or multi.
        // Log the entry shape; if it's single-strip and inline, also peek at the
        // first 16 bytes of strip data so we can identify the stream by magic.
        if let so = entries.first(where: { $0.tag == 273 }) {
            Log.processing.info("\(label, privacy: .public) StripOffsets (273): type=\(so.type) count=\(so.count) valOff=\(so.valueOffset)")
        } else {
            Log.processing.info("\(label, privacy: .public) StripOffsets (273): <ABSENT>")
        }
        if let sbc = entries.first(where: { $0.tag == 279 }) {
            Log.processing.info("\(label, privacy: .public) StripByteCounts (279): type=\(sbc.type) count=\(sbc.count) valOff=\(sbc.valueOffset)")
        } else {
            Log.processing.info("\(label, privacy: .public) StripByteCounts (279): <ABSENT>")
        }
        // Tile-layout tags (Compression=7 LJPEG iPhone DNGs use these instead of strips).
        if let tw = entries.first(where: { $0.tag == 322 }) {
            Log.processing.info("\(label, privacy: .public) TileWidth (322): type=\(tw.type) count=\(tw.count) valOff=\(tw.valueOffset)")
        }
        if let tl = entries.first(where: { $0.tag == 323 }) {
            Log.processing.info("\(label, privacy: .public) TileLength (323): type=\(tl.type) count=\(tl.count) valOff=\(tl.valueOffset)")
        }
        if let to = entries.first(where: { $0.tag == 324 }) {
            Log.processing.info("\(label, privacy: .public) TileOffsets (324): type=\(to.type) count=\(to.count) valOff=\(to.valueOffset)")
        }
        if let tbc = entries.first(where: { $0.tag == 325 }) {
            Log.processing.info("\(label, privacy: .public) TileByteCounts (325): type=\(tbc.type) count=\(tbc.count) valOff=\(tbc.valueOffset)")
        }

        // First-strip data peek: identifies JPEG (FFD8 FFE0/FFE1), Deflate (78 9C / 78 DA),
        // Apple proprietary (often 'vc8r' magic), or pure raw u16 (no recognisable magic).
        if isRaw,
           let so  = entries.first(where: { $0.tag == 273 }),
           let sbc = entries.first(where: { $0.tag == 279 }),
           so.count == 1, sbc.count == 1 {
            let off = Int(so.valueAsInlineUInt32(byteOrder: byteOrder))
            let len = Int(sbc.valueAsInlineUInt32(byteOrder: byteOrder))
            let peek = min(16, len, data.count - off)
            if peek > 0, off >= 0, off + peek <= data.count {
                let bytes = data.subdata(in: off..<(off + peek))
                let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                let asc = bytes.map { (b: UInt8) -> String in
                    (b >= 0x20 && b < 0x7F) ? String(UnicodeScalar(b)) : "."
                }.joined()
                Log.processing.info("\(label, privacy: .public) strip[0] @ \(off) len=\(len) magic=\(hex, privacy: .public) ascii=\(asc, privacy: .public)")
            }
        }

        logEntry("\(label) BlackLevel (50714)",       entries.first { $0.tag == 50714 })
        logEntry("\(label) WhiteLevel (50717)",       entries.first { $0.tag == 50717 })
        logEntry("\(label) DefaultCropOrigin (50719)", entries.first { $0.tag == 50719 })
        logEntry("\(label) DefaultCropSize (50720)",   entries.first { $0.tag == 50720 })
        logEntry("\(label) ActiveArea (50829)",        entries.first { $0.tag == 50829 })
    }

    /// Best-effort name for a Compression tag value. Covers the schemes BOREAL is
    /// likely to encounter on iPhone Bayer RAW; falls back to "unknown(N)".
    /// References: TIFF 6.0 spec §3.5, Adobe DNG 1.4 §3 "Compression".
    private static func compressionName(_ value: UInt32) -> String {
        switch value {
        case 1:     return "None"
        case 5:     return "LZW"
        case 6:     return "OldJPEG"
        case 7:     return "JPEG (baseline or lossless)"
        case 8:     return "Deflate"
        case 32773: return "PackBits"
        case 34892: return "Lossy-JPEG (DNG)"
        case 34925: return "ZSTD"
        case 34926: return "JPEG-XL"
        case 0x76633872: return "vc8r (Apple ProRAW / compressed Bayer)"
        default:    return "unknown(\(value))"
        }
    }

    private static func logEntry(_ label: String, _ entry: DNGCropTagEditor.IFDEntry?) {
        if let e = entry {
            Log.processing.info("\(label, privacy: .public): type=\(e.type) count=\(e.count) valOff=\(e.valueOffset)")
        } else {
            Log.processing.info("\(label, privacy: .public): <ABSENT>")
        }
    }
}
