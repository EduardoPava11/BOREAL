//! color.zig — owned camera-native → ProPhoto colour transform for the RGBT→HDR
//! pivot (see ../../BOREAL-RGBT-HDR-WORKFLOW.md §3).
//!
//! Where this sits in the pipeline: fuse (raw sensor space) → demosaic
//! (camera-native linear RGB) → **colorTransform (THIS module)** → ProPhoto
//! linear → {HDR TIFF, preview}. Fusion is channel-agnostic and demosaic only
//! interpolates the CFA, so up to this point the pixels are in the sensor's own
//! RGB primaries with the scene illuminant baked in — uncalibrated. This stage
//! applies white balance + the DNG colour matrix to land in a real colorimetric
//! space (ProPhoto RGB, D50 — chosen because the DNG ForwardMatrix already emits
//! XYZ at D50 and ProPhoto's reference white is D50, so NO chromatic adaptation
//! is needed).
//!
//! The per-DNG part (ForwardMatrix / ColorMatrix) is extracted in dng.zig; this
//! module owns the fixed math: XYZ→ProPhoto, matrix composition, and the SIMD
//! per-pixel apply. All pure & deterministic — unit-testable with no camera.

const std = @import("std");

const LANES = 8;
const V8 = @Vector(LANES, f32);
const V24 = @Vector(LANES * 3, f32);

/// XYZ (D50) → ProPhoto (ROMM) linear RGB. Inverse of the ROMM→XYZ matrix
/// (Lindbloom), row-major [r0 r1 r2 / g0 g1 g2 / b0 b1 b2]. Computed offline and
/// pinned by a test (white maps to white).
pub const XYZ_TO_PROPHOTO = [9]f32{
    1.3459434, -0.2556075, -0.0511118,
    -0.5445988, 1.5081673,  0.0205351,
    0.0000000,  0.0000000,  1.2118128,
};

/// Multiply two row-major 3×3 matrices: C = A · B.
pub fn matmul3(a: [9]f32, b: [9]f32) [9]f32 {
    var c: [9]f32 = undefined;
    inline for (0..3) |i| {
        inline for (0..3) |j| {
            var s: f32 = 0;
            inline for (0..3) |k| s += a[i * 3 + k] * b[k * 3 + j];
            c[i * 3 + j] = s;
        }
    }
    return c;
}

/// Compose the single camera-native-RGB → ProPhoto-linear matrix for a frame:
///   M = XYZ_TO_PROPHOTO · ForwardMatrix · diag(wb_r, wb_g, wb_b)
/// The ForwardMatrix maps white-balance-normalized camera RGB to XYZ(D50); our
/// green-normalized WB (wb_c = asn_green/asn_c) IS that normalization up to a
/// global green scale, which is just exposure and irrelevant for scene-linear.
pub fn cameraToProPhoto(forward_matrix: [9]f32, wb: [3]f32) [9]f32 {
    const fm_wb = [9]f32{
        forward_matrix[0] * wb[0], forward_matrix[1] * wb[1], forward_matrix[2] * wb[2],
        forward_matrix[3] * wb[0], forward_matrix[4] * wb[1], forward_matrix[5] * wb[2],
        forward_matrix[6] * wb[0], forward_matrix[7] * wb[1], forward_matrix[8] * wb[2],
    };
    return matmul3(XYZ_TO_PROPHOTO, fm_wb);
}

/// Invert a row-major 3×3 (for the ColorMatrix fallback: ColorMatrix is XYZ→cam,
/// so camera→XYZ is its inverse). Returns null if singular.
pub fn invert3(m: [9]f32) ?[9]f32 {
    const det = m[0] * (m[4] * m[8] - m[5] * m[7]) -
        m[1] * (m[3] * m[8] - m[5] * m[6]) +
        m[2] * (m[3] * m[7] - m[4] * m[6]);
    if (@abs(det) < 1.0e-12) return null;
    const inv_det = 1.0 / det;
    return .{
        (m[4] * m[8] - m[5] * m[7]) * inv_det,
        (m[2] * m[7] - m[1] * m[8]) * inv_det,
        (m[1] * m[5] - m[2] * m[4]) * inv_det,
        (m[5] * m[6] - m[3] * m[8]) * inv_det,
        (m[0] * m[8] - m[2] * m[6]) * inv_det,
        (m[2] * m[3] - m[0] * m[5]) * inv_det,
        (m[3] * m[7] - m[4] * m[6]) * inv_det,
        (m[1] * m[6] - m[0] * m[7]) * inv_det,
        (m[0] * m[4] - m[1] * m[3]) * inv_det,
    };
}

