// BorealKernel.h — bridging header for the Zig-backed proprietary Bayer
// bin-demosaic. Implementation lives in zig/borealkernel/.
//
// The library reads a complete DNG (uncompressed RGGB Bayer at 14 or 16 bpp,
// IFD0-hosted raw mosaic, big- or little-endian TIFF) and writes a fully
// gamma-encoded sRGB 64×64×4 RGBA8 image. Single call, no state.

#ifndef BOREALKERNEL_H
#define BOREALKERNEL_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    BK_OK                                    = 0,
    BK_BAD_TIFF_MAGIC                        = 1,
    BK_UNSUPPORTED_BYTE_ORDER                = 2,
    BK_UNSUPPORTED_COMPRESSION               = 3,   /* generic / unknown */
    BK_UNSUPPORTED_CFA_PATTERN               = 4,
    BK_UNSUPPORTED_BIT_DEPTH                 = 5,
    BK_BAD_DIMENSIONS                        = 6,
    BK_MISSING_TAG                           = 7,
    BK_SHORT_READ                            = 8,
    BK_BAD_OUTPUT_BUFFER                     = 9,
    BK_CROP_TOO_SMALL                        = 10,
    BK_BAD_CROP_ORIGIN                       = 11,
    BK_ALLOCATION_FAILED                     = 12,
    /* 13 reserved (was BK_UNSUPPORTED_COMPRESSION_JPEG; now supported) */
    BK_UNSUPPORTED_COMPRESSION_DEFLATE       = 14,  /* Compression == 8 */
    BK_UNSUPPORTED_COMPRESSION_LOSSY_DNG     = 15,  /* Compression == 34892 */
    BK_UNSUPPORTED_COMPRESSION_APPLE_VC8R    = 16,  /* Compression == 'vc8r' */
    BK_LJPEG_DECODE_FAILED                   = 17,  /* generic LJPEG failure (fallback) */
    BK_NULL_POINTER                          = 18,
    /* Per-variant LJPEG decoder errors. The Swift breadcrumb names exactly
     * which check failed on the iPhone DNG tile — no Zig source spelunking. */
    BK_LJPEG_BAD_MAGIC                       = 19,
    BK_LJPEG_UNEXPECTED_END                  = 20,
    BK_LJPEG_UNSUPPORTED_MARKER              = 21,
    BK_LJPEG_UNSUPPORTED_COMPONENT_COUNT     = 22,
    BK_LJPEG_UNSUPPORTED_PRECISION           = 23,
    BK_LJPEG_UNSUPPORTED_PREDICTOR           = 24,
    BK_LJPEG_HAS_RESTART_MARKERS             = 25,
    BK_LJPEG_MALFORMED_HUFFMAN_TABLE         = 26,
    BK_LJPEG_INVALID_HUFFMAN_CODE            = 27,
} bk_status_t;

/* CFA pattern enum — which channel sits at each 2×2 unit-cell position. */
typedef enum {
    BK_CFA_RGGB = 0,    /* R G / G B */
    BK_CFA_BGGR = 1,    /* B G / G R  ← iPhone 17 Pro main wide */
} bk_cfa_pattern_t;

/* The C ABI mirror of dng.Mosaic. Caller owns the struct (declared on its
 * own stack); on success, `samples` is a libc-malloc'd buffer that the
 * caller MUST free via bk_free_mosaic. On failure, `samples` is null and
 * bk_free_mosaic is a safe no-op. */
typedef struct {
    uint32_t          width;
    uint32_t          height;
    uint32_t          bits_per_sample;
    uint32_t          black_level;
    uint32_t          white_level;
    bk_cfa_pattern_t  cfa;
    uint32_t          crop_origin_x;
    uint32_t          crop_origin_y;
    uint32_t          crop_size_w;
    uint32_t          crop_size_h;
    float             wb_r;        /* AsShotNeutral WB multipliers, green-normalized */
    float             wb_g;        /* (= 1); feeds bk_solve_ettr_exposures' WB prior */
    float             wb_b;
    float             exposure_time; /* EXIF ExposureTime (s); 0 = absent */
    float             iso;           /* EXIF ISO; 0 = absent */
    float             fnumber;       /* EXIF FNumber; 0 = absent */
    float             cam_to_pp[9];  /* camera-native → ProPhoto-linear 3×3 (row-major) */
    bool              has_color;     /* false → cam_to_pp is identity, embed no ICC */
    uint16_t         *samples;     /* heap, length = width * height */
} bk_mosaic_t;

