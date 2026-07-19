// GeometryKernel — the crop derivation (CS1/CS6/CS7), spec-gated.
//
// The canonical side and crop origin used to live as private math in
// BurstController; the geometry fixture's crop-case table now replays
// them in the gate (spec/verify-swift), so they live here as kernels.
// Conventions: Boreal.Geometry (Haskell) is the source; fixtures carry
// the device-verified mosaic 4032×3024 (c386663).

import Foundation

extension BorealKernels {

    /// The spec canonical crop cap: 256·2^3 (CS1).
    static let canonicalSideCap = 2048

    /// Largest 256·2^j ≤ min(width, height), capped at 2048 (CS1/CS6).
    /// nil when the mosaic can't cover even the 256² ceiling.
    static func canonicalSide(width: Int, height: Int) -> Int? {
        let m = min(width, height)
        guard m >= 256 else { return nil }
        var s = 256
        while s * 2 <= m && s * 2 <= canonicalSideCap { s *= 2 }
        return s
    }

    /// Centered crop origin snapped DOWN to an even coordinate so the
    /// CFA phase (and therefore frame.cfa) is preserved (CS7).
    static func cropOrigin(_ dim: Int, side: Int) -> Int {
        ((dim - side) / 2) & ~1
    }
}
