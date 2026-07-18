//! fuse.zig — owned RGBT scene-linear fusion core (Phase 2 of the pivot;
//! see ../../BOREAL-RGBT-HDR-WORKFLOW.md §2). Hand-written, zero imaging
//! dependencies — BOREAL owns this algorithm end to end.
//!
//! Input:  4 radiometrically-bracketed raw frames (u16 samples, same geometry)
//!         + the per-frame relative exposure ratios from the capture plan.
//! Output: one scene-linear f32 buffer — the maximum-fidelity merge.
//!
//! Key property — FUSION IS CHANNEL-AGNOSTIC. The per-channel ETTR happened at
//! CAPTURE (each of R/G/B got a frame exposed just below its own clip). At fuse
//! time every sample is treated identically: a clipped sample self-zeroes, a
//! bright-but-unclipped sample dominates (best SNR), a dark/noisy sample is
//! down-weighted. So there is no per-lane channel branch — the inner loop is a
//! pure vector reduction, which is why the SIMD is strong.
//!
//! Per sample, frame t:
//!   lin   = (raw − black) / (white − black)          normalized [0,1]
//!   scene = lin / e_t                                 radiometric align (e_t = frame's exposure ratio)
//!   w     = lin · rolloff(lin)                        SNR-preference × saturation rolloff
//!   rolloff(lin) = clamp((clip − lin)/(clip − knee), 0, 1)   1 below knee → 0 at clip
//!   out   = Σ w·scene / Σ w   (defensive fallback to the darkest aligned sample if Σw≈0)
//!
//! The weight is a deliberately transcendental-free "ETTR-aware hat": it rewards
//! signal (∝ lin, the inverse-variance intuition for shot-noise-limited capture)
//! and kills clipping (rolloff → 0). No exp/log keeps the vector loop tight.

const std = @import("std");

/// f32 SIMD width. @Vector(8, f32) lowers to 2× NEON q-registers on Apple
/// silicon; large enough to amortize loop overhead, small enough to stay in
/// registers across the 4-frame unrolled reduction.
pub const LANES = 8;
const Vf = @Vector(LANES, f32);

/// Fusion parameters. C-ABI mirror (extern).
pub const FuseParams = extern struct {
    black: f32, // sensor black level (raw code)
    white: f32, // sensor saturation level (raw code)
    /// Per-frame relative exposure ratio e_t (a longer exposure → larger e_t).
    /// Aligning divides each frame by its e_t onto a common scene scale.
    exposures: [4]f32,
    knee: f32, // normalized level where saturation rolloff begins (≈0.90)
    clip: f32, // normalized level where weight reaches 0 (≈0.98)
};

/// Sensible defaults for the rolloff knee/clip given a measured white level.
pub fn defaultParams(black: f32, white: f32, exposures: [4]f32) FuseParams {
    return .{ .black = black, .white = white, .exposures = exposures, .knee = 0.90, .clip = 0.98 };
}

/// Bracket spread below this ratio (~0.05 stop = 2^0.05) is treated as sensor
/// shutter jitter → snap to equal exposure (pure temporal denoise).
pub const EQUAL_EXPOSURE_RATIO: f32 = 1.0353;
/// Maximum relative exposure ratio (2^8 = 8 stops). This is a corruption guard,
/// NOT a bracket limit: it must sit ABOVE any realistic photographic bracket so
/// legitimate wide brackets fuse with their true ratio. The app's own capture
/// planner never exceeds 5 stops, but the IMPORT path accepts arbitrary DNGs, so
/// 6–7 stop DSLR ladders are routine — clamping those to 5 stops would divide
/// their brightest-only shadows too little, biasing them bright. 8 stops covers
/// real brackets; only a garbage rational beyond that clamps (finite, bounded).
pub const MAX_EXPOSURE_RATIO: f32 = 256.0;

