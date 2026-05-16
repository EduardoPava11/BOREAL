import Foundation

/// Single source of truth for BOREAL's sensor/crop/bin geometry.
///
/// The chain of derivations (all integer math, no rounding):
///
///     binCount       = 64                              ← desired output spatial dim
///     bayerBlockSize = 46                              ← even, so Bayer phase aligns
///     cropSize       = binCount * bayerBlockSize       = 2944
///     sensorWidth    = 4224                            ← iPhone 17 Pro main wide,
///                                                        binned readout (verified
///                                                        on device 2026-05-15 via
///                                                        DNGProbe: ImageWidth=4224)
///     sensorHeight   = 3024
///     cropOriginX    = (sensorWidth  - cropSize) / 2   = 640   (even ✓)
///     cropOriginY    = (sensorHeight - cropSize) / 2  =  40   (even ✓)
///
/// The "even origin" property is what preserves the Bayer phase across the
/// crop: whatever channel sits at sensor `(0, 0)` (B for iPhone 17 Pro's BGGR
/// pattern) also sits at cropped `(0, 0)`. `BayerCenterCropper` enforces this
/// with an even-origin check so a future change to `binCount` that produces
/// odd slack fails loudly before it can scramble the phase.
///
/// Sensor dimension correction history: the initial `sensorWidth = 4032`
/// constant was an assumption (matched older iPhones' main-wide binned mode).
/// iPhone 17 Pro / iOS 26 reports `ImageWidth=4224` per the DNG IFD0 tag.
/// Updated 2026-05-15. The 1.7× shorter slack on the X axis (640 vs 544)
/// doesn't change cropSize, binCount, or any downstream geometry — just
/// where the centered window lands on the wider sensor.
///
/// `DNGCropTagEditor.CropPlan` writes the same numbers as IFD tags (metadata
/// crop honored by Lightroom etc.). This module is for the *physical* crop
/// applied at Phase 2 read time.
enum BayerCropPlan {

    static let sensorWidth: Int  = 4224
    static let sensorHeight: Int = 3024

    static let binCount: Int       = 64
    static let bayerBlockSize: Int = 46

    static let cropSize: Int = binCount * bayerBlockSize    // 2944

    static let cropOriginX: Int = (sensorWidth  - cropSize) / 2   // 640
    static let cropOriginY: Int = (sensorHeight - cropSize) / 2   //  40

    /// Per-output-pixel sample budget after binning a `bayerBlockSize × bayerBlockSize`
    /// patch into one RGB triple. 23² complete Bayer unit cells per pixel.
    static let rggbCellsPerOutputPixel: Int = (bayerBlockSize / 2) * (bayerBlockSize / 2)
    static let totalSamplesPerOutputPixel: Int = bayerBlockSize * bayerBlockSize
}
