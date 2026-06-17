//! Per-bin binomial encode for Phase 2 Stage 4.
//!
//! Input: 4 frames of 64×64×3 LAB (interleaved per pixel: L0,a0,b0,L1,a1,b1,...
//!        — that's the natural layout from the BayerBinLAB.metal output, one
//!        frame at a time. We expect the caller to concatenate 4 frames
//!        contiguously: frame0[12288 floats], frame1[12288], ...).
//!
//! Output: 10 columnar arrays, each of length 4096 (one entry per spatial bin):
//!   col_L_min:   [4096]f32
//!   col_L_max:   [4096]f32
//!   col_L_mean:  [4096]f32
//!   col_a_min:   [4096]f32
//!   col_a_max:   [4096]f32
//!   col_a_mean:  [4096]f32
//!   col_b_min:   [4096]f32
//!   col_b_max:   [4096]f32
//!   col_b_mean:  [4096]f32
//!   col_codes_flags: [4096]u32   (L_code | a_code<<8 | b_code<<16 | flags<<24)
//!
//! Per-bin SIMD: load the 4 frame samples for each LAB channel into a
//! @Vector(4, f32) register; reduce min/max/sum in single NEON instructions;
//! quantize each frame's value into 4 levels via (v - min) / (max - min) * 3;
//! pack the 4-tuple into a base-4 code; compute the 7 flag bits.

const std = @import("std");

pub const BIN_COUNT: u32 = 64;
pub const FRAMES_PER_SET: u32 = 4;
pub const SPATIAL_BINS: u32 = BIN_COUNT * BIN_COUNT;          // 4096
pub const FLOATS_PER_FRAME: u32 = SPATIAL_BINS * 3;            // 12288

/// Flag bits packed into the high byte of col_codes_flags.
pub const FLAG_STATIC                = @as(u32, 1) << 0;       // σ² < ε across all 4 frames
pub const FLAG_MONOTONIC_INCREASING  = @as(u32, 1) << 1;       // q0 ≤ q1 ≤ q2 ≤ q3 in L*
pub const FLAG_MONOTONIC_DECREASING  = @as(u32, 1) << 2;       // q0 ≥ q1 ≥ q2 ≥ q3 in L*
pub const FLAG_TEMPORAL_PULSE        = @as(u32, 1) << 3;       // peak at t=1 or t=2 (L*)
pub const FLAG_HIGH_CHROMA           = @as(u32, 1) << 4;       // √(a² + b²) > 25
pub const FLAG_HIGH_LUMA             = @as(u32, 1) << 5;       // L*_mean > 75
pub const FLAG_LOW_LUMA              = @as(u32, 1) << 6;       // L*_mean < 25
pub const FLAG_BEAUTY                = @as(u32, 1) << 7;       // L.chi2 < BEAUTY_THRESHOLD

/// "Beauty" χ² threshold against fixed Bin(3, 0.5) PMF.
/// A perfectly-uniform 4-frame trajectory (q = 0,1,2,3) hits χ² ≈ 1.33 against
/// the symmetric expected histogram {0.5, 1.5, 1.5, 0.5}; anything ≤ 4.0 is
/// "close enough to a fair coin-flip" by Pearson's small-sample lookup table
/// (df=3, p=0.25). Bins with FLAG_BEAUTY set are candidates for lossless
/// preservation in downstream GIF89a global ops.
pub const BEAUTY_THRESHOLD: f32 = 4.0;

/// Shape classification — 2 bits packed into the high lane of the shape word.
pub const ShapeClass = enum(u2) {
    symmetric    = 0,  // |γ₃| ≤ 0.5 ∧ γ₄ ≤ 1.0 — looks like a fair binomial
    left_skew    = 1,  // γ₃ < -0.5
    right_skew   = 2,  // γ₃ > +0.5
    bimodal      = 3,  // |γ₃| ≤ 0.5 ∧ γ₄ > 1.0 — sharp peaks at extremes
};

/// Expected histogram for Bin(3, 0.5) × n=4 samples = {1/8, 3/8, 3/8, 1/8} × 4.
/// This is THE "beautiful" reference distribution — see plan §H. Held as a
/// compile-time SIMD constant; the χ² FMA chain consumes it without reloads.
const EXPECTED_HIST: @Vector(4, f32)  = .{ 0.5, 1.5, 1.5, 0.5 };
const INV_EXPECTED:  @Vector(4, f32)  = .{ 2.0, 2.0 / 3.0, 2.0 / 3.0, 2.0 };

/// Per-channel reduce: take 4 samples in a vector, return (min, max, mean, code)
/// plus the new SHAPE descriptor (σ, γ₃, γ₄, χ², class).
///
/// All operations vectorize to NEON: @reduce(.Min/.Max/.Add) are single insns,
/// the quantization is one FMA per lane, the base-4 packing is integer ALU,
/// and the moment / χ² extension adds 4 muls + 3 horizontal-adds + 1 sqrt
/// + 4 lane-compares per channel — all in-register on A19's 32 × 128-bit
/// V-file (≈ 12 V regs live, zero spills).
pub const ChannelStats = struct {
    min: f32,
    max: f32,
    mean: f32,
    code: u8,
    /// Raw quantized levels q[0..3] in [0,3] — needed by the flag bits.
    q: [4]u8,
    // ── Shape (new in v3) ─────────────────────────────────────────────────
    /// Sample standard deviation on the original channel scale.
    sigma: f32,
    /// Sample skewness γ₃ = m₃ / σ³. Range typically [-1.5, +1.5] for n=4.
    gamma3: f32,
    /// Excess kurtosis γ₄ = m₄ / σ⁴ − 3. For n=4 lies on a deltoid in (γ₃,γ₄).
    gamma4: f32,
    /// Pearson χ² distance from the symmetric Bin(3, 0.5) expected histogram
    /// {0.5, 1.5, 1.5, 0.5}. LOW = the trajectory's 4-level histogram looks
    /// like a fair coin's. HIGH = degenerate or pile-up.
    chi2: f32,
    /// Classification derived from (γ₃, γ₄). See `ShapeClass`.
    shape_class: ShapeClass,
    /// Centered deviations v - μ kept around so encodeSet can compute
    /// cross-channel covariances (v4) without redoing the subtract.
    /// One @Vector(4, f32) per channel: cov_XY = ⟨d_X · d_Y⟩.
    dev: @Vector(4, f32),
};

/// User's choice of 4-frame central-tendency estimator. Mapped to a
/// `u32` for clean C ABI consumption. Default 0 = arithmetic mean
/// preserves byte-identical output for every pre-existing call site.
pub const Combiner = enum(u32) {
    mean = 0,
    median = 1,
    inverse_variance_weighted = 2,
    trimmed_mean = 3,
};

/// Compute the per-bin central tendency under the user's chosen
/// combiner. All four estimators are closed-form on n=4 — no loops,
/// no extra memory, no iteration. The chosen center then drives the
/// centered-deviation vector `d = v − center` that the rest of
/// `encodeChannel` uses for σ², γ₃, γ₄, χ², cov, motion.
inline fn computeCentralTendency(v: @Vector(4, f32), c: Combiner) f32 {
    return switch (c) {
        .mean => @reduce(.Add, v) * 0.25,
        .median => blk: {
            // Sort 4 floats via the 5-comparison Bose-Nelson network.
            var s0 = v[0]; var s1 = v[1]; var s2 = v[2]; var s3 = v[3];
            if (s0 > s1) { const t = s0; s0 = s1; s1 = t; }
            if (s2 > s3) { const t = s2; s2 = s3; s3 = t; }
            if (s0 > s2) { const t = s0; s0 = s2; s2 = t; }
            if (s1 > s3) { const t = s1; s1 = s3; s3 = t; }
            if (s1 > s2) { const t = s1; s1 = s2; s2 = t; }
            // After the network s0 ≤ s1 ≤ s2 ≤ s3. Median = (s1+s2)/2.
            break :blk (s1 + s2) * 0.5;
        },
        .inverse_variance_weighted => blk: {
            const sum = @reduce(.Add, v);
            var num: f32 = 0;
            var den: f32 = 0;
            inline for (0..4) |i| {
                const rest_mean = (sum - v[i]) * (1.0 / 3.0);
                const dev = v[i] - rest_mean;
                const sigma2 = @max(dev * dev, 1.0e-6);
                num += v[i] / sigma2;
                den += 1.0 / sigma2;
            }
            break :blk num / den;
        },
        .trimmed_mean => blk: {
            // Materialize v into a stack array so we can index by a
            // runtime variable (Zig requires comptime indices on
            // @Vector but stack arrays allow runtime indexing).
            const arr = [_]f32{ v[0], v[1], v[2], v[3] };
            const sum = arr[0] + arr[1] + arr[2] + arr[3];
            const mu = sum * 0.25;
            var max_dev: f32 = -1;
            var j: usize = 0;
            inline for (0..4) |i| {
                const d = @abs(arr[i] - mu);
                if (d > max_dev) { max_dev = d; j = i; }
            }
            break :blk (sum - arr[j]) * (1.0 / 3.0);
        },
    };
}

