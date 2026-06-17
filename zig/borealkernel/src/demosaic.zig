//! demosaic.zig — owned full-resolution demosaic (Phase 1; see
//! ../../BOREAL-RGBT-HDR-WORKFLOW.md §2). Hand-written, zero imaging libraries.
//!
//! Algorithm: Malvar–He–Cutler "High-Quality Linear Interpolation" (2004) — the
//! de-facto good linear demosaic (gradient-corrected bilinear via fixed 5×5
//! kernels). A real quality step over bilinear, but with NO data-dependent
//! branching, so it vectorizes cleanly. Runs on the FUSED scene-linear mosaic
//! (so demosaic interpolates already-denoised, radiometrically-merged data).
//!
//! Each missing channel is one of four fixed kernels (÷8), chosen by the
//! pixel's CFA position:
//!   GCROSS  green at a red/blue site
//!   RROW    the horizontal-neighbor color at a green site
//!   RCOL    the vertical-neighbor color at a green site
//!   RB      the diagonal color (red at blue, or blue at red)
//! All four sum to 1, so a flat field reproduces exactly — the correctness anchor.
//!
//! BGGR is RGGB with red/blue swapped (green sites are invariant under R↔B
//! relabeling), so we implement RGGB once and swap output channels for BGGR.
//!
//! SIMD: the interior (≥2px from every edge) is processed LANES contiguous
//! columns at a time — one vector per kernel, then a per-lane even/odd `@select`
//! assembles RGB. The thin border uses the identical scalar kernel with edge
//! clamping. A parity test pins the two paths equal.

const std = @import("std");

pub const LANES = 8;
const Vf = @Vector(LANES, f32);

const Tap = struct { dy: i32, dx: i32, w: f32 };

// Malvar kernels (×1/8). Tap order is identical in the scalar and vector paths
// so the two accumulate in the same sequence.
const GCROSS = [_]Tap{
    .{ .dy = 0, .dx = 0, .w = 4 },
    .{ .dy = -1, .dx = 0, .w = 2 }, .{ .dy = 1, .dx = 0, .w = 2 },
    .{ .dy = 0, .dx = -1, .w = 2 }, .{ .dy = 0, .dx = 1, .w = 2 },
    .{ .dy = -2, .dx = 0, .w = -1 }, .{ .dy = 2, .dx = 0, .w = -1 },
    .{ .dy = 0, .dx = -2, .w = -1 }, .{ .dy = 0, .dx = 2, .w = -1 },
};
const RROW = [_]Tap{
    .{ .dy = 0, .dx = 0, .w = 5 },
    .{ .dy = 0, .dx = -1, .w = 4 }, .{ .dy = 0, .dx = 1, .w = 4 },
    .{ .dy = 0, .dx = -2, .w = -1 }, .{ .dy = 0, .dx = 2, .w = -1 },
    .{ .dy = -1, .dx = -1, .w = -1 }, .{ .dy = -1, .dx = 1, .w = -1 },
    .{ .dy = 1, .dx = -1, .w = -1 }, .{ .dy = 1, .dx = 1, .w = -1 },
    .{ .dy = -2, .dx = 0, .w = 0.5 }, .{ .dy = 2, .dx = 0, .w = 0.5 },
};
const RCOL = [_]Tap{
    .{ .dy = 0, .dx = 0, .w = 5 },
    .{ .dy = -1, .dx = 0, .w = 4 }, .{ .dy = 1, .dx = 0, .w = 4 },
    .{ .dy = -2, .dx = 0, .w = -1 }, .{ .dy = 2, .dx = 0, .w = -1 },
    .{ .dy = -1, .dx = -1, .w = -1 }, .{ .dy = -1, .dx = 1, .w = -1 },
    .{ .dy = 1, .dx = -1, .w = -1 }, .{ .dy = 1, .dx = 1, .w = -1 },
    .{ .dy = 0, .dx = -2, .w = 0.5 }, .{ .dy = 0, .dx = 2, .w = 0.5 },
};
const RB = [_]Tap{
    .{ .dy = 0, .dx = 0, .w = 6 },
    .{ .dy = -1, .dx = -1, .w = 2 }, .{ .dy = -1, .dx = 1, .w = 2 },
    .{ .dy = 1, .dx = -1, .w = 2 }, .{ .dy = 1, .dx = 1, .w = 2 },
    .{ .dy = -2, .dx = 0, .w = -1.5 }, .{ .dy = 2, .dx = 0, .w = -1.5 },
    .{ .dy = 0, .dx = -2, .w = -1.5 }, .{ .dy = 0, .dx = 2, .w = -1.5 },
};

