//! oklab.zig — DNG → LAB, the last link: linear ProPhoto RGB → OKLab → Q16.
//! Hand-written, zero dependencies — BOREAL owns this algorithm end to end.
//! Ported from the Haskell contract `spec/Boreal/ColorPath.hs`; gated
//! BIT-EXACT by `fixtures/colorpath_golden.json` (tests/oklab_fixtures.zig).
//!
//! PORT CONVENTIONS (normative — from the spec):
//!   · owned cbrt   x = f·2^e, f ∈ [1,2) via IEEE bits; y0 = 0.75 + f/4;
//!                  y ← (2y + f/(y·y))/3 exactly 4 Newton iterations;
//!                  result = scalb(y · CORR[e mod 3], e div 3);
//!                  CORR = {1, 2^(1/3), 2^(2/3)} f64 literals;
//!                  0 → 0, negative → odd symmetry.  NEVER libm cbrt —
//!                  libm differs across languages by ulps and would break
//!                  quantization ties.
//!   · matrices     row-major 3×3; apply = m0·v0 + m1·v1 + m2·v2 evaluated
//!                  left-to-right, NO FMA; f64 end to end (f32 pipeline
//!                  samples widen exactly).
//!   · compose      PROPHOTO_TO_LMS = M1_XYZ · (BRADFORD · PROPHOTO_TO_XYZ),
//!                  innermost first, same dot order (done at comptime on
//!                  TYPED f64 — comptime_float would change the rounding).
//!   · quantize     Q16: q(x) = floor(x·65536 + 0.5) as i32.

const std = @import("std");

// ── Owned deterministic cbrt ───────────────────────────────────────────────

const CBRT2: f64 = 1.2599210498948731647672106072782; // 2^(1/3)
const CBRT4: f64 = 1.5874010519681994747517056392723; // 2^(2/3)

pub fn ownedCbrt(x: f64) f64 {
    if (x == 0) return 0;
    if (x < 0) return -ownedCbrt(-x);
    const bits: u64 = @bitCast(x);
    const e: i64 = @as(i64, @intCast((bits >> 52) & 0x7FF)) - 1023;
    const f: f64 = @bitCast((bits & 0x000FFFFFFFFFFFFF) | 0x3FF0000000000000);
    var y: f64 = 0.75 + f / 4.0;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        y = (2.0 * y + f / (y * y)) / 3.0;
    }
    const corr = [3]f64{ 1.0, CBRT2, CBRT4 };
    const r: usize = @intCast(@mod(e, 3));
    return std.math.scalbn(y * corr[r], @as(i32, @intCast(@divFloor(e, 3))));
}

// ── Matrices (row-major [9]f64; typed f64 comptime composition) ───────────

pub const PROPHOTO_TO_XYZ_D50 = [9]f64{
    0.7976749, 0.1351917, 0.0313534,
    0.2880402, 0.7118741, 0.0000857,
    0.0,       0.0,       0.8252100,
};

pub const BRADFORD_D50_D65 = [9]f64{
    0.9555766,  -0.0230393, 0.0631636,
    -0.0282895, 1.0099416,  0.0210077,
    0.0122982,  -0.0204830, 1.3299098,
};

pub const XYZ_D65_TO_LMS = [9]f64{
    0.8189330101, 0.3618667424, -0.1288597137,
    0.0329845436, 0.9293118715, 0.0361456387,
    0.0482003018, 0.2643662691, 0.6338517070,
};

pub const LMS_TO_LAB = [9]f64{
    0.2104542553, 0.7936177850,  -0.0040720468,
    1.9779984951, -2.4285922050, 0.4505937099,
    0.0259040371, 0.7827717662,  -0.8086757660,
};

fn mul3(a: [9]f64, b: [9]f64) [9]f64 {
    var c: [9]f64 = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            c[3 * i + j] = a[3 * i] * b[j] + a[3 * i + 1] * b[3 + j] + a[3 * i + 2] * b[6 + j];
        }
    }
    return c;
}

/// The ONE baked matrix: linear ProPhoto (D50) → LMS (D65-adapted).
pub const PROPHOTO_TO_LMS: [9]f64 = mul3(XYZ_D65_TO_LMS, mul3(BRADFORD_D50_D65, PROPHOTO_TO_XYZ_D50));

inline fn apply3(m: [9]f64, v0: f64, v1: f64, v2: f64) [3]f64 {
    return .{
        m[0] * v0 + m[1] * v1 + m[2] * v2,
        m[3] * v0 + m[4] * v1 + m[5] * v2,
        m[6] * v0 + m[7] * v1 + m[8] * v2,
    };
}

// ── OKLab + Q16 ────────────────────────────────────────────────────────────

pub fn oklabFromProPhoto(r: f64, g: f64, b: f64) [3]f64 {
    const lms = apply3(PROPHOTO_TO_LMS, r, g, b);
    return apply3(LMS_TO_LAB, ownedCbrt(lms[0]), ownedCbrt(lms[1]), ownedCbrt(lms[2]));
}

pub const Q_ONE: i32 = 65536;

pub fn q16(x: f64) i32 {
    return @intFromFloat(@floor(x * 65536.0 + 0.5));
}

/// Per-pixel kernel: interleaved linear-ProPhoto f32 RGB (the pipeline's
/// native output after bk_apply_color_matrix) → interleaved Q16 OKLab i32
/// (the pyramid's exact domain). f32 widens to f64 exactly; all math f64.
pub fn quantizeProPhotoToOklab(rgb: []const f32, out: []i32) void {
    var i: usize = 0;
    while (3 * i + 2 < rgb.len) : (i += 1) {
        const lab = oklabFromProPhoto(
            @floatCast(rgb[3 * i]),
            @floatCast(rgb[3 * i + 1]),
            @floatCast(rgb[3 * i + 2]),
        );
        out[3 * i] = q16(lab[0]);
        out[3 * i + 1] = q16(lab[1]);
        out[3 * i + 2] = q16(lab[2]);
    }
}

// ── Tests (pure; cross-language fixtures in tests/oklab_fixtures.zig) ──────

const testing = std.testing;

test "owned cbrt: anchors, odd symmetry, cube inverse" {
    try testing.expectEqual(@as(f64, 0), ownedCbrt(0));
    try testing.expectApproxEqAbs(@as(f64, 2), ownedCbrt(8), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), ownedCbrt(0.125), 1e-12);
    try testing.expectEqual(ownedCbrt(-8), -ownedCbrt(8));
    var y: f64 = 0.5;
    while (y < 10) : (y += 0.7) {
        try testing.expectApproxEqAbs(y, ownedCbrt(y * y * y), 1e-12 * y);
    }
}

test "ProPhoto white lands at OKLab (1,0,0) within matrix precision" {
    const lab = oklabFromProPhoto(1, 1, 1);
    try testing.expectApproxEqAbs(@as(f64, 1), lab[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0), lab[1], 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 0), lab[2], 1e-3);
}

test "q16: anchors and monotone rounding" {
    try testing.expectEqual(@as(i32, 0), q16(0));
    try testing.expectEqual(Q_ONE, q16(1));
    try testing.expectEqual(-Q_ONE, q16(-1));
    try testing.expectEqual(@as(i32, 1), q16(1.0 / 65536.0));
    try testing.expect(q16(0.3) <= q16(0.30001));
}
