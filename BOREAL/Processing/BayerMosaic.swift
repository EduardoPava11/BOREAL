import Foundation

/// Bayer color-filter-array (CFA) pattern — declares which channel sits at
/// each of the 2×2 unit cell's 4 positions. iPhone 17 Pro main wide camera
/// ships BGGR (verified on device 2026-05-15: `kCVPixelFormatType_14Bayer_BGGR`
/// = `'bgg4'` is the only RAW format the device offers).
///
/// Layouts (read as: `(0,0) (0,1)` / `(1,0) (1,1)`):
///   .rggb → R G / G B
///   .bggr → B G / G R     ← iPhone 17 Pro main wide
///   .grbg → G R / B G
///   .gbrg → G B / R G
///
/// The cropper preserves whatever pattern the source declares; the binner
/// (Stage 3, Phase 2) is the first consumer that interprets the pattern.
enum CFAPattern: String, Sendable, Codable, Equatable {
    case rggb
    case bggr
    case grbg
    case gbrg

    /// Channel at the given position within the 2×2 unit cell, where
    /// (rowParity, colParity) ∈ {0, 1}².
    @inline(__always)
    func channel(rowParity: Int, colParity: Int) -> CFAChannel {
        precondition(rowParity == 0 || rowParity == 1)
        precondition(colParity == 0 || colParity == 1)
        switch self {
        case .rggb:
            return [[.r, .g], [.g, .b]][rowParity][colParity]
        case .bggr:
            return [[.b, .g], [.g, .r]][rowParity][colParity]
        case .grbg:
            return [[.g, .r], [.b, .g]][rowParity][colParity]
        case .gbrg:
            return [[.g, .b], [.r, .g]][rowParity][colParity]
        }
    }
}

/// One of R, G, B at a Bayer photosite.
enum CFAChannel: String, Sendable, Codable, Equatable {
    case r
    case g
    case b
}

/// A planar Bayer mosaic in memory. Row-major UInt16 samples (one per
/// photosite) plus the metadata needed to interpret them: CFA pattern,
/// bit depth, black and white levels, and the dimensions.
///
/// The struct itself is decoder-agnostic — it doesn't care whether the
/// samples were extracted from a compressed iPhone DNG via the Zig
/// parser/decoder or a synthetic test fixture. The downstream binner and
/// binomial encoder consume `BayerMosaic` and don't need to know how it
/// was produced — only what pattern to interpret.
///
/// Phase invariant: sample at (row=0, col=0) belongs to the channel
/// declared by `cfaPattern.channel(rowParity:0, colParity:0)`. Width and
/// height MUST be even so a crop with even origin preserves this.
struct BayerMosaic: Sendable, Equatable {
    let width: Int
    let height: Int
    let cfaPattern: CFAPattern   // .bggr on iPhone 17 Pro
    let bitsPerSample: Int       // 14 on iPhone 17 Pro
    let blackLevel: UInt16       // raw counts of "black" (≈ 528 on iPhone 14-bit)
    let whiteLevel: UInt16       // raw counts of saturation
    let samples: [UInt16]        // length == width * height, row-major

    init(width: Int,
         height: Int,
         cfaPattern: CFAPattern,
         bitsPerSample: Int,
         blackLevel: UInt16,
         whiteLevel: UInt16,
         samples: [UInt16]) {
        precondition(width > 0 && height > 0, "Bayer mosaic must have positive dims")
        precondition(width % 2 == 0 && height % 2 == 0,
                     "Bayer mosaic must have even dims to preserve CFA phase")
        precondition(samples.count == width * height,
                     "Bayer samples count \(samples.count) != width*height \(width * height)")
        precondition(bitsPerSample == 14 || bitsPerSample == 16,
                     "Bayer mosaic bitsPerSample must be 14 or 16, got \(bitsPerSample)")
        precondition(whiteLevel > blackLevel,
                     "whiteLevel \(whiteLevel) must exceed blackLevel \(blackLevel)")
        self.width = width
        self.height = height
        self.cfaPattern = cfaPattern
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