inline fn clampi(v: i64, hi: usize) usize {
    if (v < 0) return 0;
    if (v >= @as(i64, @intCast(hi))) return hi - 1;
    return @intCast(v);
}

fn kernelScalar(m: []const f32, w: usize, h: usize, x: usize, y: usize, comptime taps: []const Tap) f32 {
    var acc: f32 = 0;
    inline for (taps) |t| {
        const yy = clampi(@as(i64, @intCast(y)) + t.dy, h);
        const xx = clampi(@as(i64, @intCast(x)) + t.dx, w);
        acc += t.w * m[yy * w + xx];
    }
    return acc * 0.125;
}

/// RGGB-convention demosaic of one pixel → {R, G, B}. (Caller swaps R/B for BGGR.)
fn pixelRGGB(m: []const f32, w: usize, h: usize, x: usize, y: usize) [3]f32 {
    const center = m[y * w + x];
    const ex = x & 1;
    const ey = y & 1;
    if (ex == 0 and ey == 0) return .{ center, kernelScalar(m, w, h, x, y, &GCROSS), kernelScalar(m, w, h, x, y, &RB) }; // R site
    if (ex == 1 and ey == 0) return .{ kernelScalar(m, w, h, x, y, &RROW), center, kernelScalar(m, w, h, x, y, &RCOL) }; // G in red row
    if (ex == 0 and ey == 1) return .{ kernelScalar(m, w, h, x, y, &RCOL), center, kernelScalar(m, w, h, x, y, &RROW) }; // G in blue row
    return .{ kernelScalar(m, w, h, x, y, &RB), kernelScalar(m, w, h, x, y, &GCROSS), center }; // B site
}

inline fn storePixel(out: []f32, o: usize, rgb: [3]f32, swap: bool) void {
    if (swap) {
        out[o + 0] = rgb[2];
        out[o + 1] = rgb[1];
        out[o + 2] = rgb[0];
    } else {
        out[o + 0] = rgb[0];
        out[o + 1] = rgb[1];
        out[o + 2] = rgb[2];
    }
}

/// Fully scalar demosaic — the reference and border path. `swap` true for BGGR.
pub fn demosaicScalar(m: []const f32, w: usize, h: usize, swap: bool, out: []f32) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            storePixel(out, (y * w + x) * 3, pixelRGGB(m, w, h, x, y), swap);
        }
    }
}

inline fn vecLoad(m: []const f32, idx: usize) Vf {
    return m[idx..][0..LANES].*;
}

inline fn kernelVec(m: []const f32, w: usize, base: usize, comptime taps: []const Tap) Vf {
    var acc: Vf = @splat(0.0);
    inline for (taps) |t| {
        const idx: usize = @intCast(@as(i64, @intCast(base)) + t.dy * @as(i64, @intCast(w)) + t.dx);
        acc += @as(Vf, @splat(t.w)) * vecLoad(m, idx);
    }
    return acc * @as(Vf, @splat(0.125));
}

// Even-lane mask: lanes 0,2,4,… are "even column" (chunks start at even x).
const EVEN: @Vector(LANES, bool) = blk: {
    var mk: [LANES]bool = undefined;
    for (0..LANES) |k| mk[k] = (k % 2 == 0);
    break :blk mk;
};