inline fn encodeChannel(v: @Vector(4, f32), combiner: Combiner) ChannelStats {
    const min_v = @reduce(.Min, v);
    const max_v = @reduce(.Max, v);
    // The user-chosen central tendency. When combiner = .mean (default
    // raw value 0), this is `@reduce(.Add, v) * 0.25` — byte-identical
    // to v4 behavior. Other combiners use closed-form formulas
    // mathematically consistent with the higher moments below.
    const mean  = computeCentralTendency(v, combiner);

    const range = max_v - min_v;
    // If the channel is flat (range ≈ 0), all q values are 0 and code is 0.
    const inv_range: f32 = if (range > 1e-6) 3.0 / range else 0.0;
    const v_min: @Vector(4, f32) = @splat(min_v);
    const v_inv: @Vector(4, f32) = @splat(inv_range);
    const norm = (v - v_min) * v_inv;
    // Clamp to [0, 3] and round, then convert to integer.
    const zero: @Vector(4, f32) = @splat(0.0);
    const three: @Vector(4, f32) = @splat(3.0);
    const clamped = @min(three, @max(zero, @round(norm)));
    const q_vec: @Vector(4, u32) = @intFromFloat(clamped);

    // Pack base-4: code = q[0] | q[1]<<2 | q[2]<<4 | q[3]<<6
    const code_u32 = q_vec[0] | (q_vec[1] << 2) | (q_vec[2] << 4) | (q_vec[3] << 6);

    // ── Shape stats (load-bearing SIMD chain) ────────────────────────────
    // Centered deviations and powers; all in @Vector(4, f32) — one NEON
    // sub + three NEON muls. m_k = ¼ Σ (q − μ)^k. Sample (not unbiased)
    // moments — for n=4 the unbiased correction is irrelevant against the
    // i8 quantization step we land on at the end.
    const v_mean: @Vector(4, f32) = @splat(mean);
    const d  = v - v_mean;
    const d2 = d * d;
    const d3 = d2 * d;
    const d4 = d2 * d2;
    const m2 = @reduce(.Add, d2) * 0.25;
    const m3 = @reduce(.Add, d3) * 0.25;
    const m4 = @reduce(.Add, d4) * 0.25;
    const sigma = @sqrt(m2);

    // Skewness / kurtosis only well-defined when σ > 0; degenerate
    // (constant) trajectories get γ₃ = γ₄ = 0 → SYMMETRIC class.
    const m2_safe = m2 > 1.0e-6;
    const inv_sigma3: f32 = if (m2_safe) 1.0 / (sigma * m2) else 0.0;
    const inv_sigma4: f32 = if (m2_safe) 1.0 / (m2 * m2)    else 0.0;
    const gamma3: f32 = m3 * inv_sigma3;
    const gamma4: f32 = if (m2_safe) (m4 * inv_sigma4 - 3.0) else 0.0;

    // χ² against fixed Bin(3, 0.5) PMF expected histogram. We build the
    // observed histogram by lane-comparing q_vec against {0, 1, 2, 3}
    // splats; each compare reduces to a single u32 count via @reduce.
    // 4 cmpeq + 4 reductions = ~8 NEON instructions.
    const k0: @Vector(4, u32) = @splat(0);
    const k1: @Vector(4, u32) = @splat(1);
    const k2: @Vector(4, u32) = @splat(2);
    const k3: @Vector(4, u32) = @splat(3);
    const h0: u32 = @reduce(.Add, @select(u32, q_vec == k0, @as(@Vector(4, u32), @splat(1)), @as(@Vector(4, u32), @splat(0))));
    const h1: u32 = @reduce(.Add, @select(u32, q_vec == k1, @as(@Vector(4, u32), @splat(1)), @as(@Vector(4, u32), @splat(0))));
    const h2: u32 = @reduce(.Add, @select(u32, q_vec == k2, @as(@Vector(4, u32), @splat(1)), @as(@Vector(4, u32), @splat(0))));
    const h3: u32 = @reduce(.Add, @select(u32, q_vec == k3, @as(@Vector(4, u32), @splat(1)), @as(@Vector(4, u32), @splat(0))));
    const observed: @Vector(4, f32) = .{
        @floatFromInt(h0), @floatFromInt(h1), @floatFromInt(h2), @floatFromInt(h3),
    };
    const diff = observed - EXPECTED_HIST;
    const chi2: f32 = @reduce(.Add, diff * diff * INV_EXPECTED);

    // Classification: prioritise asymmetry, then peakedness.
    //
    // For n=4 the kurtosis space is BOUNDED and mostly negative — uniform
    // ramp (0,1,2,3) gives γ₄ = -1.36, perfectly-bimodal (0,0,3,3) gives
    // γ₄ = -2 (the floor). A "single outlier" pattern like (0,0,0,3) gives
    // γ₄ ≈ -0.67. So BIMODAL is detected by *deeply* platykurtic γ₄ — flat
    // or U-shaped — not by positive kurtosis (which is unreachable here).
    const cls: ShapeClass = blk: {
        if (gamma3 < -0.5) break :blk .left_skew;   // single low outlier
        if (gamma3 >  0.5) break :blk .right_skew;  // single high outlier
        if (gamma4 < -1.5) break :blk .bimodal;     // (0,0,3,3)-style U-shape
        break :blk .symmetric;
    };

    return .{
        .min = min_v,
        .max = max_v,
        .mean = mean,
        .code = @intCast(code_u32 & 0xFF),
        .q = .{
            @intCast(q_vec[0]),
            @intCast(q_vec[1]),
            @intCast(q_vec[2]),
            @intCast(q_vec[3]),
        },
        .sigma = sigma,
        .gamma3 = gamma3,
        .gamma4 = gamma4,
        .chi2 = chi2,
        .shape_class = cls,
        .dev = d,
    };
}

/// Pack the shape descriptor into a u32 column word.
///
///   bits  0..7   sigma_q8    — σ × 2, clamp to 0..255 (0.5 LSB on channel scale)
///   bits  8..15  gamma3_s8   — γ₃ × 64, clamp to i8 [-128, +127]
///   bits 16..23  gamma4_s8   — γ₄ × 32, clamp to i8 (biased range ~[-2, +6])
///   bits 24..29  chi2_u6     — χ² × 2, clamp to 0..63
///   bits 30..31  shape_class — ShapeClass enum value (0..3)
pub inline fn packShapeWord(c: ChannelStats) u32 {
    const sigma_u8: u32 = @as(u32, @intFromFloat(std.math.clamp(c.sigma * 2.0, 0.0, 255.0))) & 0xFF;
    const gamma3_i: i32 = @intFromFloat(std.math.clamp(c.gamma3 * 64.0, -128.0, 127.0));
    const gamma4_i: i32 = @intFromFloat(std.math.clamp(c.gamma4 * 32.0, -128.0, 127.0));
    const gamma3_u8: u32 = @as(u32, @bitCast(gamma3_i)) & 0xFF;
    const gamma4_u8: u32 = @as(u32, @bitCast(gamma4_i)) & 0xFF;
    const chi2_u6: u32 = @as(u32, @intFromFloat(std.math.clamp(c.chi2 * 2.0, 0.0, 63.0))) & 0x3F;
    const cls_u2: u32 = @as(u32, @intFromEnum(c.shape_class)) & 0x3;
    return sigma_u8
        | (gamma3_u8 << 8)
        | (gamma4_u8 << 16)
        | (chi2_u6 << 24)
        | (cls_u2 << 30);
}

/// Compute the 8 flag bits for a bin given its 3 channels' stats.
inline fn computeFlags(L: ChannelStats, a: ChannelStats, b: ChannelStats) u8 {
    var f: u8 = 0;

    // is_static: variance across 4 L* frames is small.
    // We approximate variance by (max-min); cheap and good enough for the
    // editor's "this bin doesn't change" predicate.
    const dL = L.max - L.min;
    if (dL < 1.0) f |= 1 << 0;  // FLAG_STATIC

    // Monotonic L* trajectory (allow ties).
    const inc = L.q[0] <= L.q[1] and L.q[1] <= L.q[2] and L.q[2] <= L.q[3];
    const dec = L.q[0] >= L.q[1] and L.q[1] >= L.q[2] and L.q[2] >= L.q[3];
    if (inc and !dec) f |= 1 << 1;  // FLAG_MONOTONIC_INCREASING
    if (dec and !inc) f |= 1 << 2;  // FLAG_MONOTONIC_DECREASING

    // Temporal pulse: L* peaks at frame 1 or 2 (strictly above neighbors).
    const pulse_at_1 = L.q[1] > L.q[0] and L.q[1] > L.q[2];
    const pulse_at_2 = L.q[2] > L.q[1] and L.q[2] > L.q[3];
    if (pulse_at_1 or pulse_at_2) f |= 1 << 3;  // FLAG_TEMPORAL_PULSE

    // High chroma: √(a*² + b*²) > 25.
    const chroma_sq = a.mean * a.mean + b.mean * b.mean;
    if (chroma_sq > 625.0) f |= 1 << 4;  // FLAG_HIGH_CHROMA  (25² = 625)

    if (L.mean > 75.0) f |= 1 << 5;  // FLAG_HIGH_LUMA
    if (L.mean < 25.0) f |= 1 << 6;  // FLAG_LOW_LUMA

    // Binomial-beauty gate: L-channel trajectory's 4-level histogram is
    // close to a fair Bin(3, 0.5). The editor's global ops should preserve
    // these bins losslessly in the final GIF89a. Threshold tuned so a
    // uniform ramp (0,1,2,3) — χ² ≈ 1.33 — passes; bimodal (0,0,3,3) —
    // χ² ≈ 12 — fails; degenerate constants — χ² ≈ 28 — fail hard.
    if (L.chi2 < BEAUTY_THRESHOLD) f |= 1 << 7;  // FLAG_BEAUTY

    return f;
}

/// Per-set trailer scalars emitted alongside the columnar output. These are
/// global (over the 64×64 grid) statistics that the VoxelPack writer packs
/// into the .bvox trailer's reserved bytes — see VoxelPack.swift for layout.
pub const PerSetTrailer = extern struct {
    /// Lag-1 horizontal autocorrelation of each channel's `*_mean` grid.
    /// Range [-1, +1]; high positive ρ₁ indicates smoothly-varying channel.
    rho1_L: f32,
    rho1_a: f32,
    rho1_b: f32,
    /// KL-divergence of the empirical L_mean 16-bin histogram against the
    /// best-fit N(μ_L, σ_L²) reference. 0 = Gaussian-shaped; large = far.
    kl_L_to_gaussian: f32,
};

