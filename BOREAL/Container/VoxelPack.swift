import Foundation

/// .bvox v2 — columnar per-bin LAB tensor file.
///
/// One file per set: `<AppSupport>/BorealSession/set-NN/lab.bvox`.
///
/// Layout:
/// ```
/// Header (96 B):
///   magic="BVOX" (4), version=2 (u16), setIdx (u16), codeBudget (u16),
///   framesPerSet=4 (u16), spatialDim=64 (u16), binCount=4096 (u32),
///   channelSpace=0 LAB (u8), flags (u8), numColumns=10 (u8), reserved (u8),
///   pyramidHash (u64), colOffsets [u32; 10]
///
/// Body (10 columns, contiguous):
///   colL_min       [f32; 4096] = 16,384 B
///   colL_max       [f32; 4096] = 16,384 B
///   colL_mean      [f32; 4096] = 16,384 B
///   cola_min       [f32; 4096] = 16,384 B
///   cola_max       [f32; 4096] = 16,384 B
///   cola_mean      [f32; 4096] = 16,384 B
///   colb_min       [f32; 4096] = 16,384 B
///   colb_max       [f32; 4096] = 16,384 B
///   colb_mean      [f32; 4096] = 16,384 B
///   colCodesFlags  [u32; 4096] = 16,384 B
///   Body total = 163,840 B
///
/// Trailer (~64 B):
///   duration_ms, decode_ms, bin_ms, encode_ms, write_ms (5 × f32 = 20 B),
///   kl_divergence [f32; 3] (12 B), codebook_utilization (f32 = 4 B),
///   reserved (4 B), checksum (u64 = 8 B). Padded to 64 B.
///
/// Per file: 96 + 163,840 + 64 = 164,000 B ≈ 160 KB.
/// Per session (16 sets): ~2.56 MB.
/// ```
///
/// Endianness: little-endian throughout (matches arm64 native; we never
/// ship .bvox to non-arm64 systems for now).
enum VoxelPack {

    static let magic: [UInt8]  = [0x42, 0x56, 0x4F, 0x58]   // "BVOX"
    static let version: UInt16 = 2
    static let headerSize: Int = 96
    static let trailerSize: Int = 64
    static let columnElements: Int = 64 * 64                // 4096
    static let f32ColumnBytes: Int = columnElements * MemoryLayout<Float>.size      // 16,384
    static let u32ColumnBytes: Int = columnElements * MemoryLayout<UInt32>.size     // 16,384
    static let bodyBytes: Int = 9 * f32ColumnBytes + u32ColumnBytes                 // 163,840
    static let totalBytes: Int = headerSize + bodyBytes + trailerSize               // 164,000

    /// Per-set certificate written into the trailer.
    struct Certificate: Equatable {
        var duration_ms:        Float = 0
        var decode_ms:          Float = 0
        var bin_ms:             Float = 0
        var encode_ms:          Float = 0
        var write_ms:           Float = 0
        var kl_divergence:      [Float] = [0, 0, 0]
        var codebook_utilization: Float = 0
    }

    /// The header parsed back from disk, plus the column data and certificate.
    struct Decoded: Equatable {
        var setIdx: UInt16
        var codeBudget: UInt16
        var pyramidHash: UInt64
        var columns: BinomialEncoder.Columns
        var certificate: Certificate
    }

    enum PackError: Error, CustomStringConvertible {
        case shortFile(expected: Int, got: Int)
        case badMagic([UInt8])
        case unsupportedVersion(UInt16)
        case checksumMismatch(expected: UInt64, got: UInt64)

        var description: String {
            switch self {
            case .shortFile(let exp, let got):
                return "expected ≥\(exp) bytes, got \(got)"
            case .badMagic(let m):
                let hex = m.map { String(format: "%02X", $0) }.joined(separator: " ")
                return "bad magic \(hex), expected 42 56 4F 58 (BVOX)"
            case .unsupportedVersion(let v):
                return "unsupported .bvox version \(v); only v2 supported"
            case .checksumMismatch(let exp, let got):
                return "checksum mismatch: header says \(String(exp, radix: 16)), computed \(String(got, radix: 16))"
            }
        }
    }

    // MARK: - Write

