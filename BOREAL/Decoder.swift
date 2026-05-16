import Foundation
import os

/// Thin Swift wrapper around the Zig kernel's C ABI (`BorealKernel.h`).
///
/// MVP scope: just `bk_bin_dng_to_rgba64` is exposed so the linker confirms
/// the static library is wired in. Item 4 will add `bk_decode_dng_to_mosaic`
/// and a richer Swift surface (returns `BayerMosaic` directly).
///
/// The Zig kernel ships a static library (`libborealkernel.a`) compiled per
/// platform by `scripts/build-zig.sh` from a pre-build phase. Status codes
/// are integer constants in `bk_status_t` (see `BorealKernel.h`).
enum BorealKernel {

    enum KernelError: Error, CustomStringConvertible {
        case nonZeroStatus(bk_status_t)

        var description: String {
            switch self {
            case .nonZeroStatus(let s):
                return "borealkernel returned bk_status_t=\(s)"
            }
        }
    }

    /// Force-references a Zig symbol so the static library actually gets
    /// pulled in by the linker. Without an explicit symbol reference,
    /// `-lborealkernel` is a no-op for unused archives.
    ///
    /// Called once at app startup (or first access) — the function pointer
    /// itself is the linkage anchor; we don't need to invoke it.
    @inline(never)
    static func keepalive() {
        let _: @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?) -> Int32 =
            bk_bin_dng_to_rgba64
        Log.processing.info("BorealKernel: linkage verified — libborealkernel.a is loaded")
    }
}
