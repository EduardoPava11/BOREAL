//! borealkernel — proprietary 46×46 Bayer bin-demosaic for BOREAL.
//!
//! C ABI surface (consumed by Swift via the bridging header BorealKernel.h):
//!
//!   bk_status_t bk_bin_dng_to_rgba64(const uint8_t *dng_bytes,
//!                                    size_t         dng_len,
//!                                    uint8_t       *out_rgba);
//!
//! Swift owns both buffers. Internally we allocate the parsed mosaic on the C
//! allocator (page-aligned malloc on iOS) for a single DNG, run the bin, free.

const std = @import("std");

pub const dng      = @import("dng.zig");
pub const kernel   = @import("kernel.zig");
pub const bayer    = @import("bayer.zig");
pub const ljpeg    = @import("ljpeg.zig");
pub const binomial = @import("binomial.zig");

/// Status codes — matches `bk_status_t` enum in BorealKernel.h.
pub const Status = enum(c_int) {
    ok                                = 0,
    bad_tiff_magic                    = 1,
    unsupported_byte_order            = 2,
    unsupported_compression           = 3,   // generic / unknown
    unsupported_cfa_pattern           = 4,
    unsupported_bit_depth             = 5,
    bad_dimensions                    = 6,
    missing_tag                       = 7,
    short_read                        = 8,
    bad_output_buffer                 = 9,
    crop_too_small                    = 10,
    bad_crop_origin                   = 11,
    allocation_failed                 = 12,
    unsupported_compression_deflate   = 14,
    unsupported_compression_lossy_dng = 15,
    unsupported_compression_apple_vc8r= 16,
    ljpeg_decode_failed               = 17,
    null_pointer                      = 18,
};

/// CFA pattern — matches `bk_cfa_pattern_t` in BorealKernel.h.
pub const CfaPattern = enum(c_int) {
    rggb = 0,
    bggr = 1,
};

/// `bk_mosaic_t` — the C ABI mirror of dng.Mosaic. Caller owns the struct
/// (declared on its stack); on success, `samples` is a libc-malloc'd buffer
/// that the caller MUST free via `bk_free_mosaic`. On failure, `samples`
/// is left as null and `bk_free_mosaic` is safe to call (no-op).
pub const Mosaic = extern struct {
    width:           u32,
    height:          u32,
    bits_per_sample: u32,
    black_level:     u32,
    white_level:     u32,
    cfa:             CfaPattern,
    crop_origin_x:   u32,
    crop_origin_y:   u32,
    crop_size_w:     u32,
    crop_size_h:     u32,
    samples:         ?[*]u16,   // heap, length = width * height
};

/// Single entry point. Parses `dng_bytes`, bins the cropped 2944×2944 RGGB
/// region to a 64×64 RGBA8 image, and writes 16384 bytes to `out_rgba`.
/// Returns 0 on success, non-zero status on failure.
export fn bk_bin_dng_to_rgba64(
    dng_bytes: [*]const u8,
    dng_len:   usize,
    out_rgba:  [*]u8,
) c_int {
    const bytes = dng_bytes[0..dng_len];
    const out   = out_rgba[0 .. bayer.OUTPUT * bayer.OUTPUT * 4];

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const mosaic = dng.parse(arena, bytes) catch |err| return statusFromDngError(err);

    bayer.binToRGBA8(.{
        .mosaic   = mosaic.samples,
        .mosaic_w = mosaic.width,
        .mosaic_h = mosaic.height,
        .crop_x   = mosaic.crop_x,
        .crop_y   = mosaic.crop_y,
        .crop_w   = mosaic.crop_w,
        .crop_h   = mosaic.crop_h,
        .black    = mosaic.black,
        .white    = mosaic.white,
    }, out) catch |err| return statusFromBayerError(err);

    return @intFromEnum(Status.ok);
}

fn statusFromDngError(err: dng.Error) c_int {
    return @intFromEnum(switch (err) {
        dng.Error.BadTiffMagic                    => Status.bad_tiff_magic,
        dng.Error.UnsupportedByteOrder            => Status.unsupported_byte_order,
        dng.Error.UnsupportedCompression          => Status.unsupported_compression,
        dng.Error.UnsupportedCompressionDeflate   => Status.unsupported_compression_deflate,
        dng.Error.UnsupportedCompressionLossyDNG  => Status.unsupported_compression_lossy_dng,
        dng.Error.UnsupportedCompressionAppleVc8r => Status.unsupported_compression_apple_vc8r,
        dng.Error.UnsupportedCfaPattern           => Status.unsupported_cfa_pattern,
        dng.Error.UnsupportedBitDepth             => Status.unsupported_bit_depth,
        dng.Error.MissingTag                      => Status.missing_tag,
        dng.Error.BadDimensions                   => Status.bad_dimensions,
        dng.Error.ShortRead                       => Status.short_read,
        dng.Error.LJPEGDecodeFailed               => Status.ljpeg_decode_failed,
        dng.Error.OutOfMemory                     => Status.allocation_failed,
    });
}