/// Top-level encode for a whole set: 4 LAB frames → 20 columnar buffers +
/// per-set trailer scalars.
///
/// `lab_frames` layout: [frame_0_lab_interleaved, frame_1, frame_2, frame_3]
///                      where each frame is BIN_COUNT*BIN_COUNT*3 floats
///                      (12,288 per frame, 49,152 total).
///
/// All column buffers must have capacity ≥ SPATIAL_BINS (4096) entries.
/// Caller owns all buffers; this function only writes into them.
///
/// v4 columns appended after the v3 set:
///   col_fast_cov_La/Lb/ab  — per-bin cross-channel covariance over 4 frames
///   col_fast_nbr_rho_L/a/b — per-bin 4-neighbor spatial autocorrelation of
///                            the channel-mean grid (toroidal at edges)
///   col_fast_motion_mag    — per-bin LAB-Euclidean drift from frame 0 → 3
pub fn encodeSet(
    lab_frames: []const f32,
    col_L_min:  []f32,
    col_L_max:  []f32,
    col_L_mean: []f32,
    col_a_min:  []f32,
    col_a_max:  []f32,
    col_a_mean: []f32,
    col_b_min:  []f32,
    col_b_max:  []f32,
    col_b_mean: []f32,
    col_codes_flags: []u32,
    col_L_shape: []u32,
    col_a_shape: []u32,
    col_b_shape: []u32,
    // v4 additions (per spatial bin)
    col_fast_cov_La:     []f32,
    col_fast_cov_Lb:     []f32,
    col_fast_cov_ab:     []f32,
    col_fast_nbr_rho_L:  []f32,
    col_fast_nbr_rho_a:  []f32,
    col_fast_nbr_rho_b:  []f32,
    col_fast_motion_mag: []f32,
    out_trailer: *PerSetTrailer,
    combiner: Combiner,
) void {
    std.debug.assert(lab_frames.len == FLOATS_PER_FRAME * FRAMES_PER_SET);
    std.debug.assert(col_L_min.len  >= SPATIAL_BINS);
    std.debug.assert(col_codes_flags.len >= SPATIAL_BINS);
    std.debug.assert(col_L_shape.len >= SPATIAL_BINS);
    std.debug.assert(col_a_shape.len >= SPATIAL_BINS);
    std.debug.assert(col_b_shape.len >= SPATIAL_BINS);
    std.debug.assert(col_fast_cov_La.len >= SPATIAL_BINS);
    std.debug.assert(col_fast_motion_mag.len >= SPATIAL_BINS);

    // ── Pass 1: per-bin reductions + in-loop covariance + motion ──
    var spat: u32 = 0;
    while (spat < SPATIAL_BINS) : (spat += 1) {
        // For spatial bin `spat`, gather the 4-frame LAB triples.
        // Each frame's bin starts at frame_offset + spat*3.
        const off0 = (0 * FLOATS_PER_FRAME) + spat * 3;
        const off1 = (1 * FLOATS_PER_FRAME) + spat * 3;
        const off2 = (2 * FLOATS_PER_FRAME) + spat * 3;
        const off3 = (3 * FLOATS_PER_FRAME) + spat * 3;

        const v_L: @Vector(4, f32) = .{
            lab_frames[off0 + 0],
            lab_frames[off1 + 0],
            lab_frames[off2 + 0],
            lab_frames[off3 + 0],
        };
        const v_a: @Vector(4, f32) = .{
            lab_frames[off0 + 1],
            lab_frames[off1 + 1],
            lab_frames[off2 + 1],
            lab_frames[off3 + 1],
        };
        const v_b: @Vector(4, f32) = .{
            lab_frames[off0 + 2],
            lab_frames[off1 + 2],
            lab_frames[off2 + 2],
            lab_frames[off3 + 2],
        };

        const L = encodeChannel(v_L, combiner);
        const a = encodeChannel(v_a, combiner);
        const b = encodeChannel(v_b, combiner);
        const flags = computeFlags(L, a, b);

        col_L_min[spat]  = L.min;
        col_L_max[spat]  = L.max;
        col_L_mean[spat] = L.mean;
        col_a_min[spat]  = a.min;
        col_a_max[spat]  = a.max;
        col_a_mean[spat] = a.mean;
        col_b_min[spat]  = b.min;
        col_b_max[spat]  = b.max;
        col_b_mean[spat] = b.mean;
        col_codes_flags[spat] =
            @as(u32, L.code)
            | (@as(u32, a.code) << 8)
            | (@as(u32, b.code) << 16)
            | (@as(u32, flags) << 24);
        col_L_shape[spat] = packShapeWord(L);
        col_a_shape[spat] = packShapeWord(a);
        col_b_shape[spat] = packShapeWord(b);

        // ── v4: cross-channel covariance per bin ──
        // cov_XY = ⟨ d_X · d_Y ⟩  where d_X = v_X - mean_X (already in L.dev,
        // a.dev, b.dev). Three NEON fmul + faddv per bin, no extra subtract.
        col_fast_cov_La[spat] = @reduce(.Add, L.dev * a.dev) * 0.25;
        col_fast_cov_Lb[spat] = @reduce(.Add, L.dev * b.dev) * 0.25;
        col_fast_cov_ab[spat] = @reduce(.Add, a.dev * b.dev) * 0.25;

        // ── v4: terminal motion magnitude (frame-3 minus frame-0) ──
        // ‖(L,a,b)[t=3] − (L,a,b)[t=0]‖ in LAB Euclidean. Useful for any
        // "moving subject" look without needing per-frame optical flow.
        const dL = v_L[3] - v_L[0];
        const da = v_a[3] - v_a[0];
        const db = v_b[3] - v_b[0];
        col_fast_motion_mag[spat] = @sqrt(dL * dL + da * da + db * db);
    }

    // ── Pass 2: per-channel 4-neighbor spatial autocorrelation post-pass ──
    computeNeighborRho(col_L_mean, col_fast_nbr_rho_L);
    computeNeighborRho(col_a_mean, col_fast_nbr_rho_a);
    computeNeighborRho(col_b_mean, col_fast_nbr_rho_b);

    // ── Pass 3: per-set trailer scalars (lag-1 horizontal autocorr + KL) ──
    out_trailer.* = .{
        .rho1_L = computeRho1Horizontal(col_L_mean),
        .rho1_a = computeRho1Horizontal(col_a_mean),
        .rho1_b = computeRho1Horizontal(col_b_mean),
        .kl_L_to_gaussian = computeKlToGaussian(col_L_mean),
    };
}

// ============================================================================
// v4 helpers — spatial autocorrelation, lag-1 autocorr, Gaussian KL
// ============================================================================

const GRID_DIM: u32 = BIN_COUNT;        // 64
const GRID_SIZE: u32 = SPATIAL_BINS;     // 4096

/// 4-neighbor (N/S/E/W) spatial autocorrelation of a per-bin channel grid.
/// Toroidal at edges so every bin sees 4 neighbors. The per-bin value is
///   ρ[bin] = (C[bin] − μ_C) · (mean_of_4_neighbors − μ_C) / σ_C²
/// where μ_C and σ_C² are computed once over the whole 64×64 grid.
/// Result range ≈ [-1, +1]; sign tells local agreement/disagreement.
fn computeNeighborRho(channel: []const f32, out_rho: []f32) void {
    std.debug.assert(channel.len >= GRID_SIZE);
    std.debug.assert(out_rho.len >= GRID_SIZE);

    // μ and σ² across the entire 64×64 grid (single pass).
    var sum: f32 = 0;
    var i: u32 = 0;
    while (i < GRID_SIZE) : (i += 1) sum += channel[i];
    const mu: f32 = sum / @as(f32, @floatFromInt(GRID_SIZE));

    var ssq: f32 = 0;
    i = 0;
    while (i < GRID_SIZE) : (i += 1) {
        const d = channel[i] - mu;
        ssq += d * d;
    }
    const var_c: f32 = ssq / @as(f32, @floatFromInt(GRID_SIZE));
    const inv_var: f32 = if (var_c > 1e-9) 1.0 / var_c else 0.0;

    // Per-bin loop. Coordinates (x, y) with toroidal wrap; 4 neighbors.
    var y: u32 = 0;
    while (y < GRID_DIM) : (y += 1) {
        const ym = if (y == 0) GRID_DIM - 1 else y - 1;
        const yp = if (y + 1 == GRID_DIM) 0 else y + 1;
        var x: u32 = 0;
        while (x < GRID_DIM) : (x += 1) {
            const xm = if (x == 0) GRID_DIM - 1 else x - 1;
            const xp = if (x + 1 == GRID_DIM) 0 else x + 1;
            const idx = y * GRID_DIM + x;
            const n_mean = 0.25 * (channel[y  * GRID_DIM + xm]
                                + channel[y  * GRID_DIM + xp]
                                + channel[ym * GRID_DIM + x ]
                                + channel[yp * GRID_DIM + x ]);
            out_rho[idx] = (channel[idx] - mu) * (n_mean - mu) * inv_var;
        }
    }
}

