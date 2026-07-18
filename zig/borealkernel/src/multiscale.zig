//! multiscale.zig — the custom ISP: demosaic at EVERY scale (Phase 3).
//! Hand-written, zero dependencies — BOREAL owns this algorithm end to end.
//! Ported from `spec/Boreal/MultiScale.hs`; gated bit-exact by
//! `fixtures/multiscale_golden.json` (tests/multiscale_fixtures.zig).
//!
//! Each rung r ∈ {16,32,64,128,256} (side%r == 0, k = side/r even, ≥ 2) is
//! its OWN demosaic of the normalized mosaic: per-CFA-channel mean over the
//! rung's k×k cells (RGGB: even,even = R; odd,odd = B; else G — swapped for
//! BGGR), then camera→ProPhoto matrix, then OKLab Q16 (colorpath path, owned
//! cbrt). The latent record is the RESIDUAL STACK per channel:
//!
//!   [ rung16 | rung32 − up(rung16) | … | rung256 − up(rung128) ]
//!
//! up = exact 2×2 nearest replication (value at (y,x) = prev[y/2][x/2]).
//! Prefix through rung r = Σ r'² for r' ≤ r; decode(prefix r) == THE rung-r
//! demosaic (law MS3). PORT CONVENTION: cell means use ONE f64 accumulator
//! per channel, samples added row-major (y outer, x inner) within the cell.

const std = @import("std");
const oklab = @import("oklab.zig");

pub const ALL_RUNGS = [5]u32{ 16, 32, 64, 128, 256 };

/// The rungs available for a mosaic side, coarse → fine.
pub fn rungsFor(side: u32, buf: *[5]u32) []const u32 {
    var n: usize = 0;
    for (ALL_RUNGS) |r| {
        if (side % r == 0) {
            const k = side / r;
            if (k >= 2 and k % 2 == 0) {
                buf[n] = r;
                n += 1;
            }
        }
    }
    return buf[0..n];
}

pub fn stackLen(side: u32) usize {
    var buf: [5]u32 = undefined;
    var total: usize = 0;
    for (rungsFor(side, &buf)) |r| total += @as(usize, r) * r;
    return total;
}

/// Offset of rung r's level within the stack (Σ of coarser rungs' squares).
pub fn levelOffset(side: u32, rung: u32) usize {
    var buf: [5]u32 = undefined;
    var off: usize = 0;
    for (rungsFor(side, &buf)) |r| {
        if (r == rung) return off;
        off += @as(usize, r) * r;
    }
    return off;
}

/// One rung's demosaic, straight from the mosaic: Q16 OKLab planes.
pub fn computeRung(
    mosaic: []const f32,
    side: u32,
    cfa: u32,
    m: [9]f64, // camera → ProPhoto (identity when the DNG had no color)
    rung: u32,
    outL: []i32,
    outA: []i32,
    outB: []i32,
) void {
    const s: usize = side;
    const r: usize = rung;
    const k = s / r;
    const is_rggb = cfa == 0;
    var cy: usize = 0;
    while (cy < r) : (cy += 1) {
        var cx: usize = 0;
        while (cx < r) : (cx += 1) {
            var sr: f64 = 0;
            var sg: f64 = 0;
            var sb: f64 = 0;
            var y = cy * k;
            while (y < (cy + 1) * k) : (y += 1) {
                const py = y & 1;
                var x = cx * k;
                while (x < (cx + 1) * k) : (x += 1) {
                    const v: f64 = mosaic[y * s + x];
                    const px = x & 1;
                    if (py == 0 and px == 0) {
                        if (is_rggb) sr += v else sb += v;
                    } else if (py == 1 and px == 1) {
                        if (is_rggb) sb += v else sr += v;
                    } else {
                        sg += v;
                    }
                }
            }
            const quarter: f64 = @floatFromInt((k / 2) * (k / 2));
            const rr = sr / quarter;
            const gg = sg / (2.0 * quarter);
            const bb = sb / quarter;
            const pr = m[0] * rr + m[1] * gg + m[2] * bb;
            const pg = m[3] * rr + m[4] * gg + m[5] * bb;
            const pb = m[6] * rr + m[7] * gg + m[8] * bb;
            const lab = oklab.oklabFromProPhoto(pr, pg, pb);
            const idx = cy * r + cx;
            outL[idx] = oklab.q16(lab[0]);
            outA[idx] = oklab.q16(lab[1]);
            outB[idx] = oklab.q16(lab[2]);
        }
    }
}

/// Residualize level `cur` (side 2·rp) in place against absolute `prev`.
fn residualize(prev: []const i32, cur: []i32, rp: usize) void {
    const r = 2 * rp;
    var y: usize = 0;
    while (y < r) : (y += 1) {
        const py = y / 2;
        var x: usize = 0;
        while (x < r) : (x += 1) {
            cur[y * r + x] -= prev[py * rp + x / 2];
        }
    }
}

