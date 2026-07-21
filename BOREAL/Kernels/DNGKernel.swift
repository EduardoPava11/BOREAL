// DNGKernel.swift — pure-Swift DNG decoder (THE product decoder since M5).
//
// Lineage: faithful 1:1 translation of the device-proven Zig originals
// (dng.zig, ljpeg.zig, color.zig, tests/dng_parse.zig — tree deleted M5,
// preserved on archive/zig-kernel). The synthetic-DNG builder from the
// old test file lives on here as dngSelfTest, run by the gate's
// swift-verify leg; this file is now the normative implementation.
//
// TIFF/DNG parser for NAKED Bayer RAW (the raw CFA sensor mosaic) — 14/16-bit,
// RGGB or BGGR, with the raw mosaic in IFD0 (not a SubIFD, unlike Adobe DNGs).
// Accepts Compression=1 (uncompressed strips) AND Compression=7 (LJPEG SOF3
// tiles, as iPhone Bayer RAW ships); rejects Apple-processed ProRAW variants
// (Linear/demosaiced, 'vc8r' compressed Bayer, lossy DNG, deflate).
//
// Apple's iPhone Bayer RAW DNGs are big-endian (`MM\0*`). We read only the tags
// needed to extract the cropped u16 mosaic + colour/exposure metadata.
//
// Status codes match `bk_status_t` from BorealKernel.h / root.zig exactly:
//   0=OK 1=BAD_TIFF_MAGIC 2=UNSUPPORTED_BYTE_ORDER 3=UNSUPPORTED_COMPRESSION
//   4=UNSUPPORTED_CFA_PATTERN 5=UNSUPPORTED_BIT_DEPTH 6=BAD_DIMENSIONS
//   7=MISSING_TAG 8=SHORT_READ 12=ALLOCATION_FAILED
//   14=UNSUPPORTED_COMPRESSION_DEFLATE 15=UNSUPPORTED_COMPRESSION_LOSSY_DNG
//   16=UNSUPPORTED_COMPRESSION_APPLE_VC8R 17=LJPEG_DECODE_FAILED
//   18=NULL_POINTER (facade-level, never produced here)
//   19=LJPEG_BAD_MAGIC 20=LJPEG_UNEXPECTED_END 21=LJPEG_UNSUPPORTED_MARKER
//   22=LJPEG_UNSUPPORTED_COMPONENT_COUNT 23=LJPEG_UNSUPPORTED_PRECISION
//   24=LJPEG_UNSUPPORTED_PREDICTOR 25=LJPEG_HAS_RESTART_MARKERS
//   26=LJPEG_MALFORMED_HUFFMAN_TABLE 27=LJPEG_INVALID_HUFFMAN_CODE

import Foundation

extension BorealKernels {

    // ========================================================================
    // MARK: - Public API
    // ========================================================================

    /// Decoded mosaic, with DefaultCrop already applied. Mirrors `dng.Mosaic`
    /// (Zig) except that the Zig parser hands the full-sensor mosaic plus crop
    /// metadata to the binner; this facade applies DefaultCropOrigin/Size here
    /// so callers get the cropped mosaic directly.
    struct DNGMosaic: Sendable {
        var width: Int
        var height: Int
        var cfa: UInt32          // 0 = RGGB, 1 = BGGR
        var black: Float
        var white: Float
        var wb: (r: Float, g: Float, b: Float)
        var exposureTime: Float
        var iso: Float
        var fNumber: Float
        var camToPP: [Float]     // 9, row-major camera-native -> ProPhoto linear
        var hasColor: Bool
        var noiseS: Double       // NoiseProfile scale (var(y) = S·y + O on the
        var noiseO: Double       //   normalized signal); 0,0 = tag absent
        var asn: (Double, Double, Double)  // exact AsShotNeutral (NT input)
        var baselineExposure: Double       // stops (tag 50730); 0 = absent
        var samples: [UInt16]    // row-major, length = width * height
    }

    /// Decode one DNG. Returns the mosaic on success, or the `bk_status_t`
    /// code on failure (0 = OK). Mirrors `bk_decode_dng_to_mosaic`.
    static func decodeDNG(_ data: Data) -> (mosaic: DNGMosaic?, status: Int32) {
        let bytes = [UInt8](data)
        do {
            let m = try dngParse(bytes)
            return (m, 0)
        } catch let err as DNGError {
            return (nil, err.status)
        } catch let err as LJPEGError {
            // Defensive: dngParse maps these already; keep the mapping anyway.
            return (nil, dngMapLJPEGError(err).status)
        } catch {
            return (nil, DNGError.ljpegDecodeFailed.status)
        }
    }

    // ========================================================================
    // MARK: - Errors (dng.Error / bk_status_t)
    // ========================================================================

    fileprivate enum DNGError: Error {
        case badTiffMagic
        case unsupportedByteOrder
        case unsupportedCompression          // generic fallback
        case unsupportedCompressionDeflate   // 8
        case unsupportedCompressionLossyDNG  // 34892
        case unsupportedCompressionAppleVc8r // 'vc8r' = 0x76633872
        case unsupportedCfaPattern
        case unsupportedBitDepth
        case missingTag
        case badDimensions
        case shortRead
        case ljpegDecodeFailed               // generic fallback
        // Per-variant LJPEG decoder errors, mapped 1:1 from LJPEGError so the
        // status code names exactly which LJPEG decoder check failed.
        case ljpegBadMagic
        case ljpegUnexpectedEnd
        case ljpegUnsupportedMarker
        case ljpegUnsupportedComponentCount
        case ljpegUnsupportedPrecision
        case ljpegUnsupportedPredictor
        case ljpegHasRestartMarkers
        case ljpegMalformedHuffmanTable
        case ljpegInvalidHuffmanCode
        case allocationFailed

        var status: Int32 {
            switch self {
            case .badTiffMagic:                    return 1
            case .unsupportedByteOrder:            return 2
            case .unsupportedCompression:          return 3
            case .unsupportedCfaPattern:           return 4
            case .unsupportedBitDepth:             return 5
            case .badDimensions:                   return 6
            case .missingTag:                      return 7
            case .shortRead:                       return 8
            case .allocationFailed:                return 12
            case .unsupportedCompressionDeflate:   return 14
            case .unsupportedCompressionLossyDNG:  return 15
            case .unsupportedCompressionAppleVc8r: return 16
            case .ljpegDecodeFailed:               return 17
            // 18 = NULL_POINTER is produced by pointer-taking facades, never here.
            case .ljpegBadMagic:                   return 19
            case .ljpegUnexpectedEnd:              return 20
            case .ljpegUnsupportedMarker:          return 21
            case .ljpegUnsupportedComponentCount:  return 22
            case .ljpegUnsupportedPrecision:       return 23
            case .ljpegUnsupportedPredictor:       return 24
            case .ljpegHasRestartMarkers:          return 25
            case .ljpegMalformedHuffmanTable:      return 26
            case .ljpegInvalidHuffmanCode:         return 27
            }
        }
    }

    /// Compression-tag dispatch (dng.compressionError). `nil` means supported —
    /// uncompressed (1) or LJPEG SOF3 (7).
    fileprivate static func dngCompressionError(_ value: UInt32) -> DNGError? {
        switch value {
        case 1:          return nil                               // None
        case 7:          return nil                               // LJPEG SOF3
        case 8:          return .unsupportedCompressionDeflate
        case 34892:      return .unsupportedCompressionLossyDNG
        case 0x76633872: return .unsupportedCompressionAppleVc8r  // 'vc8r'
        default:         return .unsupportedCompression
        }
    }

    fileprivate enum DNGByteOrder { case little, big }

    // ========================================================================
    // MARK: - camera → ProPhoto composition
    // ========================================================================
    //
    // Lives in CameraMatrixKernel.swift (Boreal.ColorPath CQ9/CQ10 — the NT
    // law), gate-verified bitwise against colorpath_golden.json. The old
    // color.zig-lineage Float composition applied the WB diagonal to an
    // INVERTED ColorMatrix (valid only for a ForwardMatrix) — white balance
    // twice = the 2026-07-19 device magenta. Retired here; history + the
    // archive branches keep it.

    // ========================================================================
    // MARK: - ljpeg.zig port
    // ========================================================================
    //
    // Lossless JPEG (SOF3) decoder for iPhone Bayer RAW DNG tiles.
    // Critical correctness invariants (mirrored from ljpeg.zig — DO NOT BREAK):
    //   1. Per-component predictor history (Nf=2 components each keep their own
    //      left/above neighbors).
    //   2. Per-component Huffman table dispatch via SOS Td.
    //   3. Point transform Pt applied on emission (recon << Pt), not on residual.
    //   4. Top-row initial prediction = 1 << (P - Pt - 1).
    //   5. Interleaved output: out_col = x_lj * Nf + c.

