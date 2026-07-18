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
pub const scene    = @import("scene.zig");
pub const fuse     = @import("fuse.zig");
pub const lut      = @import("lut.zig");
pub const tiff     = @import("tiff.zig");
pub const demosaic = @import("demosaic.zig");
pub const color    = @import("color.zig");
pub const pyramid  = @import("pyramid.zig");
pub const oklab    = @import("oklab.zig");
pub const reduce   = @import("reduce.zig");
pub const giftarget = @import("giftarget.zig");
pub const multiscale = @import("multiscale.zig");
pub const gifwire  = @import("gifwire.zig");
pub const srgb_table = @import("srgb_table.zig");

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
    // Per-variant LJPEG decoder errors (mapped from ljpeg.Error). When one
    // of these surfaces, the device-side log names the exact LJPEG check
    // that rejected the iPhone DNG tile — no source spelunking required.
    ljpeg_bad_magic                   = 19,
    ljpeg_unexpected_end              = 20,
    ljpeg_unsupported_marker          = 21,
    ljpeg_unsupported_component_count = 22,
    ljpeg_unsupported_precision       = 23,
    ljpeg_unsupported_predictor       = 24,
    ljpeg_has_restart_markers         = 25,
    ljpeg_malformed_huffman_table     = 26,
    ljpeg_invalid_huffman_code        = 27,
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
    wb_r:            f32,       // AsShotNeutral WB multipliers, green-normalized
    wb_g:            f32,       // (= 1); feeds the ETTR planner's WB prior
    wb_b:            f32,
    exposure_time:   f32,       // EXIF ExposureTime (s); 0 = absent
    iso:             f32,       // EXIF ISO; 0 = absent
    fnumber:         f32,       // EXIF FNumber; 0 = absent/canceling
    cam_to_pp:       [9]f32,    // camera-native → ProPhoto-linear 3×3 (row-major)
    has_color:       bool,      // false → cam_to_pp is identity, embed no ICC
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
        dng.Error.BadTiffMagic                       => Status.bad_tiff_magic,
        dng.Error.UnsupportedByteOrder               => Status.unsupported_byte_order,
        dng.Error.UnsupportedCompression             => Status.unsupported_compression,
        dng.Error.UnsupportedCompressionDeflate      => Status.unsupported_compression_deflate,
        dng.Error.UnsupportedCompressionLossyDNG     => Status.unsupported_compression_lossy_dng,
        dng.Error.UnsupportedCompressionAppleVc8r    => Status.unsupported_compression_apple_vc8r,
        dng.Error.UnsupportedCfaPattern              => Status.unsupported_cfa_pattern,
        dng.Error.UnsupportedBitDepth                => Status.unsupported_bit_depth,
        dng.Error.MissingTag                         => Status.missing_tag,
        dng.Error.BadDimensions                      => Status.bad_dimensions,
        dng.Error.ShortRead                          => Status.short_read,
        dng.Error.LJPEGDecodeFailed                  => Status.ljpeg_decode_failed,
        dng.Error.LJPEGBadMagic                      => Status.ljpeg_bad_magic,
        dng.Error.LJPEGUnexpectedEnd                 => Status.ljpeg_unexpected_end,
        dng.Error.LJPEGUnsupportedMarker             => Status.ljpeg_unsupported_marker,
        dng.Error.LJPEGUnsupportedComponentCount     => Status.ljpeg_unsupported_component_count,
        dng.Error.LJPEGUnsupportedPrecision          => Status.ljpeg_unsupported_precision,
        dng.Error.LJPEGUnsupportedPredictor          => Status.ljpeg_unsupported_predictor,
        dng.Error.LJPEGHasRestartMarkers             => Status.ljpeg_has_restart_markers,
        dng.Error.LJPEGMalformedHuffmanTable         => Status.ljpeg_malformed_huffman_table,
        dng.Error.LJPEGInvalidHuffmanCode            => Status.ljpeg_invalid_huffman_code,
        dng.Error.OutOfMemory                        => Status.allocation_failed,
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
        .wb_r            = m.wb_r,
        .wb_g            = m.wb_g,
        .wb_b            = m.wb_b,
        .exposure_time   = m.exposure_time,
        .iso             = m.iso,
        .fnumber         = m.fnumber,
        .cam_to_pp       = m.cam_to_pp,
        .has_color       = m.has_color,
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
/// v4 per-set trailer scalars. C ABI mirror of binomial.PerSetTrailer.
pub const PerSetTrailer = binomial.PerSetTrailer;

