//! Decimating LSLCD Bayer-bin core. Maps a 2944×2944 RGGB mosaic crop to a
//! 64×64 RGBA8 image by averaging each 46×46 block.
//!
//! The implementation uses the channel-separate identity proved in kernel.zig:
//! for the unit-gain box-windowed LSLCD kernels, the recovered RGB collapses to
//!   R_out = sumR  / 529
//!   G_out = (sumGr + sumGb) / 1058
//!   B_out = sumB  / 529
//! where the sums run over the 23×23 RGGB cells in each 46×46 block. This is
//! provably identical to the three-kernel reference path (kernel.referenceApply)
//! and a synthetic test in tests/lslcd_synthetic.zig pins the two against each
//! other to within float epsilon.

const std = @import("std");
const kernel = @import("kernel.zig");

pub const BLOCK     = kernel.BLOCK;      // 46
pub const OUTPUT    = kernel.OUTPUT_DIM; // 64
pub const CROP      = kernel.CROP_DIM;   // 2944
pub const SAMPLES_PER_CHANNEL: u32 = (BLOCK / 2) * (BLOCK / 2); // 529 R, 529 B, 2·529=1058 G

pub const Error = error{ CropTooSmall, BadOutputBuffer, BadCropOrigin };

pub const BinInput = struct {
    mosaic: []const u16, // full sensor mosaic, row-major, length = mosaic_w * mosaic_h
    mosaic_w: usize,     // full sensor width (stride in u16s)
    mosaic_h: usize,
    crop_x: usize,       // RGGB-aligned origin of the analysis square (must be even)
    crop_y: usize,
    crop_w: usize,       // analysis-square dims (must be ≥ 2944, only top-left 2944² used)
    crop_h: usize,
    black: u32,          // black level in raw counts
    white: u32,          // white level in raw counts
};

/// Bin one DNG's worth of mosaic into a 64×64×4 RGBA8 buffer. Caller owns out_rgba.
/// out_rgba must be exactly 64·64·4 = 16384 bytes; longer is rejected as a likely bug.
pub fn binToRGBA8(in: BinInput, out_rgba: []u8) Error!void {
    if (out_rgba.len != OUTPUT * OUTPUT * 4) return Error.BadOutputBuffer;
    if (in.crop_w < CROP or in.crop_h < CROP) return Error.CropTooSmall;
    if ((in.crop_x & 1) != 0 or (in.crop_y & 1) != 0) return Error.BadCropOrigin;
    if (in.crop_x + CROP > in.mosaic_w) return Error.CropTooSmall;
    if (in.crop_y + CROP > in.mosaic_h) return Error.CropTooSmall;

    const black_f = @as(f32, @floatFromInt(in.black));
    const white_f = @as(f32, @floatFromInt(in.white));
    const span = white_f - black_f;
    // Guard against malformed DNG: a zero span would cause division by zero.
    // Caller's job to set black<white, but we don't crash if they fail.
    const inv_span = if (span > 0) 1.0 / span else 1.0;

    // 529 = 23² samples per primary channel per block. Pre-compute the
    // per-channel normalization including the black/white linearization:
    //   linear = (avg_raw - black) / span
    // where avg_raw = sum / N.  Combined: linear = (sum/N - black)/span
    // We'll apply per-channel.
    const inv_n_rb: f32 = 1.0 / @as(f32, @floatFromInt(SAMPLES_PER_CHANNEL));
    const inv_n_g:  f32 = 1.0 / (2.0 * @as(f32, @floatFromInt(SAMPLES_PER_CHANNEL)));

    var oy: usize = 0;
    while (oy < OUTPUT) : (oy += 1) {
        var ox: usize = 0;
        while (ox < OUTPUT) : (ox += 1) {
            const block_y = in.crop_y + oy * BLOCK;
            const block_x = in.crop_x + ox * BLOCK;

            // Four u32 channel accumulators. Maximum value: 2116 * 65535 ≈ 1.4e8 < 2^32. Safe.
            var sum_r:  u32 = 0;
            var sum_gr: u32 = 0;
            var sum_gb: u32 = 0;
            var sum_b:  u32 = 0;

            var di: usize = 0;
            while (di < BLOCK) : (di += 1) {
                const row_base = (block_y + di) * in.mosaic_w + block_x;
                const row = in.mosaic[row_base..][0..BLOCK];
                if ((di & 1) == 0) {
                    // R at even col, Gr at odd col.
                    sumEvenOdd(row, &sum_r, &sum_gr);
                } else {
                    // Gb at even col, B at odd col.
                    sumEvenOdd(row, &sum_gb, &sum_b);
                }
            }

            // Linearize each channel: linear = (avg - black) / span.
            const r_lin = (@as(f32, @floatFromInt(sum_r))  * inv_n_rb - black_f) * inv_span;
            const g_lin = (@as(f32, @floatFromInt(sum_gr + sum_gb)) * inv_n_g - black_f) * inv_span;
            const b_lin = (@as(f32, @floatFromInt(sum_b))  * inv_n_rb - black_f) * inv_span;

            const idx = (oy * OUTPUT + ox) * 4;
            out_rgba[idx + 0] = srgbEncode(r_lin);
            out_rgba[idx + 1] = srgbEncode(g_lin);
            out_rgba[idx + 2] = srgbEncode(b_lin);
            out_rgba[idx + 3] = 255;
        }
    }
}