/* Bin one DNG into a 64*64*4 = 16384 byte RGBA8 buffer.
 * Caller owns dng_bytes and out_rgba.
 * out_rgba must have at least 16384 bytes available.
 * Returns BK_OK (= 0) on success. */
int bk_bin_dng_to_rgba64(
    const uint8_t *dng_bytes,
    size_t         dng_len,
    uint8_t       *out_rgba
);

/* Decode a DNG (uncompressed Bayer or LJPEG SOF3) to a u16 mosaic.
 * On success, out_mosaic->samples is a libc-malloc'd buffer of
 * width*height u16 samples that the caller MUST free via bk_free_mosaic.
 * Returns BK_OK on success, non-zero bk_status_t on failure. */
int bk_decode_dng_to_mosaic(
    const uint8_t  *dng_bytes,
    size_t          dng_len,
    bk_mosaic_t    *out_mosaic
);

/* Free a mosaic returned by bk_decode_dng_to_mosaic. Safe to call on a
 * mosaic with samples == null (e.g., after a failed decode). */
void bk_free_mosaic(bk_mosaic_t *mosaic);

/* ── Stage A/B: pre-shutter scene analysis + exposure planning ──────────────
 * RGBT → HDR pivot (see BOREAL-RGBT-HDR-WORKFLOW.md §1). ANALYZE → PLAN. */

/* Per-channel ETTR headroom for the current scene. Mirror of scene.SceneClips.
 * room_* = stops to push that channel's bright tail to ~95% of clip (green is
 * normally smallest — it saturates first); 0 for an absent channel. */
typedef struct {
    float room_r;
    float room_g;
    float room_b;
    float shadow_depth;   /* extra stops, beyond green-ETTR, for the shadow frame */
    bool  present_r;      /* channel carries real signal (bright tail ≥ floor) */
    bool  present_g;
    bool  present_b;
} bk_scene_clips_t;

/* The 4-frame exposure plan: EV offsets (stops) from the base preview exposure,
 * applied via shutter only. Mirror of scene.ExposurePlan. */
typedef struct {
    float ev_green;   /* f1 — green ETTR  */
    float ev_red;     /* f2 — red ETTR    */
    float ev_blue;    /* f3 — blue ETTR   */
    float ev_shadow;  /* f4 — shadow floor */
} bk_exposure_plan_t;

/* Stage A. Analyze an interleaved RGB frame (3 floats/pixel, normalized [0,1];
 * supply UniWB data so per-channel tails reflect raw, not WB-scaled, levels).
 * Caller owns both buffers. */
void bk_analyze_scene(const float *rgb, uint32_t width, uint32_t height, bk_scene_clips_t *out);

/* Stage B. SceneClips + white-balance prior wb_mult[3] = {R,G,B} → 4-frame plan.
 * Present channels use their measured room; absent channels fall back to the WB
 * prior (Δ = log2(wb_c/wb_g)). extra_shadow adds stops to the shadow frame. */
void bk_solve_ettr_exposures(const bk_scene_clips_t *clips, const float *wb_mult, float extra_shadow, bk_exposure_plan_t *out);

/* Stage A, mosaic-direct (GIF-ISP Phase 2): ETTR clips straight from a RAW
 * Bayer mosaic (no demosaic) — feeds the inter-cycle EV re-plan. */
void bk_analyze_mosaic_clips(const uint16_t *samples, uint32_t width,
                             uint32_t height, uint32_t cfa, float black,
                             float white, bk_scene_clips_t *out);

/* Per-frame exposure read-out. Bin a RAW Bayer mosaic (u16 samples, length
 * width*height) into three per-channel display histograms: green at the two
 * off-diagonal CFA sites, red/blue at the corners (swapped for BGGR). Values
 * are normalized by black/white with NO white balance, so the bars show true
 * per-channel exposure — a tail in the top bin means that channel clipped.
 * cfa: 0 = RGGB, 1 = BGGR. Each out_* buffer must hold n_bins uint32_t. */