/// v4 per-session slow-scale scalars. C ABI mirror of binomial.SlowScalars.
pub const SlowScalars = binomial.SlowScalars;

// ── Stage A/B: pre-shutter scene analysis + exposure planning (scene.zig) ──
// See ../../BOREAL-RGBT-HDR-WORKFLOW.md §1: ANALYZE → PLAN.

/// C ABI mirror of scene.SceneClips — per-channel ETTR headroom (stops).
pub const SceneClips = scene.SceneClips;
/// C ABI mirror of scene.ExposurePlan — the 4-frame EV offsets.
pub const ExposurePlan = scene.ExposurePlan;

/// Stage A. Analyze an interleaved RGB frame (3 floats/pixel, normalized [0,1],
/// UniWB for raw-accurate tails) → per-channel ETTR clips. Caller owns buffers.
export fn bk_analyze_scene(rgb: [*]const f32, width: u32, height: u32, out: *SceneClips) void {
    out.* = scene.analyzeFrame(rgb, width, height);
}

/// Stage B. SceneClips + white-balance prior `wb_mult` [R,G,B] → the 4-frame
/// exposure plan. `extra_shadow` adds stops to the shadow-floor frame (f4).
export fn bk_solve_ettr_exposures(clips: *const SceneClips, wb_mult: [*]const f32, extra_shadow: f32, out: *ExposurePlan) void {
    out.* = scene.planExposures(clips.*, .{ wb_mult[0], wb_mult[1], wb_mult[2] }, extra_shadow);
}

/// Stage A, mosaic-direct (GIF-ISP Phase 2): analyze a RAW Bayer mosaic →
/// per-channel ETTR clips, no demosaic needed. Feeds bk_solve_ettr_exposures
/// for the inter-cycle EV re-plan.
export fn bk_analyze_mosaic_clips(
    samples: [*]const u16,
    width: u32,
    height: u32,
    cfa: u32,
    black: f32,
    white: f32,
    out: *SceneClips,
) void {
    out.* = scene.analyzeMosaic(samples, width, height, cfa, black, white);
}

/// Per-frame exposure read-out. Bin a RAW Bayer mosaic into three per-channel
/// display histograms (green at the off-diagonal CFA sites, red/blue at the
/// corners; swapped for BGGR), normalized by the sensor's black/white levels —
/// no white balance, so the bars read true per-channel exposure and clipping.
/// Each `out_*` buffer must hold `n_bins` u32s. Caller owns all buffers.
export fn bk_channel_histograms(
    samples: [*]const u16,
    width: u32,
    height: u32,
    cfa: u32,
    black: f32,
    white: f32,
    n_bins: u32,
    out_r: [*]u32,
    out_g: [*]u32,
    out_b: [*]u32,
) void {
    scene.channelHistograms(samples, width, height, cfa, black, white, n_bins, out_r, out_g, out_b);
}