    /// Encode a set's columnar data to a `.bvox` Data buffer.
    static func encode(setIdx: UInt16,
                       codeBudget: UInt16,
                       pyramidHash: UInt64,
                       columns: BinomialEncoder.Columns,
                       certificate: Certificate = .init()) -> Data {
        precondition(columns.L_min.count == columnElements)
        precondition(columns.codesFlags.count == columnElements)

        var data = Data(capacity: totalBytes)

        // ── Header (96 B) ──
        data.append(contentsOf: magic)                                  // 4
        appendLE16(&data, version)                                      // 2
        appendLE16(&data, setIdx)                                       // 2
        appendLE16(&data, codeBudget)                                   // 2
        appendLE16(&data, 4)              // framesPerSet                  2
        appendLE16(&data, 64)             // spatialDim                    2
        appendLE32(&data, UInt32(columnElements))                       // 4
        data.append(0)                    // channelSpace = 0 (LAB)        1
        data.append(0)                    // flags                         1
        data.append(10)                   // numColumns                    1
        data.append(0)                    // reserved                      1
        appendLE64(&data, pyramidHash)                                  // 8
        // 10 column offsets, computed from headerSize.
        var off = UInt32(headerSize)
        for _ in 0..<9 {
            appendLE32(&data, off)
            off += UInt32(f32ColumnBytes)
        }
        appendLE32(&data, off)            // 10th column = codesFlags
        // Header is now 4+2+2+2+2+2+4+1+1+1+1+8+(10*4) = 70 B; pad to 96.
        while data.count < headerSize { data.append(0) }

        // ── Body (163,840 B) ──
        appendF32Array(&data, columns.L_min)
        appendF32Array(&data, columns.L_max)
        appendF32Array(&data, columns.L_mean)
        appendF32Array(&data, columns.a_min)
        appendF32Array(&data, columns.a_max)
        appendF32Array(&data, columns.a_mean)
        appendF32Array(&data, columns.b_min)
        appendF32Array(&data, columns.b_max)
        appendF32Array(&data, columns.b_mean)
        appendU32Array(&data, columns.codesFlags)

        // ── Trailer (64 B) ──
        let trailerStart = data.count
        appendF32(&data, certificate.duration_ms)
        appendF32(&data, certificate.decode_ms)
        appendF32(&data, certificate.bin_ms)
        appendF32(&data, certificate.encode_ms)
        appendF32(&data, certificate.write_ms)
        appendF32(&data, certificate.kl_divergence[0])
        appendF32(&data, certificate.kl_divergence[1])
        appendF32(&data, certificate.kl_divergence[2])
        appendF32(&data, certificate.codebook_utilization)
        appendLE32(&data, 0)              // reserved
        // Compute CRC64 over body only (header + body, excluding trailer).
        let checksum = crc64(data[0..<trailerStart])
        appendLE64(&data, checksum)
        // Pad trailer to 64 B.
        while data.count < trailerStart + trailerSize { data.append(0) }

        return data
    }

    /// Convenience: write directly to a URL.
    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Read

    static func decode(_ data: Data) throws -> Decoded {
        guard data.count >= totalBytes else {
            throw PackError.shortFile(expected: totalBytes, got: data.count)
        }

        // ── Header ──
        let m = Array(data[0..<4])
        guard m == magic else { throw PackError.badMagic(m) }
        let version = readLE16(data, 4)
        guard version == Self.version else { throw PackError.unsupportedVersion(version) }
        let setIdx     = readLE16(data, 6)
        let codeBudget = readLE16(data, 8)
        // framesPerSet (10), spatialDim (12), binCount (14) — sanity-checked but unused.
        // channelSpace (18), flags (19), numColumns (20), reserved (21).
        let pyramidHash = readLE64(data, 22)
        // colOffsets [u32; 10] start at byte 30.

        // ── Body ──
        var cols = BinomialEncoder.Columns()
        var off = headerSize
        cols.L_min      = readF32Array(data, off, count: columnElements); off += f32ColumnBytes
        cols.L_max      = readF32Array(data, off, count: columnElements); off += f32ColumnBytes
        cols.L_mean     = readF32Array(data, off, count: columnElements); off += f32ColumnBytes
        cols.a_min      = readF32Array(data, off, count: columnElements); off += f32ColumnBytes
        cols.a_max      = readF32Array(data, off, count: columnElements); off += f32ColumnBytes
        cols.a_mean     = readF32Array(data, off, count: columnElements); off += f32ColumnBytes
        cols.b_min      = readF32Array(data, off, count: columnElements); off += f32ColumnBytes
        cols.b_max      = readF32Array(data, off, count: columnElements); off += f32ColumnBytes
        cols.b_mean     = readF32Array(data, off, count: columnElements); off += f32ColumnBytes
        cols.codesFlags = readU32Array(data, off, count: columnElements); off += u32ColumnBytes

        // ── Trailer ──
        let trailerStart = off
        var cert = Certificate()
        cert.duration_ms = readF32(data, trailerStart + 0)
        cert.decode_ms   = readF32(data, trailerStart + 4)
        cert.bin_ms      = readF32(data, trailerStart + 8)
        cert.encode_ms   = readF32(data, trailerStart + 12)
        cert.write_ms    = readF32(data, trailerStart + 16)
        cert.kl_divergence = [
            readF32(data, trailerStart + 20),
            readF32(data, trailerStart + 24),
            readF32(data, trailerStart + 28),
        ]
        cert.codebook_utilization = readF32(data, trailerStart + 32)
        // reserved at +36..+40
        let storedChecksum = readLE64(data, trailerStart + 40)
        let computed = crc64(data[0..<trailerStart])
        guard storedChecksum == computed else {
            throw PackError.checksumMismatch(expected: storedChecksum, got: computed)
        }

        return Decoded(
            setIdx: setIdx, codeBudget: codeBudget,
            pyramidHash: pyramidHash, columns: cols, certificate: cert
        )
    }

