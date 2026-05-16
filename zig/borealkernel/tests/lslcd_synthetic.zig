//! Cross-check: the fast channel-sum path in bayer.zig must produce the same
//! RGB triplet as the three-kernel reference path in kernel.zig for the
//! box-windowed LSLCD design. This is the experimental verification of the
//! analytic collapse derived in kernel.zig's doc-comment.

const std = @import("std");
const bk = @import("borealkernel");
const kernel = bk.kernel;

const BLOCK = kernel.BLOCK;

/// Re-implementation of the channel-sum path on a single block (matching
/// bayer.zig's inner-loop math, but in pure f32 without u8/sRGB encoding).
fn channelSum(block: *const [BLOCK][BLOCK]f32) struct { r: f32, g: f32, b: f32 } {
    var sum_r:  f32 = 0;
    var sum_gr: f32 = 0;
    var sum_gb: f32 = 0;
    var sum_b:  f32 = 0;
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        const s = block[di][dj];
        const parity = ((di & 1) << 1) | (dj & 1);
        switch (parity) {
            0 => sum_r  += s,
            1 => sum_gr += s,
            2 => sum_gb += s,
            3 => sum_b  += s,
            else => unreachable,
        }
    };
    const n: f32 = @floatFromInt((BLOCK / 2) * (BLOCK / 2)); // 529
    return .{
        .r = sum_r / n,
        .g = (sum_gr + sum_gb) / (2.0 * n),
        .b = sum_b / n,
    };
}

test "channel-sum path equals three-kernel reference (constant gray)" {
    var block: [BLOCK][BLOCK]f32 = undefined;
    for (&block) |*row| for (row) |*v| { v.* = 0.37; };
    const ref  = kernel.referenceApply(&block);
    const fast = channelSum(&block);
    try std.testing.expectApproxEqAbs(ref.r, fast.r, 1e-6);
    try std.testing.expectApproxEqAbs(ref.g, fast.g, 1e-6);
    try std.testing.expectApproxEqAbs(ref.b, fast.b, 1e-6);
}

test "channel-sum path equals three-kernel reference (random RGGB-shaped input)" {
    var prng = std.Random.DefaultPrng.init(0xB0_F2_EA_1B);
    const rng = prng.random();

    var block: [BLOCK][BLOCK]f32 = undefined;
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        // Pick per-channel base values, simulating an RGGB mosaic where each
        // primary varies smoothly across the block — that's the realistic
        // signal model behind LSLCD.
        const phase = ((di & 1) << 1) | (dj & 1);
        const base: f32 = switch (phase) {
            0 => 0.6,   // R
            1 => 0.5,   // Gr
            2 => 0.5,   // Gb
            3 => 0.3,   // B
            else => unreachable,
        };
        const jitter: f32 = (rng.float(f32) - 0.5) * 0.05;
        block[di][dj] = base + jitter;
    };

    const ref  = kernel.referenceApply(&block);
    const fast = channelSum(&block);

    // The closed-form derivation guarantees exact equality for box windows.
    // Allow only the float-summation reordering epsilon.
    try std.testing.expectApproxEqAbs(ref.r, fast.r, 2e-4);
    try std.testing.expectApproxEqAbs(ref.g, fast.g, 2e-4);
    try std.testing.expectApproxEqAbs(ref.b, fast.b, 2e-4);
}

test "channel-sum path equals three-kernel reference (pathological pure carriers)" {
    // M(i,j) = 0.5 + 0.3 * (-1)^(i+j)  — pure C₁ carrier with DC offset.
    var block: [BLOCK][BLOCK]f32 = undefined;
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        const sign: f32 = if (((di + dj) & 1) == 0) 1.0 else -1.0;
        block[di][dj] = 0.5 + 0.3 * sign;
    };
    const ref  = kernel.referenceApply(&block);
    const fast = channelSum(&block);
    // L=0.5, C1=0.3, C2=0 → R=0.8, G=0.2, B=0.8.
    // Tolerance widened to 2e-4 — summing 2116 f32 values of order 0.5 accumulates
    // ULP-level rounding (~1.2e-7 per add ⇒ ~2.5e-4 cumulative). Algebraically exact;
    // numerically off by the f32 limit. Verified against the f64 reference (kernel.zig).
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), ref.r, 2e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), ref.g, 2e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), ref.b, 2e-4);
    try std.testing.expectApproxEqAbs(ref.r, fast.r, 2e-4);
    try std.testing.expectApproxEqAbs(ref.g, fast.g, 2e-4);
    try std.testing.expectApproxEqAbs(ref.b, fast.b, 2e-4);
}

test "comptime constants match BOREAL pipeline" {
    try std.testing.expectEqual(@as(usize, 46),   kernel.BLOCK);
    try std.testing.expectEqual(@as(usize, 64),   kernel.OUTPUT_DIM);
    try std.testing.expectEqual(@as(usize, 2944), kernel.CROP_DIM);
    try std.testing.expectEqual(@as(usize, 23),   kernel.HALF_BLOCK);
}