/// Live preview exposure read-out. Bin an interleaved 8-bit BGRA video frame
/// (the live AVCaptureVideoDataOutput feed) into three per-channel display
/// histograms, each channel normalized /255 (display-referred — NO sensor
/// black/white, NO white balance). `row_stride` is the buffer's bytesPerRow IN
/// BYTES (CVPixelBuffer pads rows). Byte order BGRA: B@o, G@o+1, R@o+2, A
/// skipped. Each `out_*` buffer must hold `n_bins` u32s. Caller owns all buffers.
export fn bk_rgb_histograms(
    bgra: [*]const u8,
    width: u32,
    height: u32,
    row_stride: u32,
    n_bins: u32,
    out_r: [*]u32,
    out_g: [*]u32,
    out_b: [*]u32,
) void {
    scene.rgbHistograms(bgra, width, height, row_stride, n_bins, out_r, out_g, out_b);
}

// ── Stage D: RGBT scene-linear fusion (fuse.zig) ───────────────────────────
// See ../../BOREAL-RGBT-HDR-WORKFLOW.md §2. Owned algorithm, strong SIMD.

/// C ABI mirror of fuse.FuseParams.
pub const FuseParams = fuse.FuseParams;

/// Fuse 4 raw frames (u16, same length `n`) into one scene-linear f32 buffer.
/// Caller owns all five buffers; `out` must hold at least `n` floats.
export fn bk_fuse_mosaics(
    f0: [*]const u16,
    f1: [*]const u16,
    f2: [*]const u16,
    f3: [*]const u16,
    n: usize,
    params: *const FuseParams,
    out: [*]f32,
) void {
    fuse.fuse(.{ f0[0..n], f1[0..n], f2[0..n], f3[0..n] }, out[0..n], params.*);
}

/// Compute the per-frame relative exposure ratios from each frame's EXIF
/// (ExposureTime/ISO/FNumber). Single source of truth for direction,
/// normalization, fallback, and clamp — see fuse.relativeExposures.
export fn bk_relative_exposures(
    exposure_time: *const [4]f32,
    iso: *const [4]f32,
    fnumber: *const [4]f32,
    out: *[4]f32,
) void {
    out.* = fuse.relativeExposures(exposure_time.*, iso.*, fnumber.*);
}

// ── Output B: owned 64³ .cube LUT baker (lut.zig) ──────────────────────────
// See ../../BOREAL-RGBT-HDR-WORKFLOW.md §4. Owned algorithm, strong SIMD.

/// C ABI mirror of lut.LookParams (ASC-CDL grade).
pub const LookParams = lut.LookParams;

/// Bake the look into a grid³×3 interleaved RGB lattice (red fastest).
/// `out` must hold grid*grid*grid*3 floats. Caller owns both buffers.
export fn bk_build_cube_lut(params: *const LookParams, grid: u32, out: [*]f32) void {
    const n: usize = @as(usize, grid) * grid * grid * 3;
    lut.bakeLattice(out[0..n], grid, params.*);
}

/// Serialize a baked lattice as `.cube` text into `buf`. Returns bytes written,
/// or 0 if the buffer is too small.
export fn bk_emit_cube(lattice: [*]const f32, grid: u32, buf: [*]u8, buf_len: usize) usize {
    const n: usize = @as(usize, grid) * grid * grid * 3;
    return lut.emitCube(buf[0..buf_len], lattice[0..n], grid, "BOREAL") orelse 0;
}

/// Apply the SAME ASC-CDL look the cube bakes (lut.applyLook) to an interleaved
/// RGB f32 buffer of `n_px` pixels, in place. Inputs/outputs are [0,1] display-
/// referred. This is what makes the on-screen preview byte-identical to what the
/// exported .cube produces in Photoshop (★preview≡cube).
export fn bk_apply_look(rgb: [*]f32, n_px: usize, params: *const LookParams) void {
    var i: usize = 0;
    while (i < n_px) : (i += 1) {
        const base = i * 3;
        const out = lut.applyLook(.{ rgb[base], rgb[base + 1], rgb[base + 2] }, params.*);
        rgb[base] = out[0];
        rgb[base + 1] = out[1];
        rgb[base + 2] = out[2];
    }
}

// ── Phase 1: full-resolution demosaic (demosaic.zig) ───────────────────────
// See ../../BOREAL-RGBT-HDR-WORKFLOW.md §2. Owned Malvar–He–Cutler, strong SIMD.