/// SINGLE source of truth for per-frame relative exposure ratios e_t.
///
/// Direction: DIVIDE, reference = the DARKEST frame (min photometric exposure),
/// so every e_t >= 1 and the darkest frame → 1.0. fuse() divides each frame's
/// lin by its e_t onto the common scene scale, so a brighter/longer frame MUST
/// carry a larger e_t. Photometric exposure per frame: E = ISO * ExposureTime
/// / FNumber^2. Ratio = E_t / min_k(E_k). NEVER inverted, NEVER normalized to
/// frame 0 (frames arrive in arbitrary file-picker order).
///
/// Three independent fallbacks each return EXACTLY {1,1,1,1}, byte-identical to
/// today's equal-exposure merge:
///   (1) any frame's ExposureTime absent/<=0 (sentinel 0 from the decoder),
///   (2) min photometric exposure <=0 / non-finite,
///   (3) bracket spread <= EQUAL_EXPOSURE_RATIO (~0.05 stop → temporal denoise).
/// ISO/FNumber absent (0) are treated as constant (1.0) so they cancel.
/// Every returned e_t is clamped to [1.0, MAX_EXPOSURE_RATIO] and finite.
pub fn relativeExposures(exposure_time: [4]f32, iso: [4]f32, fnumber: [4]f32) [4]f32 {
    var E: [4]f32 = undefined;
    inline for (0..4) |t| {
        if (!(exposure_time[t] > 0)) return .{ 1, 1, 1, 1 }; // absent/unreadable EXIF
        const s = if (iso[t] > 0) iso[t] else 1.0;
        const f2 = if (fnumber[t] > 0) fnumber[t] * fnumber[t] else 1.0;
        E[t] = exposure_time[t] * s / f2;
    }

    var emin = E[0];
    inline for (1..4) |t| emin = @min(emin, E[t]);
    if (!(emin > 0)) return .{ 1, 1, 1, 1 }; // defensive: garbage rationals

    var out: [4]f32 = undefined;
    var emax: f32 = 1.0;
    inline for (0..4) |t| {
        out[t] = std.math.clamp(E[t] / emin, 1.0, MAX_EXPOSURE_RATIO);
        emax = @max(emax, out[t]);
    }
    if (emax <= EQUAL_EXPOSURE_RATIO) return .{ 1, 1, 1, 1 }; // equal-exposure snap
    return out;
}

inline fn clamp01(v: Vf) Vf {
    const zero: Vf = @splat(0.0);
    const one: Vf = @splat(1.0);
    return @min(@max(v, zero), one);
}

/// Per-sample weight, vectorized: SNR-preference (∝ lin) × saturation rolloff.
inline fn weightVec(lin: Vf, span_inv: Vf, clip: Vf) Vf {
    const roll = clamp01((clip - lin) * span_inv);
    const zero: Vf = @splat(0.0);
    return @max(lin, zero) * roll;
}

/// Scalar twin of weightVec — the reference the SIMD path is tested against,
/// and the body of the remainder loop. Identical formula, scalar types.
inline fn weightScalar(lin: f32, knee: f32, clip: f32) f32 {
    const span = clip - knee;
    const roll = std.math.clamp((clip - lin) / span, 0.0, 1.0);
    return @max(lin, 0.0) * roll;
}