    fileprivate enum LJPEGError: Error {
        case badMagic                  // SOI not at start
        case unexpectedEnd             // ran out of bytes mid-decode
        case unsupportedMarker         // e.g., SOF0 baseline
        case unsupportedComponentCount // SOF3 with components not in {1, 2}
        case unsupportedPrecision      // SOF3 with P outside [8, 16]
        case unsupportedPredictor      // SOS with predictor not in {1, 7}
        case hasRestartMarkers         // DRI > 0
        case malformedHuffmanTable     // DHT with inconsistent code lengths
        case invalidHuffmanCode        // bit pattern not in any table entry
    }

    /// Map an LJPEGError to the corresponding per-variant DNGError so the
    /// status code names which LJPEG decoder check failed. (dng.mapLJPEGError)
    fileprivate static func dngMapLJPEGError(_ err: LJPEGError) -> DNGError {
        switch err {
        case .badMagic:                  return .ljpegBadMagic
        case .unexpectedEnd:             return .ljpegUnexpectedEnd
        case .unsupportedMarker:         return .ljpegUnsupportedMarker
        case .unsupportedComponentCount: return .ljpegUnsupportedComponentCount
        case .unsupportedPrecision:      return .ljpegUnsupportedPrecision
        case .unsupportedPredictor:      return .ljpegUnsupportedPredictor
        case .hasRestartMarkers:         return .ljpegHasRestartMarkers
        case .malformedHuffmanTable:     return .ljpegMalformedHuffmanTable
        case .invalidHuffmanCode:        return .ljpegInvalidHuffmanCode
        }
    }

    // ------------------------------------------------------------------------
    // Section 1: BitReader (MSB-first, JPEG byte-stuffing aware)
    // ------------------------------------------------------------------------

    fileprivate struct LJPEGBitReader {
        let bytes: [UInt8]
        var pos: Int             // index into bytes
        var bitBuf: UInt32 = 0   // accumulated bits (MSB-first; top of buf is next bit)
        var bitCount: Int = 0    // valid bits in bitBuf
        /// True once we hit a non-stuffed FFxx marker.
        var hitMarker = false
        var markerByte: UInt8 = 0

        init(bytes: [UInt8], pos: Int = 0) {
            self.bytes = bytes
            self.pos = pos
        }

        /// Refill bitBuf until at least `minBits` bits are available (or hit
        /// a marker / end of data).
        mutating func fill(_ minBits: Int) throws {
            while bitCount < minBits {
                if hitMarker { throw LJPEGError.unexpectedEnd }
                if pos >= bytes.count { throw LJPEGError.unexpectedEnd }
                let b = bytes[pos]
                pos += 1
                if b == 0xFF {
                    // Possible marker. Look at next byte.
                    if pos >= bytes.count { throw LJPEGError.unexpectedEnd }
                    let next = bytes[pos]
                    pos += 1
                    if next == 0x00 {
                        // Stuffed zero — emit the 0xFF as a literal data byte.
                        bitBuf |= UInt32(0xFF) << (24 - bitCount)
                        bitCount += 8
                    } else {
                        // Real marker. Park it; tell caller to stop.
                        hitMarker = true
                        markerByte = next
                        if bitCount < minBits { throw LJPEGError.unexpectedEnd }
                        return
                    }
                } else {
                    bitBuf |= UInt32(b) << (24 - bitCount)
                    bitCount += 8
                }
            }
        }

        /// Peek the top `n` bits without consuming.
        func peek(_ n: Int) -> UInt32 {
            if n == 0 { return 0 }
            return bitBuf >> (32 - n)
        }

        /// Consume the top `n` bits.
        mutating func consume(_ n: Int) {
            bitBuf <<= UInt32(n)
            bitCount -= n
        }

        /// Read and consume `n` bits.
        mutating func readBits(_ n: Int) throws -> UInt32 {
            if n == 0 { return 0 }
            try fill(n)
            let v = peek(n)
            consume(n)
            return v
        }

        /// JPEG-standard signed value extension ("EXTEND", ISO/IEC 10918-1
        /// §F.2.2.1): sign-extend an `n`-bit raw value to a signed integer.
        static func extend(_ v: UInt32, _ n: Int) -> Int32 {
            if n == 0 { return 0 }
            let half = UInt32(1) << (n - 1)
            if v >= half {
                return Int32(v)
            } else {
                let maxV = Int32(1) << n
                return Int32(v) - maxV + 1
            }
        }
    }

    // ------------------------------------------------------------------------
    // Section 2: Markers
    // ------------------------------------------------------------------------
    // Marker byte values (Zig ljpeg.Marker): soi=0xD8 eoi=0xD9 sof3=0xC3
    // dht=0xC4 sos=0xDA dri=0xDD com=0xFE; anything else is unhandled.

    /// Scan from `start` looking for the next FFxx marker (xx != 00, != FF).
    fileprivate static func ljpegParseNextMarker(_ bytes: [UInt8], _ start: Int) throws -> (marker: UInt8, pos: Int) {
        var i = start
        while i + 1 < bytes.count {
            if bytes[i] != 0xFF { i += 1; continue }
            // Skip fill bytes (FF FF FF ... is allowed before a marker).
            var j = i + 1
            while j < bytes.count && bytes[j] == 0xFF { j += 1 }
            if j >= bytes.count { throw LJPEGError.unexpectedEnd }
            let b = bytes[j]
            if b == 0x00 {
                // Stuffed zero — skip and continue scanning.
                i = j + 1
                continue
            }
            return (b, j)
        }
        throw LJPEGError.unexpectedEnd
    }

    /// Read a 16-bit big-endian value (JPEG segment fields are big-endian).
    fileprivate static func ljpegReadBE16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        if offset + 2 > bytes.count { throw LJPEGError.unexpectedEnd }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    // ------------------------------------------------------------------------
    // Section 3: Huffman table (canonical, build + decode)
    // ------------------------------------------------------------------------

    fileprivate struct LJPEGHuffmanTable {
        /// minimum code value at each length (1..16). minCode[0] unused.
        var minCode = [Int32](repeating: -1, count: 17)
        /// maximum code value at each length, or -1 if no codes at this length.
        var maxCode = [Int32](repeating: -1, count: 17)
        /// index into values[] of the first code of each length.
        var valPtr = [UInt32](repeating: 0, count: 17)
        /// flat array of decoded values, in canonical order.
        var values: [UInt8] = []

        /// Build from the DHT marker payload-after-length:
        ///   1 byte Tc/Td, 16 bytes Li (counts per length 1..16), sum(Li) values.
        static func parse(_ payload: [UInt8]) throws -> LJPEGHuffmanTable {
            if payload.count < 17 { throw LJPEGError.malformedHuffmanTable }
            // Skip Tc byte; counts are payload[1...16].
            var nValues = 0
            var ci = 1
            while ci <= 16 { nValues += Int(payload[ci]); ci += 1 }
            if payload.count < 17 + nValues { throw LJPEGError.malformedHuffmanTable }

            var t = LJPEGHuffmanTable()
            t.values = Array(payload[17 ..< 17 + nValues])

            // Build min/max code per length, value pointers (ISO/IEC 10918-1 Annex C).
            var code: Int32 = 0
            var vIdx: UInt32 = 0
            var length = 1
            while length <= 16 {
                let n = Int(payload[length])   // counts[length - 1]
                if n == 0 {
                    t.maxCode[length] = -1
                } else {
                    t.valPtr[length] = vIdx
                    t.minCode[length] = code
                    t.maxCode[length] = code + Int32(n) - 1
                    code += Int32(n)
                    vIdx += UInt32(n)
                }
                code <<= 1
                length += 1
            }
            return t
        }

        /// Decode one symbol (the "category" SSSS for LJPEG DC). Reads 1..16
        /// bits, bit-by-bit walk per ITU-T81 Annex F.2.2.3 "DECODE".
        func decode(_ r: inout LJPEGBitReader) throws -> UInt8 {
            var code: Int32 = 0
            var length = 1
            while length <= 16 {
                try r.fill(1)
                let bit = r.peek(1)
                r.consume(1)
                code = (code << 1) | Int32(bit)
                if code <= maxCode[length] {
                    let idx = Int(valPtr[length]) + Int(code - minCode[length])
                    if idx >= values.count { throw LJPEGError.invalidHuffmanCode }
                    return values[idx]
                }
                length += 1
            }
            throw LJPEGError.invalidHuffmanCode
        }
    }

    // ------------------------------------------------------------------------
    // Section 4: SOF3 + SOS headers
    // ------------------------------------------------------------------------