/// Global lag-1 horizontal autocorrelation of a per-bin channel grid:
///   ρ₁ = Σ_{x<63, y} (C[x,y] − μ)(C[x+1,y] − μ) / ((63·64) · σ²)
/// Result range [-1, +1]; high = smoothly-varying channel left-to-right.
fn computeRho1Horizontal(channel: []const f32) f32 {
    std.debug.assert(channel.len >= GRID_SIZE);

    var sum: f32 = 0;
    var i: u32 = 0;
    while (i < GRID_SIZE) : (i += 1) sum += channel[i];
    const mu: f32 = sum / @as(f32, @floatFromInt(GRID_SIZE));

    var ssq: f32 = 0;
    i = 0;
    while (i < GRID_SIZE) : (i += 1) {
        const d = channel[i] - mu;
        ssq += d * d;
    }
    const var_c: f32 = ssq / @as(f32, @floatFromInt(GRID_SIZE));
    if (var_c < 1e-9) return 0.0;

    var acc: f32 = 0;
    var pairs: f32 = 0;
    var y: u32 = 0;
    while (y < GRID_DIM) : (y += 1) {
        var x: u32 = 0;
        while (x + 1 < GRID_DIM) : (x += 1) {
            const d0 = channel[y * GRID_DIM + x    ] - mu;
            const d1 = channel[y * GRID_DIM + x + 1] - mu;
            acc += d0 * d1;
            pairs += 1;
        }
    }
    return acc / (pairs * var_c);
}

/// KL-divergence of the empirical channel-mean distribution to its best-fit
/// Gaussian N(μ, σ²). Uses a 16-bin histogram over the [μ−3σ, μ+3σ] range;
/// the Gaussian reference is evaluated at each bin center and normalized.
/// Result is non-negative; 0 ≡ exactly Gaussian-shaped on this grid.
fn computeKlToGaussian(channel: []const f32) f32 {
    std.debug.assert(channel.len >= GRID_SIZE);
    const N: u32 = 16;
    const Nf: f32 = @floatFromInt(N);

    var sum: f32 = 0;
    var i: u32 = 0;
    while (i < GRID_SIZE) : (i += 1) sum += channel[i];
    const mu: f32 = sum / @as(f32, @floatFromInt(GRID_SIZE));

    var ssq: f32 = 0;
    i = 0;
    while (i < GRID_SIZE) : (i += 1) {
        const d = channel[i] - mu;
        ssq += d * d;
    }
    const var_c: f32 = ssq / @as(f32, @floatFromInt(GRID_SIZE));
    if (var_c < 1e-9) return 0.0;
    const sigma: f32 = @sqrt(var_c);

    const lo: f32 = mu - 3.0 * sigma;
    const hi: f32 = mu + 3.0 * sigma;
    const bin_w: f32 = (hi - lo) / Nf;
    if (bin_w < 1e-9) return 0.0;

    // Build empirical histogram in 16 bins (clamped).
    var hist: [16]f32 = .{0} ** 16;
    i = 0;
    while (i < GRID_SIZE) : (i += 1) {
        const v = channel[i];
        const t = (v - lo) / bin_w;
        const k_i: i32 = @intFromFloat(@floor(t));
        const k_clamp: u32 = if (k_i < 0) 0 else if (k_i >= 16) 15 else @intCast(k_i);
        hist[k_clamp] += 1.0;
    }
    var inv_total: f32 = 1.0 / @as(f32, @floatFromInt(GRID_SIZE));
    var k: u32 = 0;
    while (k < N) : (k += 1) hist[k] *= inv_total;

    // Build Gaussian reference at bin centers.
    var gref: [16]f32 = .{0} ** 16;
    var gsum: f32 = 0;
    const two_var = 2.0 * var_c;
    k = 0;
    while (k < N) : (k += 1) {
        const center: f32 = lo + (@as(f32, @floatFromInt(k)) + 0.5) * bin_w;
        const d = center - mu;
        const g = @exp(-(d * d) / two_var);
        gref[k] = g;
        gsum += g;
    }
    inv_total = 1.0 / gsum;
    k = 0;
    while (k < N) : (k += 1) gref[k] *= inv_total;

    // KL(P || Q) = Σ P log(P / Q); skip zeros to avoid -inf.
    var kl: f32 = 0;
    k = 0;
    while (k < N) : (k += 1) {
        if (hist[k] > 1e-9 and gref[k] > 1e-9) {
            kl += hist[k] * @log(hist[k] / gref[k]);
        }
    }
    return kl;
}

// ============================================================================
// v4 slow-scale fold — 16 sets × per-bin → per-bin slow statistics
// ============================================================================

/// Per-session "slow" scalars emitted by `slowFoldSession`. Mirror to extern
/// for the C ABI in root.zig.
pub const SlowScalars = extern struct {
    /// Global lag-1 autocorrelation of the per-set channel-mean sequence
    /// (length 16, one mean per set). Range [-1, +1]: high = stable session.
    slow_rho1_L: f32,
    slow_rho1_a: f32,
    slow_rho1_b: f32,
    /// Between/within hierarchical variance ratio ν = σ²_between / σ²_total
    /// per Theorem 6 (Fahmy Ch.1). Range [0, 1]; 0 = all variance within sets,
    /// 1 = all variance between sets. L-channel only (single signature scalar).
    nu_L: f32,
};

/// Pack of input columns for slow-scale fold. The caller hands 16 sets worth
/// of L_mean, a_mean, b_mean arrays — pointers only, no copy.
pub const SlowFoldInput = struct {
    L_means: [16][*]const f32,
    a_means: [16][*]const f32,
    b_means: [16][*]const f32,
};

/// Fold 16 sets' per-bin channel means into per-bin slow statistics.
///
/// For each spatial bin (i,j) we gather 16 channel-mean samples (one per set)
/// and run the *same* statistical pipeline as the fast scale: mean, variance,
/// covariance, motion magnitude — only N = 16 instead of N = 4. SIMD lane
/// width is @Vector(16, f32) which fits comfortably on ARM64 NEON.
pub fn slowFoldSession(
    inp: SlowFoldInput,
    out_slow_L_mean: []f32,
    out_slow_a_mean: []f32,
    out_slow_b_mean: []f32,
    out_slow_L_var:  []f32,
    out_slow_a_var:  []f32,
    out_slow_b_var:  []f32,
    out_slow_cov_La: []f32,
    out_slow_cov_Lb: []f32,
    out_slow_cov_ab: []f32,
    out_slow_motion: []f32,
    out_scalars:     *SlowScalars,
) void {
    std.debug.assert(out_slow_L_mean.len >= GRID_SIZE);
    std.debug.assert(out_slow_motion.len >= GRID_SIZE);

    const inv16: f32 = 1.0 / 16.0;

    var spat: u32 = 0;
    while (spat < GRID_SIZE) : (spat += 1) {
        // Gather 16 set-mean samples for each channel into N=16 vectors.
        var v_L: @Vector(16, f32) = undefined;
        var v_a: @Vector(16, f32) = undefined;
        var v_b: @Vector(16, f32) = undefined;
        comptime var s: u32 = 0;
        inline while (s < 16) : (s += 1) {
            v_L[s] = inp.L_means[s][spat];
            v_a[s] = inp.a_means[s][spat];
            v_b[s] = inp.b_means[s][spat];
        }

        const mean_L = @reduce(.Add, v_L) * inv16;
        const mean_a = @reduce(.Add, v_a) * inv16;
        const mean_b = @reduce(.Add, v_b) * inv16;
        const d_L = v_L - @as(@Vector(16, f32), @splat(mean_L));
        const d_a = v_a - @as(@Vector(16, f32), @splat(mean_a));
        const d_b = v_b - @as(@Vector(16, f32), @splat(mean_b));
        const var_L = @reduce(.Add, d_L * d_L) * inv16;
        const var_a = @reduce(.Add, d_a * d_a) * inv16;
        const var_b = @reduce(.Add, d_b * d_b) * inv16;
        const cov_La = @reduce(.Add, d_L * d_a) * inv16;
        const cov_Lb = @reduce(.Add, d_L * d_b) * inv16;
        const cov_ab = @reduce(.Add, d_a * d_b) * inv16;

        const dL = v_L[15] - v_L[0];
        const da = v_a[15] - v_a[0];
        const db = v_b[15] - v_b[0];
        const motion = @sqrt(dL * dL + da * da + db * db);

        out_slow_L_mean[spat] = mean_L;
        out_slow_a_mean[spat] = mean_a;
        out_slow_b_mean[spat] = mean_b;
        out_slow_L_var [spat] = var_L;
        out_slow_a_var [spat] = var_a;
        out_slow_b_var [spat] = var_b;
        out_slow_cov_La[spat] = cov_La;
        out_slow_cov_Lb[spat] = cov_Lb;
        out_slow_cov_ab[spat] = cov_ab;
        out_slow_motion[spat] = motion;
    }

    // ── Session-level scalars ──
    // ν (between/within decomposition of L-channel, Theorem 6 Ch.1, Fahmy).
    // σ²_between = variance of the 16 set-level L means (treating each
    //              spatial bin's per-set value as a sample). We use the
    //              grid-mean per set as the canonical "set mean".
    var set_mean_L: [16]f32 = .{0} ** 16;
    var s: u32 = 0;
    while (s < 16) : (s += 1) {
        var acc: f64 = 0;
        var i: u32 = 0;
        while (i < GRID_SIZE) : (i += 1) acc += inp.L_means[s][i];
        set_mean_L[s] = @floatCast(acc / @as(f64, @floatFromInt(GRID_SIZE)));
    }
    var grand_mean: f64 = 0;
    s = 0;
    while (s < 16) : (s += 1) grand_mean += set_mean_L[s];
    grand_mean *= 1.0 / 16.0;
    var var_between: f64 = 0;
    s = 0;
    while (s < 16) : (s += 1) {
        const d = @as(f64, set_mean_L[s]) - grand_mean;
        var_between += d * d;
    }
    var_between *= 1.0 / 16.0;
    // σ²_within: mean across the 16 sets of within-set SPATIAL variance of
    // the L_mean grid (variance of {L_means[s][i] : i ∈ grid} for each s).
    // Textbook Theorem 6 (Fahmy Ch.1): σ²_total = σ²_between + σ²_within.
    var var_within: f64 = 0;
    var i: u32 = 0;
    s = 0;
    while (s < 16) : (s += 1) {
        var ssq: f64 = 0;
        i = 0;
        while (i < GRID_SIZE) : (i += 1) {
            const d = @as(f64, inp.L_means[s][i]) - @as(f64, set_mean_L[s]);
            ssq += d * d;
        }
        var_within += ssq / @as(f64, @floatFromInt(GRID_SIZE));
    }
    var_within *= 1.0 / 16.0;
    const total: f64 = var_between + var_within;
    out_scalars.nu_L = if (total > 1e-9)
        @floatCast(var_between / total)
    else
        0.0;

    // Slow lag-1 autocorrelation: compute over the 16-set sequence of
    // set-mean values for each channel.
    var set_mean_a: [16]f32 = .{0} ** 16;
    var set_mean_b: [16]f32 = .{0} ** 16;
    s = 0;
    while (s < 16) : (s += 1) {
        var ac: f64 = 0;
        var bc: f64 = 0;
        i = 0;
        while (i < GRID_SIZE) : (i += 1) {
            ac += inp.a_means[s][i];
            bc += inp.b_means[s][i];
        }
        const inv = 1.0 / @as(f64, @floatFromInt(GRID_SIZE));
        set_mean_a[s] = @floatCast(ac * inv);
        set_mean_b[s] = @floatCast(bc * inv);
    }
    out_scalars.slow_rho1_L = rho1Sequence16(&set_mean_L);
    out_scalars.slow_rho1_a = rho1Sequence16(&set_mean_a);
    out_scalars.slow_rho1_b = rho1Sequence16(&set_mean_b);
}

