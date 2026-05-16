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

/* Per-bin binomial encode for one set's 4 LAB frames.
 *
 * lab_frames: pointer to 4 × 64*64*3 = 49,152 floats, laid out as
 *   [frame0_lab_interleaved, frame1, frame2, frame3].
 * Each col_* output buffer must point to a caller-allocated array of at
 * least 4096 elements (= 64*64 spatial bins). Caller owns all buffers.
 * col_codes_flags layout per bin:
 *   bits  0..7   = L_code (256 base-4 quantization patterns)
 *   bits  8..15  = a_code
 *   bits 16..23  = b_code
 *   bits 24..31  = flags (precomputed predicates) */
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
    uint32_t    *col_codes_flags
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
/* bit 7 reserved */

#ifdef __cplusplus
}
#endif

#endif /* BOREALKERNEL_H */