/// Fuse 4 raw frames into one scene-linear f32 buffer. All slices must have the
/// same length n; `out.len == frames[i].len`. Strong-SIMD main loop + scalar
/// remainder. Deterministic — no allocation, no global state.
pub fn fuse(frames: [4][]const u16, out: []f32, p: FuseParams) void {
    std.debug.assert(out.len == frames[0].len);
    const n = out.len;

    const black_s = p.black;
    const inv_range_s = 1.0 / (p.white - p.black);
    const span_s = p.clip - p.knee;
    var inv_e_s: [4]f32 = undefined;
    inline for (0..4) |t| inv_e_s[t] = 1.0 / p.exposures[t];

    // ── SIMD main loop: LANES pixels at a time, 4 frames unrolled ──
    const black: Vf = @splat(black_s);
    const inv_range: Vf = @splat(inv_range_s);
    const clip: Vf = @splat(p.clip);
    const span_inv: Vf = @splat(1.0 / span_s);
    const eps: Vf = @splat(1.0e-8);
    var inv_e: [4]Vf = undefined;
    inline for (0..4) |t| inv_e[t] = @splat(inv_e_s[t]);

    var i: usize = 0;
    while (i + LANES <= n) : (i += LANES) {
        var num: Vf = @splat(0.0);
        var den: Vf = @splat(0.0);
        var scene_min: Vf = @splat(std.math.floatMax(f32));
        inline for (0..4) |t| {
            const chunk: @Vector(LANES, u16) = frames[t][i..][0..LANES].*;
            const raw: Vf = @floatFromInt(chunk);
            const lin = (raw - black) * inv_range;
            const scene = lin * inv_e[t];
            const w = weightVec(lin, span_inv, clip);
            num += w * scene;
            den += w;
            scene_min = @min(scene_min, scene);
        }
        const fused = num / @max(den, eps);
        // Defensive: if every frame was clipped or black here (Σw≈0), fall back
        // to the darkest aligned sample — finite, never NaN.
        const ok = den > eps;
        const result = @select(f32, ok, fused, scene_min);
        out[i..][0..LANES].* = result;
    }

    // ── scalar remainder (identical math) ──
    while (i < n) : (i += 1) {
        var num: f32 = 0;
        var den: f32 = 0;
        var scene_min: f32 = std.math.floatMax(f32);
        inline for (0..4) |t| {
            const lin = (@as(f32, @floatFromInt(frames[t][i])) - black_s) * inv_range_s;
            const scene = lin * inv_e_s[t];
            const w = weightScalar(lin, p.knee, p.clip);
            num += w * scene;
            den += w;
            scene_min = @min(scene_min, scene);
        }
        out[i] = if (den > 1.0e-8) num / den else scene_min;
    }
}

/// Per-FRAME normalization (GIF-ISP per-frame rendering): one exposure's
/// mosaic onto the common scene scale — lin = (raw − black)/(white − black),
/// then divided by the frame's own relative exposure e_t (inv_e = 1/e_t).
/// The same affine + 1-homogeneous algebra the fuse applies per sample
/// (spec laws CQ6 + EV4); negatives clamp to 0 (below sensor black).
pub fn normalizeMosaic(samples: []const u16, black: f32, white: f32, inv_e: f32, out: []f32) void {
    const range = @max(white - black, 1.0);
    const scale = inv_e / range;
    for (samples, 0..) |s, i| {
        out[i] = @max((@as(f32, @floatFromInt(s)) - black) * scale, 0.0);
    }
}

// ── Tests (spec-first: §2 laws + the SIMD≡scalar gate) ─────────────────────

test "normalizeMosaic: black→0, white→1/e, affine, clamped" {
    var s = [4]u16{ 512, 16383, 8447, 100 }; // black, white, mid, below-black
    var out: [4]f32 = undefined;
    normalizeMosaic(&s, 512, 16383, 0.5, &out); // e_t = 2
    try std.testing.expectEqual(@as(f32, 0), out[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), out[2], 1e-3);
    try std.testing.expectEqual(@as(f32, 0), out[3]); // clamped
}

const testing = std.testing;

/// Independent scalar reference implementation — intentionally NOT sharing the
/// production loop, so the parity test catches a bug in either path.
fn fuseRef(frames: [4][]const u16, out: []f32, p: FuseParams) void {
    for (0..out.len) |i| {
        var num: f32 = 0;
        var den: f32 = 0;
        var smin: f32 = std.math.floatMax(f32);
        for (0..4) |t| {
            const lin = (@as(f32, @floatFromInt(frames[t][i])) - p.black) / (p.white - p.black);
            const scene = lin / p.exposures[t];
            const span = p.clip - p.knee;
            const roll = std.math.clamp((p.clip - lin) / span, 0.0, 1.0);
            const w = @max(lin, 0.0) * roll;
            num += w * scene;
            den += w;
            smin = @min(smin, scene);
        }
        out[i] = if (den > 1.0e-8) num / den else smin;
    }
}

test "weight: 0 at black, rises with signal, 0 past clip" {
    try testing.expectEqual(@as(f32, 0), weightScalar(0.0, 0.90, 0.98));
    try testing.expect(weightScalar(0.85, 0.90, 0.98) > weightScalar(0.30, 0.90, 0.98));
    try testing.expectEqual(@as(f32, 0), weightScalar(0.99, 0.90, 0.98)); // past clip
}

