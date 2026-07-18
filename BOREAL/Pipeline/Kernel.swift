import Foundation
import CoreGraphics
import os

/// Subsystem logger — view in Console.app / `log stream --predicate 'subsystem == "com.daniel.boreal"'`.
let blog = Logger(subsystem: "com.daniel.boreal", category: "pipeline")

/// Thin facade over the pure-Swift kernel core (`BorealKernels`, in
/// BOREAL/Kernels/ — Phase 5: Swift + Metal is the kernel language; the Zig
/// tree is deleted). Pure, stateless, nonisolated. Every kernel is gated by
/// the spec's golden fixtures (`make -C spec gate` runs the Swift parity
/// harness) or by ported self-tests.
enum Kernel {

    struct Frame {
        var width: Int
        var height: Int
        var cfa: UInt32          // 0 = RGGB, 1 = BGGR
        var black: Float
        var white: Float
        var wb: (r: Float, g: Float, b: Float)  // green-normalized AsShotNeutral
        var exposureTime: Float   // EXIF seconds; 0 = absent
        var iso: Float            // 0 = absent
        var fNumber: Float        // 0 = absent (cancels)
        var camToPP: [Float]      // camera-native → ProPhoto-linear 3×3 (row-major, 9)
        var hasColor: Bool        // false → camToPP identity, no colour data
        var samples: [UInt16]
    }

    /// Human name for a decode status code — turns a bare "could not decode"
    /// into the exact reason the decoder rejected the DNG.
    static func statusName(_ s: Int32) -> String {
        switch s {
        case 0:  return "OK"
        case 1:  return "BAD_TIFF_MAGIC"
        case 2:  return "UNSUPPORTED_BYTE_ORDER"
        case 3:  return "UNSUPPORTED_COMPRESSION"
        case 4:  return "UNSUPPORTED_CFA_PATTERN"
        case 5:  return "UNSUPPORTED_BIT_DEPTH"
        case 6:  return "BAD_DIMENSIONS"
        case 7:  return "MISSING_TAG"
        case 8:  return "SHORT_READ"
        case 9:  return "BAD_OUTPUT_BUFFER"
        case 10: return "CROP_TOO_SMALL"
        case 11: return "BAD_CROP_ORIGIN"
        case 12: return "ALLOCATION_FAILED"
        case 14: return "UNSUPPORTED_COMPRESSION_DEFLATE"
        case 15: return "UNSUPPORTED_COMPRESSION_LOSSY_DNG"
        case 16: return "UNSUPPORTED_COMPRESSION_APPLE_VC8R"
        case 17: return "LJPEG_DECODE_FAILED"
        case 18: return "NULL_POINTER"
        case 19: return "LJPEG_BAD_MAGIC"
        case 20: return "LJPEG_UNEXPECTED_END"
        case 21: return "LJPEG_UNSUPPORTED_MARKER"
        case 22: return "LJPEG_UNSUPPORTED_COMPONENT_COUNT"
        case 23: return "LJPEG_UNSUPPORTED_PRECISION"
        case 24: return "LJPEG_UNSUPPORTED_PREDICTOR"
        case 25: return "LJPEG_HAS_RESTART_MARKERS"
        case 26: return "LJPEG_MALFORMED_HUFFMAN_TABLE"
        case 27: return "LJPEG_INVALID_HUFFMAN_CODE"
        default: return "UNKNOWN(\(s))"
        }
    }

    /// Decode one naked-Bayer DNG (pure-Swift TIFF/LJPEG decoder).
    static func decodeDNG(_ data: Data) -> (frame: Frame?, status: Int32) {
        let (mosaic, status) = BorealKernels.decodeDNG(data)
        guard let m = mosaic else {
            blog.error("decodeDNG failed: \(data.count) bytes → status \(status) (\(Self.statusName(status), privacy: .public))")
            return (nil, status)
        }
        return (Frame(width: m.width, height: m.height, cfa: m.cfa,
                      black: m.black, white: m.white, wb: m.wb,
                      exposureTime: m.exposureTime, iso: m.iso, fNumber: m.fNumber,
                      camToPP: m.camToPP, hasColor: m.hasColor,
                      samples: m.samples), 0)
    }

    /// Per-frame relative exposure ratios from EXIF (darkest = 1; EV1-EV5).
    static func relativeExposures(_ frames: [Frame]) -> [Float] {
        guard frames.count == 4 else { return [1, 1, 1, 1] }
        return BorealKernels.relativeExposures(et: frames.map(\.exposureTime),
                                               iso: frames.map(\.iso),
                                               fnum: frames.map(\.fNumber))
    }