    fileprivate struct LJPEGFrameHeader {
        var precision: UInt8      // P
        var height: UInt16        // Y
        var width: UInt16         // X
        var nComponents: UInt8    // Nf
        var components: [Component]  // 4 entries

        struct Component {
            var id: UInt8 = 0       // Ci
            var hFactor: UInt8 = 0  // Hi
            var vFactor: UInt8 = 0  // Vi
            var tq: UInt8 = 0       // Tqi (unused for SOF3)
        }

        /// Parse SOF3 segment payload (after the 2-byte length).
        static func parse(_ payload: [UInt8]) throws -> LJPEGFrameHeader {
            if payload.count < 6 { throw LJPEGError.unexpectedEnd }
            let precision = payload[0]
            let height = (UInt16(payload[1]) << 8) | UInt16(payload[2])
            let width  = (UInt16(payload[3]) << 8) | UInt16(payload[4])
            let nf = payload[5]
            if nf == 0 || nf > 4 { throw LJPEGError.unsupportedComponentCount }
            if payload.count < 6 + Int(nf) * 3 { throw LJPEGError.unexpectedEnd }
            // Accept any precision in [8, 16] — iPhone DNGs declare P=12.
            if precision < 8 || precision > 16 { throw LJPEGError.unsupportedPrecision }
            // Accept Nf in {1, 2}. iPhone Bayer LJPEG uses Nf=2 (verified 2026-05-16:
            // SOF3 P=12 Y=378 X=132 Nf=2, matching TileWidth=264, TileLength=378).
            if nf == 0 || nf > 2 { throw LJPEGError.unsupportedComponentCount }

            var comps = [Component](repeating: Component(), count: 4)
            var i = 0
            while i < Int(nf) {
                let off = 6 + i * 3
                comps[i] = Component(
                    id: payload[off],
                    hFactor: (payload[off + 1] >> 4) & 0x0F,
                    vFactor: payload[off + 1] & 0x0F,
                    tq: payload[off + 2]
                )
                i += 1
            }
            return LJPEGFrameHeader(precision: precision, height: height, width: width,
                                    nComponents: nf, components: comps)
        }
    }

    fileprivate struct LJPEGScanHeader {
        var predictor: UInt8        // Ss, 1..7 for SOF3
        var nComponents: UInt8      // Ns
        var components: [Component] // 4 entries
        var pointTransform: UInt8   // Al

        struct Component {
            var cs: UInt8 = 0   // component selector
            var td: UInt8 = 0   // huffman table dest
        }

        static func parse(_ payload: [UInt8]) throws -> LJPEGScanHeader {
            if payload.count < 1 { throw LJPEGError.unexpectedEnd }
            let ns = payload[0]
            if ns == 0 || ns > 4 { throw LJPEGError.unsupportedComponentCount }
            if payload.count < 1 + Int(ns) * 2 + 3 { throw LJPEGError.unexpectedEnd }
            var comps = [Component](repeating: Component(), count: 4)
            var i = 0
            while i < Int(ns) {
                let off = 1 + i * 2
                comps[i] = Component(cs: payload[off], td: (payload[off + 1] >> 4) & 0x0F)
                i += 1
            }
            let tail = 1 + Int(ns) * 2
            let predictor = payload[tail]                        // Ss
            // payload[tail + 1] is Se (= 0 for SOF3)
            let pointTransform = payload[tail + 2] & 0x0F        // Al
            // Accept Ns in {1, 2} matching the FrameHeader Nf relaxation.
            if ns == 0 || ns > 2 { throw LJPEGError.unsupportedComponentCount }
            if predictor != 1 && predictor != 7 { throw LJPEGError.unsupportedPredictor }
            return LJPEGScanHeader(predictor: predictor, nComponents: ns,
                                   components: comps, pointTransform: pointTransform)
        }
    }

    // ------------------------------------------------------------------------
    // Section 5: decode() top-level (multi-component, point-transform aware)
    // ------------------------------------------------------------------------

    fileprivate struct LJPEGDecoded {
        var width: Int         // physical width in u16 samples (= lj_w * nf)
        var height: Int
        var precision: UInt8
        var samples: [UInt16]  // length = width * height, row-major
    }

    /// Top-level LJPEG SOF3 decode. Walks markers, parses SOF3 + DHT(s) + SOS,
    /// then runs the predictor loop on the entropy data.
    fileprivate static func ljpegDecode(_ bytes: [UInt8]) throws -> LJPEGDecoded {
        if bytes.count < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8 {
            throw LJPEGError.badMagic
        }

        var pos = 2
        var frame: LJPEGFrameHeader? = nil
        var scan: LJPEGScanHeader? = nil
        // Up to 4 DC Huffman tables, indexed by destination 0..3.
        var dcTables: [LJPEGHuffmanTable?] = [nil, nil, nil, nil]
        var entropyStart = 0

        // Marker walk until SOS (after which we're in the entropy-coded segment).
        markerLoop: while true {
            let fm = try ljpegParseNextMarker(bytes, pos)
            switch fm.marker {
            case 0xD8: // SOI
                pos = fm.pos + 1
                continue
            case 0xC3: // SOF3
                if fm.pos + 3 > bytes.count { throw LJPEGError.unexpectedEnd }
                let segLen = Int(try ljpegReadBE16(bytes, fm.pos + 1))
                if fm.pos + 1 + segLen > bytes.count { throw LJPEGError.unexpectedEnd }
                frame = try LJPEGFrameHeader.parse(Array(bytes[(fm.pos + 3) ..< (fm.pos + 1 + segLen)]))
                pos = fm.pos + 1 + segLen
            case 0xC4: // DHT
                if fm.pos + 3 > bytes.count { throw LJPEGError.unexpectedEnd }
                let segLen = Int(try ljpegReadBE16(bytes, fm.pos + 1))
                if fm.pos + 1 + segLen > bytes.count { throw LJPEGError.unexpectedEnd }
                // A DHT segment can contain multiple tables; walk them.
                var dhtOff = fm.pos + 3
                let dhtEnd = fm.pos + 1 + segLen
                while dhtOff < dhtEnd {
                    if dhtOff + 17 > dhtEnd { throw LJPEGError.malformedHuffmanTable }
                    let td = Int(bytes[dhtOff] & 0x0F)
                    if td > 3 { throw LJPEGError.malformedHuffmanTable }
                    var nValues = 0
                    var k = 1
                    while k <= 16 { nValues += Int(bytes[dhtOff + k]); k += 1 }
                    // (Zig would trip its slice bounds check here; report the
                    // same condition as a malformed table.)
                    if dhtOff + 17 + nValues > bytes.count { throw LJPEGError.malformedHuffmanTable }
                    let tablePayload = Array(bytes[dhtOff ..< dhtOff + 17 + nValues])
                    dcTables[td] = try LJPEGHuffmanTable.parse(tablePayload)
                    dhtOff += 17 + nValues
                }
                pos = fm.pos + 1 + segLen
            case 0xDD: // DRI
                if fm.pos + 3 > bytes.count { throw LJPEGError.unexpectedEnd }
                let ri = try ljpegReadBE16(bytes, fm.pos + 3)
                if ri != 0 { throw LJPEGError.hasRestartMarkers }
                pos = fm.pos + 1 + 4  // 4-byte segment
            case 0xDA: // SOS
                if fm.pos + 3 > bytes.count { throw LJPEGError.unexpectedEnd }
                let segLen = Int(try ljpegReadBE16(bytes, fm.pos + 1))
                if fm.pos + 1 + segLen > bytes.count { throw LJPEGError.unexpectedEnd }
                scan = try LJPEGScanHeader.parse(Array(bytes[(fm.pos + 3) ..< (fm.pos + 1 + segLen)]))
                entropyStart = fm.pos + 1 + segLen
                break markerLoop
            case 0xFE: // COM — skip comment
                if fm.pos + 3 > bytes.count { throw LJPEGError.unexpectedEnd }
                let segLen = Int(try ljpegReadBE16(bytes, fm.pos + 1))
                pos = fm.pos + 1 + segLen
            case 0xD9: // EOI — SOS never seen
                throw LJPEGError.unexpectedEnd
            default:
                throw LJPEGError.unsupportedMarker
            }
        }

        guard let f = frame else { throw LJPEGError.unexpectedEnd }
        guard let s = scan else { throw LJPEGError.unexpectedEnd }
        if s.nComponents != f.nComponents { throw LJPEGError.unsupportedComponentCount }

        // Per-component Huffman table lookups via the Td destination in SOS.
        var compTables = [LJPEGHuffmanTable]()
        var ci = 0
        while ci < Int(f.nComponents) {
            let tdIdx = Int(s.components[ci].td)
            if tdIdx > 3 { throw LJPEGError.malformedHuffmanTable }
            guard let t = dcTables[tdIdx] else { throw LJPEGError.malformedHuffmanTable }
            compTables.append(t)
            ci += 1
        }

        // Geometry:
        //   f.width  = LJPEG pixels per row; Nf = components per LJPEG pixel.
        //   out_w    = f.width * Nf (iPhone: 132 * 2 = 264 = TileWidth).
        let nf = Int(f.nComponents)
        let ljW = Int(f.width)
        let h = Int(f.height)
        let outW = ljW * nf
        var samples = [UInt16](repeating: 0, count: outW * h)

        // Initial predictor for first sample of first row: 2^(P - Pt - 1)
        // (ISO/IEC 10918-1 §H.1.2.1; iPhone P=12, Pt=1 -> 1024 pre-shift).
        // Point transform Pt: left-shift each reconstructed sample by Pt on
        // emission (predictor neighbors are stored AFTER shift, so the
        // history-vs-shift composition is automatic).
        // max_val clamp is (1 << P) - 1 (= 4095 for P=12, the observed WhiteLevel).
        let pt = Int(s.pointTransform)
        let initialPred: Int32 = 1 << (Int(f.precision) - pt - 1)
        let maxVal: Int32 = (1 << Int(f.precision)) - 1

        var r = LJPEGBitReader(bytes: bytes, pos: entropyStart)

        // Decode loop: per LJPEG pixel position, decode Nf samples (one per
        // component), each with its own predictor history. Output columns
        // interleave: component c at out_col = x_lj * nf + c.
        var y = 0
        while y < h {
            var xlj = 0
            while xlj < ljW {
                var c = 0
                while c < nf {
                    let outCol = xlj * nf + c
                    // ── Per-component predictor (LOAD-BEARING) ──
                    // The "left" neighbor for component c at LJPEG pixel x is
                    // the SAME component at pixel x-1, i.e. output column
                    // (x-1)*nf + c — NOT out_col - 1. Cross-component bleed
                    // would scramble the two greens in a BGGR cell.
                    let predicted: Int32
                    if xlj == 0 && y == 0 {
                        predicted = initialPred
                    } else if y == 0 {
                        // First row, x_lj > 0: Pa (same component, previous LJPEG pixel)
                        let leftCol = (xlj - 1) * nf + c
                        predicted = Int32(samples[leftCol])
                    } else if xlj == 0 {
                        // First column of subsequent rows: Pb (same component above)
                        predicted = Int32(samples[(y - 1) * outW + c])
                    } else {
                        let pa = Int32(samples[y * outW + (xlj - 1) * nf + c])
                        let pb = Int32(samples[(y - 1) * outW + xlj * nf + c])
                        switch s.predictor {
                        case 1: predicted = pa
                        case 7: predicted = (pa + pb) / 2   // @divTrunc
                        default: throw LJPEGError.unsupportedPredictor
                        }
                    }

                    // Decode diff via this component's Huffman table.
                    let t = try compTables[c].decode(&r)
                    let raw: UInt32 = (t == 0) ? 0 : try r.readBits(Int(t))
                    let diff = LJPEGBitReader.extend(raw, Int(t))

                    // Reconstruct, point-transform left-shift, clamp.
                    let recon = predicted + diff
                    let shifted = recon << pt
                    let clipped = max(Int32(0), min(maxVal, shifted))
                    samples[y * outW + outCol] = UInt16(clipped)
                    c += 1
                }
                xlj += 1
            }
            y += 1
        }

        return LJPEGDecoded(width: outW, height: h, precision: f.precision, samples: samples)
    }