/// Sum even-indexed and odd-indexed u16s into two u32 accumulators.
/// 46 elements per row -> 23 pairs.
fn sumEvenOdd(row: []const u16, even_acc: *u32, odd_acc: *u32) void {
    var k: usize = 0;
    var e: u32 = 0;
    var o: u32 = 0;
    while (k < row.len) : (k += 2) {
        e += @as(u32, row[k]);
        o += @as(u32, row[k + 1]);
    }
    even_acc.* += e;
    odd_acc.*  += o;
}

/// IEC 61966-2-1 sRGB OETF, clamped to [0,255] u8.
fn srgbEncode(linear: f32) u8 {
    const x = std.math.clamp(linear, 0.0, 1.0);
    const encoded: f32 = if (x <= 0.0031308)
        12.92 * x
    else
        1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
    return @intFromFloat(std.math.clamp(encoded * 255.0 + 0.5, 0.0, 255.0));
}

// --- Tests for the channel-bin core (synthetic mosaic) ---

test "binToRGBA8 rejects undersized crop" {
    var pixels: [4]u16 = .{0, 0, 0, 0};
    var out: [OUTPUT * OUTPUT * 4]u8 = undefined;
    const r = binToRGBA8(.{
        .mosaic = &pixels, .mosaic_w = 2, .mosaic_h = 2,
        .crop_x = 0, .crop_y = 0, .crop_w = 2, .crop_h = 2,
        .black = 0, .white = 65535,
    }, &out);
    try std.testing.expectError(Error.CropTooSmall, r);
}

test "binToRGBA8 rejects misaligned crop origin" {
    const W = CROP + 2;
    const pixels = try std.testing.allocator.alloc(u16, W * W);
    defer std.testing.allocator.free(pixels);
    for (pixels) |*p| p.* = 0;
    var out: [OUTPUT * OUTPUT * 4]u8 = undefined;
    const r = binToRGBA8(.{
        .mosaic = pixels, .mosaic_w = W, .mosaic_h = W,
        .crop_x = 1, .crop_y = 0, .crop_w = CROP, .crop_h = CROP,
        .black = 0, .white = 65535,
    }, &out);
    try std.testing.expectError(Error.BadCropOrigin, r);
}