/// Lag-1 autocorrelation of a 16-element sequence (no SIMD needed; trivial).
fn rho1Sequence16(seq: *const [16]f32) f32 {
    var mu: f32 = 0;
    var k: u32 = 0;
    while (k < 16) : (k += 1) mu += seq[k];
    mu *= 1.0 / 16.0;
    var ssq: f32 = 0;
    k = 0;
    while (k < 16) : (k += 1) {
        const d = seq[k] - mu;
        ssq += d * d;
    }
    const var_s = ssq * (1.0 / 16.0);
    if (var_s < 1e-9) return 0.0;
    var acc: f32 = 0;
    k = 0;
    while (k + 1 < 16) : (k += 1) {
        acc += (seq[k] - mu) * (seq[k + 1] - mu);
    }
    return acc / (15.0 * var_s);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Test helper: full ChannelStats literal in one call. Keeps the existing
/// flag-tests readable now that ChannelStats carries five extra fields.
fn makeStats(
    min_v: f32, max_v: f32, mean_v: f32,
    q: [4]u8,
    sigma: f32, gamma3: f32, gamma4: f32, chi2: f32,
    cls: ShapeClass,
) ChannelStats {
    return .{
        .min = min_v, .max = max_v, .mean = mean_v,
        .code = 0, .q = q,
        .sigma = sigma, .gamma3 = gamma3, .gamma4 = gamma4, .chi2 = chi2,
        .shape_class = cls,
        .dev = @splat(0.0),
    };
}

test "encodeChannel: constant input → min=max=mean, code=0, flat q" {
    const v: @Vector(4, f32) = .{ 50.0, 50.0, 50.0, 50.0 };
    const c = encodeChannel(v, .mean);
    try testing.expectApproxEqAbs(@as(f32, 50.0), c.min, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 50.0), c.max, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 50.0), c.mean, 1e-6);
    try testing.expectEqual(@as(u8, 0), c.code);
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, c.q);
}

test "encodeChannel: monotonic increasing → q=(0,1,2,3), code=0xE4" {
    // 0.0, 0.333..., 0.666..., 1.0 in normalized space.
    const v: @Vector(4, f32) = .{ 0.0, 1.0, 2.0, 3.0 };
    const c = encodeChannel(v, .mean);
    try testing.expectEqual([4]u8{ 0, 1, 2, 3 }, c.q);
    // code = 0 | 1<<2 | 2<<4 | 3<<6 = 0 + 4 + 32 + 192 = 228 = 0xE4
    try testing.expectEqual(@as(u8, 0xE4), c.code);
}

test "encodeChannel: monotonic decreasing → q=(3,2,1,0), code=0x1B" {
    const v: @Vector(4, f32) = .{ 3.0, 2.0, 1.0, 0.0 };
    const c = encodeChannel(v, .mean);
    try testing.expectEqual([4]u8{ 3, 2, 1, 0 }, c.q);
    // code = 3 | 2<<2 | 1<<4 | 0<<6 = 3 + 8 + 16 + 0 = 27 = 0x1B
    try testing.expectEqual(@as(u8, 0x1B), c.code);
}

test "encodeChannel: pulse at frame 1 → q=(0,3,1,0)" {
    const v: @Vector(4, f32) = .{ 0.0, 30.0, 10.0, 0.0 };
    const c = encodeChannel(v, .mean);
    try testing.expectEqual(@as(f32, 0.0), c.min);
    try testing.expectEqual(@as(f32, 30.0), c.max);
    try testing.expectEqual(@as(u8, 3), c.q[1]);  // peak
    try testing.expect(c.q[1] > c.q[0]);
    try testing.expect(c.q[1] > c.q[2]);
}

test "computeFlags: constant L → static" {
    const L = makeStats(50.0, 50.5, 50.2, .{ 0, 0, 0, 0 }, 0.25, 0.0, 0.0, 28.0, .symmetric);
    const a = makeStats(0.0, 0.0, 0.0, .{ 0, 0, 0, 0 }, 0.0, 0.0, 0.0, 28.0, .symmetric);
    const b = makeStats(0.0, 0.0, 0.0, .{ 0, 0, 0, 0 }, 0.0, 0.0, 0.0, 28.0, .symmetric);
    const flags = computeFlags(L, a, b);
    try testing.expect((flags & (1 << 0)) != 0);   // FLAG_STATIC
    try testing.expect((flags & (1 << 1)) == 0);   // not monotonic increasing (all equal)
}

test "computeFlags: increasing L → monotonic_increasing" {
    const L = makeStats(0.0, 100.0, 50.0, .{ 0, 1, 2, 3 }, 37.27, 0.0, -1.36, 1.33, .symmetric);
    const a = makeStats(0.0, 0.0, 0.0, .{ 0, 0, 0, 0 }, 0.0, 0.0, 0.0, 28.0, .symmetric);
    const b = makeStats(0.0, 0.0, 0.0, .{ 0, 0, 0, 0 }, 0.0, 0.0, 0.0, 28.0, .symmetric);
    const flags = computeFlags(L, a, b);
    try testing.expect((flags & (1 << 1)) != 0);   // FLAG_MONOTONIC_INCREASING
    try testing.expect((flags & (1 << 2)) == 0);   // not decreasing
}

test "computeFlags: high chroma" {
    const L = makeStats(50.0, 50.0, 50.0, .{ 0, 0, 0, 0 }, 0.0, 0.0, 0.0, 28.0, .symmetric);
    const a = makeStats(30.0, 30.0, 30.0, .{ 0, 0, 0, 0 }, 0.0, 0.0, 0.0, 28.0, .symmetric);
    const b = makeStats(30.0, 30.0, 30.0, .{ 0, 0, 0, 0 }, 0.0, 0.0, 0.0, 28.0, .symmetric);
    const flags = computeFlags(L, a, b);
    // sqrt(30² + 30²) ≈ 42.4 > 25
    try testing.expect((flags & (1 << 4)) != 0);   // FLAG_HIGH_CHROMA
}

test "computeFlags: high luma + low luma exclusive" {
    const high_L = makeStats(80.0, 80.0, 80.0, .{ 0, 0, 0, 0 }, 0.0, 0.0, 0.0, 28.0, .symmetric);
    const a0 = makeStats(0.0, 0.0, 0.0, .{ 0, 0, 0, 0 }, 0.0, 0.0, 0.0, 28.0, .symmetric);
    const f_high = computeFlags(high_L, a0, a0);
    try testing.expect((f_high & (1 << 5)) != 0);  // HIGH_LUMA
    try testing.expect((f_high & (1 << 6)) == 0);  // not LOW_LUMA

    const low_L = makeStats(10.0, 10.0, 10.0, .{ 0, 0, 0, 0 }, 0.0, 0.0, 0.0, 28.0, .symmetric);
    const f_low = computeFlags(low_L, a0, a0);
    try testing.expect((f_low & (1 << 5)) == 0);
    try testing.expect((f_low & (1 << 6)) != 0);   // LOW_LUMA
}

// ============================================================================
// v3 SHAPE tests — Bin(3, 0.5) χ², skewness, kurtosis, classification, pack
// ============================================================================

test "shape: uniform ramp (0,1,2,3) → γ₃≈0, γ₄<0, SYMMETRIC, low χ²" {
    // Quantizing values 0, 25, 50, 75 produces q = (0, 1, 2, 3). Histogram
    // (1,1,1,1) vs expected (.5, 1.5, 1.5, .5) → χ² = .5 + 1/6 + 1/6 + .5 ≈ 1.33.
    // This is the textbook "deltoid corner" — most-symmetric n=4 sample.
    const v: @Vector(4, f32) = .{ 0.0, 25.0, 50.0, 75.0 };
    const c = encodeChannel(v, .mean);
    try testing.expectApproxEqAbs(@as(f32, 0.0),  c.gamma3, 0.05);
    try testing.expect(c.gamma4 < 0.0);          // platykurtic
    try testing.expectEqual(ShapeClass.symmetric, c.shape_class);
    try testing.expectApproxEqAbs(@as(f32, 1.333), c.chi2, 0.01);
}