    // ========================================================================
    // MARK: - dng.zig port
    // ========================================================================

    /// TIFF tags we actually consume (Adobe DNG Spec 1.4.0.0 / TIFF 6.0).
    fileprivate enum DNGTag {
        static let imageWidth: UInt16                = 256
        static let imageLength: UInt16               = 257
        static let bitsPerSample: UInt16             = 258
        static let compression: UInt16               = 259
        static let photometricInterpretation: UInt16 = 262
        static let stripOffsets: UInt16              = 273
        static let rowsPerStrip: UInt16              = 278
        static let stripByteCounts: UInt16           = 279
        static let tileWidth: UInt16                 = 322
        static let tileLength: UInt16                = 323
        static let tileOffsets: UInt16               = 324
        static let tileByteCounts: UInt16            = 325
        static let cfaPattern: UInt16                = 33422
        static let blackLevel: UInt16                = 50714
        static let whiteLevel: UInt16                = 50717
        static let defaultCropOrigin: UInt16         = 50719
        static let defaultCropSize: UInt16           = 50720
        static let asShotNeutral: UInt16             = 50728  // RATIONAL[3] — capture WB
        static let exifIfdPointer: UInt16            = 34665  // LONG -> EXIF SubIFD offset
        static let exposureTime: UInt16              = 33434  // RATIONAL seconds
        static let fnumber: UInt16                   = 33437  // RATIONAL
        static let iso: UInt16                       = 34855  // SHORT/LONG ISOSpeedRatings
        static let noiseProfile: UInt16              = 51041  // DOUBLE[2 or 2·planes] — var(y) = S·y + O
        static let baselineExposure: UInt16          = 50730  // SRATIONAL[1] — maker's display-lift hint, stops
        static let colorMatrix1: UInt16              = 50721  // SRATIONAL[9] — XYZ(illum1, StdA)->camera
        static let colorMatrix2: UInt16              = 50722  // SRATIONAL[9] — XYZ(illum2, D65)->camera
        static let forwardMatrix1: UInt16            = 50964  // SRATIONAL[9] — cameraWB->XYZ(D50), illum1
        static let forwardMatrix2: UInt16            = 50965  // SRATIONAL[9] — cameraWB->XYZ(D50), illum2
    }

    fileprivate static let dngCFAPhotometric: UInt32 = 32803

    /// Parse the DNG bytes -> cropped mosaic. (dng.parse + facade crop apply)
    fileprivate static func dngParse(_ bytes: [UInt8]) throws -> DNGMosaic {
        if bytes.count < 8 { throw DNGError.badTiffMagic }

        let order: DNGByteOrder
        if bytes[0] == UInt8(ascii: "I") && bytes[1] == UInt8(ascii: "I") {
            order = .little
        } else if bytes[0] == UInt8(ascii: "M") && bytes[1] == UInt8(ascii: "M") {
            order = .big
        } else {
            throw DNGError.badTiffMagic
        }

        let magic = dngReadU16(bytes, 2, order)
        if magic != 42 { throw DNGError.badTiffMagic }

        let ifd0Off = dngReadU32(bytes, 4, order)
        return try dngParseIfd0(bytes, ifd0Off, order)
    }