/// Demosaic the mosaic into interleaved RGB. SIMD interior + scalar border.
/// `swap` true for BGGR (red/blue output swapped). out.len ≥ w*h*3.
pub fn demosaic(m: []const f32, w: usize, h: usize, swap: bool, out: []f32) void {
    // Small images: pure scalar (no room for the 2px interior).
    if (w < LANES + 4 or h < 5) {
        demosaicScalar(m, w, h, swap, out);
        return;
    }
    var y: usize = 0;
    while (y < h) : (y += 1) {
        if (y < 2 or y >= h - 2) {
            // border row — all scalar
            var x: usize = 0;
            while (x < w) : (x += 1) storePixel(out, (y * w + x) * 3, pixelRGGB(m, w, h, x, y), swap);
            continue;
        }
        // left border columns
        var x: usize = 0;
        while (x < 2) : (x += 1) storePixel(out, (y * w + x) * 3, pixelRGGB(m, w, h, x, y), swap);

        // interior, SIMD, LANES columns per step (x stays even → lane parity = column parity)
        const ey = y & 1;
        while (x + LANES <= w - 2) : (x += LANES) {
            const base = y * w + x;
            const center = vecLoad(m, base);
            const gcross = kernelVec(m, w, base, &GCROSS);
            const rrow = kernelVec(m, w, base, &RROW);
            const rcol = kernelVec(m, w, base, &RCOL);
            const rb = kernelVec(m, w, base, &RB);
            var rv: Vf = undefined;
            var gv: Vf = undefined;
            var bv: Vf = undefined;
            if (ey == 0) { // red row: even col = R site, odd col = G-in-red-row
                rv = @select(f32, EVEN, center, rrow);
                gv = @select(f32, EVEN, gcross, center);
                bv = @select(f32, EVEN, rb, rcol);
            } else { // blue row: even col = G-in-blue-row, odd col = B site
                rv = @select(f32, EVEN, rcol, rb);
                gv = @select(f32, EVEN, center, gcross);
                bv = @select(f32, EVEN, rrow, center);
            }
            inline for (0..LANES) |k| {
                storePixel(out, (base + k) * 3, .{ rv[k], gv[k], bv[k] }, swap);
            }
        }
        // right remainder + border
        while (x < w) : (x += 1) storePixel(out, (y * w + x) * 3, pixelRGGB(m, w, h, x, y), swap);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

fn fillFlat(m: []f32, c: f32) void {
    @memset(m, c);
}

test "flat field reproduces exactly (kernels sum to 1)" {
    const w = 16;
    const h = 16;
    var m: [w * h]f32 = undefined;
    fillFlat(&m, 0.42);
    var out: [w * h * 3]f32 = undefined;
    demosaic(&m, w, h, false, &out);
    for (out) |v| try testing.expectApproxEqAbs(@as(f32, 0.42), v, 1e-5);
}

test "green at a green site equals the sampled value (no interpolation)" {
    // Synthetic: green sites carry a distinct value; check it survives.
    const w = 16;
    const h = 16;
    var m: [w * h]f32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const ex = x & 1;
        const ey = y & 1;
        const is_green = (ex + ey) == 1;
        m[y * w + x] = if (is_green) 0.7 else 0.3;
    };
    var out: [w * h * 3]f32 = undefined;
    demosaic(&m, w, h, false, &out);
    // an interior green site (1,2): G output must equal its mosaic sample 0.7
    try testing.expectApproxEqAbs(@as(f32, 0.7), out[(2 * w + 1) * 3 + 1], 1e-5);
}

fn rampMosaic(m: []f32, w: usize, h: usize) void {
    for (0..h) |y| for (0..w) |x| {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        m[y * w + x] = 0.1 + 0.01 * fx + 0.007 * fy;
    };
}

test "SIMD ≡ scalar, RGGB (interior + borders + ragged width)" {
    const w = 21; // not a multiple of LANES → exercises the remainder
    const h = 14;
    var m: [w * h]f32 = undefined;
    rampMosaic(&m, w, h);
    var a: [w * h * 3]f32 = undefined;
    var b: [w * h * 3]f32 = undefined;
    demosaic(&m, w, h, false, &a);
    demosaicScalar(&m, w, h, false, &b);
    for (0..a.len) |i| try testing.expectApproxEqAbs(b[i], a[i], 1e-5);
}

test "SIMD ≡ scalar, BGGR (R/B swap path)" {
    const w = 20;
    const h = 12;
    var m: [w * h]f32 = undefined;
    rampMosaic(&m, w, h);
    var a: [w * h * 3]f32 = undefined;
    var b: [w * h * 3]f32 = undefined;
    demosaic(&m, w, h, true, &a);
    demosaicScalar(&m, w, h, true, &b);
    for (0..a.len) |i| try testing.expectApproxEqAbs(b[i], a[i], 1e-5);
}

test "BGGR flat field also reproduces exactly" {
    const w = 16;
    const h = 16;
    var m: [w * h]f32 = undefined;
    fillFlat(&m, 0.6);
    var out: [w * h * 3]f32 = undefined;
    demosaic(&m, w, h, true, &out);
    for (out) |v| try testing.expectApproxEqAbs(@as(f32, 0.6), v, 1e-5);
}