void bk_channel_histograms(
    const uint16_t *samples,
    uint32_t        width,
    uint32_t        height,
    uint32_t        cfa,
    float           black,
    float           white,
    uint32_t        n_bins,
    uint32_t       *out_r,
    uint32_t       *out_g,
    uint32_t       *out_b
);

/* Live preview exposure read-out. Bin an interleaved 8-bit BGRA video frame (the
 * live AVCaptureVideoDataOutput feed) into three per-channel display histograms.
 * Each channel is normalized by /255 — display-referred 8-bit, so there is NO
 * sensor black/white level and NO white balance (unlike bk_channel_histograms);
 * this is a relative pre-shutter exposure guide, not comparable in absolute terms
 * to the RAW per-frame histograms. row_stride is the buffer's bytesPerRow IN
 * BYTES (a CVPixelBuffer pads each row past width*4 — stride by this, not
 * width*4). Byte order is BGRA: B at offset o, G at o+1, R at o+2, A skipped.
 * Each out_* buffer must hold n_bins uint32_t; all three are zeroed first. */
void bk_rgb_histograms(
    const uint8_t *bgra,
    uint32_t       width,
    uint32_t       height,
    uint32_t       row_stride,
    uint32_t       n_bins,
    uint32_t      *out_r,
    uint32_t      *out_g,
    uint32_t      *out_b
);

/* ── Stage D: RGBT scene-linear fusion (see WORKFLOW §2) ────────────────────
 * Owned algorithm. Mirror of fuse.FuseParams. */
typedef struct {
    float black;          /* sensor black level (raw code) */
    float white;          /* sensor saturation level (raw code) */
    float exposures[4];   /* per-frame relative exposure ratio e_t */
    float knee;           /* normalized level where saturation rolloff begins (≈0.90) */
    float clip;           /* normalized level where weight reaches 0 (≈0.98) */
} bk_fuse_params_t;

/* Fuse 4 raw frames (u16, each length n) into one scene-linear f32 buffer.
 * out must hold ≥ n floats. Channel-agnostic, saturation+SNR weighted. */
void bk_fuse_mosaics(
    const uint16_t *f0,
    const uint16_t *f1,
    const uint16_t *f2,
    const uint16_t *f3,
    size_t          n,
    const bk_fuse_params_t *params,
    float          *out
);

/* Compute per-frame relative exposure ratios e_t from each frame's EXIF
 * (ExposureTime/ISO/FNumber, 0 = absent). Single source of truth for
 * direction/normalization/fallback/clamp. out[t] in [1.0, 32.0], darkest = 1.0.
 * Returns {1,1,1,1} when there is no usable bracket. */
void bk_relative_exposures(const float et[4], const float iso[4], const float fnum[4], float out[4]);

/* ── Output B: owned 64³ .cube LUT baker (see WORKFLOW §4) ──────────────────
 * ASC-CDL grade. Mirror of lut.LookParams. */
typedef struct {
    float slope[3];   /* per-channel gain   */
    float offset[3];  /* per-channel lift   */
    float power[3];   /* per-channel gamma  */
    float luma_w[3];  /* luminance weights for the saturation mix */
    float sat;        /* saturation (1 = identity) */
} bk_look_params_t;

/* Bake the look into a grid^3 * 3 interleaved RGB lattice (red fastest).
 * out must hold grid*grid*grid*3 floats. Use grid = 64 for Photoshop. */
void bk_build_cube_lut(const bk_look_params_t *params, uint32_t grid, float *out);

/* Serialize a baked lattice as Adobe/Resolve .cube text into buf. Returns bytes
 * written, or 0 if buf is too small. */
size_t bk_emit_cube(const float *lattice, uint32_t grid, uint8_t *buf, size_t buf_len);

/* Apply the SAME ASC-CDL look the cube bakes to an interleaved RGB f32 buffer of
 * n_px pixels, in place ([0,1] display-referred). Used to make the on-screen
 * preview match the exported .cube exactly (★preview≡cube). */
void bk_apply_look(float *rgb, size_t n_px, const bk_look_params_t *params);

/* ── Phase 1: full-resolution demosaic (see WORKFLOW §2) ────────────────────
 * Malvar–He–Cutler high-quality linear demosaic. Input: single-channel fused
 * scene-linear mosaic. cfa: 0 = RGGB, 1 = BGGR. out holds w*h*3 floats. */