fn statusFromBayerError(err: bayer.Error) c_int {
    return @intFromEnum(switch (err) {
        bayer.Error.CropTooSmall    => Status.crop_too_small,
        bayer.Error.BadOutputBuffer => Status.bad_output_buffer,
        bayer.Error.BadCropOrigin   => Status.bad_crop_origin,
    });
}

/// Decode a DNG (uncompressed Bayer or LJPEG SOF3) to a u16 mosaic. On
/// success, `out_mosaic.samples` is a libc-malloc'd buffer of
/// `width * height` u16 samples that the caller MUST free via
/// `bk_free_mosaic`.
///
/// On failure, returns a non-zero `bk_status_t` and `out_mosaic.samples`
/// is set to null (so `bk_free_mosaic` is safe to call regardless).
export fn bk_decode_dng_to_mosaic(
    dng_bytes: [*]const u8,
    dng_len:   usize,
    out_mosaic: *Mosaic,
) c_int {
    out_mosaic.samples = null;

    const bytes = dng_bytes[0..dng_len];

    // dng.parse uses `c_allocator` so the returned `backing` slice is
    // libc-malloc'd. We can hand its base pointer + length to the caller
    // and free it with `c_allocator.free` later.
    const m = dng.parse(std.heap.c_allocator, bytes) catch |err| {
        return statusFromDngError(err);
    };

    out_mosaic.* = .{
        .width           = m.width,
        .height          = m.height,
        .bits_per_sample = m.bits,
        .black_level     = m.black,
        .white_level     = m.white,
        .cfa             = switch (m.cfa) {
            .rggb => .rggb,
            .bggr => .bggr,
        },
        .crop_origin_x   = m.crop_x,
        .crop_origin_y   = m.crop_y,
        .crop_size_w     = m.crop_w,
        .crop_size_h     = m.crop_h,
        .samples         = m.backing.ptr,
    };
    // Don't `dng.deinit(&m)` — we transferred ownership of `backing` to the
    // caller via `out_mosaic.samples`. The wrapper Mosaic struct is on the
    // stack and goes away with the function return.
    return @intFromEnum(Status.ok);
}

/// Free a mosaic returned by `bk_decode_dng_to_mosaic`. Safe to call on a
/// mosaic with `samples == null` (e.g., after a failed decode).
export fn bk_free_mosaic(mosaic: *Mosaic) void {
    if (mosaic.samples) |ptr| {
        const len = @as(usize, mosaic.width) * @as(usize, mosaic.height);
        const slice = ptr[0..len];
        std.heap.c_allocator.free(slice);
        mosaic.samples = null;
    }
}

/// Per-bin binomial encode for one set's 4 LAB frames.
///
/// `lab_frames` points to 4 × 64×64×3 = 49,152 floats laid out as
/// [frame_0_lab_interleaved, frame_1, frame_2, frame_3].
///
/// All 10 output buffers must point to caller-allocated arrays of at least
/// 4096 elements (SPATIAL_BINS). Caller owns all buffers; this function
/// just writes into them.
///
/// codes_flags layout per bin:
///   bits  0..7   = L_code (one of 256 base-4 quantization codes)
///   bits  8..15  = a_code
///   bits 16..23  = b_code
///   bits 24..31  = flags (precomputed predicates; see binomial.zig FLAG_*)
export fn bk_binomial_encode_set(
    lab_frames:  [*]const f32,    // 49,152 floats
    col_L_min:   [*]f32,
    col_L_max:   [*]f32,
    col_L_mean:  [*]f32,
    col_a_min:   [*]f32,
    col_a_max:   [*]f32,
    col_a_mean:  [*]f32,
    col_b_min:   [*]f32,
    col_b_max:   [*]f32,
    col_b_mean:  [*]f32,
    col_codes_flags: [*]u32,
) c_int {
    const total_floats = binomial.FLOATS_PER_FRAME * binomial.FRAMES_PER_SET;
    const spatial = binomial.SPATIAL_BINS;
    binomial.encodeSet(
        lab_frames[0..total_floats],
        col_L_min[0..spatial],   col_L_max[0..spatial],   col_L_mean[0..spatial],
        col_a_min[0..spatial],   col_a_max[0..spatial],   col_a_mean[0..spatial],
        col_b_min[0..spatial],   col_b_max[0..spatial],   col_b_mean[0..spatial],
        col_codes_flags[0..spatial],
    );
    return @intFromEnum(Status.ok);
}

test "root: status enum stays in sync with bridging header values" {
    try std.testing.expectEqual(@as(c_int, 0),  @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, 12), @intFromEnum(Status.allocation_failed));
}

test "root: ref all decls" {
    std.testing.refAllDecls(@This());
}
