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

pub const dng    = @import("dng.zig");
pub const kernel = @import("kernel.zig");
pub const bayer  = @import("bayer.zig");
pub const ljpeg  = @import("ljpeg.zig");

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

test "root: status enum stays in sync with bridging header values" {
    try std.testing.expectEqual(@as(c_int, 0),  @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, 12), @intFromEnum(Status.allocation_failed));
}

test "root: ref all decls" {
    std.testing.refAllDecls(@This());
}