void bk_demosaic_full(const float *m, uint32_t width, uint32_t height, uint32_t cfa, float *out);

/* ── Colour transform: camera-native → ProPhoto linear (see WORKFLOW §3) ─────
 * Apply the mosaic's cam_to_pp 3×3 (row-major) to an interleaved RGB f32 buffer
 * of n_px pixels, in place. Negatives clamp to 0; HDR highlights (>1) kept. */
void bk_apply_color_matrix(float *rgb, size_t n_px, const float *matrix);

/* ── Output A: owned 32-bit-float HDR TIFF encoder (see WORKFLOW §3) ────────
 * Baseline little-endian RGB TIFF, SampleFormat=IEEE-float, single strip. */

/* Bytes needed for a width×height float-RGB TIFF with an icc_len-byte ICC. */
size_t bk_tiff_size(uint32_t width, uint32_t height, size_t icc_len);

/* Encode a 32-bit-float RGB TIFF into buf. pixels = interleaved RGB,
 * length >= width*height*3. icc may be NULL (icc_len 0). Returns bytes
 * written, or 0 if buf is too small. */
size_t bk_write_tiff_f32(
    uint32_t       width,
    uint32_t       height,
    const float   *pixels,
    const uint8_t *icc,
    size_t         icc_len,
    uint8_t       *buf,
    size_t         buf_len
);

/* v4 per-set trailer scalars, mirror of binomial.PerSetTrailer in Zig.
 * Populated by bk_binomial_encode_set and packed into the .bvox trailer's
 * reserved bytes by the VoxelPack writer. */
typedef struct {
    float rho1_L;             /* global lag-1 horizontal autocorr of L_mean */
    float rho1_a;
    float rho1_b;
    float kl_L_to_gaussian;   /* KL of L_mean histogram vs N(μ, σ²) */
} bk_per_set_trailer_t;

/* v4 per-session slow-scale scalars, mirror of binomial.SlowScalars in Zig. */
typedef struct {
    float slow_rho1_L;
    float slow_rho1_a;
    float slow_rho1_b;
    float nu_L;               /* σ²_between / σ²_total (Theorem 6 Ch.1) */
} bk_slow_scalars_t;

/* Per-bin binomial encode for one set's 4 LAB frames (v4 ABI).
 *
 * lab_frames: pointer to 4 × 64*64*3 = 49,152 floats, laid out as
 *   [frame0_lab_interleaved, frame1, frame2, frame3].
 * Each col_* output buffer must point to a caller-allocated array of at
 * least 4096 elements (= 64*64 spatial bins). Caller owns all buffers.
 * col_codes_flags layout per bin:
 *   bits  0..7   = L_code (256 base-4 quantization patterns)
 *   bits  8..15  = a_code
 *   bits 16..23  = b_code
 *   bits 24..31  = flags (precomputed predicates, see BK_FLAG_*)
 * col_{L,a,b}_shape layout per bin (v3 SHAPE descriptor):
 *   bits  0..7   = sigma_q8    — σ × 2, 0.5 LSB on channel scale
 *   bits  8..15  = gamma3_s8   — skewness γ₃ × 64, signed i8
 *   bits 16..23  = gamma4_s8   — excess kurtosis γ₄ × 32, signed i8
 *   bits 24..29  = chi2_u6     — χ² to Bin(3, 0.5) × 2, clamped 0..63
 *   bits 30..31  = shape_class — 0=SYMMETRIC, 1=LEFT_SKEW, 2=RIGHT_SKEW, 3=BIMODAL
 *
 * v4 columns:
 *   col_fast_cov_La/Lb/ab — per-bin cross-channel covariance over 4 frames
 *   col_fast_nbr_rho_*    — per-bin 4-neighbor spatial autocorrelation
 *   col_fast_motion       — per-bin ‖LAB[frame3] - LAB[frame0]‖ Euclidean drift */
/* User-chosen 4-frame central-tendency estimator. Default (0) =
 * arithmetic mean, byte-identical to v4 behavior. */
typedef enum {
    BK_COMBINER_MEAN                       = 0u,
    BK_COMBINER_MEDIAN                     = 1u,
    BK_COMBINER_INVERSE_VARIANCE_WEIGHTED  = 2u,
    BK_COMBINER_TRIMMED_MEAN               = 3u,
} bk_combiner_t;