test "binToRGBA8 constant gray mosaic → uniform mid-gray output" {
    const W = CROP;
    const pixels = try std.testing.allocator.alloc(u16, W * W);
    defer std.testing.allocator.free(pixels);
    // Mid-scale linear: black=0, white=65535, value=32768 -> linear ≈ 0.5
    for (pixels) |*p| p.* = 32768;
    var out: [OUTPUT * OUTPUT * 4]u8 = undefined;
    try binToRGBA8(.{
        .mosaic = pixels, .mosaic_w = W, .mosaic_h = W,
        .crop_x = 0, .crop_y = 0, .crop_w = W, .crop_h = W,
        .black = 0, .white = 65535,
    }, &out);

    // sRGB encode of 0.5 is approximately 188.
    const expected = srgbEncode(32768.0 / 65535.0);
    for (0..OUTPUT) |y| for (0..OUTPUT) |x| {
        const idx = (y * OUTPUT + x) * 4;
        try std.testing.expectEqual(expected, out[idx + 0]);
        try std.testing.expectEqual(expected, out[idx + 1]);
        try std.testing.expectEqual(expected, out[idx + 2]);
        try std.testing.expectEqual(@as(u8, 255), out[idx + 3]);
    };
}

test "binToRGBA8 pure-R mosaic → red-only output" {
    const W = CROP;
    const pixels = try std.testing.allocator.alloc(u16, W * W);
    defer std.testing.allocator.free(pixels);
    // R lives at (even, even) in the RGGB-aligned crop. Set R=full, G=B=0.
    for (0..W) |y| for (0..W) |x| {
        pixels[y * W + x] = if ((y & 1) == 0 and (x & 1) == 0) 65535 else 0;
    };
    var out: [OUTPUT * OUTPUT * 4]u8 = undefined;
    try binToRGBA8(.{
        .mosaic = pixels, .mosaic_w = W, .mosaic_h = W,
        .crop_x = 0, .crop_y = 0, .crop_w = W, .crop_h = W,
        .black = 0, .white = 65535,
    }, &out);

    // Each block: 529 R-positions at value 65535, sumR = 529 * 65535 ≈ 3.47e7.
    // avg = 65535, linear = 1.0, sRGB-encoded = 255.
    try std.testing.expectEqual(@as(u8, 255), out[0]); // R
    try std.testing.expectEqual(@as(u8, 0),   out[1]); // G
    try std.testing.expectEqual(@as(u8, 0),   out[2]); // B
}

test "binToRGBA8 pure-G mosaic → green-only output" {
    const W = CROP;
    const pixels = try std.testing.allocator.alloc(u16, W * W);
    defer std.testing.allocator.free(pixels);
    for (0..W) |y| for (0..W) |x| {
        const is_g = ((y & 1) ^ (x & 1)) == 1;
        pixels[y * W + x] = if (is_g) 65535 else 0;
    };
    var out: [OUTPUT * OUTPUT * 4]u8 = undefined;
    try binToRGBA8(.{
        .mosaic = pixels, .mosaic_w = W, .mosaic_h = W,
        .crop_x = 0, .crop_y = 0, .crop_w = W, .crop_h = W,
        .black = 0, .white = 65535,
    }, &out);
    try std.testing.expectEqual(@as(u8, 0),   out[0]);
    try std.testing.expectEqual(@as(u8, 255), out[1]);
    try std.testing.expectEqual(@as(u8, 0),   out[2]);
}

test "binToRGBA8 pure-B mosaic → blue-only output" {
    const W = CROP;
    const pixels = try std.testing.allocator.alloc(u16, W * W);
    defer std.testing.allocator.free(pixels);
    for (0..W) |y| for (0..W) |x| {
        pixels[y * W + x] = if ((y & 1) == 1 and (x & 1) == 1) 65535 else 0;
    };
    var out: [OUTPUT * OUTPUT * 4]u8 = undefined;
    try binToRGBA8(.{
        .mosaic = pixels, .mosaic_w = W, .mosaic_h = W,
        .crop_x = 0, .crop_y = 0, .crop_w = W, .crop_h = W,
        .black = 0, .white = 65535,
    }, &out);
    try std.testing.expectEqual(@as(u8, 0),   out[0]);
    try std.testing.expectEqual(@as(u8, 0),   out[1]);
    try std.testing.expectEqual(@as(u8, 255), out[2]);
}
