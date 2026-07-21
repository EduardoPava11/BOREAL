import Foundation

/// OrientationKernel — the product orientation transform (Daniel's
/// decree 2026-07-19: rotate clockwise, to portrait).
///
/// The sensor is landscape-native (4032×3024); the phone is held
/// portrait. Rotation is applied at the APP layer, AFTER rung decode:
/// a 90°-CW permutation of decoded square planes/index maps. It must
/// NEVER touch the mosaic (rotating Bayer data scrambles the CFA
/// phase and every gated law); the encoder stack (bands) stays
/// sensor-native, documented in the bundles. Everything derived from
/// decoded planes — GIF frames, rung PNGs, preview, the N0 fractal
/// record, σ grids — rotates consistently.
///
///   dst[y][x] = src[side − 1 − x][y]     (row-major, square)
///
/// Pure permutation: palette-preserving, bijective, rotate×4 == id
/// (BOREALTests pins both properties).
extension BorealKernels {

    static func rotateCW<T>(_ buf: [T], side: Int) -> [T] {
        guard buf.count == side * side else { return buf }
        var out = buf
        buf.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<side {
                    for x in 0..<side {
                        dst[y * side + x] = src[(side - 1 - x) * side + y]
                    }
                }
            }
        }
        return out
    }
}