/// Demosaic a single-channel mosaic (fused, scene-linear f32) into interleaved
/// RGB. `cfa`: 0 = RGGB, 1 = BGGR (matches bk_cfa_pattern_t). `out` ≥ w*h*3.
export fn bk_demosaic_full(m: [*]const f32, width: u32, height: u32, cfa: u32, out: [*]f32) void {
    const w: usize = width;
    const h: usize = height;
    demosaic.demosaic(m[0 .. w * h], w, h, cfa == 1, out[0 .. w * h * 3]);
}

// ── Colour transform: camera-native → ProPhoto linear (color.zig) ──────────
// See ../../BOREAL-RGBT-HDR-WORKFLOW.md §3. Owned algorithm, strong SIMD.

/// Apply a row-major 3×3 (the mosaic's `cam_to_pp`) to an interleaved RGB f32
/// buffer of `n_px` pixels, in place. Negatives clamp to 0; HDR highlights kept.
export fn bk_apply_color_matrix(rgb: [*]f32, n_px: usize, matrix: [*]const f32) void {
    var m: [9]f32 = undefined;
    inline for (0..9) |k| m[k] = matrix[k];
    color.applyMatrix(rgb[0 .. n_px * 3], m);
}

// ── Output A: owned 32-bit-float HDR TIFF encoder (tiff.zig) ───────────────
// See ../../BOREAL-RGBT-HDR-WORKFLOW.md §3.

/// Bytes needed to encode a width×height float-RGB TIFF with an `icc_len` ICC.
export fn bk_tiff_size(width: u32, height: u32, icc_len: usize) usize {
    return tiff.tiffSize(width, height, icc_len);
}

/// Encode a 32-bit-float RGB TIFF into `buf`. `pixels` = interleaved RGB,
/// length ≥ width*height*3. `icc`/`icc_len` may be null/0. Returns bytes
/// written, or 0 if `buf` is too small.
export fn bk_write_tiff_f32(
    width: u32,
    height: u32,
    pixels: [*]const f32,
    icc: ?[*]const u8,
    icc_len: usize,
    buf: [*]u8,
    buf_len: usize,
) usize {
    const npx: usize = @as(usize, width) * @as(usize, height) * 3;
    const icc_slice: []const u8 = if (icc) |p| p[0..icc_len] else &.{};
    return tiff.writeTiff(buf[0..buf_len], width, height, pixels[0..npx], icc_slice) orelse 0;
}

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
    col_L_shape: [*]u32,
    col_a_shape: [*]u32,
    col_b_shape: [*]u32,
    // v4 fast-scale additions
    col_fast_cov_La:    [*]f32,
    col_fast_cov_Lb:    [*]f32,
    col_fast_cov_ab:    [*]f32,
    col_fast_nbr_rho_L: [*]f32,
    col_fast_nbr_rho_a: [*]f32,
    col_fast_nbr_rho_b: [*]f32,
    col_fast_motion:    [*]f32,
    out_trailer:        *PerSetTrailer,
    /// User-chosen 4-frame combiner. See `bk_combiner_t` in BorealKernel.h:
    /// 0=mean (default, v4-compatible), 1=median, 2=inverse-variance
    /// weighted, 3=trimmed (drop farthest from μ).
    combiner: u32,
) c_int {
    const total_floats = binomial.FLOATS_PER_FRAME * binomial.FRAMES_PER_SET;
    const spatial = binomial.SPATIAL_BINS;
    // Clamp combiner to valid enum range; out-of-range values fall
    // back to .mean rather than UB.
    const combiner_enum: binomial.Combiner = switch (combiner) {
        0 => .mean,
        1 => .median,
        2 => .inverse_variance_weighted,
        3 => .trimmed_mean,
        else => .mean,
    };
    binomial.encodeSet(
        lab_frames[0..total_floats],
        col_L_min[0..spatial],   col_L_max[0..spatial],   col_L_mean[0..spatial],
        col_a_min[0..spatial],   col_a_max[0..spatial],   col_a_mean[0..spatial],
        col_b_min[0..spatial],   col_b_max[0..spatial],   col_b_mean[0..spatial],
        col_codes_flags[0..spatial],
        col_L_shape[0..spatial], col_a_shape[0..spatial], col_b_shape[0..spatial],
        col_fast_cov_La[0..spatial],    col_fast_cov_Lb[0..spatial],    col_fast_cov_ab[0..spatial],
        col_fast_nbr_rho_L[0..spatial], col_fast_nbr_rho_a[0..spatial], col_fast_nbr_rho_b[0..spatial],
        col_fast_motion[0..spatial],
        out_trailer,
        combiner_enum,
    );
    return @intFromEnum(Status.ok);
}

