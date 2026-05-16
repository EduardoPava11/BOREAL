import Foundation
import os

/// Thin Swift wrapper around the Zig kernel's C ABI (`BorealKernel.h`).
///
/// The Zig kernel ships a static library (`libborealkernel.a`) compiled per
/// platform by `scripts/build-zig.sh` from a pre-build phase. Status codes
/// are integer constants in `bk_status_t` (see `BorealKernel.h`).
enum BorealKernel {

    enum KernelError: Error, CustomStringConvertible {
        case nonZeroStatus(Int32)
        case unknownCFA(Int32)
        case nullSamples

        var description: String {
            switch self {
            case .nonZeroStatus(let s): return "borealkernel returned bk_status_t=\(s)"
            case .unknownCFA(let v):    return "borealkernel returned unknown bk_cfa_pattern_t=\(v)"
            case .nullSamples:          return "borealkernel returned BK_OK but samples==null"
            }
        }
    }

    /// Force-references a Zig symbol so the static library actually gets
    /// pulled in by the linker. Without an explicit symbol reference,
    /// `-lborealkernel` is a no-op for unused archives.
    @inline(never)
    static func keepalive() {
        let _: @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?) -> Int32 =
            bk_bin_dng_to_rgba64
        Log.processing.info("BorealKernel: linkage verified — libborealkernel.a is loaded")
    }

    /// Decode an iPhone DNG (uncompressed Bayer or LJPEG SOF3) into a Swift
    /// `BayerMosaic`. Copies the Zig-allocated u16 buffer into a Swift array
    /// so the kernel-managed memory can be freed before this returns.
    ///
    /// - Throws: `KernelError.nonZeroStatus` if the kernel rejects the bytes
    ///   (bad TIFF magic, unsupported compression, malformed LJPEG, etc.).
    /// - Note: Copying the ~12 MB sample buffer takes ~2–5 ms on iPhone NVMe
    ///   bandwidth. Negligible against the ~80 ms LJPEG decode it sits on top of.
    static func decodeDNG(_ dngData: Data) throws -> BayerMosaic {
        var raw = bk_mosaic_t()
        let status = dngData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int32 in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(BK_NULL_POINTER.rawValue)
            }
            return bk_decode_dng_to_mosaic(base, buf.count, &raw)
        }
        guard status == BK_OK.rawValue else {
            // Zig may have left samples=null; bk_free_mosaic is a no-op then.
            bk_free_mosaic(&raw)
            throw KernelError.nonZeroStatus(status)
        }
        guard let samplesPtr = raw.samples else {
            throw KernelError.nullSamples
        }
        defer { bk_free_mosaic(&raw) }

        // Map the Zig CFA enum to Swift's CFAPattern.
        let pattern: CFAPattern
        switch raw.cfa {
        case BK_CFA_RGGB: pattern = .rggb
        case BK_CFA_BGGR: pattern = .bggr
        default:          throw KernelError.unknownCFA(Int32(raw.cfa.rawValue))
        }

        // Copy samples into Swift-owned array. Zig's buffer goes away in the
        // defer above; the Swift array is independent.
        let count = Int(raw.width) * Int(raw.height)
        let samples = Array(UnsafeBufferPointer(start: samplesPtr, count: count))

        return BayerMosaic(
            width: Int(raw.width),
            height: Int(raw.height),
            cfaPattern: pattern,
            bitsPerSample: Int(raw.bits_per_sample),
            blackLevel: UInt16(min(raw.black_level, UInt32(UInt16.max))),
            whiteLevel: UInt16(min(raw.white_level, UInt32(UInt16.max))),
            samples: samples
        )
    }
}