    fileprivate static func dngParseIfd0(_ bytes: [UInt8], _ ifdOff: UInt32,
                                         _ order: DNGByteOrder) throws -> DNGMosaic {
        if bytes.count < Int(ifdOff) + 2 { throw DNGError.shortRead }
        let entryCount = dngReadU16(bytes, Int(ifdOff), order)
        let entriesBase = Int(ifdOff) + 2
        if bytes.count < entriesBase + Int(entryCount) * 12 { throw DNGError.shortRead }

        // Required-to-find tags; default zeros mean "missing" -> error at the end.
        var w: UInt32 = 0
        var h: UInt32 = 0
        var bits: UInt32 = 0
        var compression: UInt32 = 0
        var photometric: UInt32 = 0
        var rowsPerStrip: UInt32 = 0
        var cfaKind: UInt32? = nil          // 0 = RGGB, 1 = BGGR
        var black: UInt32 = 0
        var white: UInt32 = 0
        var cropX: UInt32 = 0
        var cropY: UInt32 = 0
        var cropW: UInt32 = 0
        var cropH: UInt32 = 0
        var wbR: Float = 1.0
        let wbG: Float = 1.0  // green is the reference; never reassigned
        var wbB: Float = 1.0
        var asn: (Double, Double, Double) = (1, 1, 1)  // exact AsShotNeutral (NT input)
        var noiseS = 0.0                    // NoiseProfile (0,0 = absent)
        var noiseO = 0.0
        var baselineExposure = 0.0          // stops; 0 = absent
        var exifIfdOff: UInt32 = 0          // EXIF SubIFD offset (tag 34665)
        var forwardMatrix1: [Double]? = nil // cameraWB->XYZ(D50), illum1
        var forwardMatrix2: [Double]? = nil // cameraWB->XYZ(D50), illum2 (preferred)
        var colorMatrix1: [Double]? = nil   // XYZ(StdA)->camera, fallback of the fallback
        var colorMatrix2: [Double]? = nil   // XYZ(D65)->camera, the iPhone live path

        var stripOffsetsEntry: DNGEntry? = nil
        var stripByteCountsEntry: DNGEntry? = nil
        var tileOffsetsEntry: DNGEntry? = nil
        var tileByteCountsEntry: DNGEntry? = nil
        var tileWidth: UInt32 = 0
        var tileLength: UInt32 = 0

        var i = 0
        while i < Int(entryCount) {
            let off = entriesBase + i * 12
            let e = DNGEntry(
                tag: dngReadU16(bytes, off, order),
                type: dngReadU16(bytes, off + 2, order),
                count: dngReadU32(bytes, off + 4, order),
                valueOff: dngReadU32(bytes, off + 8, order)
            )
            switch e.tag {
            case DNGTag.imageWidth:                w = e.inlineU32(order)
            case DNGTag.imageLength:               h = e.inlineU32(order)
            case DNGTag.bitsPerSample:             bits = e.inlineU32(order)
            case DNGTag.compression:               compression = e.inlineU32(order)
            case DNGTag.photometricInterpretation: photometric = e.inlineU32(order)
            case DNGTag.stripOffsets:              stripOffsetsEntry = e
            case DNGTag.rowsPerStrip:              rowsPerStrip = e.inlineU32(order)
            case DNGTag.stripByteCounts:           stripByteCountsEntry = e
            case DNGTag.tileWidth:                 tileWidth = e.inlineU32(order)
            case DNGTag.tileLength:                tileLength = e.inlineU32(order)
            case DNGTag.tileOffsets:               tileOffsetsEntry = e
            case DNGTag.tileByteCounts:            tileByteCountsEntry = e
            case DNGTag.cfaPattern:
                // CFA pattern is 4 bytes inline for type=1 BYTE count=4: R=0 G=1 B=2.
                // Accept RGGB = [0,1,1,2] and BGGR = [2,1,1,0]. Try both byte
                // orders for big-endian DNGs (TIFF spec leaves BYTE-array layout
                // ambiguous in BE files).
                if e.type == 1 && e.count == 4 {
                    let p0 = UInt8(truncatingIfNeeded: e.valueOff)
                    let p1 = UInt8(truncatingIfNeeded: e.valueOff >> 8)
                    let p2 = UInt8(truncatingIfNeeded: e.valueOff >> 16)
                    let p3 = UInt8(truncatingIfNeeded: e.valueOff >> 24)
                    if p0 == 0 && p1 == 1 && p2 == 1 && p3 == 2 { cfaKind = 0 }
                    if p3 == 0 && p2 == 1 && p1 == 1 && p0 == 2 { cfaKind = 0 }
                    if p0 == 2 && p1 == 1 && p2 == 1 && p3 == 0 { cfaKind = 1 }
                    if p3 == 2 && p2 == 1 && p1 == 1 && p0 == 0 { cfaKind = 1 }
                }
            case DNGTag.blackLevel: black = try dngReadUintAt(bytes, e, order)
            case DNGTag.whiteLevel: white = try dngReadUintAt(bytes, e, order)
            case DNGTag.defaultCropOrigin:
                let vals = try dngReadUintPair(bytes, e, order)
                cropX = vals.0
                cropY = vals.1
            case DNGTag.defaultCropSize:
                let vals = try dngReadUintPair(bytes, e, order)
                cropW = vals.0
                cropH = vals.1
            case DNGTag.asShotNeutral:
                // RATIONAL[3] camera-neutral, kept EXACT in f64 (the NT
                // law's input). WB multiplier = green/channel (f32, the
                // ETTR planner's view). Unreadable -> leave neutral (1,1,1).
                if let a = try? dngReadRational3(bytes, e, order) {
                    let g = a[1] > 1.0e-6 ? a[1] : 1.0
                    if a[0] > 1.0e-6 { wbR = Float(g / a[0]) }
                    if a[2] > 1.0e-6 { wbB = Float(g / a[2]) }
                    // wbG stays 1 (green is the reference)
                    if a[0] > 1.0e-6, a[1] > 1.0e-6, a[2] > 1.0e-6 {
                        asn = (a[0], a[1], a[2])
                    }
                }
            // The SubIFD pointer can appear in any entry order; record the
            // offset and parse the SubIFD after the IFD0 loop closes.
            case DNGTag.exifIfdPointer: exifIfdOff = e.inlineU32(order)
            // Colour matrices (SRATIONAL[9]). ForwardMatrix preferred
            // (illum2/D65 over illum1/StdA); ColorMatrix is the fallback —
            // iPhone DNGs carry ONLY CM1+CM2. Unreadable -> nil ->
            // camera-native passthrough downstream.
            case DNGTag.noiseProfile:
                // DNG 1.4 NoiseProfile: the sensor's calibrated Poisson-
                // Gaussian model, per capture (Apple writes it per frame —
                // including the dual-conversion-gain break; RAW-LIKELIHOOD
                // research doc §5/§7). First (S, O) pair; per-plane variants
                // collapse to plane 0 (iPhone writes a single pair anyway).
                if e.type == 12, e.count >= 2, bytes.count >= Int(e.valueOff) + 16 {
                    let s = dngReadF64(bytes, Int(e.valueOff), order)
                    let o = dngReadF64(bytes, Int(e.valueOff) + 8, order)
                    if s > 0, o >= 0, s.isFinite, o.isFinite {
                        noiseS = s
                        noiseO = o
                    }
                }
            case DNGTag.baselineExposure:
                // SRATIONAL[1], the maker's calibrated display-lift hint in
                // stops (Apple writes it per frame). Diagnostic only — the
                // ISP stays scene-linear; whether the GIF applies a lift is
                // a product decision.
                if e.type == 10, e.count >= 1, bytes.count >= Int(e.valueOff) + 8 {
                    let num = Int32(bitPattern: dngReadU32(bytes, Int(e.valueOff), order))
                    let den = Int32(bitPattern: dngReadU32(bytes, Int(e.valueOff) + 4, order))
                    if den != 0 { baselineExposure = Double(num) / Double(den) }
                }
            case DNGTag.forwardMatrix1: forwardMatrix1 = try? dngReadSRational9(bytes, e, order)
            case DNGTag.forwardMatrix2: forwardMatrix2 = try? dngReadSRational9(bytes, e, order)
            case DNGTag.colorMatrix1:   colorMatrix1 = try? dngReadSRational9(bytes, e, order)
            case DNGTag.colorMatrix2:   colorMatrix2 = try? dngReadSRational9(bytes, e, order)
            default: break
            }
            i += 1
        }

        // ── EXIF SubIFD pass (additive; never errors — leaves 0 sentinels) ──
        var exposureTime: Float = 0
        var iso: Float = 0
        var fnumber: Float = 0
        if exifIfdOff != 0 && bytes.count >= Int(exifIfdOff) + 2 {
            let ec = dngReadU16(bytes, Int(exifIfdOff), order)
            let eb = Int(exifIfdOff) + 2
            if bytes.count >= eb + Int(ec) * 12 {
                var j = 0
                while j < Int(ec) {
                    let eoff = eb + j * 12
                    let ee = DNGEntry(
                        tag: dngReadU16(bytes, eoff, order),
                        type: dngReadU16(bytes, eoff + 2, order),
                        count: dngReadU32(bytes, eoff + 4, order),
                        valueOff: dngReadU32(bytes, eoff + 8, order)
                    )
                    switch ee.tag {
                    case DNGTag.exposureTime: exposureTime = dngReadRational1(bytes, ee, order)
                    case DNGTag.fnumber:      fnumber = dngReadRational1(bytes, ee, order)
                    // ISOSpeedRatings is SHORT/LONG and MAY have count>1 (the
                    // array is then stored out-of-line). dngReadUintAt reads the
                    // first element in- or out-of-line with bounds + type guard;
                    // plain inlineU32 would return valueOff (a FILE OFFSET) for
                    // count>1, decoding a bogus ISO. Unreadable -> 0 sentinel.
                    case DNGTag.iso:
                        iso = Float((try? dngReadUintAt(bytes, ee, order)) ?? 0)
                    default: break
                    }
                    j += 1
                }
            }
        }

        if w == 0 || h == 0 { throw DNGError.badDimensions }
        if bits != 14 && bits != 16 { throw DNGError.unsupportedBitDepth }
        if let compErr = dngCompressionError(compression) { throw compErr }
        if photometric != dngCFAPhotometric { throw DNGError.unsupportedCfaPattern }
        guard let cfa = cfaKind else { throw DNGError.unsupportedCfaPattern }
        if cropW == 0 || cropH == 0 { throw DNGError.missingTag }

        // Default sensible black/white if DNG omitted them.
        if black == 0 && bits == 14 { black = 528 }     // iPhone 17 Pro typical
        if white == 0 { white = (UInt32(1) << bits) - 1 }

        // Compose the camera-native -> ProPhoto-linear matrix (NT law:
        // AsShotNeutral MUST land on ProPhoto gray). ForwardMatrix path
        // when present (FM2/D65 preferred); else the ColorMatrix fallback
        // (CM2/D65 preferred — the iPhone live path: implicit WB via the
        // scene white + Bradford to D50, NO wb diagonal); else camera-native
        // (hasColor=false -> caller embeds no ICC, no mis-tag). Math in f64
        // (spec/Boreal/ColorPath.hs), rounded to f32 once, here.
        var camToPP: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        var hasColor = false
        if let fm = forwardMatrix2 ?? forwardMatrix1,
           let m = BorealKernels.cameraToProPhotoFM(fm, asn: asn) {
            camToPP = m.map(Float.init)
            hasColor = true
        } else if let cm = colorMatrix2 ?? colorMatrix1,
                  let m = BorealKernels.cameraToProPhotoCM(cm, asn: asn) {
            camToPP = m.map(Float.init)
            hasColor = true
        }

        let W = Int(w)
        let H = Int(h)
        let pixelCount = W * H

        // ── Image-data layout dispatch (verified on iPhone 17 Pro 2026-05-16) ──
        //
        // iPhone DNGs use ONE layout in practice: tiles + Compression=7 (LJPEG).
        // The strip path is preserved for synthetic test fixtures (Compression=1
        // uncompressed Bayer) and for other DNG sources. On device the
        // strip-related tags (273/279/278) are ABSENT — only tile tags 322-325.
        //
        // iPhone 17 Pro at 12 MP binned Bayer:
        //   TileWidth = 264 (= LJPEG raster width * Nf = 132 * 2), TileLength = 378
        //   Tile count = (4224/264) * (3024/378) = 16 * 8 = 128
        var pixels: [UInt16]
        if let toEntry = tileOffsetsEntry, let tbcEntry = tileByteCountsEntry {
            // Tile layout: N tiles in row-major order. Edge tiles may extend
            // beyond the image bounds (trailing padding discarded by the copy).
            if toEntry.count != tbcEntry.count { throw DNGError.missingTag }
            var tw = Int(tileWidth)
            var tl = Int(tileLength)
            if tw == 0 { tw = W }     // single-tile fallback
            if tl == 0 { tl = H }
            if compression != 7 { throw DNGError.unsupportedCompression }

            let tilesAcross = (W + tw - 1) / tw
            let tilesDown = (H + tl - 1) / tl
            let expectedTiles = tilesAcross * tilesDown
            if Int(toEntry.count) != expectedTiles { throw DNGError.badDimensions }

            pixels = [UInt16](repeating: 0, count: pixelCount)

            var ti = 0
            while ti < expectedTiles {
                let tileX = (ti % tilesAcross) * tw
                let tileY = (ti / tilesAcross) * tl
                let off = Int(try dngReadArrayU32(bytes, toEntry, ti, order))
                let cnt = Int(try dngReadArrayU32(bytes, tbcEntry, ti, order))
                if bytes.count < off + cnt { throw DNGError.shortRead }
                let tileBytes = Array(bytes[off ..< off + cnt])

                // Decode this tile's LJPEG payload.
                let dec: LJPEGDecoded
                do {
                    dec = try ljpegDecode(tileBytes)
                } catch let err as LJPEGError {
                    throw dngMapLJPEGError(err)
                }

                // Copy decoded tile samples into the right rectangle of `pixels`,
                // discarding edge-tile padding beyond the image boundary.
                let copyW = min(tw, W - tileX)
                let copyH = min(tl, H - tileY)
                var ry = 0
                while ry < copyH {
                    let srcRow = ry * dec.width
                    let dstRow = (tileY + ry) * W + tileX
                    pixels.replaceSubrange(dstRow ..< dstRow + copyW,
                                           with: dec.samples[srcRow ..< srcRow + copyW])
                    ry += 1
                }
                ti += 1
            }
        } else if let soEntry = stripOffsetsEntry, let sbcEntry = stripByteCountsEntry {
            // Strip layout. Single-strip is the common case for uncompressed
            // Bayer; multi-strip falls back to the loop below.
            if soEntry.count == 1 && sbcEntry.count == 1 {
                let dataOff = Int(soEntry.inlineU32(order))
                let dataLen = Int(sbcEntry.inlineU32(order))
                if bytes.count < dataOff + dataLen { throw DNGError.shortRead }

                switch compression {
                case 1:
                    let singleStripByteCount = pixelCount * 2
                    if dataLen < singleStripByteCount { throw DNGError.shortRead }
                    pixels = [UInt16](repeating: 0, count: pixelCount)
                    dngDecodeMosaicU16(bytes, srcOffset: dataOff, into: &pixels,
                                       dstOffset: 0, count: pixelCount, order)
                case 7:
                    let dec: LJPEGDecoded
                    do {
                        dec = try ljpegDecode(Array(bytes[dataOff ..< dataOff + dataLen]))
                    } catch let err as LJPEGError {
                        throw dngMapLJPEGError(err)
                    }
                    if dec.width != W || dec.height != H { throw DNGError.badDimensions }
                    pixels = dec.samples
                default:
                    // Unreachable: dngCompressionError() above admits only 1 and 7.
                    throw DNGError.unsupportedCompression
                }
            } else {
                // Multi-strip — only supported for uncompressed today.
                if compression != 1 { throw DNGError.ljpegDecodeFailed }
                let nStrips = Int(soEntry.count)
                if sbcEntry.count != soEntry.count { throw DNGError.missingTag }
                if rowsPerStrip == 0 { throw DNGError.missingTag }

                pixels = [UInt16](repeating: 0, count: pixelCount)

                var dstIdx = 0
                var si = 0
                while si < nStrips {
                    let off = Int(try dngReadArrayU32(bytes, soEntry, si, order))
                    let cnt = Int(try dngReadArrayU32(bytes, sbcEntry, si, order))
                    if bytes.count < off + cnt { throw DNGError.shortRead }
                    let dstWords = cnt / 2
                    if dstIdx + dstWords > pixelCount { throw DNGError.badDimensions }
                    dngDecodeMosaicU16(bytes, srcOffset: off, into: &pixels,
                                       dstOffset: dstIdx, count: dstWords, order)
                    dstIdx += dstWords
                    si += 1
                }
                if dstIdx != pixelCount { throw DNGError.badDimensions }
            }
        } else {
            // Neither tile nor strip layout — DNG is malformed for our purposes.
            throw DNGError.missingTag
        }

        // ── DefaultCrop application (facade-level) ──
        // The Zig parser returns the full-sensor mosaic plus crop metadata and
        // lets the binner apply the crop; this port applies DefaultCropOrigin/
        // Size here so DNGMosaic carries the cropped mosaic directly. A crop
        // rectangle that falls outside the sensor bounds is ignored (full
        // mosaic returned). Crop origin is assumed CFA-aligned (even), as the
        // Zig binner enforced; `cfa` is reported as parsed.
        let cX = Int(cropX), cY = Int(cropY), cW = Int(cropW), cH = Int(cropH)
        var outW = W
        var outH = H
        var outSamples = pixels
        if cX + cW <= W && cY + cH <= H
            && !(cX == 0 && cY == 0 && cW == W && cH == H) {
            var cropped = [UInt16](repeating: 0, count: cW * cH)
            var ry = 0
            while ry < cH {
                let src = (cY + ry) * W + cX
                let dst = ry * cW
                cropped.replaceSubrange(dst ..< dst + cW, with: pixels[src ..< src + cW])
                ry += 1
            }
            outSamples = cropped
            outW = cW
            outH = cH
        }

        return DNGMosaic(
            width: outW,
            height: outH,
            cfa: cfa,
            black: Float(black),
            white: Float(white),
            wb: (r: wbR, g: wbG, b: wbB),
            exposureTime: exposureTime,
            iso: iso,
            fNumber: fnumber,
            camToPP: camToPP,
            hasColor: hasColor,
            noiseS: noiseS,
            noiseO: noiseO,
            asn: asn,
            baselineExposure: baselineExposure,
            samples: outSamples
        )
    }