    static func read(from url: URL) throws -> Decoded {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    // MARK: - Byte primitives

    private static func appendLE16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
    }
    private static func appendLE32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 24) & 0xFF))
    }
    private static func appendLE64(_ d: inout Data, _ v: UInt64) {
        for i in 0..<8 { d.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) }
    }
    private static func appendF32(_ d: inout Data, _ v: Float) {
        var bits = v.bitPattern
        withUnsafeBytes(of: &bits) { d.append(contentsOf: $0) }
    }
    private static func appendF32Array(_ d: inout Data, _ a: [Float]) {
        a.withUnsafeBufferPointer { buf in
            d.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
    }
    private static func appendU32Array(_ d: inout Data, _ a: [UInt32]) {
        a.withUnsafeBufferPointer { buf in
            d.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
    }

    private static func readLE16(_ d: Data, _ off: Int) -> UInt16 {
        UInt16(d[off]) | (UInt16(d[off + 1]) << 8)
    }
    private static func readLE32(_ d: Data, _ off: Int) -> UInt32 {
        UInt32(d[off])
            | (UInt32(d[off + 1]) << 8)
            | (UInt32(d[off + 2]) << 16)
            | (UInt32(d[off + 3]) << 24)
    }
    private static func readLE64(_ d: Data, _ off: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[off + i]) << (8 * UInt64(i)) }
        return v
    }
    private static func readF32(_ d: Data, _ off: Int) -> Float {
        Float(bitPattern: readLE32(d, off))
    }
    private static func readF32Array(_ d: Data, _ off: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBytes { dst in
            d.withUnsafeBytes { src in
                let from = src.baseAddress!.advanced(by: off)
                dst.baseAddress!.copyMemory(from: from, byteCount: count * 4)
            }
        }
        return out
    }
    private static func readU32Array(_ d: Data, _ off: Int, count: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: count)
        out.withUnsafeMutableBytes { dst in
            d.withUnsafeBytes { src in
                let from = src.baseAddress!.advanced(by: off)
                dst.baseAddress!.copyMemory(from: from, byteCount: count * 4)
            }
        }
        return out
    }

    // MARK: - CRC64 (ISO 3309 polynomial, used for checksum integrity)

    /// Computed once at first use — Swift static lazy init.
    private static let crc64Table: [UInt64] = {
        var table = [UInt64](repeating: 0, count: 256)
        let poly: UInt64 = 0xC96C5795D7870F42   // ISO 3309 reflected
        for i in 0..<256 {
            var crc = UInt64(i)
            for _ in 0..<8 {
                if crc & 1 != 0 { crc = (crc >> 1) ^ poly } else { crc >>= 1 }
            }
            table[i] = crc
        }
        return table
    }()

    private static func crc64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var crc: UInt64 = ~UInt64(0)
        for b in bytes {
            let idx = Int((crc ^ UInt64(b)) & 0xFF)
            crc = (crc >> 8) ^ crc64Table[idx]
        }
        return ~crc
    }
}
