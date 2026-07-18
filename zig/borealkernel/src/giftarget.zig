//! giftarget.zig — the ISP's target surface: GIF structure from the seed.
//! Hand-written, zero dependencies — BOREAL owns this algorithm end to end.
//! Ported from `spec/Boreal/GifTarget.hs`; gated bit-exact by
//! `fixtures/giftarget_golden.json` (tests/giftarget_fixtures.zig).
//!
//! PORT CONVENTIONS (normative — from the spec):
//!   · indexing   argmin over the sum of squared Q16 deltas (i64);
//!                STRICT-LESS update ⇒ ties resolve to the LOWEST index
//!   · inverse    OKLab → linear sRGB via Ottosson's inverse literals;
//!                cube = y·y·y pinned; dot left-to-right, no FMA; f64
//!   · display    sRGB u8 encode is NORMATIVE DATA — the generated
//!                srgb_table.zig (from the spec emitter); lookup index =
//!                floor(c·4095 + 0.5) clamped; NEVER call pow at runtime

const std = @import("std");
const srgb_table = @import("srgb_table.zig");

// ── Integer Q16 index maps ─────────────────────────────────────────────────

inline fn dist2(l0: i64, a0: i64, b0: i64, l1: i64, a1: i64, b1: i64) i64 {
    const dl = l0 - l1;
    const da = a0 - a1;
    const db = b0 - b1;
    return dl * dl + da * da + db * db;
}

/// Planar Q16 OKLab pixels vs a 256-entry planar Q16 palette → u8 indices.
pub fn indexMap(
    pxL: []const i32,
    pxA: []const i32,
    pxB: []const i32,
    palL: []const i32,
    palA: []const i32,
    palB: []const i32,
    out: []u8,
) void {
    for (out, 0..) |*o, i| {
        var best: usize = 0;
        var bestD: i64 = std.math.maxInt(i64);
        for (0..palL.len) |j| {
            const d = dist2(pxL[i], pxA[i], pxB[i], palL[j], palA[j], palB[j]);
            if (d < bestD) {
                bestD = d;
                best = j;
            }
        }
        o.* = @intCast(best);
    }
}

// ── OKLab → sRGB8 display path (inverse literals + normative table) ────────

const INV_AB = [6]f64{
    0.3963377774,  0.2158037573,
    -0.1055613458, -0.0638541728,
    -0.0894841775, -1.2914855480,
};

const LMS_TO_SRGB = [9]f64{
    4.0767416621,  -3.3077115913, 0.2309699292,
    -1.2684380046, 2.6097574011,  -0.3413193965,
    -0.0041960863, -0.7034186147, 1.7076147010,
};

inline fn encode8(c: f64) u8 {
    const idx: i64 = @intFromFloat(@floor(c * 4095.0 + 0.5));
    const clamped: usize = @intCast(std.math.clamp(idx, 0, 4095));
    return srgb_table.SRGB8_FROM_LINEAR_4096[clamped];
}

/// One Q16 OKLab triple → sRGB bytes.
pub fn srgb8FromOklabQ16(ql: i32, qa: i32, qb: i32) [3]u8 {
    const L = @as(f64, @floatFromInt(ql)) / 65536.0;
    const a = @as(f64, @floatFromInt(qa)) / 65536.0;
    const b = @as(f64, @floatFromInt(qb)) / 65536.0;
    const lp = L + INV_AB[0] * a + INV_AB[1] * b;
    const mp = L + INV_AB[2] * a + INV_AB[3] * b;
    const sp = L + INV_AB[4] * a + INV_AB[5] * b;
    const l = lp * lp * lp;
    const m = mp * mp * mp;
    const s = sp * sp * sp;
    var out: [3]u8 = undefined;
    inline for (0..3) |r| {
        const c = LMS_TO_SRGB[3 * r] * l + LMS_TO_SRGB[3 * r + 1] * m + LMS_TO_SRGB[3 * r + 2] * s;
        out[r] = encode8(c);
    }
    return out;
}

/// Planar Q16 OKLab → interleaved sRGB8 (n triples → 3n bytes).
pub fn srgb8Batch(pxL: []const i32, pxA: []const i32, pxB: []const i32, out: []u8) void {
    for (0..pxL.len) |i| {
        const rgb = srgb8FromOklabQ16(pxL[i], pxA[i], pxB[i]);
        out[3 * i] = rgb[0];
        out[3 * i + 1] = rgb[1];
        out[3 * i + 2] = rgb[2];
    }
}

// ── Tests (pure; cross-language fixtures in tests/giftarget_fixtures.zig) ──

const testing = std.testing;

test "ties resolve to the lowest index" {
    const palL = [4]i32{ 100, 100, 200, 300 };
    const palA = [4]i32{ 0, 0, 0, 0 };
    const palB = [4]i32{ 0, 0, 0, 0 };
    var out: [1]u8 = undefined;
    indexMap(&.{100}, &.{0}, &.{0}, &palL, &palA, &palB, &out);
    try testing.expectEqual(@as(u8, 0), out[0]);
}

test "table anchors through the display path" {
    // Q16 white (65536, 0, 0) must display as pure white.
    const rgb = srgb8FromOklabQ16(65536, 0, 0);
    try testing.expectEqual(@as(u8, 255), rgb[0]);
    try testing.expectEqual(@as(u8, 255), rgb[1]);
    try testing.expectEqual(@as(u8, 255), rgb[2]);
    const black = srgb8FromOklabQ16(0, 0, 0);
    try testing.expectEqual(@as(u8, 0), black[0]);
}
