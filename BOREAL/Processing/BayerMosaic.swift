import Foundation

/// A planar Bayer RGGB mosaic in memory. Row-major UInt16 samples (one per
/// photosite) plus the metadata needed to interpret them: bit depth, black
/// and white levels, and the dimensions.
///
/// The struct itself is decoder-agnostic — it doesn't care whether the
/// samples were extracted from a compressed iPhone DNG via CIRAWFilter, an
/// uncompressed DNG via the Zig parser, or a synthetic test fixture.
/// The downstream binner and binomial encoder consume `BayerMosaic` and
/// don't need to know how it was produced.
///
/// Bayer phase invariant: sample at (row=0, col=0) is an R photosite.
/// Width and height MUST be even so a crop with even origin preserves this.
struct BayerMosaic: Sendable, Equatable {
    let width: Int
    let height: Int
    let bitsPerSample: Int       // 14 on iPhone 17 Pro
    let blackLevel: UInt16       // raw counts of "black" (≈ 528 on iPhone 14-bit)
    let whiteLevel: UInt16       // raw counts of saturation
    let samples: [UInt16]        // length == width * height, row-major

    init(width: Int,
         height: Int,
         bitsPerSample: Int,
         blackLevel: UInt16,
         whiteLevel: UInt16,
         samples: [UInt16]) {
        precondition(width > 0 && height > 0, "Bayer mosaic must have positive dims")
        precondition(width % 2 == 0 && height % 2 == 0,
                     "Bayer mosaic must have even dims to preserve RGGB phase")
        precondition(samples.count == width * height,
                     "Bayer samples count \(samples.count) != width*height \(width * height)")
        precondition(bitsPerSample == 14 || bitsPerSample == 16,
                     "Bayer mosaic bitsPerSample must be 14 or 16, got \(bitsPerSample)")
        precondition(whiteLevel > blackLevel,
                     "whiteLevel \(whiteLevel) must exceed blackLevel \(blackLevel)")
        self.width = width
        self.height = height
        self.bitsPerSample = bitsPerSample
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.samples = samples
    }

    /// Read the sample at (row, col) without bounds checking — for hot loops.
    /// Use `safeSample` when bounds are not statically known.
    @inline(__always)
    func sample(row: Int, col: Int) -> UInt16 {
        samples[row * width + col]
    }

    func safeSample(row: Int, col: Int) -> UInt16? {
        guard row >= 0, row < height, col >= 0, col < width else { return nil }
        return samples[row * width + col]
    }
}