int bk_binomial_encode_set(
    const float *lab_frames,
    float       *col_L_min,
    float       *col_L_max,
    float       *col_L_mean,
    float       *col_a_min,
    float       *col_a_max,
    float       *col_a_mean,
    float       *col_b_min,
    float       *col_b_max,
    float       *col_b_mean,
    uint32_t    *col_codes_flags,
    uint32_t    *col_L_shape,
    uint32_t    *col_a_shape,
    uint32_t    *col_b_shape,
    float       *col_fast_cov_La,
    float       *col_fast_cov_Lb,
    float       *col_fast_cov_ab,
    float       *col_fast_nbr_rho_L,
    float       *col_fast_nbr_rho_a,
    float       *col_fast_nbr_rho_b,
    float       *col_fast_motion,
    bk_per_set_trailer_t *out_trailer,
    uint32_t     combiner   /* bk_combiner_t — 0=mean is v4-compatible */
);

/* v4 slow-scale fold across 16 sets' per-bin channel-mean grids. Inputs:
 * 16 pointers to L_mean grids, 16 to a_mean, 16 to b_mean (each 4096
 * floats). Outputs: 10 per-bin slow columns + 4 session-level scalars.
 * Same statistical pipeline as the fast scale, just N=16 (instead of N=4)
 * and per-session (instead of per-set). Stored in the .bcube SLOW block. */
int bk_slow_fold_session(
    const float * const *L_means_ptrs,    /* 16 × float* (L_mean grids) */
    const float * const *a_means_ptrs,
    const float * const *b_means_ptrs,
    float       *out_slow_L_mean,
    float       *out_slow_a_mean,
    float       *out_slow_b_mean,
    float       *out_slow_L_var,
    float       *out_slow_a_var,
    float       *out_slow_b_var,
    float       *out_slow_cov_La,
    float       *out_slow_cov_Lb,
    float       *out_slow_cov_ab,
    float       *out_slow_motion,
    bk_slow_scalars_t *out_scalars
);

/* Flag bits packed into col_codes_flags' high byte. Mirror binomial.zig's
 * FLAG_* constants. */
#define BK_FLAG_STATIC                 (1u << 0)
#define BK_FLAG_MONOTONIC_INCREASING   (1u << 1)
#define BK_FLAG_MONOTONIC_DECREASING   (1u << 2)
#define BK_FLAG_TEMPORAL_PULSE         (1u << 3)
#define BK_FLAG_HIGH_CHROMA            (1u << 4)
#define BK_FLAG_HIGH_LUMA              (1u << 5)
#define BK_FLAG_LOW_LUMA               (1u << 6)
#define BK_FLAG_BEAUTY                 (1u << 7)  /* L.chi2 < 4 — close to Bin(3, 0.5) */

/* Shape-class enum values stored in col_*_shape bits 30..31. */
#define BK_SHAPE_SYMMETRIC   0u
#define BK_SHAPE_LEFT_SKEW   1u
#define BK_SHAPE_RIGHT_SKEW  2u
#define BK_SHAPE_BIMODAL     3u

/* ── Embedded S-transform pyramid (spec/Boreal/Pyramid.hs contract) ──────
 *
 * Image (side² int32, row-major) ⇄ coefficient bands (side² int32, PREFIX
 * layout): top band base² row-major at [0, base²); detail level with
 * quad-grid side s at [s², 4·s²) as interleaved (LH, HL, HH) per quad,
 * levels coarse→fine. Prefixes telescope: every prefix is a rung
 * (16², 32², 64², 128², 256²). The 16×16 latent frame IS bands[0..256);
 * back-trace = exact inverse transform, reading deeper into the buffer.
 *
 * side and base must be powers of two with base <= side. Caller owns all
 * buffers; scratch must hold (side*side)/2 elements. Returns BK_OK or
 * BK_BAD_DIMENSIONS (as int, per the house prototype convention).
 * Gated bit-exact by fixtures/pyramid_golden.json. */
int bk_pyramid_analyze(const int32_t *img, uint32_t side, uint32_t base,
                       int32_t *out_bands, int32_t *scratch);
int bk_pyramid_synthesize(const int32_t *bands, uint32_t side, uint32_t base,
                          int32_t *out_img, int32_t *scratch);