/// Apply a row-major 3×3 to an interleaved RGB f32 buffer IN PLACE. Negative
/// out-of-gamut results are clamped to 0 (HDR highlights >1 are KEPT — the float
/// master is scene-linear). Strong-SIMD: load LANES pixels (24 floats), @shuffle
/// to deinterleave R/G/B, 9 vector mul-adds, scalar-store; scalar remainder.
pub fn applyMatrix(rgb: []f32, m: [9]f32) void {
    const n_px = rgb.len / 3;
    const mask_r = @Vector(LANES, i32){ 0, 3, 6, 9, 12, 15, 18, 21 };
    const mask_g = @Vector(LANES, i32){ 1, 4, 7, 10, 13, 16, 19, 22 };
    const mask_b = @Vector(LANES, i32){ 2, 5, 8, 11, 14, 17, 20, 23 };

    const m00: V8 = @splat(m[0]);
    const m01: V8 = @splat(m[1]);
    const m02: V8 = @splat(m[2]);
    const m10: V8 = @splat(m[3]);
    const m11: V8 = @splat(m[4]);
    const m12: V8 = @splat(m[5]);
    const m20: V8 = @splat(m[6]);
    const m21: V8 = @splat(m[7]);
    const m22: V8 = @splat(m[8]);
    const zero: V8 = @splat(0.0);

    var i: usize = 0;
    while (i + LANES <= n_px) : (i += LANES) {
        const base = i * 3;
        const v: V24 = rgb[base..][0 .. LANES * 3].*;
        const r = @shuffle(f32, v, undefined, mask_r);
        const g = @shuffle(f32, v, undefined, mask_g);
        const b = @shuffle(f32, v, undefined, mask_b);
        const or_ = @max(m00 * r + m01 * g + m02 * b, zero);
        const og = @max(m10 * r + m11 * g + m12 * b, zero);
        const ob = @max(m20 * r + m21 * g + m22 * b, zero);
        inline for (0..LANES) |k| {
            rgb[base + k * 3 + 0] = or_[k];
            rgb[base + k * 3 + 1] = og[k];
            rgb[base + k * 3 + 2] = ob[k];
        }
    }
    // scalar remainder (identical math)
    while (i < n_px) : (i += 1) {
        const base = i * 3;
        const r = rgb[base + 0];
        const g = rgb[base + 1];
        const b = rgb[base + 2];
        rgb[base + 0] = @max(m[0] * r + m[1] * g + m[2] * b, 0.0);
        rgb[base + 1] = @max(m[3] * r + m[4] * g + m[5] * b, 0.0);
        rgb[base + 2] = @max(m[6] * r + m[7] * g + m[8] * b, 0.0);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────
const testing = std.testing;

fn applyRef(rgb: []f32, m: [9]f32) void {
    var i: usize = 0;
    while (i < rgb.len / 3) : (i += 1) {
        const base = i * 3;
        const r = rgb[base + 0];
        const g = rgb[base + 1];
        const b = rgb[base + 2];
        rgb[base + 0] = @max(m[0] * r + m[1] * g + m[2] * b, 0.0);
        rgb[base + 1] = @max(m[3] * r + m[4] * g + m[5] * b, 0.0);
        rgb[base + 2] = @max(m[6] * r + m[7] * g + m[8] * b, 0.0);
    }
}

test "matmul3: identity is the unit" {
    const id = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    const a = [9]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const c = matmul3(a, id);
    inline for (0..9) |k| try testing.expectApproxEqAbs(a[k], c[k], 1e-5);
}

test "invert3: M · M⁻¹ = I" {
    const m = [9]f32{ 2, 0, 1, 1, 3, 0, 0, 1, 2 };
    const inv = invert3(m).?;
    const id = matmul3(m, inv);
    const expect = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    inline for (0..9) |k| try testing.expectApproxEqAbs(expect[k], id[k], 1e-4);
}

test "XYZ_TO_PROPHOTO: ProPhoto white (1,1,1) ↔ D50 white maps consistently" {
    // ProPhoto→XYZ of (1,1,1) is D50 white; XYZ_TO_PROPHOTO of that must return (1,1,1).
    const d50 = [3]f32{ 0.9642957, 1.0, 0.8251046 }; // ROMM→XYZ row sums
    const m = XYZ_TO_PROPHOTO;
    const r = m[0] * d50[0] + m[1] * d50[1] + m[2] * d50[2];
    const g = m[3] * d50[0] + m[4] * d50[1] + m[5] * d50[2];
    const b = m[6] * d50[0] + m[7] * d50[1] + m[8] * d50[2];
    try testing.expectApproxEqAbs(@as(f32, 1.0), r, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), g, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), b, 1e-3);
}

test "applyMatrix: identity leaves pixels unchanged (incl. HDR >1)" {
    const id = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    var px = [_]f32{ 0.1, 0.5, 0.9, 2.0, 0.0, 0.3, 1.0, 1.0, 1.0 };
    const orig = px;
    applyMatrix(&px, id);
    inline for (0..px.len) |k| try testing.expectApproxEqAbs(orig[k], px[k], 1e-6);
}

test "applyMatrix: negatives clamp to 0, highlights kept" {
    // A matrix that produces a negative for one channel.
    const m = [9]f32{ 1, -2, 0, 0, 1, 0, 0, 0, 1 };
    var px = [_]f32{ 0.2, 0.5, 3.0 }; // r' = 0.2 - 1.0 = -0.8 → 0; b' = 3.0 kept
    applyMatrix(&px, m);
    try testing.expectApproxEqAbs(@as(f32, 0.0), px[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.5), px[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 3.0), px[2], 1e-6);
}

test "applyMatrix: SIMD ≡ scalar on a ragged buffer" {
    // 11 pixels = one full LANES block + 3 remainder.
    const m = [9]f32{ 0.8, 0.1, 0.1, 0.2, 0.7, 0.1, 0.0, 0.2, 0.8 };
    var a: [11 * 3]f32 = undefined;
    for (0..a.len) |k| a[k] = @as(f32, @floatFromInt((k * 37) % 100)) / 50.0;
    var b = a;
    applyMatrix(&a, m); // production (SIMD + remainder)
    applyRef(&b, m); // reference scalar
    inline for (0..a.len) |k| try testing.expectApproxEqAbs(b[k], a[k], 1e-5);
}