/// v4 slow-scale fold across 16 sets' channel-mean grids. Inputs are 16
/// pointers each to a 4,096-float L_mean, a_mean, b_mean column from the
/// per-set `.bvox`. Outputs are 10 per-bin slow columns + 4 session-level
/// scalars (3 lag-1 autocorr + 1 hierarchical variance ratio ν).
export fn bk_slow_fold_session(
    L_means_ptrs: [*]const [*]const f32,    // 16 pointers to L_mean grids
    a_means_ptrs: [*]const [*]const f32,    // 16 pointers to a_mean grids
    b_means_ptrs: [*]const [*]const f32,    // 16 pointers to b_mean grids
    out_slow_L_mean: [*]f32,
    out_slow_a_mean: [*]f32,
    out_slow_b_mean: [*]f32,
    out_slow_L_var:  [*]f32,
    out_slow_a_var:  [*]f32,
    out_slow_b_var:  [*]f32,
    out_slow_cov_La: [*]f32,
    out_slow_cov_Lb: [*]f32,
    out_slow_cov_ab: [*]f32,
    out_slow_motion: [*]f32,
    out_scalars:     *SlowScalars,
) c_int {
    const spatial = binomial.SPATIAL_BINS;

    var inp: binomial.SlowFoldInput = undefined;
    var s: u32 = 0;
    while (s < 16) : (s += 1) {
        inp.L_means[s] = L_means_ptrs[s];
        inp.a_means[s] = a_means_ptrs[s];
        inp.b_means[s] = b_means_ptrs[s];
    }

    binomial.slowFoldSession(
        inp,
        out_slow_L_mean[0..spatial],
        out_slow_a_mean[0..spatial],
        out_slow_b_mean[0..spatial],
        out_slow_L_var [0..spatial],
        out_slow_a_var [0..spatial],
        out_slow_b_var [0..spatial],
        out_slow_cov_La[0..spatial],
        out_slow_cov_Lb[0..spatial],
        out_slow_cov_ab[0..spatial],
        out_slow_motion[0..spatial],
        out_scalars,
    );
    return @intFromEnum(Status.ok);
}

/// Embedded S-transform pyramid: image (side² i32, row-major) → coefficient
/// bands (side² i32, prefix layout: top base² row-major, then detail level
/// with quad-grid side s at [s², 4·s²) as interleaved (LH,HL,HH) per quad).
/// The 16×16 latent is the prefix; back-trace is exact inverse transform.
/// side/base must be powers of two, base ≤ side. Caller owns ALL buffers;
/// `scratch` must hold (side·side)/2 elements.
export fn bk_pyramid_analyze(
    img: [*]const i32,
    side: u32,
    base: u32,
    out_bands: [*]i32,
    scratch: [*]i32,
) c_int {
    const n = @as(usize, side) * @as(usize, side);
    const ok = pyramid.analyze(img[0..n], side, base, out_bands[0..n], scratch[0 .. n / 2]);
    return if (ok) @intFromEnum(Status.ok) else @intFromEnum(Status.bad_dimensions);
}

