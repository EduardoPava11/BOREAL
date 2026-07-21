import Foundation
import Metal

/// Metal path for the GIF-target index map (Phase 5 M2; memory discipline
/// per BOREAL-METAL-PRECISION-WORKFLOW.md P2) — the hottest kernel at burst
/// load: 68 frames × 65,536 px × 256 palette entries of pure i64 integer
/// math. Integer ops on the GPU are EXACT, and the ascending strict-less
/// loop preserves the ties→lowest law, so the GPU result is bit-identical
/// to `BorealKernels.indexMap` (the CPU reference) — the gate's harness
/// proves it against the goldens on the Mac GPU.
///
/// Exactness notes for the two optimizations:
///   • palette in `constant` address space (3 KB — lives in the constant
///     cache instead of per-pixel device loads); same integers, same math.
///   • early exit on bestD == 0: distances are sums of squares (≥ 0), so
///     nothing after a zero can win strict-less, and breaking at the FIRST
///     zero is precisely the ties→lowest rule.
///
/// Buffer discipline: one pooled set of input/output buffers, grown to the
/// largest frame seen and reused — zero steady-state allocation inside the
/// burst loop (previously 7 makeBuffer copies per frame). Calls are
/// serialized by a lock; both product paths already reduce serially.
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

    private let lock = NSLock()
    // Pooled buffers (guarded by `lock`): capacity in pixels.
    private var bufL: MTLBuffer?
    private var bufA: MTLBuffer?
    private var bufB: MTLBuffer?
    private var bufOut: MTLBuffer?
    private var capacity = 0
    // GPU wall time per dispatch (ms), drained by Perf into report bundles.
    private var gpuSampleMs: [Double] = []

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void index_map(device const int*  pxL  [[buffer(0)]],
                          device const int*  pxA  [[buffer(1)]],
                          device const int*  pxB  [[buffer(2)]],
                          constant int*      palL [[buffer(3)]],
                          constant int*      palA [[buffer(4)]],
                          constant int*      palB [[buffer(5)]],
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
            if (d < bestD) {
                bestD = d;
                best = j;
                if (d == 0) { break; }             // exact: 0 is unbeatable,
            }                                      //   first 0 = lowest index
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

    /// GPU timings (ms) accumulated since the last drain. Self-contained
    /// here so the spec harness, which compiles Kernels/ alone, stays
    /// closed — the app's Perf collector pulls these into report bundles.
    func drainGPUSampleMs() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        let xs = gpuSampleMs
        gpuSampleMs.removeAll(keepingCapacity: true)
        return xs
    }

    /// Grow-only pool: (re)allocate the four pooled buffers when a larger
    /// frame arrives; otherwise reuse. Caller holds `lock`.
    private func ensureCapacity(_ nPx: Int) -> Bool {
        if nPx <= capacity, bufL != nil { return true }
        guard let L = device.makeBuffer(length: nPx * 4, options: .storageModeShared),
              let a = device.makeBuffer(length: nPx * 4, options: .storageModeShared),
              let b = device.makeBuffer(length: nPx * 4, options: .storageModeShared),
              let o = device.makeBuffer(length: nPx, options: .storageModeShared)
        else { return false }
        bufL = L; bufA = a; bufB = b; bufOut = o
        capacity = nPx
        return true
    }

    /// Bit-identical to `BorealKernels.indexMap`; nil on any Metal failure
    /// (callers fall back to the CPU reference).
    func map(L: [Int32], a: [Int32], b: [Int32],
             palL: [Int32], palA: [Int32], palB: [Int32]) -> [UInt8]? {
        let nPx = L.count
        guard nPx > 0, palL.count == 256, palA.count == 256, palB.count == 256,
              a.count == nPx, b.count == nPx else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard ensureCapacity(nPx),
              let bL = bufL, let bA = bufA, let bB = bufB, let bOut = bufOut,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { return nil }

        func fill(_ buf: MTLBuffer, _ xs: [Int32]) {
            xs.withUnsafeBufferPointer {
                buf.contents().copyMemory(from: $0.baseAddress!,
                                          byteCount: nPx * 4)
            }
        }
        fill(bL, L); fill(bA, a); fill(bB, b)

        var n = UInt32(nPx)
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(bL, offset: 0, index: 0)
        enc.setBuffer(bA, offset: 0, index: 1)
        enc.setBuffer(bB, offset: 0, index: 2)
        // Palettes ride setBytes into the constant address space: 1 KB each
        // (≤ the 4 KB setBytes ceiling), no MTLBuffer, no allocation.
        palL.withUnsafeBufferPointer { enc.setBytes($0.baseAddress!, length: 1024, index: 3) }
        palA.withUnsafeBufferPointer { enc.setBytes($0.baseAddress!, length: 1024, index: 4) }
        palB.withUnsafeBufferPointer { enc.setBytes($0.baseAddress!, length: 1024, index: 5) }
        enc.setBuffer(bOut, offset: 0, index: 6)
        enc.setBytes(&n, length: 4, index: 7)

        let w = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        enc.dispatchThreads(MTLSize(width: nPx, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { return nil }
        if cmd.gpuEndTime > cmd.gpuStartTime {
            gpuSampleMs.append((cmd.gpuEndTime - cmd.gpuStartTime) * 1000)
        }

        return [UInt8](UnsafeBufferPointer(start: bOut.contents()
            .assumingMemoryBound(to: UInt8.self), count: nPx))
    }
}
