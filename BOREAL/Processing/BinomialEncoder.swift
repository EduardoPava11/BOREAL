import Foundation

/// Phase 2 Stage 4: per-spatial-bin binomial encode of a set's 4 LAB
/// frames into 10 columnar arrays ready for the .bvox writer.
///
/// Wraps the Zig kernel's `bk_binomial_encode_set` C ABI. The actual
/// per-bin SIMD work (`@Vector(4, f32)` reductions, base-4 packing,
/// flag-bit computation) lives in `zig/borealkernel/src/binomial.zig`.
///
/// Per-call cost on iPhone 17 Pro / A19 Pro: ~25 μs single-threaded for
/// 4096 bins × 3 channels = 12,288 NEON-reduced scalar emissions.
enum BinomialEncoder {

    /// Output of one set's encode — 10 contiguous arrays mirroring the
    /// .bvox columnar layout. Length of each array = 4096 (one per bin).
    struct Columns {
        var L_min:       [Float]
        var L_max:       [Float]
        var L_mean:      [Float]
        var a_min:       [Float]
        var a_max:       [Float]
        var a_mean:      [Float]
        var b_min:       [Float]
        var b_max:       [Float]
        var b_mean:      [Float]
        var codesFlags:  [UInt32]

        static let binCount: Int = 64 * 64

        init() {
            self.L_min       = [Float](repeating: 0, count: Self.binCount)
            self.L_max       = [Float](repeating: 0, count: Self.binCount)
            self.L_mean      = [Float](repeating: 0, count: Self.binCount)
            self.a_min       = [Float](repeating: 0, count: Self.binCount)
            self.a_max       = [Float](repeating: 0, count: Self.binCount)
            self.a_mean      = [Float](repeating: 0, count: Self.binCount)
            self.b_min       = [Float](repeating: 0, count: Self.binCount)
            self.b_max       = [Float](repeating: 0, count: Self.binCount)
            self.b_mean      = [Float](repeating: 0, count: Self.binCount)
            self.codesFlags  = [UInt32](repeating: 0, count: Self.binCount)
        }

        /// Read one bin's L_code (base-4 quantization, 0..255) at spatial index.
        @inline(__always)
        func lCode(at idx: Int) -> UInt8 { UInt8(codesFlags[idx] & 0xFF) }
        @inline(__always)
        func aCode(at idx: Int) -> UInt8 { UInt8((codesFlags[idx] >> 8) & 0xFF) }
        @inline(__always)
        func bCode(at idx: Int) -> UInt8 { UInt8((codesFlags[idx] >> 16) & 0xFF) }
        @inline(__always)
        func flags(at idx: Int) -> UInt8 { UInt8((codesFlags[idx] >> 24) & 0xFF) }
    }

    /// Encode a set's 4 LAB frames into 10 columnar buffers.
    ///
    /// `labFrames` MUST have length exactly `4 × 64 × 64 × 3 = 49,152`,
    /// laid out as 4 contiguous frame blocks of `64 × 64 × 3` interleaved
    /// LAB triples (the natural output of 4 sequential `BayerBinner.binToLAB`
    /// calls concatenated in frame order).
    static func encodeSet(_ labFrames: [Float]) -> Columns {
        precondition(labFrames.count == 4 * 64 * 64 * 3,
                     "labFrames must be exactly 49,152 floats; got \(labFrames.count)")

        var cols = Columns()

        labFrames.withUnsafeBufferPointer { lab in
            cols.L_min.withUnsafeMutableBufferPointer { lMin in
            cols.L_max.withUnsafeMutableBufferPointer { lMax in
            cols.L_mean.withUnsafeMutableBufferPointer { lMean in
            cols.a_min.withUnsafeMutableBufferPointer { aMin in
            cols.a_max.withUnsafeMutableBufferPointer { aMax in
            cols.a_mean.withUnsafeMutableBufferPointer { aMean in
            cols.b_min.withUnsafeMutableBufferPointer { bMin in
            cols.b_max.withUnsafeMutableBufferPointer { bMax in
            cols.b_mean.withUnsafeMutableBufferPointer { bMean in
            cols.codesFlags.withUnsafeMutableBufferPointer { cf in
                _ = bk_binomial_encode_set(
                    lab.baseAddress,
                    lMin.baseAddress, lMax.baseAddress, lMean.baseAddress,
                    aMin.baseAddress, aMax.baseAddress, aMean.baseAddress,
                    bMin.baseAddress, bMax.baseAddress, bMean.baseAddress,
                    cf.baseAddress
                )
            }}}}}}}}}}
        }

        return cols
    }
}