/// Exact inverse of bk_pyramid_analyze: bands (prefix layout) → image.
/// Same side/base/scratch contract.
export fn bk_pyramid_synthesize(
    bands: [*]const i32,
    side: u32,
    base: u32,
    out_img: [*]i32,
    scratch: [*]i32,
) c_int {
    const n = @as(usize, side) * @as(usize, side);
    const ok = pyramid.synthesize(bands[0..n], side, base, out_img[0..n], scratch[0 .. n / 2]);
    return if (ok) @intFromEnum(Status.ok) else @intFromEnum(Status.bad_dimensions);
}

/// DNG → LAB, last link: interleaved linear-ProPhoto f32 RGB (the output
/// of bk_apply_color_matrix) → interleaved Q16 OKLab i32 — the pyramid's
/// exact integer domain. Deterministic by construction (owned cbrt, pinned
/// op order, f64 math); gated bit-exact by fixtures/colorpath_golden.json.
export fn bk_oklab_q16_from_prophoto(
    rgb: [*]const f32,
    n_px: usize,
    out: [*]i32,
) void {
    oklab.quantizeProPhotoToOklab(rgb[0 .. 3 * n_px], out[0 .. 3 * n_px]);
}

/// Linear-light box downsample: interleaved RGB f32 (width×height) → RGB f32
/// ((width/k)×(height/k)). k must divide both dimensions. Deterministic
/// (single f64 accumulator per channel, pinned order); gated bit-exact by
/// the boxReduce section of fixtures/colorpath_golden.json.
export fn bk_box_reduce_rgb(
    rgb: [*]const f32,
    width: u32,
    height: u32,
    k: u32,
    out: [*]f32,
) void {
    const w: usize = width;
    const h: usize = height;
    const kk: usize = k;
    reduce.boxReduceRgb(rgb[0 .. 3 * w * h], w, h, kk, out[0 .. 3 * (w / kk) * (h / kk)]);
}

/// GIF-target index map: planar Q16 OKLab pixels vs the 256-entry planar Q16
/// seed palette → u8 indices. Integer i64 argmin, ties → lowest index.
/// Gated bit-exact by fixtures/giftarget_golden.json.
export fn bk_index_map(
    px_l: [*]const i32,
    px_a: [*]const i32,
    px_b: [*]const i32,
    n_px: usize,
    pal_l: [*]const i32,
    pal_a: [*]const i32,
    pal_b: [*]const i32,
    out: [*]u8,
) void {
    giftarget.indexMap(px_l[0..n_px], px_a[0..n_px], px_b[0..n_px],
        pal_l[0..256], pal_a[0..256], pal_b[0..256], out[0..n_px]);
}

/// Display path: planar Q16 OKLab → interleaved sRGB8 (3·n_px bytes out).
/// Ottosson inverse literals + the GENERATED normative encode table.
export fn bk_oklab_q16_to_srgb8(
    px_l: [*]const i32,
    px_a: [*]const i32,
    px_b: [*]const i32,
    n_px: usize,
    out: [*]u8,
) void {
    giftarget.srgb8Batch(px_l[0..n_px], px_a[0..n_px], px_b[0..n_px], out[0 .. 3 * n_px]);
}

/// Per-frame normalization onto the common scene scale (per-frame GIF
/// rendering): lin = (raw − black)/(white − black) · inv_e, clamped ≥ 0.
export fn bk_normalize_mosaic(
    samples: [*]const u16,
    n: usize,
    black: f32,
    white: f32,
    inv_e: f32,
    out: [*]f32,
) void {
    fuse.normalizeMosaic(samples[0..n], black, white, inv_e, out[0..n]);
}

/// Multi-scale stack length for a mosaic side (Σ r² over its rungs).
export fn bk_ms_stack_len(side: u32) usize {
    return multiscale.stackLen(side);
}