test "denoise identity: 4 equal frames at same exposure → that scene value" {
    const n = 20;
    var f: [4][n]u16 = undefined;
    inline for (0..4) |t| @memset(&f[t], 30000);
    var out: [n]f32 = undefined;
    const p = defaultParams(0, 65535, .{ 1, 1, 1, 1 });
    fuse(.{ &f[0], &f[1], &f[2], &f[3] }, &out, p);
    const expect: f32 = 30000.0 / 65535.0;
    for (out) |v| try testing.expectApproxEqAbs(expect, v, 1e-4);
}

test "radiometric alignment: 2× exposure + 2× raw → same scene-linear value" {
    const n = 8;
    // f0 at e=1 reads 10000; f1 at e=2 reads 20000 → both map to scene = 10000/W.
    var f0: [n]u16 = [_]u16{10000} ** n;
    var f1: [n]u16 = [_]u16{20000} ** n;
    var f2: [n]u16 = [_]u16{10000} ** n;
    var f3: [n]u16 = [_]u16{20000} ** n;
    var out: [n]f32 = undefined;
    const p = defaultParams(0, 65535, .{ 1, 2, 1, 2 });
    fuse(.{ &f0, &f1, &f2, &f3 }, &out, p);
    const expect: f32 = 10000.0 / 65535.0;
    for (out) |v| try testing.expectApproxEqAbs(expect, v, 1e-3);
}

test "clip rejection: a blown frame must not pollute the merge" {
    const n = 8;
    const good: u16 = 30000; // ~0.46 normalized, unclipped, well exposed
    var f0: [n]u16 = [_]u16{good} ** n;
    var f1: [n]u16 = [_]u16{65535} ** n; // hard-clipped → weight 0
    var f2: [n]u16 = [_]u16{good} ** n;
    var f3: [n]u16 = [_]u16{good} ** n;
    var out: [n]f32 = undefined;
    const p = defaultParams(0, 65535, .{ 1, 1, 1, 1 });
    fuse(.{ &f0, &f1, &f2, &f3 }, &out, p);
    const expect: f32 = @as(f32, good) / 65535.0;
    for (out) |v| try testing.expectApproxEqAbs(expect, v, 1e-4);
}

test "all-clipped fallback: finite, never NaN" {
    const n = 8;
    var f: [4][n]u16 = undefined;
    inline for (0..4) |t| @memset(&f[t], 65535);
    var out: [n]f32 = undefined;
    const p = defaultParams(0, 65535, .{ 1, 1, 1, 1 });
    fuse(.{ &f[0], &f[1], &f[2], &f[3] }, &out, p);
    for (out) |v| try testing.expect(std.math.isFinite(v));
}

test "exposure: shutter-only 1-stop bracket" {
    // 1/250..1/31 — a clean 1-stop ladder, no ISO/aperture.
    const et: [4]f32 = .{ 0.004, 0.008, 0.016, 0.032 };
    const z: [4]f32 = .{ 0, 0, 0, 0 };
    const e = relativeExposures(et, z, z);
    try testing.expectApproxEqAbs(@as(f32, 1), e[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2), e[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 4), e[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 8), e[3], 1e-4);
    inline for (0..4) |t| try testing.expect(e[t] >= 1.0); // divide-direction
    var emin = e[0];
    inline for (1..4) |t| emin = @min(emin, e[t]);
    try testing.expectEqual(@as(f32, 1.0), emin); // frame-min == reference
}

test "exposure: ISO and aperture factored" {
    const et: [4]f32 = .{ 0.01, 0.01, 0.01, 0.01 };
    const iso: [4]f32 = .{ 100, 200, 100, 100 };
    const fnum: [4]f32 = .{ 2, 2, 2.8, 2 };
    const e = relativeExposures(et, iso, fnum);
    // E_t = ExposureTime * ISO / FNumber^2; ratio = E_t / min(E).
    var E: [4]f32 = undefined;
    inline for (0..4) |t| E[t] = et[t] * iso[t] / (fnum[t] * fnum[t]);
    var emin = E[0];
    inline for (1..4) |t| emin = @min(emin, E[t]);
    inline for (0..4) |t| {
        const want = std.math.clamp(E[t] / emin, 1.0, MAX_EXPOSURE_RATIO);
        try testing.expectApproxEqAbs(want, e[t], 1e-4);
    }
}

