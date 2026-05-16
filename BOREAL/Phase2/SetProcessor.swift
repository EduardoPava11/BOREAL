import Foundation
import os

/// Phase 2 orchestrator for one set's full pipeline.
///
/// Given a `setIdx`, reads the 4 DNGs from `set-NN/`, runs them through
/// the Phase 2 pipeline (decode → crop → bin → encode → write), and
/// emits `set-NN/lab.bvox`.
///
/// ── End-to-end verified on iPhone 17 Pro 2026-05-16 ──
///   set-00 (4 DNGs, ~45 MB total) → 668 ms wall clock → 164 KB lab.bvox
///   Decoder path: BGGR Bayer LJPEG (Apple format P=12, Pt=1, Nf=2,
///   128 tiles per DNG) via `borealkernel.dng.parse`.
///
/// Pipeline composition:
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
/// ── Operational profile (measured on device, not estimated) ──
///   - decode (Zig LJPEG, 4 frames serial): ~150 ms each = ~600 ms
///   - crop + bin (Metal, 4 frames serial): ~10 ms each = ~40 ms
///   - encode (Zig SIMD, 4096 bins): <1 ms
///   - VoxelPack write (164 KB atomic): ~25 ms
///   - Total: ~668 ms per set
///
/// The LJPEG decode dominates. Two parallelization opportunities exist:
///   (a) Inter-frame: the 4 frames are independent — switch the for-loop
///       to a TaskGroup once memory budgets allow concurrent decoding.
///   (b) Intra-frame: each DNG has 128 independent LJPEG tiles — decode
///       them concurrently inside `borealkernel.dng.parse`.
/// Either should bring per-set time well under 200 ms.
///
/// Scaling note: when BOREAL extends to the 64-frame / 16-set pyramid,
/// this function stays unchanged; the caller wires it behind an
/// `AsyncChannel<Int>` for backpressure + per-set concurrency. Trigger
/// today: `AppCoordinator.applyEventSideEffects` fires
/// `Task.detached { try await SetProcessor.process(setIdx: 0) }` on the
/// reducer's `.setComplete` event (4th frame delivered).
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