/// Encode the full residual stack (per channel) from a normalized mosaic.
/// No scratch: pass 1 writes ABSOLUTE rungs at their offsets; pass 2
/// residualizes fine → coarse (the coarser level is still absolute).
pub fn encode(
    mosaic: []const f32,
    side: u32,
    cfa: u32,
    m: [9]f64,
    outL: []i32,
    outA: []i32,
    outB: []i32,
) bool {
    var buf: [5]u32 = undefined;
    const rungs = rungsFor(side, &buf);
    if (rungs.len == 0) return false;
    if (mosaic.len < @as(usize, side) * side) return false;
    const total = stackLen(side);
    if (outL.len < total or outA.len < total or outB.len < total) return false;

    var off: usize = 0;
    for (rungs) |r| {
        const n = @as(usize, r) * r;
        computeRung(mosaic, side, cfa, m, r, outL[off .. off + n],
            outA[off .. off + n], outB[off .. off + n]);
        off += n;
    }

    var i = rungs.len;
    while (i > 1) : (i -= 1) {
        const r = rungs[i - 1];
        const rp = rungs[i - 2];
        if (r != 2 * rp) return false;
        const offR = levelOffset(side, r);
        const offP = levelOffset(side, rp);
        const nR = @as(usize, r) * r;
        const nP = @as(usize, rp) * rp;
        residualize(outL[offP .. offP + nP], outL[offR .. offR + nR], rp);
        residualize(outA[offP .. offP + nP], outA[offR .. offR + nR], rp);
        residualize(outB[offP .. offP + nP], outB[offR .. offR + nR], rp);
    }
    return true;
}

/// Decode one channel's prefix back to the rung-`rung` demosaic, in place in
/// `out` (rung² elements). In-place doubling walks indices DESCENDING so a
/// target write never clobbers a source cell that a later read needs.
pub fn decodeRung(bands: []const i32, side: u32, rung: u32, out: []i32) bool {
    var buf: [5]u32 = undefined;
    const rungs = rungsFor(side, &buf);
    if (rungs.len == 0) return false;
    var found = false;
    for (rungs) |r| {
        if (r == rung) found = true;
    }
    if (!found) return false;
    if (out.len < @as(usize, rung) * rung) return false;

    const base = rungs[0];
    @memcpy(out[0 .. @as(usize, base) * base], bands[0 .. @as(usize, base) * base]);

    var cur: usize = base;
    while (cur < rung) {
        const next = 2 * cur;
        const det = bands[levelOffset(side, @intCast(next))..];
        var y = next;
        while (y > 0) {
            y -= 1;
            const py = y / 2;
            var x = next;
            while (x > 0) {
                x -= 1;
                out[y * next + x] = out[py * cur + x / 2] + det[y * next + x];
            }
        }
        cur = next;
    }
    return true;
}

// ── Tests (pure; cross-language fixtures in tests/multiscale_fixtures.zig) ─

const testing = std.testing;

const IDENT = [9]f64{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

fn testMosaic(comptime side: usize, seed: i64) [side * side]f32 {
    var m: [side * side]f32 = undefined;
    var s = seed;
    for (&m) |*v| {
        const q: i64 = @mod(@divFloor(s, 65536), 16384);
        v.* = @as(f32, @floatFromInt(q)) / 16384.0;
        s = s *% 6364136223846793005 +% 1442695040888963407;
    }
    return m;
}

test "MS3 in Zig: decode(prefix r) == the direct rung-r demosaic" {
    const side = 64; // rungs {16, 32}
    const mosaic = testMosaic(side, 7);
    const total = stackLen(side);
    var bL: [1280]i32 = undefined;
    var bA: [1280]i32 = undefined;
    var bB: [1280]i32 = undefined;
    try testing.expectEqual(@as(usize, 1280), total);
    try testing.expect(encode(&mosaic, side, 0, IDENT, &bL, &bA, &bB));

    inline for (.{ 16, 32 }) |r| {
        var direct: [r * r]i32 = undefined;
        var dA: [r * r]i32 = undefined;
        var dB: [r * r]i32 = undefined;
        computeRung(&mosaic, side, 0, IDENT, r, &direct, &dA, &dB);
        var got: [r * r]i32 = undefined;
        try testing.expect(decodeRung(&bL, side, r, &got));
        try testing.expectEqualSlices(i32, &direct, &got);
    }
}

test "layout closed form: 87296 at the 2048/256 product shape" {
    try testing.expectEqual(@as(usize, 87296), stackLen(2048));
    try testing.expectEqual(@as(usize, 256), levelOffset(2048, 32));
    try testing.expectEqual(@as(usize, 21760), levelOffset(2048, 256));
    var buf: [5]u32 = undefined;
    try testing.expectEqual(@as(usize, 5), rungsFor(2048, &buf).len);
}