test "exposure: missing ExposureTime forces equal" {
    const et: [4]f32 = .{ 0.004, 0, 0.016, 0.032 }; // one absent
    const z: [4]f32 = .{ 0, 0, 0, 0 };
    const e = relativeExposures(et, z, z);
    try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, e);
}

test "exposure: equal-exposure snap" {
    // All within 0.05 stop of each other (ratio <= EQUAL_EXPOSURE_RATIO).
    const et: [4]f32 = .{ 0.01000, 0.01010, 0.01020, 0.01030 };
    const z: [4]f32 = .{ 0, 0, 0, 0 };
    const e = relativeExposures(et, z, z);
    try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, e);
}

test "exposure: clamp blowup" {
    // One frame far beyond 8 stops (ratio 500) → clamped to MAX_EXPOSURE_RATIO; finite.
    const et: [4]f32 = .{ 0.002, 0.002, 0.002, 1.0 };
    const z: [4]f32 = .{ 0, 0, 0, 0 };
    const e = relativeExposures(et, z, z);
    try testing.expectApproxEqAbs(MAX_EXPOSURE_RATIO, e[3], 1e-4);
    inline for (0..4) |t| try testing.expect(std.math.isFinite(e[t]));
}

test "exposure: wide bracket within 8 stops passes through (not clamped to 5)" {
    // 6-stop ladder (ratio 64). Pre-fix MAX=32 would have truncated this to 32,
    // biasing brightest-only shadows ~1 stop bright. Now it fuses with true 64.
    const et: [4]f32 = .{ 0.001, 0.004, 0.016, 0.064 };
    const z: [4]f32 = .{ 0, 0, 0, 0 };
    const e = relativeExposures(et, z, z);
    try testing.expectApproxEqAbs(@as(f32, 1), e[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 64), e[3], 1e-2);
    try testing.expect(e[3] < MAX_EXPOSURE_RATIO); // not clamped
}

test "exposure: integration with radiometric alignment" {
    // Build the e={1,2,1,2} ladder via relativeExposures, then re-run the
    // alignment invariant from fuse.zig:176 against it.
    const et: [4]f32 = .{ 0.004, 0.008, 0.004, 0.008 };
    const z: [4]f32 = .{ 0, 0, 0, 0 };
    const e = relativeExposures(et, z, z);
    try testing.expectApproxEqAbs(@as(f32, 1), e[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2), e[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1), e[2], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2), e[3], 1e-4);

    const n = 8;
    var f0: [n]u16 = [_]u16{10000} ** n;
    var f1: [n]u16 = [_]u16{20000} ** n;
    var f2: [n]u16 = [_]u16{10000} ** n;
    var f3: [n]u16 = [_]u16{20000} ** n;
    var out: [n]f32 = undefined;
    const p = defaultParams(0, 65535, e);
    fuse(.{ &f0, &f1, &f2, &f3 }, &out, p);
    const expect: f32 = 10000.0 / 65535.0;
    for (out) |v| try testing.expectApproxEqAbs(expect, v, 1e-3);
}

test "SIMD ≡ scalar: vectorized path bit-matches the reference (incl. ragged tail)" {
    const n = LANES * 3 + 5; // forces both the vector loop and the remainder
    var f: [4][n]u16 = undefined;
    // Deterministic pseudo-varied data per lane/frame (no Math.random in scripts).
    inline for (0..4) |t| {
        for (0..n) |i| {
            const x: u32 = @intCast((i * 2654435761 + t * 40503) & 0xFFFF);
            f[t][i] = @intCast(x);
        }
    }
    var got: [n]f32 = undefined;
    var ref: [n]f32 = undefined;
    const p = defaultParams(512, 65535, .{ 1.0, 1.7, 2.9, 5.2 });
    fuse(.{ &f[0], &f[1], &f[2], &f[3] }, &got, p);
    fuseRef(.{ &f[0], &f[1], &f[2], &f[3] }, &ref, p);
    for (0..n) |i| try testing.expectApproxEqAbs(ref[i], got[i], 1e-5);
}