    /// Fuse 4 same-geometry frames into one scene-linear f32 mosaic (the
    /// cycle's analysis reference; EV-aware via EXIF).
    static func fuse(_ frames: [Frame]) -> [Float]? {
        guard frames.count == 4 else { return nil }
        let ev = relativeExposures(frames)
        return BorealKernels.fuse(frames: frames.map(\.samples),
                                  black: frames[0].black, white: frames[0].white,
                                  exposures: ev, knee: 0.90, clip: 0.98)
    }

    // ── EV planning (Phase 2: the inter-cycle ETTR loop) ───────────────────

    static func analyzeMosaicClips(_ f: Frame) -> BorealKernels.SceneClips {
        BorealKernels.analyzeMosaic(samples: f.samples, width: f.width,
                                    height: f.height, cfa: f.cfa,
                                    black: f.black, white: f.white)
    }

    static func solveETTR(clips: BorealKernels.SceneClips,
                          wb: (r: Float, g: Float, b: Float),
                          extraShadow: Float = 0) -> [Float] {
        BorealKernels.planExposures(clips: clips, wb: wb, extraShadow: extraShadow)
    }

    static func normalizeMosaic(_ f: Frame, invE: Float) -> [Float] {
        BorealKernels.normalizeMosaic(samples: f.samples, black: f.black,
                                      white: f.white, invE: invE)
    }

    // ── Multi-scale demosaic: the custom ISP (Phase 3, MS laws) ────────────

    static func msRungs(side: Int) -> [Int] { BorealKernels.msRungs(side: side) }

    static func msStackLen(side: Int) -> Int { BorealKernels.msStackLen(side: side) }

    static func msEncode(mosaic: [Float], side: Int, cfa: UInt32,
                         camToPP: [Float], hasColor: Bool)
        -> (L: [Int32], a: [Int32], b: [Int32])? {
        BorealKernels.msEncode(mosaic: mosaic, side: side, cfa: cfa,
                               camToPP: camToPP, hasColor: hasColor)
    }

    static func msDecode(_ bands: [Int32], mosaicSide: Int, rung: Int) -> [Int32]? {
        BorealKernels.msDecode(bands, mosaicSide: mosaicSide, rung: rung)
    }

    // ── GIF target + wire ──────────────────────────────────────────────────

    static func indexMap(L: [Int32], a: [Int32], b: [Int32],
                         palL: [Int32], palA: [Int32], palB: [Int32]) -> [UInt8] {
        BorealKernels.indexMap(L: L, a: a, b: b, palL: palL, palA: palA, palB: palB)
    }

    static func oklabQ16ToSRGB8(L: [Int32], a: [Int32], b: [Int32]) -> [UInt8] {
        BorealKernels.oklabQ16ToSRGB8(L: L, a: a, b: b)
    }

    static func gifEncode(frames: [[UInt8]], side: Int, paletteRGB: [UInt8],
                          delayCs: Int) -> Data? {
        BorealKernels.gifEncode(frames: frames, side: side, gct: paletteRGB,
                                delayCs: delayCs)
    }

    static func upscaleIndices(_ indices: [UInt8], from r: Int, to target: Int) -> [UInt8] {
        guard target % r == 0 else { return indices }
        let k = target / r
        var out = [UInt8](repeating: 0, count: target * target)
        for y in 0..<target {
            let sy = y / k
            for x in 0..<target {
                out[y * target + x] = indices[sy * r + x / k]
            }
        }
        return out
    }

    // ── Live exposure read-out (the pre-shutter overlay) ───────────────────

    struct ChannelHistogram: Sendable {
        let bins: Int
        let r: [UInt32]
        let g: [UInt32]
        let b: [UInt32]

        /// Largest single bar across all channels — the y-axis scale for a plot.
        var peak: UInt32 { max(r.max() ?? 0, max(g.max() ?? 0, b.max() ?? 0)) }

        /// Fraction of a channel's samples in the top bin ≈ how much it clipped.
        func clipFraction(_ ch: [UInt32]) -> Double {
            let total = ch.reduce(0) { $0 + Int($1) }
            guard total > 0, let top = ch.last else { return 0 }
            return Double(top) / Double(total)
        }
        var clipR: Double { clipFraction(r) }
        var clipG: Double { clipFraction(g) }
        var clipB: Double { clipFraction(b) }
    }

    static func liveHistograms(bgra: UnsafePointer<UInt8>, width: Int, height: Int,
                               rowStride: Int, bins: Int = 128) -> ChannelHistogram {
        let h = BorealKernels.rgbHistograms(bgra: bgra, width: width, height: height,
                                            rowStride: rowStride, bins: bins)
        return ChannelHistogram(bins: bins, r: h.r, g: h.g, b: h.b)
    }
}
