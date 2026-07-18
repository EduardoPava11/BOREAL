import Foundation

/// BorealKernels — the pure-Swift kernel core (Phase 5 migration, M1).
/// Ported from the Haskell contracts (spec/Boreal/*.hs); verified against
/// the SAME golden fixtures as every other port (make -C spec gate runs the
/// Swift parity harness). Swift + Metal is the app's kernel language —
/// Daniel's decree, 2026-07-17.
enum BorealKernels {

    // ── Owned deterministic cbrt (ColorPath conventions) ───────────────────
    //
    // NEVER libm cbrt: x = f·2^e with f ∈ [1,2) via IEEE bits; y₀ = 0.75 +
    // f/4; exactly 4 Newton steps y = (2y + f/(y·y))/3; result =
    // scalb(y·CORR[e mod 3], e div 3). Identical IEEE f64 ops in Haskell /
    // Python / Zig / Swift — bit-exact everywhere.

    static let cbrt2 = 1.2599210498948731647672106072782
    static let cbrt4 = 1.5874010519681994747517056392723

    static func ownedCbrt(_ x: Double) -> Double {
        if x == 0 { return 0 }
        if x < 0 { return -ownedCbrt(-x) }
        let bits = x.bitPattern
        let e = Int((bits >> 52) & 0x7FF) - 1023
        let f = Double(bitPattern: (bits & 0x000F_FFFF_FFFF_FFFF) | 0x3FF0_0000_0000_0000)
        var y = 0.75 + f / 4
        for _ in 0..<4 { y = (2 * y + f / (y * y)) / 3 }
        let r = ((e % 3) + 3) % 3                 // floor mod
        let corr = r == 0 ? 1.0 : (r == 1 ? cbrt2 : cbrt4)
        return scalbn(y * corr, (e - r) / 3)      // floor div; scalb is exact
    }

    // ── Matrices (row-major [9]; apply = m0·v0 + m1·v1 + m2·v2, no FMA) ────

    static let prophotoToXyzD50: [Double] = [
        0.7976749, 0.1351917, 0.0313534,
        0.2880402, 0.7118741, 0.0000857,
        0.0,       0.0,       0.8252100,
    ]
    static let bradfordD50toD65: [Double] = [
        0.9555766, -0.0230393, 0.0631636,
        -0.0282895, 1.0099416, 0.0210077,
        0.0122982, -0.0204830, 1.3299098,
    ]
    static let xyzD65toLms: [Double] = [
        0.8189330101, 0.3618667424, -0.1288597137,
        0.0329845436, 0.9293118715, 0.0361456387,
        0.0482003018, 0.2643662691, 0.6338517070,
    ]
    static let lmsToLab: [Double] = [
        0.2104542553, 0.7936177850, -0.0040720468,
        1.9779984951, -2.4285922050, 0.4505937099,
        0.0259040371, 0.7827717662, -0.8086757660,
    ]

    static func mul3(_ a: [Double], _ b: [Double]) -> [Double] {
        var c = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                c[3 * i + j] = a[3 * i] * b[j] + a[3 * i + 1] * b[3 + j]
                    + a[3 * i + 2] * b[6 + j]
            }
        }
        return c
    }

    /// The ONE baked matrix: linear ProPhoto (D50) → LMS (D65-adapted).
    /// Composed at first use with the pinned order — same f64 ops as the
    /// Haskell composition, fixture-proven equal.
    static let prophotoToLms: [Double] =
        mul3(xyzD65toLms, mul3(bradfordD50toD65, prophotoToXyzD50))

    @inline(__always)
    static func apply3(_ m: [Double], _ v0: Double, _ v1: Double, _ v2: Double)
        -> (Double, Double, Double) {
        (m[0] * v0 + m[1] * v1 + m[2] * v2,
         m[3] * v0 + m[4] * v1 + m[5] * v2,
         m[6] * v0 + m[7] * v1 + m[8] * v2)
    }

    // ── OKLab + Q16 ────────────────────────────────────────────────────────

    static func oklabFromProPhoto(_ r: Double, _ g: Double, _ b: Double)
        -> (Double, Double, Double) {
        let lms = apply3(prophotoToLms, r, g, b)
        return apply3(lmsToLab, ownedCbrt(lms.0), ownedCbrt(lms.1), ownedCbrt(lms.2))
    }

    @inline(__always)
    static func q16(_ x: Double) -> Int32 {
        Int32(floor(x * 65536 + 0.5))
    }
}
