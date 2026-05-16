import Foundation
import os

/// Phase 2 orchestrator for one set's full pipeline.
///
/// Given a `setIdx`, reads the 4 DNGs from `set-NN/`, runs them through
/// the Phase 2 pipeline (decode → crop → bin → encode → write), and
/// emits `set-NN/lab.bvox`.
///
/// Pipeline composition (all from items 4-7):
///   ┌─ frame i (i ∈ 0..3) ─────────────────────────────────────────┐
///   │  load DNG bytes from disk                                     │
///   │  → BorealKernel.decodeDNG(bytes) → BayerMosaic                │
///   │  → BayerCenterCropper.centerCrop(mosaic) → 2944² BGGR mosaic  │
///   │  → BayerBinner.binToLAB(cropped) → [Float] (12,288 LAB floats)│
///   └──────────────────────────────────────────────────────────────┘
///   concatenate 4 frames → labFrames: [Float] (49,152 floats)
///   → BinomialEncoder.encodeSet(labFrames) → Columns (10 buffers)
///   → VoxelPack.encode(setIdx, codeBudget, pyramidHash, columns) → Data
///   → write to set-NN/lab.bvox
///
/// MVP scope (4-frame single-set burst): one `process(setIdx:)` call per
/// burst, fired synchronously from `AppCoordinator.applyEventSideEffects`
/// when the 4th frame's `frameDelivered` event lands. When BOREAL scales
/// back to the 64-frame / 16-set burst, this function stays unchanged;
/// the caller wires it behind an `AsyncChannel<Int>` (per the v3 plan)
/// for backpressure + per-set concurrency.
///
/// Per-set timing (estimate from items 5-7 benchmarks):
///   - decode (Zig LJPEG, 4 frames serial): ~80 ms each = ~320 ms
///   - bin (Metal, 4 frames serial): ~1 ms each = ~4 ms
///   - encode (Zig SIMD, 4096 bins): ~25 µs
///   - VoxelPack write (164 KB to disk): ~10 ms
///   - Total: ~340 ms per set on iPhone 17 Pro
enum SetProcessor {

    enum ProcessError: Error, CustomStringConvertible {
        case missingFrame(setIdx: Int, frameInSet: Int, url: URL)
        case decodeFailure(setIdx: Int, frameInSet: Int, underlying: Error)
        case cropFailure(setIdx: Int, frameInSet: Int, underlying: Error)
        case binFailure(setIdx: Int, frameInSet: Int, underlying: Error)
        case writeFailure(setIdx: Int, underlying: Error)

        var description: String {
            switch self {
            case .missingFrame(let s, let f, let url):
                return "set-\(s) frame \(f) missing at \(url.lastPathComponent)"
            case .decodeFailure(let s, let f, let e):
                return "set-\(s) frame \(f) decode failed: \(e)"
            case .cropFailure(let s, let f, let e):
                return "set-\(s) frame \(f) crop failed: \(e)"
            case .binFailure(let s, let f, let e):
                return "set-\(s) frame \(f) bin failed: \(e)"
            case .writeFailure(let s, let e):
                return "set-\(s) lab.bvox write failed: \(e)"
            }
        }
    }

    /// Run the Phase 2 pipeline for one set. Reads inputs from
    /// `set-NN/frame-{0..3}.dng`; writes output to `set-NN/lab.bvox`.
    ///
    /// Uses a shared `BayerBinner` (Metal pipeline state is expensive to
    /// construct; the caller may pass one in to avoid the cost across
    /// multiple sets in a single burst). If `nil`, a fresh one is created.
    static func process(
        setIdx: Int,
        binner: BayerBinner? = nil
    ) async throws -> URL {
        let started = Date()
        Log.processing.info("SetProcessor.process(setIdx: \(setIdx)) starting")

        let activeBinner: BayerBinner
        if let b = binner {
            activeBinner = b
        } else {
            do {
                activeBinner = try BayerBinner()
            } catch {
                throw ProcessError.binFailure(setIdx: setIdx, frameInSet: 0, underlying: error)
            }
        }

        // ── Stages 1-3 per frame: decode → crop → bin ──
        var labFrames: [Float] = []
        labFrames.reserveCapacity(4 * 64 * 64 * 3)

        for f in 0..<PyramidTable.framesPerSet {
            let frameURL = Storage.frameURL(setIdx: setIdx, frameInSet: f)
            guard FileManager.default.fileExists(atPath: frameURL.path) else {
                throw ProcessError.missingFrame(setIdx: setIdx, frameInSet: f, url: frameURL)
            }

            let dngData: Data
            do {
                dngData = try Data(contentsOf: frameURL)
            } catch {
                throw ProcessError.missingFrame(setIdx: setIdx, frameInSet: f, url: frameURL)
            }

            let fullMosaic: BayerMosaic
            do {
                fullMosaic = try BorealKernel.decodeDNG(dngData)
            } catch {
                throw ProcessError.decodeFailure(setIdx: setIdx, frameInSet: f, underlying: error)
            }

            let cropped: BayerMosaic
            do {
                cropped = try BayerCenterCropper.centerCrop(fullMosaic)
            } catch {
                throw ProcessError.cropFailure(setIdx: setIdx, frameInSet: f, underlying: error)
            }

            let labFrame: [Float]
            do {
                labFrame = try activeBinner.binToLAB(cropped)
            } catch {
                throw ProcessError.binFailure(setIdx: setIdx, frameInSet: f, underlying: error)
            }
            labFrames.append(contentsOf: labFrame)
        }

        // ── Stage 4: per-bin binomial encode ──
        let columns = BinomialEncoder.encodeSet(labFrames)

        // ── Stage 5: write .bvox ──
        let outURL = Storage.setSidecarURL(setIdx: setIdx)
            .deletingLastPathComponent()
            .appendingPathComponent("lab.bvox")

        let elapsedMs = Float(Date().timeIntervalSince(started) * 1000.0)
        var cert = VoxelPack.Certificate()
        cert.duration_ms = elapsedMs

        let pyramidHash = pyramidHashU64()
        let codeBudget = UInt16(PyramidTable.codeBudget(setIdx: setIdx))
        let bvoxData = VoxelPack.encode(
            setIdx: UInt16(setIdx),
            codeBudget: codeBudget,
            pyramidHash: pyramidHash,
            columns: columns,
            certificate: cert
        )

        do {
            try bvoxData.write(to: outURL, options: .atomic)
        } catch {
            throw ProcessError.writeFailure(setIdx: setIdx, underlying: error)
        }

        Log.processing.info("SetProcessor.process(setIdx: \(setIdx)) done in \(elapsedMs, format: .fixed(precision: 1)) ms → \(outURL.lastPathComponent, privacy: .public)")
        return outURL
    }

    /// FNV-1a 64-bit hash of the pyramid table — embedded in .bvox so
    /// downstream readers can verify they're parsing data with a known
    /// pyramid configuration.
    private static func pyramidHashU64() -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for value in PyramidTable.pyramid {
            // Hash the int as 4 bytes little-endian.
            let v = UInt64(value)
            for i in 0..<4 {
                let byte = UInt64((v >> (8 * UInt64(i))) & 0xFF)
                h ^= byte
                h = h &* 0x100000001B3
            }
        }
        return h
    }
}