test "shape: constant input → σ=0, γ₃=0, γ₄=0, high χ²" {
    // Degenerate trajectory: q = (0,0,0,0) → histogram (4,0,0,0).
    // χ² = 3.5²/.5 + 1.5²/1.5 + 1.5²/1.5 + .5²/.5 = 24.5 + 1.5 + 1.5 + .5 = 28.
    const v: @Vector(4, f32) = .{ 50.0, 50.0, 50.0, 50.0 };
    const c = encodeChannel(v, .mean);
    try testing.expectEqual(@as(f32, 0.0), c.sigma);
    try testing.expectEqual(@as(f32, 0.0), c.gamma3);
    try testing.expectEqual(@as(f32, 0.0), c.gamma4);
    try testing.expectApproxEqAbs(@as(f32, 28.0), c.chi2, 0.01);
    try testing.expectEqual(ShapeClass.symmetric, c.shape_class);
}

test "shape: single high outlier (0,0,0,3) → RIGHT_SKEW" {
    // Three samples at the floor + one at the ceiling — long right tail in
    // value space (regardless of temporal position of the spike). γ₃ > 0.
    // Histogram (3,0,0,1) → moderate χ².
    const v: @Vector(4, f32) = .{ 0.0, 0.0, 0.0, 3.0 };
    const c = encodeChannel(v, .mean);
    try testing.expect(c.gamma3 > 0.5);          // right tail
    try testing.expectEqual(ShapeClass.right_skew, c.shape_class);
}

test "shape: temporally-leading high outlier (3,0,0,0) → still RIGHT_SKEW" {
    // Same VALUE-distribution as the test above (just shuffled in time).
    // γ₃ is histogram-based so cannot tell early-vs-late — that's
    // FLAG_TEMPORAL_PULSE's job. Skew sign is determined by the asymmetry
    // of values, not their ordering.
    const v: @Vector(4, f32) = .{ 3.0, 0.0, 0.0, 0.0 };
    const c = encodeChannel(v, .mean);
    try testing.expect(c.gamma3 > 0.5);
    try testing.expectEqual(ShapeClass.right_skew, c.shape_class);
}

test "shape: single low outlier (3,3,3,0) → LEFT_SKEW" {
    // Three samples at the ceiling + one at the floor — long left tail in
    // value space. γ₃ < 0.
    const v: @Vector(4, f32) = .{ 3.0, 3.0, 3.0, 0.0 };
    const c = encodeChannel(v, .mean);
    try testing.expect(c.gamma3 < -0.5);
    try testing.expectEqual(ShapeClass.left_skew, c.shape_class);
}

test "shape: bimodal (0,0,3,3) → BIMODAL via deeply-platykurtic γ₄" {
    // Two clusters at opposite ends → q = (0,0,3,3) → histogram (2,0,0,2).
    // γ₃ = 0 (symmetric); γ₄ = -2 (deeply platykurtic — the n=4 kurtosis
    // floor for a symmetric two-point sample). For n=4 the kurtosis space
    // is mostly negative; BIMODAL is the *most* negative corner.
    // χ² = 1.5²/.5 + 1.5²/1.5 + 1.5²/1.5 + 1.5²/.5 = 4.5 + 1.5 + 1.5 + 4.5 = 12.
    const v: @Vector(4, f32) = .{ 0.0, 0.0, 3.0, 3.0 };
    const c = encodeChannel(v, .mean);
    try testing.expectApproxEqAbs(@as(f32, 0.0), c.gamma3, 0.05);
    try testing.expectApproxEqAbs(@as(f32, -2.0), c.gamma4, 0.05);
    try testing.expectEqual(ShapeClass.bimodal, c.shape_class);
    try testing.expectApproxEqAbs(@as(f32, 12.0), c.chi2, 0.01);
}

test "shape: pulse (0,3,3,0) — same histogram as bimodal, same χ²" {
    // After per-bin normalization, q = (0,3,3,0). Histogram (2,0,0,2) —
    // identical to the bimodal test above. χ² is histogram-based so it
    // can't distinguish temporal order; that's what the EXISTING
    // FLAG_TEMPORAL_PULSE is for. This test pins the (intentional)
    // order-blindness of the shape-word χ².
    const v: @Vector(4, f32) = .{ 0.0, 3.0, 3.0, 0.0 };
    const c = encodeChannel(v, .mean);
    try testing.expectApproxEqAbs(@as(f32, 12.0), c.chi2, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.0), c.gamma3, 0.05);
}

test "shape: FLAG_BEAUTY fires for uniform ramp, not for bimodal" {
    var lab = [_]f32{0.0} ** (FLOATS_PER_FRAME * FRAMES_PER_SET);

    // Bin 0: uniform ramp on L → χ² ≈ 1.33 → FLAG_BEAUTY set.
    const ramp: [4]f32 = .{ 0.0, 25.0, 50.0, 75.0 };
    inline for (0..4) |f| { lab[f * FLOATS_PER_FRAME + 0 * 3 + 0] = ramp[f]; }

    // Bin 1: bimodal on L → χ² ≈ 12 → FLAG_BEAUTY clear.
    const bim: [4]f32 = .{ 0.0, 0.0, 75.0, 75.0 };
    inline for (0..4) |f| { lab[f * FLOATS_PER_FRAME + 1 * 3 + 0] = bim[f]; }

    var L_min  = [_]f32{0} ** SPATIAL_BINS;
    var L_max  = [_]f32{0} ** SPATIAL_BINS;
    var L_mean = [_]f32{0} ** SPATIAL_BINS;
    var a_min  = [_]f32{0} ** SPATIAL_BINS;
    var a_max  = [_]f32{0} ** SPATIAL_BINS;
    var a_mean = [_]f32{0} ** SPATIAL_BINS;
    var b_min  = [_]f32{0} ** SPATIAL_BINS;
    var b_max  = [_]f32{0} ** SPATIAL_BINS;
    var b_mean = [_]f32{0} ** SPATIAL_BINS;
    var cf     = [_]u32{0} ** SPATIAL_BINS;
    var L_shape = [_]u32{0} ** SPATIAL_BINS;
    var a_shape = [_]u32{0} ** SPATIAL_BINS;
    var b_shape = [_]u32{0} ** SPATIAL_BINS;
    var fc_La  = [_]f32{0} ** SPATIAL_BINS;
    var fc_Lb  = [_]f32{0} ** SPATIAL_BINS;
    var fc_ab  = [_]f32{0} ** SPATIAL_BINS;
    var fn_L   = [_]f32{0} ** SPATIAL_BINS;
    var fn_a   = [_]f32{0} ** SPATIAL_BINS;
    var fn_b   = [_]f32{0} ** SPATIAL_BINS;
    var fmot   = [_]f32{0} ** SPATIAL_BINS;
    var trailer: PerSetTrailer = undefined;

    encodeSet(&lab, &L_min, &L_max, &L_mean,
              &a_min, &a_max, &a_mean,
              &b_min, &b_max, &b_mean, &cf,
              &L_shape, &a_shape, &b_shape,
              &fc_La, &fc_Lb, &fc_ab,
              &fn_L, &fn_a, &fn_b, &fmot, &trailer, .mean);

    // Bin 0: FLAG_BEAUTY set.
    try testing.expect((cf[0] & (FLAG_BEAUTY << 24)) != 0);
    // Bin 1: FLAG_BEAUTY clear.
    try testing.expectEqual(@as(u32, 0), cf[1] & (FLAG_BEAUTY << 24));
}

test "packShapeWord: round-trips within quantization step" {
    const c: ChannelStats = .{
        .min = 0.0, .max = 100.0, .mean = 50.0,
        .code = 0, .q = .{ 0, 1, 2, 3 },
        .sigma = 27.95, .gamma3 = -0.6, .gamma4 = 1.5, .chi2 = 2.5,
        .shape_class = .left_skew,
        .dev = @splat(0.0),
    };
    const word = packShapeWord(c);

    // Decode and verify each field round-trips inside its quantization step.
    const sigma_back: f32 = @as(f32, @floatFromInt(word & 0xFF)) / 2.0;
    const gamma3_back: f32 = @as(f32, @floatFromInt(@as(i8, @bitCast(@as(u8, @intCast((word >> 8) & 0xFF)))))) / 64.0;
    const gamma4_back: f32 = @as(f32, @floatFromInt(@as(i8, @bitCast(@as(u8, @intCast((word >> 16) & 0xFF)))))) / 32.0;
    const chi2_back: f32 = @as(f32, @floatFromInt((word >> 24) & 0x3F)) / 2.0;
    const cls_back: u2 = @intCast((word >> 30) & 0x3);

    try testing.expectApproxEqAbs(c.sigma,  sigma_back,  0.5);
    try testing.expectApproxEqAbs(c.gamma3, gamma3_back, 1.0 / 64.0);
    try testing.expectApproxEqAbs(c.gamma4, gamma4_back, 1.0 / 32.0);
    try testing.expectApproxEqAbs(c.chi2,   chi2_back,   0.5);
    try testing.expectEqual(@intFromEnum(c.shape_class), @as(u32, cls_back));
}

