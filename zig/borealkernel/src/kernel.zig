//! Comptime decimating LSLCD kernel for 46×46 → 1 pixel binning, RGGB phase.
//!
//! Derived from the Alleysson 2005 frequency-domain CFA model:
//!   M(i,j) = L(i,j) + C₂(i,j)·((-1)ⁱ + (-1)ʲ) + C₁(i,j)·(-1)^(i+j)
//!     L  = (R + 2G + B) / 4         (luma)
//!     C₁ = (R - 2G + B) / 4         (diagonal chroma, carrier (π,π))
//!     C₂ = (R - B)      / 4         (axial chroma, carriers (π,0) & (0,π))
//!
//! Unit-gain decimating kernels with a 46×46 box window:
//!   w_L  [di,dj] = 1 / 2116
//!   w_C1 [di,dj] = (-1)^(di+dj) / 2116
//!   w_C2 [di,dj] = ((-1)^di + (-1)^dj) / 4232
//!
//! Recovery (provably exact for constant-RGB inputs):
//!   R = L + C₁ + 2·C₂
//!   G = L - C₁
//!   B = L + C₁ - 2·C₂
//!
//! At this binning ratio the output Nyquist is π/47, two orders of magnitude
//! below the chroma carriers — the box's sinc nulls land exactly on (π,0),
//! (0,π), (π,π), so the kernel rejects them perfectly.
//!
//! These tables are baked into the binary as `const` arrays. The production
//! bayer.zig path uses the closed-form channel-separate decomposition (which
//! is mathematically identical for the box window) — these tables exist for
//! audit, for testing, and for future Gaussian/trained variants.

const std = @import("std");

pub const BLOCK: usize = 46;             // mosaic px per output pixel (= 2 · 23 RGGB cells)
pub const OUTPUT_DIM: usize = 64;        // output frame side
pub const CROP_DIM: usize = OUTPUT_DIM * BLOCK; // 2944
pub const SAMPLES_PER_BLOCK: f32 = @floatFromInt(BLOCK * BLOCK); // 2116
pub const HALF_BLOCK: usize = BLOCK / 2; // 23 RGGB cells per side

const Table = [BLOCK][BLOCK]f32;

/// Luma kernel: uniform 1/2116 over the 46×46 box.
pub const K_L: Table = blk: {
    @setEvalBranchQuota(20_000);
    var t: Table = undefined;
    const w: f32 = 1.0 / SAMPLES_PER_BLOCK;
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        t[di][dj] = w;
    };
    break :blk t;
};

/// Diagonal chroma kernel: (-1)^(di+dj) / 2116.
pub const K_C1: Table = blk: {
    @setEvalBranchQuota(20_000);
    var t: Table = undefined;
    const w: f32 = 1.0 / SAMPLES_PER_BLOCK;
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        const sign: f32 = if (((di + dj) & 1) == 0) 1.0 else -1.0;
        t[di][dj] = sign * w;
    };
    break :blk t;
};

/// Axial chroma kernel: ((-1)^di + (-1)^dj) / 4232.
pub const K_C2: Table = blk: {
    @setEvalBranchQuota(20_000);
    var t: Table = undefined;
    const w: f32 = 1.0 / (2.0 * SAMPLES_PER_BLOCK);
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        const si: f32 = if ((di & 1) == 0) 1.0 else -1.0;
        const sj: f32 = if ((dj & 1) == 0) 1.0 else -1.0;
        t[di][dj] = (si + sj) * w;
    };
    break :blk t;
};

// --- Comptime invariants (sanity checks baked into the binary) ---
// Σ w_L = 1.  Σ w_C1 = 0.  Σ w_C2 = 0.
// Σ w_C1 · (-1)^(di+dj) = 1.    (unit gain on C₁ basis)
// Σ w_C2 · ((-1)^di + (-1)^dj) = 1.   (unit gain on C₂ basis)
comptime {
    @setEvalBranchQuota(30_000);

    // Sum in f64 — accumulating 2116 copies of (1.0/2116) in f32 picks up ~2.5e-4
    // of rounding error, which is real but irrelevant to the kernel's correctness
    // (we use the f32 weights at runtime; this check only validates the design).
    var sum_L: f64 = 0;
    var sum_C1: f64 = 0;
    var sum_C2: f64 = 0;
    var gain_C1: f64 = 0;
    var gain_C2: f64 = 0;
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        const s_diag: f64 = if (((di + dj) & 1) == 0) 1.0 else -1.0;
        const s_i: f64 = if ((di & 1) == 0) 1.0 else -1.0;
        const s_j: f64 = if ((dj & 1) == 0) 1.0 else -1.0;
        const s_axial = s_i + s_j;

        sum_L  += @as(f64, K_L [di][dj]);
        sum_C1 += @as(f64, K_C1[di][dj]);
        sum_C2 += @as(f64, K_C2[di][dj]);
        gain_C1 += @as(f64, K_C1[di][dj]) * s_diag;
        gain_C2 += @as(f64, K_C2[di][dj]) * s_axial;
    };

    // Threshold = 1e-4 generously absorbs the f32-rounding artifact while still
    // catching any actual algebraic error (which would be O(1)).
    if (@abs(sum_L  - 1.0)  > 1.0e-4) @compileError("K_L does not sum to 1");
    if (@abs(sum_C1)        > 1.0e-4) @compileError("K_C1 does not sum to 0");
    if (@abs(sum_C2)        > 1.0e-4) @compileError("K_C2 does not sum to 0");
    if (@abs(gain_C1 - 1.0) > 1.0e-4) @compileError("K_C1 unit-gain check failed");
    if (@abs(gain_C2 - 1.0) > 1.0e-4) @compileError("K_C2 unit-gain check failed");
}

