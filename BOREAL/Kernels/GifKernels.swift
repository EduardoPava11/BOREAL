import Foundation

/// GIF target (spec/Boreal/GifTarget.hs, G laws) + GIF89a wire
/// (spec/Boreal/GifWire.hs, W laws). Pure Swift ports (Phase 5 M1),
/// verified byte-exact against the golden fixtures.
extension BorealKernels {

    // ── Index maps: i64 Q16 argmin, ties → LOWEST index ────────────────────

    static func indexMap(L: [Int32], a: [Int32], b: [Int32],
                         palL: [Int32], palA: [Int32], palB: [Int32]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: L.count)
        for i in 0..<L.count {
            let pl = Int64(L[i]), pa = Int64(a[i]), pb = Int64(b[i])
            var best = 0
            var bestD = Int64.max
            for j in 0..<palL.count {
                let dl = pl - Int64(palL[j])
                let da = pa - Int64(palA[j])
                let db = pb - Int64(palB[j])
                let d = dl * dl + da * da + db * db
                if d < bestD {
                    bestD = d
                    best = j
                }
            }
            out[i] = UInt8(best)
        }
        return out
    }

    // ── Display path: Ottosson inverse + the generated normative table ─────

    static let oklabInvAB: [Double] = [
        0.3963377774, 0.2158037573,
        -0.1055613458, -0.0638541728,
        -0.0894841775, -1.2914855480,
    ]
    static let lmsToSrgb: [Double] = [
        4.0767416621, -3.3077115913, 0.2309699292,
        -1.2684380046, 2.6097574011, -0.3413193965,
        -0.0041960863, -0.7034186147, 1.7076147010,
    ]

    @inline(__always)
    static func encode8(_ c: Double) -> UInt8 {
        let idx = Int(floor(c * 4095 + 0.5))
        return srgb8FromLinear4096[min(4095, max(0, idx))]
    }

    static func srgb8(fromOklabQ16 ql: Int32, _ qa: Int32, _ qb: Int32)
        -> (UInt8, UInt8, UInt8) {
        let L = Double(ql) / 65536, a = Double(qa) / 65536, b = Double(qb) / 65536
        let lp = L + oklabInvAB[0] * a + oklabInvAB[1] * b
        let mp = L + oklabInvAB[2] * a + oklabInvAB[3] * b
        let sp = L + oklabInvAB[4] * a + oklabInvAB[5] * b
        let l = lp * lp * lp, m = mp * mp * mp, s = sp * sp * sp
        let r = lmsToSrgb[0] * l + lmsToSrgb[1] * m + lmsToSrgb[2] * s
        let g = lmsToSrgb[3] * l + lmsToSrgb[4] * m + lmsToSrgb[5] * s
        let bb = lmsToSrgb[6] * l + lmsToSrgb[7] * m + lmsToSrgb[8] * s
        return (encode8(r), encode8(g), encode8(bb))
    }

    static func oklabQ16ToSRGB8(L: [Int32], a: [Int32], b: [Int32]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 3 * L.count)
        for i in 0..<L.count {
            let rgb = srgb8(fromOklabQ16: L[i], a[i], b[i])
            out[3 * i] = rgb.0
            out[3 * i + 1] = rgb.1
            out[3 * i + 2] = rgb.2
        }
        return out
    }

    // ── GIF89a wire: fixed 9-bit LZW, closed-form length ───────────────────

    static func gifFrameDataLen(_ n: Int) -> Int {
        let chunks = n == 0 ? 1 : (n + 253) / 254
        let codes = 1 + n + (chunks - 1) + 1
        let dataB = (9 * codes + 7) / 8
        return 1 + dataB + (dataB + 254) / 255 + 1
    }

    static func gifEncodedLen(side: Int, frames: Int) -> Int {
        6 + 7 + 768 + 19 + frames * (8 + 10 + gifFrameDataLen(side * side)) + 1
    }

    static func gifEncode(frames: [[UInt8]], side: Int, gct: [UInt8],
                          delayCs: Int) -> Data? {
        guard !frames.isEmpty, gct.count >= 768,
              frames.allSatisfy({ $0.count == side * side }) else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(gifEncodedLen(side: side, frames: frames.count))

        func u16(_ v: Int) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }

        out.append(contentsOf: Array("GIF89a".utf8))
        u16(side); u16(side)
        out.append(contentsOf: [0xF7, 0x00, 0x00])
        out.append(contentsOf: gct[0..<768])
        out.append(contentsOf: [0x21, 0xFF, 0x0B])
        out.append(contentsOf: Array("NETSCAPE2.0".utf8))
        out.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])

        for frame in frames {
            out.append(contentsOf: [0x21, 0xF9, 0x04, 0x00])
            u16(delayCs)
            out.append(contentsOf: [0x00, 0x00])
            out.append(0x2C)
            u16(0); u16(0); u16(side); u16(side)
            out.append(0x00)
            writeFrameData(frame, into: &out)
        }
        out.append(0x3B)
        guard out.count == gifEncodedLen(side: side, frames: frames.count) else { return nil }
        return Data(out)
    }

    /// Streaming 9-bit LSB-first packer into ≤255-byte sub-blocks with a
    /// back-patched length byte (mirrors gifwire.zig's BlockPacker).
    private static func writeFrameData(_ indices: [UInt8], into out: inout [UInt8]) {
        out.append(8)                     // minCodeSize
        var acc: UInt32 = 0
        var nbits = 0
        var lenAt = out.count
        out.append(0)                     // patched later
        var fill = 0

        func putByte(_ b: UInt8) {
            if fill == 255 {
                out[lenAt] = 255
                lenAt = out.count
                out.append(0)
                fill = 0
            }
            out.append(b)
            fill += 1
        }
        func code(_ c: UInt32) {
            acc |= c << UInt32(nbits)
            nbits += 9
            while nbits >= 8 {
                putByte(UInt8(acc & 0xFF))
                acc >>= 8
                nbits -= 8
            }
        }

        code(256)                         // CLEAR
        var emitted = 0
        for ix in indices {
            if emitted == 254 { code(256); emitted = 0 }
            code(UInt32(ix))
            emitted += 1
        }
        code(257)                         // EOI
        if nbits > 0 { putByte(UInt8(acc & 0xFF)) }
        out[lenAt] = UInt8(fill)
        out.append(0)                     // sub-block terminator
    }
}
