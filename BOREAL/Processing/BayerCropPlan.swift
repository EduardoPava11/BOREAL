import Foundation

/// Single source of truth for BOREAL's sensor/crop/bin geometry.
///
/// The chain of derivations (all integer math, no rounding):
///
///     binCount       = 64                              ← desired output spatial dim
///     bayerBlockSize = 46                              ← even, so RGGB phase aligns
///     cropSize       = binCount * bayerBlockSize       = 2944
///     sensorWidth    = 4032                            ← iPhone 17 Pro 12 MP binned
///     sensorHeight   = 3024
///     cropOriginX    = (sensorWidth  - cropSize) / 2   = 544   (even ✓)
///     cropOriginY    = (sensorHeight - cropSize) / 2  =  40   (even ✓)
///
/// The "even origin" property is what preserves the RGGB Bayer phase across
/// the crop: row 0 / column 0 of the cropped mosaic is still an R sample.
/// `BayerCenterCropper` enforces this with `assertEvenOrigin()` so a future
/// change to `binCount` that produces odd slack fails loudly before it can
/// scramble Bayer phase.
///
/// `DNGCropTagEditor.CropPlan` writes the same numbers as IFD tags (metadata
/// crop honored by Lightroom etc.). This module is for the *physical* crop
/// applied at Phase 2 read time.
enum BayerCropPlan {

    static let sensorWidth: Int  = 4032
    static let sensorHeight: Int = 3024

    static let binCount: Int       = 64
    static let bayerBlockSize: Int = 46

    static let cropSize: Int = binCount * bayerBlockSize    // 2944

    static let cropOriginX: Int = (sensorWidth  - cropSize) / 2   // 544
    static let cropOriginY: Int = (sensorHeight - cropSize) / 2   //  40

    /// Per-output-pixel sample budget after binning a `bayerBlockSize × bayerBlockSize`
    /// patch into one RGB triple. 23² complete RGGB unit cells per pixel.
    static let rggbCellsPerOutputPixel: Int = (bayerBlockSize / 2) * (bayerBlockSize / 2)
    static let totalSamplesPerOutputPixel: Int = bayerBlockSize * bayerBlockSize
}
