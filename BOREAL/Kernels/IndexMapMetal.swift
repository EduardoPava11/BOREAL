import Foundation
import Metal

/// Metal path for the GIF-target index map (Phase 5 M2) — the hottest kernel
/// at burst load: 68 frames × 65,536 px × 256 palette entries of pure i64
/// integer math. Integer ops on the GPU are EXACT, and the ascending
/// strict-less loop preserves the ties→lowest law, so the GPU result is
/// bit-identical to `BorealKernels.indexMap` (the CPU reference) — the gate's
/// harness proves it against the goldens on the Mac GPU.
///
/// The shader is compiled from source at init (one source of truth; no
/// build-phase plumbing; works identically in-app and in the CLI harness).
/// Unavailable Metal (or a compile failure) → callers fall back to the CPU
/// reference, which is always correct.
final class MetalIndexMapper: @unchecked Sendable {

    /// nil when Metal is unavailable — callers use the CPU reference.
    static let shared: MetalIndexMapper? = MetalIndexMapper()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void index_map(device const int*  pxL  [[buffer(0)]],
                          device const int*  pxA  [[buffer(1)]],
                          device const int*  pxB  [[buffer(2)]],
                          device const int*  palL [[buffer(3)]],
                          device const int*  palA [[buffer(4)]],
                          device const int*  palB [[buffer(5)]],
                          device uchar*      out  [[buffer(6)]],
                          constant uint&     nPx  [[buffer(7)]],
                          uint gid [[thread_position_in_grid]]) {
        if (gid >= nPx) { return; }
        const long pl = pxL[gid];
        const long pa = pxA[gid];
        const long pb = pxB[gid];
        long bestD = 0x7FFFFFFFFFFFFFFF;
        uint best = 0;
        for (uint j = 0; j < 256; ++j) {          // ascending + strict-less
            const long dl = pl - palL[j];          //   => ties -> LOWEST index
            const long da = pa - palA[j];
            const long db = pb - palB[j];
            const long d = dl * dl + da * da + db * db;
            if (d < bestD) { bestD = d; best = j; }
        }
        out[gid] = uchar(best);
    }
    """

    private init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue(),
              let lib = try? dev.makeLibrary(source: Self.source, options: nil),
              let fn = lib.makeFunction(name: "index_map"),
              let pso = try? dev.makeComputePipelineState(function: fn)
        else { return nil }
        device = dev
        queue = q
        pipeline = pso
    }

    /// Bit-identical to `BorealKernels.indexMap`; nil on any Metal failure
    /// (callers fall back to the CPU reference).
    func map(L: [Int32], a: [Int32], b: [Int32],
             palL: [Int32], palA: [Int32], palB: [Int32]) -> [UInt8]? {
        let nPx = L.count
        guard nPx > 0, palL.count == 256, palA.count == 256, palB.count == 256,
              a.count == nPx, b.count == nPx else { return nil }

        func buf(_ xs: [Int32]) -> MTLBuffer? {
            xs.withUnsafeBufferPointer { p in
                device.makeBuffer(bytes: p.baseAddress!,
                                  length: xs.count * 4, options: .storageModeShared)
            }
        }
        guard let bL = buf(L), let bA = buf(a), let bB = buf(b),
              let pL = buf(palL), let pA = buf(palA), let pB = buf(palB),
              let bOut = device.makeBuffer(length: nPx, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return nil }

        var n = UInt32(nPx)
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(bL, offset: 0, index: 0)
        enc.setBuffer(bA, offset: 0, index: 1)
        enc.setBuffer(bB, offset: 0, index: 2)
        enc.setBuffer(pL, offset: 0, index: 3)
        enc.setBuffer(pA, offset: 0, index: 4)
        enc.setBuffer(pB, offset: 0, index: 5)
        enc.setBuffer(bOut, offset: 0, index: 6)
        enc.setBytes(&n, length: 4, index: 7)

        let w = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        enc.dispatchThreads(MTLSize(width: nPx, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }

        return [UInt8](UnsafeBufferPointer(start: bOut.contents()
            .assumingMemoryBound(to: UInt8.self), count: nPx))
    }
}