test "encodeSet: all-zero input → all-zero output (smoke test)" {
    const allocator = testing.allocator;
    const frames = try allocator.alloc(f32, FLOATS_PER_FRAME * FRAMES_PER_SET);
    defer allocator.free(frames);
    @memset(frames, 0.0);

    var L_min  = [_]f32{0} ** SPATIAL_BINS;
    var L_max  = [_]f32{0} ** SPATIAL_BINS;
    var L_mean = [_]f32{0} ** SPATIAL_BINS;
    var a_min  = [_]f32{0} ** SPATIAL_BINS;
    var a_max  = [_]f32{0} ** SPATIAL_BINS;
    var a_mean = [_]f32{0} ** SPATIAL_BINS;
    var b_min  = [_]f32{0} ** SPATIAL_BINS;
    var b_max  = [_]f32{0} ** SPATIAL_BINS;
    var b_mean = [_]f32{0} ** SPATIAL_BINS;
    var cf     = [_]u32{0} ** SPATIAL_BINS;
    var L_shape = [_]u32{0} ** SPATIAL_BINS;
    var a_shape = [_]u32{0} ** SPATIAL_BINS;
    var b_shape = [_]u32{0} ** SPATIAL_BINS;
    var fc_La  = [_]f32{0} ** SPATIAL_BINS;
    var fc_Lb  = [_]f32{0} ** SPATIAL_BINS;
    var fc_ab  = [_]f32{0} ** SPATIAL_BINS;
    var fn_L   = [_]f32{0} ** SPATIAL_BINS;
    var fn_a   = [_]f32{0} ** SPATIAL_BINS;
    var fn_b   = [_]f32{0} ** SPATIAL_BINS;
    var fmot   = [_]f32{0} ** SPATIAL_BINS;
    var trailer: PerSetTrailer = undefined;

    encodeSet(frames, &L_min, &L_max, &L_mean,
              &a_min, &a_max, &a_mean,
              &b_min, &b_max, &b_mean, &cf,
              &L_shape, &a_shape, &b_shape,
              &fc_La, &fc_Lb, &fc_ab,
              &fn_L, &fn_a, &fn_b, &fmot, &trailer, .mean);

    // Trailer on all-zero input: degenerate grid → rho1 = 0, KL = 0.
    try testing.expectEqual(@as(f32, 0.0), trailer.rho1_L);
    try testing.expectEqual(@as(f32, 0.0), trailer.kl_L_to_gaussian);
    // v4 covariance columns on all-zero input: all zero.
    try testing.expectEqual(@as(f32, 0.0), fc_La[0]);
    try testing.expectEqual(@as(f32, 0.0), fmot[0]);

    // Every bin: min=max=mean=0, code=0, flags has FLAG_STATIC + FLAG_LOW_LUMA set.
    // FLAG_BEAUTY does NOT fire — a constant trajectory quantizes to (0,0,0,0)
    // which gives observed (4,0,0,0) vs expected (.5,1.5,1.5,.5); χ² ≈ 28 ≫ 4.
    const expected_flags: u32 = (FLAG_STATIC | FLAG_LOW_LUMA) << 24;
    for (0..SPATIAL_BINS) |i| {
        try testing.expectEqual(@as(f32, 0.0), L_mean[i]);
        try testing.expectEqual(expected_flags, cf[i]);
        // Shape word: all stats zero except chi2 (which packs to its u6 quantum).
        // shape_class = SYMMETRIC (0), gamma3 = gamma4 = 0, sigma = 0.
        // chi2 = ~28 → clamped to 63 via * 2 then min(63) → 56 in 6 bits.
        // Just sanity-check that the cls bits are 0 (SYMMETRIC).
        try testing.expectEqual(@as(u32, 0), (L_shape[i] >> 30) & 0x3);
    }
}

// ============================================================================
// v4 SCALE tests — fast covariance, motion magnitude, neighbor autocorr, KL,
// slow-fold session (textbook sufficient statistics across two time scales).
// ============================================================================

test "v4 fast_cov: L=a perfectly correlated → cov_La ≈ var_L" {
    // Build one bin with identical L, a trajectory: q = (0, 1, 2, 3) in both.
    // ChannelStats.dev for (0,1,2,3) is (-1.5, -0.5, 0.5, 1.5). Reduce of
    // d·d = 5 / 4 = 1.25 → var = 1.25. cov_La should equal var since L = a.
    const v_L: @Vector(4, f32) = .{ 0.0, 1.0, 2.0, 3.0 };
    const v_a: @Vector(4, f32) = .{ 0.0, 1.0, 2.0, 3.0 };
    const sL = encodeChannel(v_L, .mean);
    const sa = encodeChannel(v_a, .mean);
    const cov = @reduce(.Add, sL.dev * sa.dev) * 0.25;
    try testing.expectApproxEqAbs(@as(f32, 1.25), cov, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.25), sL.sigma * sL.sigma, 1e-6);
}

test "v4 fast_cov: L,a anticorrelated → cov_La < 0" {
    const v_L: @Vector(4, f32) = .{ 0.0, 1.0, 2.0, 3.0 };
    const v_a: @Vector(4, f32) = .{ 3.0, 2.0, 1.0, 0.0 };
    const sL = encodeChannel(v_L, .mean);
    const sa = encodeChannel(v_a, .mean);
    const cov = @reduce(.Add, sL.dev * sa.dev) * 0.25;
    try testing.expect(cov < 0.0);
}

test "v4 fast_cov: constant input → cov_La = 0" {
    const v_L: @Vector(4, f32) = .{ 50.0, 50.0, 50.0, 50.0 };
    const v_a: @Vector(4, f32) = .{ 7.0,  7.0,  7.0,  7.0  };
    const sL = encodeChannel(v_L, .mean);
    const sa = encodeChannel(v_a, .mean);
    const cov = @reduce(.Add, sL.dev * sa.dev) * 0.25;
    try testing.expectApproxEqAbs(@as(f32, 0.0), cov, 1e-6);
}

test "v4 motion_mag: terminal drift from frame 0 to frame 3" {
    // L drift = 3, a drift = 4 → magnitude = 5 (3-4-5 triangle), b = 0.
    const v_L: @Vector(4, f32) = .{ 0.0, 1.0, 2.0, 3.0 };
    const v_a: @Vector(4, f32) = .{ 0.0, 0.0, 0.0, 4.0 };
    const v_b: @Vector(4, f32) = .{ 0.0, 0.0, 0.0, 0.0 };
    const dL = v_L[3] - v_L[0];
    const da = v_a[3] - v_a[0];
    const db = v_b[3] - v_b[0];
    const mag = @sqrt(dL * dL + da * da + db * db);
    try testing.expectApproxEqAbs(@as(f32, 5.0), mag, 1e-6);
}

test "v4 neighbor_rho: uniform field → 0" {
    var grid = [_]f32{42.0} ** SPATIAL_BINS;
    var rho  = [_]f32{99.0} ** SPATIAL_BINS;
    computeNeighborRho(&grid, &rho);
    // Constant grid: σ² = 0 → inv_var = 0 → all rho values zero.
    try testing.expectEqual(@as(f32, 0.0), rho[0]);
    try testing.expectEqual(@as(f32, 0.0), rho[2048]);
}

test "v4 neighbor_rho: smooth horizontal gradient → +1 (locally agreeing)" {
    var grid = [_]f32{0.0} ** SPATIAL_BINS;
    var y: u32 = 0;
    while (y < 64) : (y += 1) {
        var x: u32 = 0;
        while (x < 64) : (x += 1) {
            grid[y * 64 + x] = @floatFromInt(x);
        }
    }
    var rho  = [_]f32{0.0} ** SPATIAL_BINS;
    computeNeighborRho(&grid, &rho);
    // Take the bin at (32, 32): C[32] − μ_C = (32 − 31.5) = 0.5. Its
    // 4-neighbors average to (31+33+32+32)/4 = 32 = C[32] − 0 → neighbor
    // mean − μ = 0.5. Product = 0.25; σ_C² for x ∈ 0..63 = 341.25.
    // ρ = 0.25 / 341.25 ≈ 0.000733 — small but positive, confirms sign.
    try testing.expect(rho[32 * 64 + 32] > 0.0);
}

test "v4 neighbor_rho: checkerboard → strongly negative" {
    var grid = [_]f32{0.0} ** SPATIAL_BINS;
    var y: u32 = 0;
    while (y < 64) : (y += 1) {
        var x: u32 = 0;
        while (x < 64) : (x += 1) {
            grid[y * 64 + x] = if ((x + y) % 2 == 0) 0.0 else 1.0;
        }
    }
    var rho  = [_]f32{0.0} ** SPATIAL_BINS;
    computeNeighborRho(&grid, &rho);
    // For a checkerboard with toroidal wrap (even grid): every bin is
    // surrounded by 4 neighbors of the opposite color. Take a "0" bin:
    // its neighbors mean = 1, μ = 0.5, σ² = 0.25.
    // ρ = (0 − 0.5)(1 − 0.5) / 0.25 = -1 exactly. Same for "1" bins.
    try testing.expectApproxEqAbs(@as(f32, -1.0), rho[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -1.0), rho[2049], 1e-4);
}

test "v4 rho1: smooth ramp → near +1" {
    var grid = [_]f32{0.0} ** SPATIAL_BINS;
    var y: u32 = 0;
    while (y < 64) : (y += 1) {
        var x: u32 = 0;
        while (x < 64) : (x += 1) {
            grid[y * 64 + x] = @floatFromInt(x);
        }
    }
    const r = computeRho1Horizontal(&grid);
    // A pure x-ramp has near-perfect horizontal autocorrelation. For width
    // 64 with 63 lag-1 pairs/row the analytical ρ₁ ≈ 0.969 (not 1.0
    // because the 63 lag products miss one tail value per row).
    try testing.expect(r > 0.95);
}

test "v4 rho1: constant grid → 0 (no signal)" {
    var grid = [_]f32{17.0} ** SPATIAL_BINS;
    const r = computeRho1Horizontal(&grid);
    try testing.expectEqual(@as(f32, 0.0), r);
}

test "v4 kl_to_gaussian: constant grid → 0" {
    var grid = [_]f32{42.0} ** SPATIAL_BINS;
    const kl = computeKlToGaussian(&grid);
    try testing.expectEqual(@as(f32, 0.0), kl);
}