/// Apply the full three-kernel reference implementation to a single 46×46 block.
/// This is the "audit path" — slow but matches the math literally. The production
/// path in bayer.zig collapses the same algebra into four channel sums.
pub fn referenceApply(
    block: *const [BLOCK][BLOCK]f32,
) struct { r: f32, g: f32, b: f32 } {
    var L_acc: f32 = 0;
    var C1_acc: f32 = 0;
    var C2_acc: f32 = 0;
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        const s = block[di][dj];
        L_acc  += K_L [di][dj] * s;
        C1_acc += K_C1[di][dj] * s;
        C2_acc += K_C2[di][dj] * s;
    };
    return .{
        .r = L_acc + C1_acc + 2.0 * C2_acc,
        .g = L_acc - C1_acc,
        .b = L_acc + C1_acc - 2.0 * C2_acc,
    };
}

test "K_L is uniform 1/2116" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 2116.0), K_L[0][0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 2116.0), K_L[23][37], 1e-9);
}

test "K_C1 sign pattern matches (-1)^(di+dj)" {
    try std.testing.expect(K_C1[0][0] > 0);
    try std.testing.expect(K_C1[0][1] < 0);
    try std.testing.expect(K_C1[1][0] < 0);
    try std.testing.expect(K_C1[1][1] > 0);
}

test "K_C2 has four phases: +1/2116 at R, 0 at G, -1/2116 at B" {
    // w_C2 = ((-1)^di + (-1)^dj) / 4232.
    // At R (even,even): (1+1)/4232 = 2/4232 = 1/2116 ≈ 0.000473.
    // At Gr/Gb:         (1-1)/4232 = 0.
    // At B (odd,odd):   (-1-1)/4232 = -1/2116.
    const wR: f32 = 1.0 / 2116.0;
    try std.testing.expectApproxEqAbs( wR, K_C2[0][0], 1e-9); // even,even = R
    try std.testing.expectApproxEqAbs(0.0, K_C2[0][1], 1e-9); // even,odd  = Gr
    try std.testing.expectApproxEqAbs(0.0, K_C2[1][0], 1e-9); // odd,even  = Gb
    try std.testing.expectApproxEqAbs(-wR, K_C2[1][1], 1e-9); // odd,odd   = B
}

test "referenceApply: constant gray in → equal R=G=B out" {
    var block: [BLOCK][BLOCK]f32 = undefined;
    for (&block) |*row| for (row) |*v| { v.* = 0.5; };
    const out = referenceApply(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out.r, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out.g, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out.b, 1e-5);
}

test "referenceApply: synthetic pure-R mosaic → R=v, G=0, B=0" {
    var block: [BLOCK][BLOCK]f32 = undefined;
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        // R is at (even, even) in RGGB.
        block[di][dj] = if ((di & 1) == 0 and (dj & 1) == 0) 0.8 else 0.0;
    };
    const out = referenceApply(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), out.r, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.g, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.b, 1e-5);
}

test "referenceApply: synthetic pure-G mosaic → R=0, G=v, B=0" {
    var block: [BLOCK][BLOCK]f32 = undefined;
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        // G is at (even,odd) or (odd,even) in RGGB.
        const is_g = ((di & 1) ^ (dj & 1)) == 1;
        block[di][dj] = if (is_g) 0.6 else 0.0;
    };
    const out = referenceApply(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.r, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), out.g, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.b, 1e-5);
}

test "referenceApply: synthetic pure-B mosaic → R=0, G=0, B=v" {
    var block: [BLOCK][BLOCK]f32 = undefined;
    for (0..BLOCK) |di| for (0..BLOCK) |dj| {
        block[di][dj] = if ((di & 1) == 1 and (dj & 1) == 1) 0.4 else 0.0;
    };
    const out = referenceApply(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.r, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.g, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), out.b, 1e-5);
}
