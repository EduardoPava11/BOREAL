import Foundation
import Metal

/// Phase 2 Stage 3: bin a cropped 2944² BGGR mosaic into a 64×64×3 LAB
/// tensor on the GPU via `BayerBinLAB.metal`.
///
/// Each call dispatches the `bayerBinLAB_BGGR` compute kernel with one
/// thread per output bin (4096 threads total) and waits for completion.
/// Per-call cost on iPhone 17 Pro / A19 Pro: well under 1 ms.
///
/// The Stage 4 binomial encoder (item 6) consumes the output of 4 calls
/// (one per frame in the set) as its `4 × 64 × 64 × 3` LAB tensor input.
final class BayerBinner {

    enum BinnerError: Error, CustomStringConvertible {
        case noMetalDevice
        case shaderNotFound(String)
        case bufferAllocFailed
        case dispatchFailed(String)
        case wrongMosaicShape(width: Int, height: Int, cfa: CFAPattern)

        var description: String {
            switch self {
            case .noMetalDevice:                  return "Metal device unavailable"
            case .shaderNotFound(let n):          return "Metal function '\(n)' not found in default library"
            case .bufferAllocFailed:              return "MTLDevice.makeBuffer returned nil"
            case .dispatchFailed(let s):          return "Metal dispatch failed: \(s)"
            case .wrongMosaicShape(let w, let h, let cfa):
                return "expected 2944×2944 BGGR mosaic, got \(w)×\(h) \(cfa)"
            }
        }
    }

    /// Per-bin output: 64 × 64 spatial × 3 LAB channels = 12,288 floats.
    static let outputCount: Int = BayerCropPlan.binCount * BayerCropPlan.binCount * 3

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BinnerError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw BinnerError.dispatchFailed("makeCommandQueue returned nil")
        }
        let library = try device.makeDefaultLibrary(bundle: .main)
        guard let function = library.makeFunction(name: "bayerBinLAB_BGGR") else {
            throw BinnerError.shaderNotFound("bayerBinLAB_BGGR")
        }
        self.device = device
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Bin one frame. Synchronous (waitUntilCompleted). Caller is expected
    /// to dispatch this on a background queue if blocking the calling thread
    /// is undesirable. Per-call cost is ~1 ms on iPhone 17 Pro; callers
    /// running 4 frames per set will see ~4 ms total.
    func binToLAB(_ mosaic: BayerMosaic) throws -> [Float] {
        let cropSize = BayerCropPlan.cropSize
        guard mosaic.width == cropSize, mosaic.height == cropSize, mosaic.cfaPattern == .bggr else {
            throw BinnerError.wrongMosaicShape(
                width: mosaic.width, height: mosaic.height, cfa: mosaic.cfaPattern
            )
        }

        // Input buffer: copy the mosaic samples in.
        let mosaicByteCount = cropSize * cropSize * MemoryLayout<UInt16>.size
        guard let mosaicBuffer = device.makeBuffer(length: mosaicByteCount,
                                                   options: .storageModeShared) else {
            throw BinnerError.bufferAllocFailed
        }
        mosaic.samples.withUnsafeBufferPointer { src in
            mosaicBuffer.contents().copyMemory(from: src.baseAddress!,
                                               byteCount: mosaicByteCount)
        }

        // Output buffer: 64×64×3 floats.
        let outByteCount = Self.outputCount * MemoryLayout<Float>.size
        guard let outBuffer = device.makeBuffer(length: outByteCount,
                                                options: .storageModeShared) else {
            throw BinnerError.bufferAllocFailed
        }

        // Dispatch.
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw BinnerError.dispatchFailed("could not make command buffer or encoder")
        }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(mosaicBuffer, offset: 0, index: 0)
        enc.setBuffer(outBuffer,    offset: 0, index: 1)
        var black = Float(mosaic.blackLevel)
        var white = Float(mosaic.whiteLevel)
        enc.setBytes(&black, length: MemoryLayout<Float>.size, index: 2)
        enc.setBytes(&white, length: MemoryLayout<Float>.size, index: 3)

        // 64×64 grid, threadgroup 8×8 (= 64 threads = warp width on Apple GPU).
        let bin = BayerCropPlan.binCount
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(width: (bin + 7) / 8, height: (bin + 7) / 8, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let err = cmd.error {
            throw BinnerError.dispatchFailed(err.localizedDescription)
        }

        // Extract output as a Swift array.
        let outPtr = outBuffer.contents().bindMemory(to: Float.self, capacity: Self.outputCount)
        return Array(UnsafeBufferPointer(start: outPtr, count: Self.outputCount))
    }
}
