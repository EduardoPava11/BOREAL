//! reduce.zig — linear-light box downsample (L2 step 6 of the 16-LAB design).
//! Hand-written, zero dependencies — BOREAL owns this algorithm end to end.
//! Ported from `spec/Boreal/ColorPath.hs` boxReduceRgb; gated bit-exact by
//! the boxReduce section of `fixtures/colorpath_golden.json`.
//!
//! PORT CONVENTION (normative — from the spec): per output pixel and channel,
//! ONE f64 accumulator; samples added in row-major order within the k×k block
//! (sy outer, sx inner); multiply by 1/(k·k) (exact for power-of-two k).
//! Averaging happens in LINEAR light, BEFORE OKLab — averaging photons is
//! only physically correct pre-transfer-function.

const std = @import("std");

/// Interleaved RGB f32, row-major. `k` must divide width and height.
pub fn boxReduceRgb(rgb: []const f32, width: usize, height: usize, k: usize, out: []f32) void {
    const ow = width / k;
    const oh = height / k;
    const inv: f64 = 1.0 / @as(f64, @floatFromInt(k * k));
    var oy: usize = 0;
    while (oy < oh) : (oy += 1) {
        var ox: usize = 0;
        while (ox < ow) : (ox += 1) {
            var acc = [3]f64{ 0, 0, 0 };
            var sy: usize = 0;
            while (sy < k) : (sy += 1) {
                const row = (oy * k + sy) * width + ox * k;
                var sx: usize = 0;
                while (sx < k) : (sx += 1) {
                    const p = 3 * (row + sx);
                    acc[0] += rgb[p];
                    acc[1] += rgb[p + 1];
                    acc[2] += rgb[p + 2];
                }
            }
            const q = 3 * (oy * ow + ox);
            out[q] = @floatCast(acc[0] * inv);
            out[q + 1] = @floatCast(acc[1] * inv);
            out[q + 2] = @floatCast(acc[2] * inv);
        }
    }
}

const testing = std.testing;

test "box reduce preserves constant images exactly" {
    var img: [16 * 16 * 3]f32 = undefined;
    var i: usize = 0;
    while (i < img.len) : (i += 3) {
        img[i] = 0.25;
        img[i + 1] = 0.5;
        img[i + 2] = 0.75;
    }
    var out: [2 * 2 * 3]f32 = undefined;
    boxReduceRgb(&img, 16, 16, 8, &out);
    i = 0;
    while (i < out.len) : (i += 3) {
        try testing.expectEqual(@as(f32, 0.25), out[i]);
        try testing.expectEqual(@as(f32, 0.5), out[i + 1]);
        try testing.expectEqual(@as(f32, 0.75), out[i + 2]);
    }
}

test "box reduce is 1-homogeneous on dyadic inputs" {
    var img: [8 * 8 * 3]f32 = undefined;
    for (&img, 0..) |*v, j| v.* = @as(f32, @floatFromInt((j * 37) % 1024)) / 1024.0;
    var scaled: [8 * 8 * 3]f32 = undefined;
    for (&scaled, 0..) |*v, j| v.* = 4.0 * img[j];
    var a: [2 * 2 * 3]f32 = undefined;
    var b: [2 * 2 * 3]f32 = undefined;
    boxReduceRgb(&img, 8, 8, 4, &a);
    boxReduceRgb(&scaled, 8, 8, 4, &b);
    for (a, b) |x, y| try testing.expectEqual(4.0 * x, y);
}
