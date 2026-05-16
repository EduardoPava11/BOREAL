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
// bit 7 reserved

/// Per-channel reduce: take 4 samples in a vector, return (min, max, mean, code).
/// All operations vectorize to NEON: @reduce(.Min/.Max/.Add) are single insns,
/// the quantization is one FMA per lane, the base-4 packing is integer ALU.
pub const ChannelStats = struct {
    min: f32,
    max: f32,
    mean: f32,
    code: u8,
    /// Raw quantized levels q[0..3] in [0,3] — needed by the flag bits.
    q: [4]u8,
};

inline fn encodeChannel(v: @Vector(4, f32)) ChannelStats {
    const min_v = @reduce(.Min, v);
    const max_v = @reduce(.Max, v);
    const sum   = @reduce(.Add, v);
    const mean  = sum * 0.25;

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
    };
}

/// Compute the 7 flag bits for a bin given its 3 channels' stats.
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

    return f;
}

/// Top-level encode for a whole set: 4 LAB frames → 10 columnar buffers.
///
/// `lab_frames` layout: [frame_0_lab_interleaved, frame_1, frame_2, frame_3]
///                      where each frame is BIN_COUNT*BIN_COUNT*3 floats
///                      (12,288 per frame, 49,152 total).
///
/// Output buffers must each have capacity ≥ SPATIAL_BINS (4096) entries.
/// Caller owns all buffers; this function only writes into them.
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
) void {
    std.debug.assert(lab_frames.len == FLOATS_PER_FRAME * FRAMES_PER_SET);
    std.debug.assert(col_L_min.len  >= SPATIAL_BINS);
    std.debug.assert(col_codes_flags.len >= SPATIAL_BINS);

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

        const L = encodeChannel(v_L);
        const a = encodeChannel(v_a);
        const b = encodeChannel(v_b);
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
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "encodeChannel: constant input → min=max=mean, code=0, flat q" {
    const v: @Vector(4, f32) = .{ 50.0, 50.0, 50.0, 50.0 };
    const c = encodeChannel(v);
    try testing.expectApproxEqAbs(@as(f32, 50.0), c.min, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 50.0), c.max, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 50.0), c.mean, 1e-6);
    try testing.expectEqual(@as(u8, 0), c.code);
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, c.q);
}

test "encodeChannel: monotonic increasing → q=(0,1,2,3), code=0xE4" {
    // 0.0, 0.333..., 0.666..., 1.0 in normalized space.
    const v: @Vector(4, f32) = .{ 0.0, 1.0, 2.0, 3.0 };
    const c = encodeChannel(v);
    try testing.expectEqual([4]u8{ 0, 1, 2, 3 }, c.q);
    // code = 0 | 1<<2 | 2<<4 | 3<<6 = 0 + 4 + 32 + 192 = 228 = 0xE4
    try testing.expectEqual(@as(u8, 0xE4), c.code);
}

test "encodeChannel: monotonic decreasing → q=(3,2,1,0), code=0x1B" {
    const v: @Vector(4, f32) = .{ 3.0, 2.0, 1.0, 0.0 };
    const c = encodeChannel(v);
    try testing.expectEqual([4]u8{ 3, 2, 1, 0 }, c.q);
    // code = 3 | 2<<2 | 1<<4 | 0<<6 = 3 + 8 + 16 + 0 = 27 = 0x1B
    try testing.expectEqual(@as(u8, 0x1B), c.code);
}

test "encodeChannel: pulse at frame 1 → q=(0,3,1,0)" {
    const v: @Vector(4, f32) = .{ 0.0, 30.0, 10.0, 0.0 };
    const c = encodeChannel(v);
    try testing.expectEqual(@as(f32, 0.0), c.min);
    try testing.expectEqual(@as(f32, 30.0), c.max);
    try testing.expectEqual(@as(u8, 3), c.q[1]);  // peak
    try testing.expect(c.q[1] > c.q[0]);
    try testing.expect(c.q[1] > c.q[2]);
}

test "computeFlags: constant L → static" {
    const L = ChannelStats{ .min = 50.0, .max = 50.5, .mean = 50.2, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const a = ChannelStats{ .min = 0.0, .max = 0.0, .mean = 0.0, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const b = ChannelStats{ .min = 0.0, .max = 0.0, .mean = 0.0, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const flags = computeFlags(L, a, b);
    try testing.expect((flags & (1 << 0)) != 0);   // FLAG_STATIC
    try testing.expect((flags & (1 << 1)) == 0);   // not monotonic increasing (all equal)
}

test "computeFlags: increasing L → monotonic_increasing" {
    const L = ChannelStats{ .min = 0.0, .max = 100.0, .mean = 50.0, .code = 0xE4,
                            .q = .{ 0, 1, 2, 3 } };
    const a = ChannelStats{ .min = 0.0, .max = 0.0, .mean = 0.0, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const b = ChannelStats{ .min = 0.0, .max = 0.0, .mean = 0.0, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const flags = computeFlags(L, a, b);
    try testing.expect((flags & (1 << 1)) != 0);   // FLAG_MONOTONIC_INCREASING
    try testing.expect((flags & (1 << 2)) == 0);   // not decreasing
}

test "computeFlags: high chroma" {
    const L = ChannelStats{ .min = 50.0, .max = 50.0, .mean = 50.0, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const a = ChannelStats{ .min = 30.0, .max = 30.0, .mean = 30.0, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const b = ChannelStats{ .min = 30.0, .max = 30.0, .mean = 30.0, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const flags = computeFlags(L, a, b);
    // sqrt(30² + 30²) ≈ 42.4 > 25
    try testing.expect((flags & (1 << 4)) != 0);   // FLAG_HIGH_CHROMA
}

test "computeFlags: high luma + low luma exclusive" {
    const high_L = ChannelStats{ .min = 80.0, .max = 80.0, .mean = 80.0, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const a0 = ChannelStats{ .min = 0.0, .max = 0.0, .mean = 0.0, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const f_high = computeFlags(high_L, a0, a0);
    try testing.expect((f_high & (1 << 5)) != 0);  // HIGH_LUMA
    try testing.expect((f_high & (1 << 6)) == 0);  // not LOW_LUMA

    const low_L = ChannelStats{ .min = 10.0, .max = 10.0, .mean = 10.0, .code = 0, .q = .{ 0, 0, 0, 0 } };
    const f_low = computeFlags(low_L, a0, a0);
    try testing.expect((f_low & (1 << 5)) == 0);
    try testing.expect((f_low & (1 << 6)) != 0);   // LOW_LUMA
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

    encodeSet(frames, &L_min, &L_max, &L_mean,
              &a_min, &a_max, &a_mean,
              &b_min, &b_max, &b_mean, &cf);

    // Every bin: min=max=mean=0, code=0, flags has FLAG_STATIC + FLAG_LOW_LUMA set.
    const expected_flags: u32 = (FLAG_STATIC | FLAG_LOW_LUMA) << 24;
    for (0..SPATIAL_BINS) |i| {
        try testing.expectEqual(@as(f32, 0.0), L_mean[i]);
        try testing.expectEqual(expected_flags, cf[i]);
    }
}