test "v4 kl_to_gaussian: Gaussian-shaped data → small" {
    // Build a synthetic "approximately Gaussian" grid by sampling a discrete
    // bell curve. Box-Muller-lite: deterministic, mean=50, sigma≈10.
    var grid = [_]f32{0.0} ** SPATIAL_BINS;
    var i: u32 = 0;
    while (i < SPATIAL_BINS) : (i += 1) {
        // Quasi-normal: sum of 6 uniforms in [-1, +1] approximates N(0,2).
        var s: f32 = 0;
        var k: u32 = 0;
        while (k < 6) : (k += 1) {
            const u: f32 = @as(f32, @floatFromInt((i * 31 + k * 7) % 1009)) / 1009.0;
            s += u * 2.0 - 1.0;
        }
        grid[i] = 50.0 + s * 10.0;
    }
    const kl = computeKlToGaussian(&grid);
    // Box-Muller-lite is approximately Gaussian; KL should be < 1 bit.
    try testing.expect(kl < 1.0);
}

test "v4 slow_fold: 16 identical sets → slow_var = 0, slow_motion = 0" {
    var rep_L = [_]f32{50.0} ** SPATIAL_BINS;
    var rep_a = [_]f32{0.0}  ** SPATIAL_BINS;
    var rep_b = [_]f32{0.0}  ** SPATIAL_BINS;
    var inp: SlowFoldInput = undefined;
    var s: u32 = 0;
    while (s < 16) : (s += 1) {
        inp.L_means[s] = &rep_L;
        inp.a_means[s] = &rep_a;
        inp.b_means[s] = &rep_b;
    }

    var sL_mean = [_]f32{0} ** SPATIAL_BINS;
    var sa_mean = [_]f32{0} ** SPATIAL_BINS;
    var sb_mean = [_]f32{0} ** SPATIAL_BINS;
    var sL_var  = [_]f32{0} ** SPATIAL_BINS;
    var sa_var  = [_]f32{0} ** SPATIAL_BINS;
    var sb_var  = [_]f32{0} ** SPATIAL_BINS;
    var sc_La   = [_]f32{0} ** SPATIAL_BINS;
    var sc_Lb   = [_]f32{0} ** SPATIAL_BINS;
    var sc_ab   = [_]f32{0} ** SPATIAL_BINS;
    var smot    = [_]f32{0} ** SPATIAL_BINS;
    var sc: SlowScalars = undefined;

    slowFoldSession(inp,
        &sL_mean, &sa_mean, &sb_mean,
        &sL_var,  &sa_var,  &sb_var,
        &sc_La,   &sc_Lb,   &sc_ab,
        &smot, &sc);

    try testing.expectEqual(@as(f32, 50.0), sL_mean[0]);
    try testing.expectEqual(@as(f32, 0.0),  sL_var[0]);
    try testing.expectEqual(@as(f32, 0.0),  smot[0]);
    try testing.expectEqual(@as(f32, 0.0),  sc_La[0]);
    // ν: var_between = 0 (all sets identical) → ν = 0.
    try testing.expectEqual(@as(f32, 0.0),  sc.nu_L);
}

test "v4 slow_fold: 16 ramped sets → slow_motion captures terminal drift" {
    // Set s has L = s + 100. Per-bin slow trajectory across 16 sets:
    // 100, 101, ..., 115. Mean = 107.5, var = 21.25, motion = 115-100 = 15.
    var L_grids: [16][SPATIAL_BINS]f32 = undefined;
    var a_grid = [_]f32{0.0} ** SPATIAL_BINS;
    var b_grid = [_]f32{0.0} ** SPATIAL_BINS;
    var s: u32 = 0;
    while (s < 16) : (s += 1) {
        @memset(&L_grids[s], 100.0 + @as(f32, @floatFromInt(s)));
    }
    var inp: SlowFoldInput = undefined;
    s = 0;
    while (s < 16) : (s += 1) {
        inp.L_means[s] = &L_grids[s];
        inp.a_means[s] = &a_grid;
        inp.b_means[s] = &b_grid;
    }

    var sL_mean = [_]f32{0} ** SPATIAL_BINS;
    var sa_mean = [_]f32{0} ** SPATIAL_BINS;
    var sb_mean = [_]f32{0} ** SPATIAL_BINS;
    var sL_var  = [_]f32{0} ** SPATIAL_BINS;
    var sa_var  = [_]f32{0} ** SPATIAL_BINS;
    var sb_var  = [_]f32{0} ** SPATIAL_BINS;
    var sc_La   = [_]f32{0} ** SPATIAL_BINS;
    var sc_Lb   = [_]f32{0} ** SPATIAL_BINS;
    var sc_ab   = [_]f32{0} ** SPATIAL_BINS;
    var smot    = [_]f32{0} ** SPATIAL_BINS;
    var sc: SlowScalars = undefined;

    slowFoldSession(inp,
        &sL_mean, &sa_mean, &sb_mean,
        &sL_var,  &sa_var,  &sb_var,
        &sc_La,   &sc_Lb,   &sc_ab,
        &smot, &sc);

    try testing.expectApproxEqAbs(@as(f32, 107.5), sL_mean[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 21.25), sL_var[0],  1e-3);
    try testing.expectApproxEqAbs(@as(f32, 15.0),  smot[0],    1e-3);
    // ν: var_between dominates (all between-set variation, no within-set
    // variation since each set is constant) → ν ≈ 1.
    try testing.expect(sc.nu_L > 0.99);
    // slow_rho1 on a strictly monotonic 16-sequence: analytically ≈ 0.867
    // (the 15 lag-1 products of a centered ramp don't reach 1 because the
    // tail terms have asymmetric mass — same effect as the rho1 ramp test).
    try testing.expect(sc.slow_rho1_L > 0.85);
}

// ============================================================================
// Combiner tests — user-choice 4-frame central-tendency estimators.
// Each pure-math estimator (mean, median, μ_w, trimmed) is closed-form
// on n=4 and tested against a hand-computed expected value.
// ============================================================================

test "combiner mean: equals ¼ Σ vᵢ (default behavior)" {
    const v: @Vector(4, f32) = .{ 10.0, 20.0, 30.0, 40.0 };
    const c = encodeChannel(v, .mean);
    // μ = (10+20+30+40)/4 = 25.
    try testing.expectApproxEqAbs(@as(f32, 25.0), c.mean, 1e-5);
}

test "combiner median: (10, 20, 30, 100) → 25" {
    // Sorted: [10, 20, 30, 100]. Median = (20+30)/2 = 25.
    const v: @Vector(4, f32) = .{ 10.0, 20.0, 30.0, 100.0 };
    const c = encodeChannel(v, .median);
    try testing.expectApproxEqAbs(@as(f32, 25.0), c.mean, 1e-5);
}

test "combiner trimmed: (10, 20, 30, 100) → 20" {
    // Arithmetic μ = 40. Distances: |10-40|=30, |20-40|=20, |30-40|=10,
    // |100-40|=60. Drop 100 (farthest). Average remaining: (10+20+30)/3 = 20.
    const v: @Vector(4, f32) = .{ 10.0, 20.0, 30.0, 100.0 };
    const c = encodeChannel(v, .trimmed_mean);
    try testing.expectApproxEqAbs(@as(f32, 20.0), c.mean, 1e-5);
}

test "combiner ivw: outlier downweighted vs arithmetic mean" {
    // v = (0, 10, 10, 10): v[0] has high leave-one-out deviation
    // (rest_mean = 30/3 = 10; dev = -10; σ²=100). The other three
    // frames have rest_mean = 20/3 ≈ 6.67; dev ≈ 3.33; σ² ≈ 11.11.
    // So v[1..3] dominate via 1/σ². μ_w pulls toward 10.
    const v: @Vector(4, f32) = .{ 0.0, 10.0, 10.0, 10.0 };
    const c_ivw = encodeChannel(v, .inverse_variance_weighted);
    const c_mean = encodeChannel(v, .mean);
    // Arithmetic μ = 7.5; μ_w should be closer to 10.
    try testing.expectApproxEqAbs(@as(f32, 7.5), c_mean.mean, 1e-5);
    try testing.expect(c_ivw.mean > 8.5);
    try testing.expect(c_ivw.mean < 10.5);
}

test "combiner mean: byte-identical to v4 (.mean preserves prior behavior)" {
    // Sanity: the new code path with .mean must produce the exact same
    // ChannelStats fields as the original arithmetic-mean computation.
    const v: @Vector(4, f32) = .{ 0.0, 25.0, 50.0, 75.0 };
    const c = encodeChannel(v, .mean);
    try testing.expectApproxEqAbs(@as(f32, 37.5), c.mean, 1e-5);
    // q-codes: (0, 1, 2, 3) base-4 → 0xE4
    try testing.expectEqual(@as(u8, 0xE4), c.code);
    try testing.expectEqual(ShapeClass.symmetric, c.shape_class);
}

test "combiner median: degenerate constant input → constant" {
    const v: @Vector(4, f32) = .{ 50.0, 50.0, 50.0, 50.0 };
    const c = encodeChannel(v, .median);
    try testing.expectApproxEqAbs(@as(f32, 50.0), c.mean, 1e-5);
}

test "combiner ivw: degenerate constant input handled gracefully" {
    // All frames identical → leave-one-out dev = 0 → σ²=ε (1e-6 floor).
    // The math doesn't divide by zero; result should be exactly the value.
    const v: @Vector(4, f32) = .{ 42.0, 42.0, 42.0, 42.0 };
    const c = encodeChannel(v, .inverse_variance_weighted);
    try testing.expectApproxEqAbs(@as(f32, 42.0), c.mean, 1e-3);
}