/* ── DNG → LAB: linear ProPhoto → OKLab → Q16 (Boreal.ColorPath) ────────
 *
 * rgb = interleaved linear-ProPhoto f32 (output of bk_apply_color_matrix),
 * out = interleaved OKLab in Q16 int32 (L,a,b per pixel) — the pyramid's
 * exact integer domain. Deterministic by construction: owned cbrt (never
 * libm), pinned matrix op order, f64 math throughout. Caller owns both
 * buffers (3*n_px each). Gated bit-exact by fixtures/colorpath_golden.json. */
void bk_oklab_q16_from_prophoto(const float *rgb, size_t n_px, int32_t *out);

/* Linear-light box downsample (L2 step 6): interleaved RGB f32 in, RGB f32
 * out at (width/k)x(height/k). k must divide both dimensions. Runs BEFORE
 * OKLab because averaging light is only correct in linear space. Caller owns
 * both buffers. Gated bit-exact by fixtures/colorpath_golden.json. */
void bk_box_reduce_rgb(const float *rgb, uint32_t width, uint32_t height,
                       uint32_t k, float *out);

/* ── GIF target: index map + display palette (Boreal.GifTarget) ─────────
 *
 * The ISP targets GIF structure: a 256-color palette seeded by the 16x16
 * latent (grid position == palette color) and a u8 index map per rung.
 * bk_index_map: planar Q16 OKLab pixels vs the planar 256-entry palette,
 * integer i64 argmin, ties -> LOWEST index. bk_oklab_q16_to_srgb8: planar
 * Q16 OKLab -> interleaved sRGB bytes (3*n_px) via Ottosson's inverse and
 * the generated normative encode table (never pow at runtime). Both gated
 * bit-exact by fixtures/giftarget_golden.json. */
void bk_index_map(const int32_t *px_l, const int32_t *px_a, const int32_t *px_b,
                  size_t n_px, const int32_t *pal_l, const int32_t *pal_a,
                  const int32_t *pal_b, uint8_t *out);
void bk_oklab_q16_to_srgb8(const int32_t *px_l, const int32_t *px_a,
                           const int32_t *px_b, size_t n_px, uint8_t *out);

/* ── Multi-scale demosaic: the custom ISP (Boreal.MultiScale, MS laws) ───
 *
 * Each rung r in {16,32,64,128,256} (side%r==0, side/r even >= 2) is its
 * OWN demosaic of the normalized mosaic (per-CFA-channel exact mean at
 * that rung's cell size -> camera->ProPhoto -> OKLab Q16). The latent is
 * the RESIDUAL STACK per channel: rung16 ++ (rung2s - nearest-up(rungS)),
 * coarse->fine; prefix through rung r = sum of r'^2 and decodes to THE
 * rung-r demosaic. Overcomplete by design: every residual is a JEPA
 * prediction target. bk_ms_stack_len(2048) == 87296. Caller owns all
 * buffers. Gated bit-exact by fixtures/multiscale_golden.json. */
size_t bk_ms_stack_len(uint32_t side);
int bk_ms_encode(const float *mosaic, uint32_t side, uint32_t cfa,
                 const float *cam_to_pp, bool has_color,
                 int32_t *out_l, int32_t *out_a, int32_t *out_b);
int bk_ms_decode(const int32_t *bands, uint32_t side, uint32_t rung,
                 int32_t *out);

/* ── GIF89a wire (Boreal.GifWire, laws W1-W5) ───────────────────────────
 *
 * Deterministic animated GIF: fixed-9-bit LZW (CLEAR every 254 index
 * codes so the code width never grows — byte-exact everywhere, readable
 * by any decoder), one global 768-byte color table, NETSCAPE infinite
 * loop, per-frame delay in centiseconds. frames = n_frames x side^2
 * palette indices, flat. bk_gif_encoded_len gives the EXACT output size
 * (the format's length is a closed form). Returns bytes written or 0.
 * Gated byte-exact by fixtures/gifwire_golden.json. */
size_t bk_gif_encoded_len(uint32_t side, uint32_t n_frames);
size_t bk_gif_encode(const uint8_t *frames, uint32_t n_frames, uint32_t side,
                     const uint8_t *gct, uint32_t delay_cs,
                     uint8_t *out, size_t out_len);

#ifdef __cplusplus
}
#endif

#endif /* BOREALKERNEL_H */
