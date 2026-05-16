import Foundation

/// Per-set binomial code-budget pyramid for a 16-set BOREAL session.
///
/// Each set captures `framesPerSet` (= 4) DNGs. The 4 frames within a set
/// resolve, per channel, into one of `pyramid[setIdx]` distinct binomial
/// codes per pixel. The pyramid is symmetric and dyadic so every per-set
/// budget is an exact power of two — the per-pixel storage in the voxel
/// pack is therefore a whole number of bits with no padding.
///
///     setIdx:   0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
///     codes:    1  1  2  4  8 16 32 64 64 32 16  8  4  2  1  1
///     bits:     0  0  1  2  3  4  5  6  6  5  4  3  2  1  0  0
///
/// Sum of `pyramid` is 256 — the conservation invariant. Across the whole
/// 64-frame GIF, exactly 256 distinct per-channel temporal-dither codes are
/// spent (per channel; R, G, B are independent).
enum PyramidTable {

    /// Number of capture sets in a BOREAL session.
    static let setCount: Int = 16

    /// DNGs captured per set.
    static let framesPerSet: Int = 4

    /// Total DNGs per session = setCount * framesPerSet = 64.
    static let totalFrameCount: Int = setCount * framesPerSet

    /// Per-channel binomial code budget for each set.
    static let pyramid: [Int] = [1, 1, 2, 4, 8, 16, 32, 64,
                                 64, 32, 16, 8, 4, 2, 1, 1]

    /// Total code budget across all sets, per channel. Invariant: 256.
    static let codeBudgetSumPerChannel: Int = 256

    /// Code budget for `setIdx`. Traps on out-of-range index.
    static func codeBudget(setIdx: Int) -> Int {
        precondition(setIdx >= 0 && setIdx < setCount,
                     "setIdx \(setIdx) out of range 0..<\(setCount)")
        return pyramid[setIdx]
    }

    /// Bits required to represent one per-pixel-per-channel code in this set.
    /// `bitsPerCode(0) == 0` — the budget of 1 carries no information per pixel,
    /// so the voxel pack stores nothing for that set's code stream.
    static func bitsPerCode(setIdx: Int) -> Int {
        let budget = codeBudget(setIdx: setIdx)
        // Powers-of-two only; trailingZeroBitCount is exact log2 here.
        return budget.trailingZeroBitCount
    }
}