    // ------------------------------------------------------------------------
    // MARK: dng.zig internals
    // ------------------------------------------------------------------------

    fileprivate struct DNGEntry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var valueOff: UInt32

        func typeSize() -> Int {
            switch type {
            case 1, 2, 7: return 1  // BYTE, ASCII, UNDEFINED
            case 3:       return 2  // SHORT
            case 4:       return 4  // LONG
            case 5:       return 8  // RATIONAL
            default:      return 0
            }
        }

        /// SHORT (count=1) lives in different halves of the 4-byte value field
        /// depending on byte order.
        func inlineU32(_ order: DNGByteOrder) -> UInt32 {
            if type == 3 && count == 1 {
                return order == .little
                    ? valueOff & 0xFFFF   // low half
                    : valueOff >> 16      // high half (already byte-swapped on read)
            }
            return valueOff
        }
    }

    /// Read the first value of an array-of-uint tag (BlackLevel / WhiteLevel /
    /// ISO), SHORT or LONG or RATIONAL, count possibly > 1.
    fileprivate static func dngReadUintAt(_ bytes: [UInt8], _ e: DNGEntry,
                                          _ order: DNGByteOrder) throws -> UInt32 {
        switch e.type {
        case 3:
            if e.count == 1 { return e.inlineU32(order) }
            let base = Int(e.valueOff)
            if bytes.count < base + 2 { throw DNGError.shortRead }
            return UInt32(dngReadU16(bytes, base, order))
        case 4:
            if e.count == 1 { return e.inlineU32(order) }
            let base = Int(e.valueOff)
            if bytes.count < base + 4 { throw DNGError.shortRead }
            return dngReadU32(bytes, base, order)
        case 5:
            // RATIONAL = LONG numerator / LONG denominator, always out-of-line.
            let base = Int(e.valueOff)
            if bytes.count < base + 8 { throw DNGError.shortRead }
            let num = dngReadU32(bytes, base, order)
            let den = dngReadU32(bytes, base + 4, order)
            if den == 0 { return 0 }
            return num / den
        default:
            throw DNGError.missingTag
        }
    }

    /// Read a count-2 uint tag (e.g., DefaultCropOrigin = [x, y]).
    fileprivate static func dngReadUintPair(_ bytes: [UInt8], _ e: DNGEntry,
                                            _ order: DNGByteOrder) throws -> (UInt32, UInt32) {
        if e.count != 2 { throw DNGError.missingTag }
        switch e.type {
        case 3:
            // Two SHORTs fit inline in 4 bytes.
            let a = order == .little ? e.valueOff & 0xFFFF : e.valueOff >> 16
            let b = order == .little ? e.valueOff >> 16 : e.valueOff & 0xFFFF
            return (a, b)
        case 4:
            let base = Int(e.valueOff)
            if bytes.count < base + 8 { throw DNGError.shortRead }
            return (dngReadU32(bytes, base, order), dngReadU32(bytes, base + 4, order))
        case 5:
            let base = Int(e.valueOff)
            if bytes.count < base + 16 { throw DNGError.shortRead }
            let n0 = dngReadU32(bytes, base, order)
            let d0 = dngReadU32(bytes, base + 4, order)
            let n1 = dngReadU32(bytes, base + 8, order)
            let d1 = dngReadU32(bytes, base + 12, order)
            return (d0 == 0 ? 0 : n0 / d0, d1 == 0 ? 0 : n1 / d1)
        default:
            throw DNGError.missingTag
        }
    }

    /// Read a single RATIONAL value as Float. RATIONAL is always out-of-line
    /// (8 bytes). Returns 0 (sentinel, NOT error/optional) on any unreadable
    /// condition so the EXIF pass stays fully graceful. MUST be used for
    /// ExposureTime/FNumber instead of dngReadUintAt, which integer-divides
    /// (flooring e.g. 1/250 -> 0 — the documented bug).
    fileprivate static func dngReadRational1(_ bytes: [UInt8], _ e: DNGEntry,
                                             _ order: DNGByteOrder) -> Float {
        if e.type != 5 || e.count < 1 { return 0 }
        let base = Int(e.valueOff)  // RATIONAL always out-of-line
        if bytes.count < base + 8 { return 0 }
        let num = dngReadU32(bytes, base, order)
        let den = dngReadU32(bytes, base + 4, order)
        if den == 0 { return 0 }
        return Float(num) / Float(den)
    }

    /// Read a count-3 RATIONAL tag (e.g., AsShotNeutral) as three f64 ratios
    /// (num/den in Double — the exact value every spec language computes).
    /// Always out-of-line (3 rationals = 24 bytes).
    fileprivate static func dngReadRational3(_ bytes: [UInt8], _ e: DNGEntry,
                                             _ order: DNGByteOrder) throws -> [Double] {
        if e.count != 3 || e.type != 5 { throw DNGError.missingTag }
        let base = Int(e.valueOff)
        if bytes.count < base + 24 { throw DNGError.shortRead }
        var out = [Double](repeating: 0, count: 3)
        var k = 0
        while k < 3 {
            let num = dngReadU32(bytes, base + k * 8, order)
            let den = dngReadU32(bytes, base + k * 8 + 4, order)
            out[k] = den == 0 ? 0 : Double(num) / Double(den)
            k += 1
        }
        return out
    }

    /// Read a count-9 SRATIONAL tag (ColorMatrix / ForwardMatrix) as a
    /// row-major [Double] of 9 (num/den in f64 — the exact value every spec
    /// language computes; the composition math is normative in f64).
    /// SRATIONAL = signed LONG num / signed LONG den; 9 of them = 72 bytes,
    /// always out-of-line. Throws (caught to nil by the caller) on any
    /// unreadable condition so a malformed matrix degrades to camera-native.
    fileprivate static func dngReadSRational9(_ bytes: [UInt8], _ e: DNGEntry,
                                              _ order: DNGByteOrder) throws -> [Double] {
        if e.count != 9 || e.type != 10 { throw DNGError.missingTag }
        let base = Int(e.valueOff)
        if bytes.count < base + 72 { throw DNGError.shortRead }
        var out = [Double](repeating: 0, count: 9)
        var k = 0
        while k < 9 {
            let num = Int32(bitPattern: dngReadU32(bytes, base + k * 8, order))
            let den = Int32(bitPattern: dngReadU32(bytes, base + k * 8 + 4, order))
            out[k] = den == 0 ? 0 : Double(num) / Double(den)
            k += 1
        }
        return out
    }

    fileprivate static func dngReadArrayU32(_ bytes: [UInt8], _ e: DNGEntry,
                                            _ idx: Int, _ order: DNGByteOrder) throws -> UInt32 {
        let elemSize = e.typeSize()
        let base = Int(e.valueOff)
        let at = base + idx * elemSize
        switch e.type {
        case 3:
            if bytes.count < at + 2 { throw DNGError.shortRead }
            return UInt32(dngReadU16(bytes, at, order))
        case 4:
            if bytes.count < at + 4 { throw DNGError.shortRead }
            return dngReadU32(bytes, at, order)
        default:
            throw DNGError.missingTag
        }
    }

    fileprivate static func dngReadU16(_ bytes: [UInt8], _ offset: Int,
                                       _ order: DNGByteOrder) -> UInt16 {
        let lo = UInt16(bytes[offset])
        let hi = UInt16(bytes[offset + 1])
        switch order {
        case .little: return (hi << 8) | lo
        case .big:    return (lo << 8) | hi
        }
    }

    /// 8-byte IEEE double (TIFF type 12), byte-order aware.
    fileprivate static func dngReadF64(_ bytes: [UInt8], _ offset: Int,
                                       _ order: DNGByteOrder) -> Double {
        var bits: UInt64 = 0
        switch order {
        case .little:
            for k in stride(from: 7, through: 0, by: -1) {
                bits = (bits << 8) | UInt64(bytes[offset + k])
            }
        case .big:
            for k in 0..<8 {
                bits = (bits << 8) | UInt64(bytes[offset + k])
            }
        }
        return Double(bitPattern: bits)
    }

    fileprivate static func dngReadU32(_ bytes: [UInt8], _ offset: Int,
                                       _ order: DNGByteOrder) -> UInt32 {
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2])
        let b3 = UInt32(bytes[offset + 3])
        switch order {
        case .little: return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
        case .big:    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
    }

    /// Pixels are packed as 2 bytes per sample. The TIFF spec gives BPS=14 with
    /// values left-justified in 16-bit containers — or right-justified depending
    /// on writer. iPhone writes left-justified, but the downstream black/white
    /// levels we read from the DNG describe the actual values, so no shift here.
    fileprivate static func dngDecodeMosaicU16(_ src: [UInt8], srcOffset: Int,
                                               into dst: inout [UInt16], dstOffset: Int,
                                               count: Int, _ order: DNGByteOrder) {
        var i = 0
        while i < count {
            dst[dstOffset + i] = dngReadU16(src, srcOffset + i * 2, order)
            i += 1
        }
    }

    // ========================================================================
    // MARK: - Self-test (port of tests/dng_parse.zig synthetic-DNG builder)
    // ========================================================================

    /// Port of "parse synthetic 64x64 RGGB DNG": builds an in-memory
    /// big-endian uncompressed RGGB DNG, decodes it, and checks the same
    /// assertions as the Zig test. Returns true when all checks pass.
    static func dngSelfTest() -> Bool {
        let dngBytes = dngBuildSyntheticDNG(width: 64, height: 64, fillValue: 12345)
        let (mOpt, status) = decodeDNG(Data(dngBytes))
        guard status == 0, let m = mOpt else { return false }
        // Zig asserts: width/height 64, bits 16 (not exposed here), crop
        // (0,0,64,64) — crop == full frame, so post-crop dims stay 64x64.
        // (The Zig test deliberately does NOT assert `cfa`: the BE inline
        // bytes [0,1,1,2] match both the reversed-RGGB and forward-BGGR
        // accept rules, and last-match-wins yields BGGR in both ports.)
        guard m.width == 64, m.height == 64 else { return false }
        guard m.black == 0, m.white == 65535 else { return false }
        guard m.samples.count == 64 * 64 else { return false }
        guard m.samples[0] == 12345 else { return false }
        guard m.samples[m.samples.count - 1] == 12345 else { return false }
        return true
    }

    /// Build a synthetic uncompressed RGGB DNG in-memory. Big-endian to match
    /// what iPhone Bayer RAW captures look like. (tests/dng_parse.zig
    /// buildSyntheticDng, order fixed to .big as in the Zig test.)
    fileprivate static func dngBuildSyntheticDNG(width: Int, height: Int,
                                                 fillValue: UInt16) -> [UInt8] {
        let order = DNGByteOrder.big
        let pixelBytes = width * height * 2

        // Layout:
        //   [0..8)     TIFF header (MM, magic=42, IFD0 offset)
        //   [8..8+N)   IFD0: 13 entries * 12 bytes + 2 (count) + 4 (next-IFD)
        //   [8+N..)    Pixel data
        let ifdOffset = 8
        let nEntries = 13
        let ifdBytes = 2 + nEntries * 12 + 4
        let pixelOffset = ifdOffset + ifdBytes
        let totalSize = pixelOffset + pixelBytes

        var buf = [UInt8](repeating: 0, count: totalSize)

        // Header
        buf[0] = UInt8(ascii: "M")
        buf[1] = UInt8(ascii: "M")
        dngWriteU16(&buf, 2, 42, order)
        dngWriteU32(&buf, 4, UInt32(ifdOffset), order)

        // IFD0 entry count
        dngWriteU16(&buf, ifdOffset, UInt16(nEntries), order)

        var idx = ifdOffset + 2
        // ImageWidth (LONG)
        dngWriteIfdEntry(&buf, &idx, DNGTag.imageWidth, 4, 1, UInt32(width), order)
        // ImageLength (LONG)
        dngWriteIfdEntry(&buf, &idx, DNGTag.imageLength, 4, 1, UInt32(height), order)
        // BitsPerSample (SHORT)
        dngWriteIfdEntry(&buf, &idx, DNGTag.bitsPerSample, 3, 1, 16, order)
        // Compression (SHORT, = 1 uncompressed)
        dngWriteIfdEntry(&buf, &idx, DNGTag.compression, 3, 1, 1, order)
        // PhotometricInterpretation (SHORT, = 32803 CFA)
        dngWriteIfdEntry(&buf, &idx, DNGTag.photometricInterpretation, 3, 1, 32803, order)
        // StripOffsets (LONG)
        dngWriteIfdEntry(&buf, &idx, DNGTag.stripOffsets, 4, 1, UInt32(pixelOffset), order)
        // RowsPerStrip (LONG)
        dngWriteIfdEntry(&buf, &idx, DNGTag.rowsPerStrip, 4, 1, UInt32(height), order)
        // StripByteCounts (LONG)
        dngWriteIfdEntry(&buf, &idx, DNGTag.stripByteCounts, 4, 1, UInt32(pixelBytes), order)
        // CFAPattern (BYTE count=4, value = RGGB = [0,1,1,2]). BIG ENDIAN means
        // [0,1,1,2] appears as the high-to-low bytes of the u32.
        let cfaInline: UInt32 = (0 << 24) | (1 << 16) | (1 << 8) | 2
        dngWriteIfdEntry(&buf, &idx, DNGTag.cfaPattern, 1, 4, cfaInline, order)
        // BlackLevel (LONG = 0)
        dngWriteIfdEntry(&buf, &idx, DNGTag.blackLevel, 4, 1, 0, order)
        // WhiteLevel (LONG = 65535)
        dngWriteIfdEntry(&buf, &idx, DNGTag.whiteLevel, 4, 1, 65535, order)
        // DefaultCropOrigin (SHORT count=2 inline).
        dngWriteIfdEntry(&buf, &idx, DNGTag.defaultCropOrigin, 3, 2,
                         dngPackTwoShortsForOrder(0, 0, order), order)
        // DefaultCropSize (SHORT count=2 inline). Use (width, height).
        dngWriteIfdEntry(&buf, &idx, DNGTag.defaultCropSize, 3, 2,
                         dngPackTwoShortsForOrder(UInt16(width), UInt16(height), order), order)

        // Next-IFD offset (zero = no more IFDs) — buffer already zeroed.

        // Pixel data: fillValue for every sample, big-endian u16.
        var py = 0
        while py < height {
            var px = 0
            while px < width {
                let off = pixelOffset + (py * width + px) * 2
                dngWriteU16(&buf, off, fillValue, order)
                px += 1
            }
            py += 1
        }

        return buf
    }

    fileprivate static func dngWriteIfdEntry(_ buf: inout [UInt8], _ idx: inout Int,
                                             _ tag: UInt16, _ typ: UInt16,
                                             _ count: UInt32, _ value: UInt32,
                                             _ order: DNGByteOrder) {
        dngWriteU16(&buf, idx, tag, order)
        dngWriteU16(&buf, idx + 2, typ, order)
        dngWriteU32(&buf, idx + 4, count, order)

        // The 4-byte value field layout depends on the TIFF type:
        //   SHORT (3) count=1: one u16 in the FIRST 2 bytes (last 2 unused).
        //   SHORT (3) count=2: two u16 packed via dngPackTwoShortsForOrder.
        //   LONG  (4) count=1: one u32, spans all 4 bytes.
        //   BYTE  (1) count=4: four bytes in order; caller pre-packs.
        if typ == 3 && count == 1 {
            dngWriteU16(&buf, idx + 8, UInt16(value), order)
            // Trailing 2 bytes stay 0 (buffer zero-initialized).
        } else {
            dngWriteU32(&buf, idx + 8, value, order)
        }
        idx += 12
    }

    /// Pack two SHORTs into a u32 such that, when written through dngWriteU32
    /// with the given byte order, the parser decodes back the same two SHORTs
    /// in the correct positions.
    fileprivate static func dngPackTwoShortsForOrder(_ a: UInt16, _ b: UInt16,
                                                     _ order: DNGByteOrder) -> UInt32 {
        switch order {
        case .little: return (UInt32(b) << 16) | UInt32(a)
        case .big:    return (UInt32(a) << 16) | UInt32(b)
        }
    }

    fileprivate static func dngWriteU16(_ buf: inout [UInt8], _ off: Int,
                                        _ value: UInt16, _ order: DNGByteOrder) {
        switch order {
        case .little:
            buf[off]     = UInt8(value & 0xFF)
            buf[off + 1] = UInt8((value >> 8) & 0xFF)
        case .big:
            buf[off]     = UInt8((value >> 8) & 0xFF)
            buf[off + 1] = UInt8(value & 0xFF)
        }
    }

    fileprivate static func dngWriteU32(_ buf: inout [UInt8], _ off: Int,
                                        _ value: UInt32, _ order: DNGByteOrder) {
        switch order {
        case .little:
            buf[off]     = UInt8(value & 0xFF)
            buf[off + 1] = UInt8((value >> 8) & 0xFF)
            buf[off + 2] = UInt8((value >> 16) & 0xFF)
            buf[off + 3] = UInt8((value >> 24) & 0xFF)
        case .big:
            buf[off]     = UInt8((value >> 24) & 0xFF)
            buf[off + 1] = UInt8((value >> 16) & 0xFF)
            buf[off + 2] = UInt8((value >> 8) & 0xFF)
            buf[off + 3] = UInt8(value & 0xFF)
        }
    }
}
