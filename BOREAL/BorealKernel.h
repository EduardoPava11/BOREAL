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
    BK_UNSUPPORTED_COMPRESSION_JPEG          = 13,  /* Compression == 7 */
    BK_UNSUPPORTED_COMPRESSION_DEFLATE       = 14,  /* Compression == 8 */
    BK_UNSUPPORTED_COMPRESSION_LOSSY_DNG     = 15,  /* Compression == 34892 */
    BK_UNSUPPORTED_COMPRESSION_APPLE_VC8R    = 16,  /* Compression == 'vc8r' */
} bk_status_t;

// Bin one DNG into a 64*64*4 = 16384 byte RGBA8 buffer.
// Caller owns dng_bytes and out_rgba.
// out_rgba must have at least 16384 bytes available.
// Returns BK_OK (= 0) on success.
int bk_bin_dng_to_rgba64(
    const uint8_t *dng_bytes,
    size_t         dng_len,
    uint8_t       *out_rgba
);

#ifdef __cplusplus
}
#endif

#endif /* BOREALKERNEL_H */