/// The custom ISP (Phase 3): normalized f32 mosaic → per-channel residual
/// stacks in Q16 OKLab. Each rung is its OWN demosaic; prefix through rung
/// r decodes to exactly that rung (MS laws). cam_to_pp is the camera →
/// ProPhoto 3×3 (row-major f32; pass has_color=false to use identity).
/// Each out buffer holds bk_ms_stack_len(side) i32. Returns BK_OK or
/// BK_BAD_DIMENSIONS.
export fn bk_ms_encode(
    mosaic: [*]const f32,
    side: u32,
    cfa: u32,
    cam_to_pp: [*]const f32,
    has_color: bool,
    out_l: [*]i32,
    out_a: [*]i32,
    out_b: [*]i32,
) c_int {
    var m = [9]f64{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    if (has_color) {
        for (0..9) |i| m[i] = cam_to_pp[i];
    }
    const n = @as(usize, side) * @as(usize, side);
    const total = multiscale.stackLen(side);
    const ok = multiscale.encode(mosaic[0..n], side, cfa, m,
        out_l[0..total], out_a[0..total], out_b[0..total]);
    return if (ok) @intFromEnum(Status.ok) else @intFromEnum(Status.bad_dimensions);
}

/// Decode one channel's prefix back to the rung-r demosaic (rung² i32 out).
export fn bk_ms_decode(
    bands: [*]const i32,
    side: u32,
    rung: u32,
    out: [*]i32,
) c_int {
    const total = multiscale.stackLen(side);
    const ok = multiscale.decodeRung(bands[0..total], side, rung,
        out[0 .. @as(usize, rung) * rung]);
    return if (ok) @intFromEnum(Status.ok) else @intFromEnum(Status.bad_dimensions);
}

/// Exact byte size of an encoded GIF (side² frames, fixed-9-bit scheme).
export fn bk_gif_encoded_len(side: u32, n_frames: u32) usize {
    return gifwire.encodedLen(side, n_frames);
}

/// Encode an animated GIF89a: flat frames (n_frames × side² palette
/// indices), a 768-byte GCT, per-frame delay in centiseconds, infinite
/// loop. Deterministic fixed-9-bit LZW (never grows, any decoder reads
/// it). Returns bytes written, or 0 on a too-small buffer. Gated
/// byte-exact by fixtures/gifwire_golden.json.
export fn bk_gif_encode(
    frames: [*]const u8,
    n_frames: u32,
    side: u32,
    gct: [*]const u8,
    delay_cs: u32,
    out: [*]u8,
    out_len: usize,
) usize {
    const n = @as(usize, side) * side;
    return gifwire.encode(frames[0 .. @as(usize, n_frames) * n], n_frames, side,
        gct[0..768], delay_cs, out[0..out_len]);
}

test "root: status enum stays in sync with bridging header values" {
    try std.testing.expectEqual(@as(c_int, 0),  @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, 12), @intFromEnum(Status.allocation_failed));
}

test "root: ref all decls" {
    std.testing.refAllDecls(@This());
}

test "root: Mosaic ABI parity (matches bk_mosaic_t in BorealKernel.h)" {
    // The C header lays these fields out identically; drift means Swift reads
    // garbage. Layout: 10×u32 (incl. CfaPattern=c_int) → wb @40, exposure/iso/
    // fnumber @52/56/60, cam_to_pp[9] @64..100, has_color @100, then samples is
    // pointer-aligned to @104 and the struct rounds to 112B.
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Mosaic, "wb_r"));
    try std.testing.expectEqual(@as(usize, 52), @offsetOf(Mosaic, "exposure_time"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Mosaic, "iso"));
    try std.testing.expectEqual(@as(usize, 60), @offsetOf(Mosaic, "fnumber"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(Mosaic, "cam_to_pp"));
    try std.testing.expectEqual(@as(usize, 100), @offsetOf(Mosaic, "has_color"));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(Mosaic, "samples"));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(Mosaic));
}
