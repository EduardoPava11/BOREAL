import Foundation
import CoreGraphics
import os

/// Subsystem logger — view in Console.app / `log stream --predicate 'subsystem == "com.daniel.boreal"'`.
let blog = Logger(subsystem: "com.daniel.boreal", category: "pipeline")

/// Thin Swift facade over the new Zig RGBT→HDR pipeline (declared in
/// `BorealKernel.h`, linked via `-lborealkernel`). Pure, stateless, nonisolated.
///
/// Pipeline: decodeDNG ×4 → fuse → demosaic → writeTIFF / buildCubeLUT.
/// EV-aware merge: each DNG's EXIF (ExposureTime/ISO/FNumber) drives the
/// per-frame relative exposure ratios (computed in Zig), so EV-bracketed frames
/// fuse correctly into one scene-linear HDR. Frames with no usable bracket fall
/// back to equal exposure (pure temporal denoise).
enum Kernel {

    /// Force the linker to keep `libborealkernel.a` by referencing a symbol.
    /// A launch-time call makes a missing link fail loudly and immediately.
    @inline(never)
    static func keepalive() {
        let _: @convention(c) (UInt32, UInt32, Int) -> Int = bk_tiff_size
    }

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
        var hasColor: Bool        // false → camToPP identity, no colour data / ICC
        var samples: [UInt16]    // Swift-owned copy (Zig buffer freed before return)
    }

    enum Failure: Error, CustomStringConvertible {
        case decode(String), dimensionMismatch, fuseFailed
        var description: String {
            switch self {
            case .decode(let f): return "Could not decode \(f)"
            case .dimensionMismatch: return "The 4 DNGs must share dimensions"
            case .fuseFailed: return "Fusion failed"
            }
        }
    }

    /// Human name for a `bk_status_t` code (from BorealKernel.h) — turns a bare
    /// "could not decode" into the exact reason the Zig decoder rejected the DNG.
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

    /// Decode one DNG. Returns the frame on success, or the raw `bk_status_t` on
    /// failure so the caller can report exactly why (and it's logged here too).
    static func decodeDNG(_ data: Data) -> (frame: Frame?, status: Int32) {
        var m = bk_mosaic_t()
        let status = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 18 } // NULL_POINTER
            return bk_decode_dng_to_mosaic(base, data.count, &m)
        }
        guard status == 0, let s = m.samples else {
            blog.error("decodeDNG failed: \(data.count) bytes → status \(status) (\(Self.statusName(status), privacy: .public))")
            bk_free_mosaic(&m)   // safe no-op when samples == null
            return (nil, status)
        }
        let width = Int(m.width), height = Int(m.height)
        let cfa: UInt32 = (m.cfa == BK_CFA_BGGR) ? 1 : 0
        let black = Float(m.black_level), white = Float(m.white_level)
        let samples = Array(UnsafeBufferPointer(start: s, count: width * height))
        let wb = (r: m.wb_r, g: m.wb_g, b: m.wb_b)
        let exposureTime = m.exposure_time, iso = m.iso, fNumber = m.fnumber
        let c = m.cam_to_pp   // C `float[9]` imports as a 9-tuple
        let camToPP = [c.0, c.1, c.2, c.3, c.4, c.5, c.6, c.7, c.8]
        let hasColor = m.has_color
        bk_free_mosaic(&m)
        blog.debug("decoded \(width)×\(height) cfa=\(cfa) black=\(black) white=\(white) et=\(exposureTime) iso=\(iso) f=\(fNumber) hasColor=\(hasColor)")
        return (Frame(width: width, height: height, cfa: cfa, black: black, white: white,
                      wb: wb, exposureTime: exposureTime, iso: iso, fNumber: fNumber,
                      camToPP: camToPP, hasColor: hasColor, samples: samples), 0)
    }

    /// Apply the camera-native → ProPhoto-linear colour transform in place (Zig,
    /// SIMD). No-op when the DNG carried no usable colour matrix.
    static func applyColor(_ rgb: inout [Float], width: Int, height: Int, matrix: [Float]) {
        guard matrix.count == 9 else { return }
        let nPx = width * height
        rgb.withUnsafeMutableBufferPointer { p in
            matrix.withUnsafeBufferPointer { m in
                bk_apply_color_matrix(p.baseAddress, nPx, m.baseAddress)
            }
        }
    }

    /// Fuse 4 same-geometry frames into one scene-linear f32 mosaic.
    static func fuse(_ frames: [Frame]) -> [Float]? {
        guard frames.count == 4 else { return nil }
        let n = frames[0].width * frames[0].height
        var params = bk_fuse_params_t()
        params.black = frames[0].black
        params.white = frames[0].white
        // Per-frame relative exposure ratios from EXIF. All direction/
        // normalization/fallback/clamp logic lives in Zig (bk_relative_exposures).
        var et: [Float] = [frames[0].exposureTime, frames[1].exposureTime, frames[2].exposureTime, frames[3].exposureTime]
        var isoArr: [Float] = [frames[0].iso, frames[1].iso, frames[2].iso, frames[3].iso]
        var fnArr: [Float] = [frames[0].fNumber, frames[1].fNumber, frames[2].fNumber, frames[3].fNumber]
        var ev = [Float](repeating: 1, count: 4)
        bk_relative_exposures(&et, &isoArr, &fnArr, &ev)
        params.exposures = (ev[0], ev[1], ev[2], ev[3])
        params.knee = 0.90
        params.clip = 0.98
        var out = [Float](repeating: 0, count: n)
        frames[0].samples.withUnsafeBufferPointer { p0 in
            frames[1].samples.withUnsafeBufferPointer { p1 in
                frames[2].samples.withUnsafeBufferPointer { p2 in
                    frames[3].samples.withUnsafeBufferPointer { p3 in
                        out.withUnsafeMutableBufferPointer { o in
                            bk_fuse_mosaics(p0.baseAddress, p1.baseAddress, p2.baseAddress,
                                            p3.baseAddress, n, &params, o.baseAddress)
                        }
                    }
                }
            }
        }
        return out
    }

    /// Demosaic a fused single-channel mosaic into interleaved RGB f32.
    static func demosaic(_ mosaic: [Float], width: Int, height: Int, cfa: UInt32) -> [Float] {
        var out = [Float](repeating: 0, count: width * height * 3)
        mosaic.withUnsafeBufferPointer { m in
            out.withUnsafeMutableBufferPointer { o in
                bk_demosaic_full(m.baseAddress, UInt32(width), UInt32(height), cfa, o.baseAddress)
            }
        }
        return out
    }

    // ── EV planning (GIF-ISP Phase 2: the inter-cycle ETTR loop) ───────────

    /// Analyze a frame's RAW mosaic directly → per-channel ETTR clips
    /// (no demosaic; black/white-normalized, no WB → true exposure).
    static func analyzeMosaicClips(_ f: Frame) -> bk_scene_clips_t {
        var out = bk_scene_clips_t()
        f.samples.withUnsafeBufferPointer { p in
            bk_analyze_mosaic_clips(p.baseAddress, UInt32(f.width), UInt32(f.height),
                                    f.cfa, f.black, f.white, &out)
        }
        return out
    }

    /// Clips + WB prior → the 4-frame EV plan [green, red, blue, shadow]
    /// (stops from the base exposure). All solver logic lives in scene.zig.
    static func solveETTR(clips: bk_scene_clips_t,
                          wb: (r: Float, g: Float, b: Float),
                          extraShadow: Float = 0) -> [Float] {
        var c = clips
        var plan = bk_exposure_plan_t()
        let wbArr: [Float] = [wb.r, wb.g, wb.b]
        wbArr.withUnsafeBufferPointer { w in
            bk_solve_ettr_exposures(&c, w.baseAddress, extraShadow, &plan)
        }
        return [plan.ev_green, plan.ev_red, plan.ev_blue, plan.ev_shadow]
    }

    /// Per-frame relative exposure ratios from EXIF (darkest = 1; the same
    /// single-source math the fuse uses — see EV1-EV5 laws).
    static func relativeExposures(_ frames: [Frame]) -> [Float] {
        guard frames.count == 4 else { return [1, 1, 1, 1] }
        var et = frames.map(\.exposureTime)
        var iso = frames.map(\.iso)
        var fn = frames.map(\.fNumber)
        var ev = [Float](repeating: 1, count: 4)
        bk_relative_exposures(&et, &iso, &fn, &ev)
        return ev
    }

    // ── 16-LAB latent chain (BOREAL-16LAB-DESIGN.md L2 steps 6-8) ──────────

    /// Linear-light box downsample: interleaved RGB f32 → RGB f32 at
    /// (width/k)×(height/k). Runs BEFORE OKLab (averaging light is only
    /// correct in linear space). k must divide both dimensions.
    static func boxReduceRGB(_ rgb: [Float], width: Int, height: Int, factor: Int) -> [Float] {
        let ow = width / factor, oh = height / factor
        var out = [Float](repeating: 0, count: ow * oh * 3)
        rgb.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                bk_box_reduce_rgb(p.baseAddress, UInt32(width), UInt32(height),
                                  UInt32(factor), o.baseAddress)
            }
        }
        return out
    }

    /// Linear ProPhoto RGB → interleaved Q16 OKLab i32 (the pyramid's exact
    /// integer domain; owned deterministic cbrt in Zig).
    static func oklabQ16(fromProPhoto rgb: [Float]) -> [Int32] {
        let nPx = rgb.count / 3
        var out = [Int32](repeating: 0, count: nPx * 3)
        rgb.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                bk_oklab_q16_from_prophoto(p.baseAddress, nPx, o.baseAddress)
            }
        }
        return out
    }

    /// Exact integer S-transform pyramid: side² i32 image → side² i32 bands in
    /// prefix layout (bands[0..base²) IS the base-rung latent; every prefix is
    /// a rung; back-trace is exact inverse). nil on invalid sides.
    static func pyramidAnalyze(_ img: [Int32], side: Int, base: Int = 16) -> [Int32]? {
        var bands = [Int32](repeating: 0, count: side * side)
        var scratch = [Int32](repeating: 0, count: side * side / 2)
        let status = img.withUnsafeBufferPointer { p in
            bands.withUnsafeMutableBufferPointer { b in
                scratch.withUnsafeMutableBufferPointer { s in
                    bk_pyramid_analyze(p.baseAddress, UInt32(side), UInt32(base),
                                       b.baseAddress, s.baseAddress)
                }
            }
        }
        return status == 0 ? bands : nil
    }

    /// Exact inverse of pyramidAnalyze on a PREFIX: bands[0..side²) of a
    /// larger buffer are themselves the complete rung-`side` encoding.
    static func pyramidSynthesize(_ bands: [Int32], side: Int, base: Int = 16) -> [Int32]? {
        var img = [Int32](repeating: 0, count: side * side)
        var scratch = [Int32](repeating: 0, count: max(1, side * side / 2))
        let status = bands.withUnsafeBufferPointer { p in
            img.withUnsafeMutableBufferPointer { o in
                scratch.withUnsafeMutableBufferPointer { s in
                    bk_pyramid_synthesize(p.baseAddress, UInt32(side), UInt32(base),
                                          o.baseAddress, s.baseAddress)
                }
            }
        }
        return status == 0 ? img : nil
    }

    /// GIF-target index map: planar Q16 OKLab pixels against the 256-entry
    /// planar seed palette → u8 indices (i64 argmin, ties → lowest).
    static func indexMap(L: [Int32], a: [Int32], b: [Int32],
                         palL: [Int32], palA: [Int32], palB: [Int32]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: L.count)
        L.withUnsafeBufferPointer { pl in a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in palL.withUnsafeBufferPointer { ql in
                palA.withUnsafeBufferPointer { qa in palB.withUnsafeBufferPointer { qb in
                    out.withUnsafeMutableBufferPointer { o in
                        bk_index_map(pl.baseAddress, pa.baseAddress, pb.baseAddress, L.count,
                                     ql.baseAddress, qa.baseAddress, qb.baseAddress, o.baseAddress)
                    }
                }}
            }}
        }}
        return out
    }

    /// Display path: planar Q16 OKLab → interleaved sRGB8 bytes (3n), via the
    /// generated normative encode table (deterministic, never pow at runtime).
    static func oklabQ16ToSRGB8(L: [Int32], a: [Int32], b: [Int32]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 3 * L.count)
        L.withUnsafeBufferPointer { pl in a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                out.withUnsafeMutableBufferPointer { o in
                    bk_oklab_q16_to_srgb8(pl.baseAddress, pa.baseAddress, pb.baseAddress,
                                          L.count, o.baseAddress)
                }
            }
        }}
        return out
    }

    /// Encode interleaved RGB f32 as a 32-bit-float HDR TIFF, optionally tagging
    /// it with an embedded ICC profile (color DATA, sourced by Swift per the
    /// ownership rule — the Zig encoder just memcpy's the blob into the tag).
    static func writeTIFF(rgb: [Float], width: Int, height: Int, icc: Data? = nil) -> Data {
        let iccBytes = icc.map { [UInt8]($0) } ?? []
        let size = bk_tiff_size(UInt32(width), UInt32(height), iccBytes.count)
        var buf = [UInt8](repeating: 0, count: size)
        let n = rgb.withUnsafeBufferPointer { p in
            buf.withUnsafeMutableBufferPointer { b in
                iccBytes.withUnsafeBufferPointer { ic in
                    bk_write_tiff_f32(UInt32(width), UInt32(height), p.baseAddress,
                                      iccBytes.isEmpty ? nil : ic.baseAddress, iccBytes.count,
                                      b.baseAddress, size)
                }
            }
        }
        return Data(buf[0..<n])
    }

    /// A LINEAR ProPhoto (ROMM) ICC profile to tag the scene-linear HDR master.
    /// iOS has no built-in linear-ProPhoto space, so we take Apple's validated
    /// ROMM profile (gamma 1.8) and patch its three TRC curves to linear (gamma
    /// 1.0) IN PLACE — same byte size, so the ICC tag table needs no rewrite.
    /// Validated via CGColorSpace before use; returns nil (→ untagged) on any
    /// mismatch, so a bad patch never corrupts the file.
    static func linearProPhotoICC() -> Data? {
        guard let cs = CGColorSpace(name: CGColorSpace.rommrgb),
              let icc = cs.copyICCData() as Data? else { return nil }
        var b = [UInt8](icc)
        guard b.count > 132 else { return nil }
        func beU32(_ o: Int) -> UInt32 {
            (UInt32(b[o]) << 24) | (UInt32(b[o+1]) << 16) | (UInt32(b[o+2]) << 8) | UInt32(b[o+3])
        }
        let tagCount = Int(beU32(128))
        let table = 132
        let trcSigs: Set<UInt32> = [0x72545243, 0x67545243, 0x62545243] // 'rTRC','gTRC','bTRC'
        var patched = 0
        for i in 0..<tagCount {
            let e = table + i * 12
            guard e + 12 <= b.count else { break }
            guard trcSigs.contains(beU32(e)) else { continue }
            let off = Int(beU32(e + 4))
            guard off + 12 <= b.count else { continue }
            let typ = beU32(off)
            if typ == 0x63757276 {              // 'curv'
                let count = beU32(off + 8)
                if count == 0 { patched += 1 }   // already linear
                else if count == 1, off + 14 <= b.count {
                    b[off+12] = 0x01; b[off+13] = 0x00   // u8Fixed8 gamma = 1.0
                    patched += 1
                }
            } else if typ == 0x70617261 {        // 'para'
                let funcType = (UInt16(b[off+8]) << 8) | UInt16(b[off+9])
                if funcType == 0, off + 16 <= b.count {  // Y = X^g, one s15Fixed16 param
                    b[off+12] = 0x00; b[off+13] = 0x01; b[off+14] = 0x00; b[off+15] = 0x00 // g = 1.0
                    patched += 1
                }
            }
        }
        guard patched == 3 else { return nil }
        let out = Data(b)
        guard CGColorSpace(iccData: out as CFData) != nil else { return nil }
        return out
    }

    /// A creative ASC-CDL grade, expressed as four artist-facing knobs that map
    /// onto the per-channel CDL the LUT bakes. `.default` is a gentle filmic look
    /// (slight contrast + saturation), NOT identity.
    struct GradeParams: Sendable, Equatable {
        var exposure: Float = 0      // stops, ±2 → global slope ×2^exposure
        var contrast: Float = 1.10   // pivoted at 0.5: slope=contrast, offset=0.5(1−contrast)
        var saturation: Float = 1.10 // 1 = neutral, 0 = mono
        var temperature: Float = 0   // −0.2…0.2, warms (R↑/B↓) or cools

        static let `default` = GradeParams()
        static let identity = GradeParams(exposure: 0, contrast: 1, saturation: 1, temperature: 0)

        /// Compose the per-channel ASC-CDL parameters from the knobs.
        var look: bk_look_params_t {
            var p = bk_look_params_t()
            let g = pow(2.0, exposure)
            let sr = contrast * g * (1 + temperature)
            let sg = contrast * g
            let sb = contrast * g * (1 - temperature)
            let off = 0.5 * (1 - contrast)        // keep mid-grey ~fixed under contrast
            p.slope = (sr, sg, sb)
            p.offset = (off, off, off)
            p.power = (1, 1, 1)
            p.luma_w = (0.2126, 0.7152, 0.0722)
            p.sat = saturation
            return p
        }
    }

    /// Apply the baked ASC-CDL look to an interleaved [0,1] RGB buffer in place
    /// (Zig — the same operator the .cube uses, so preview ≡ exported cube).
    static func applyLook(_ rgb: inout [Float], look: bk_look_params_t) {
        var p = look
        let nPx = rgb.count / 3
        rgb.withUnsafeMutableBufferPointer { b in
            bk_apply_look(b.baseAddress, nPx, &p)
        }
    }

    /// Bake the look into a `grid³` `.cube` LUT.
    static func buildCubeLUT(look: bk_look_params_t, grid: UInt32 = 64) -> Data {
        var p = look
        let latCount = Int(grid) * Int(grid) * Int(grid) * 3
        var lattice = [Float](repeating: 0, count: latCount)
        lattice.withUnsafeMutableBufferPointer { l in bk_build_cube_lut(&p, grid, l.baseAddress) }
        let cap = 16 * 1024 * 1024
        var buf = [UInt8](repeating: 0, count: cap)
        let n = lattice.withUnsafeBufferPointer { l in
            buf.withUnsafeMutableBufferPointer { b in
                bk_emit_cube(l.baseAddress, grid, b.baseAddress, cap)
            }
        }
        return Data(buf[0..<n])
    }

    /// A small, screen-displayable RGBA8 thumbnail of scene-linear RGB float.
    /// Sendable so it can cross back to the main actor for display.
    struct PreviewImage: Sendable {
        let width: Int
        let height: Int
        let rgba: [UInt8]   // length width*height*4, alpha = 255
    }

    /// Downsample + tone-map (Reinhard + sRGB-ish gamma) scene-linear RGB to a
    /// preview thumbnail. The HDR float master can't be shown directly; this is
    /// a quick "did my photo come out?" view, not the graded result.
    /// ProPhoto-linear (D50) → sRGB-linear (D65, Bradford-adapted) 3×3, row-major.
    /// Computed offline; used to color-manage the preview so wide-gamut ProPhoto
    /// data displays correctly in the device's sRGB framebuffer (without this the
    /// preview would read ProPhoto values as sRGB → oversaturated/wrong hue).
    private static let proPhotoToSRGB: [Float] = [
         2.0340758, -0.7273341, -0.3067418,
        -0.2288131,  1.2317301, -0.0029169,
        -0.0085698, -0.1532866,  1.1618564,
    ]

    static func makePreview(rgb: [Float], width: Int, height: Int, fromProPhoto: Bool = false, maxDim: Int = 600) -> PreviewImage {
        let step = max(1, max(width, height) / maxDim)
        let ow = max(1, width / step)
        let oh = max(1, height / step)
        var out = [UInt8](repeating: 255, count: ow * oh * 4)
        let m = proPhotoToSRGB
        for oy in 0..<oh {
            let sy = oy * step
            for ox in 0..<ow {
                let si = (sy * width + ox * step) * 3
                let di = (oy * ow + ox) * 4
                var r = max(0, rgb[si + 0]), g = max(0, rgb[si + 1]), b = max(0, rgb[si + 2])
                if fromProPhoto {   // ProPhoto-linear → sRGB-linear
                    let nr = m[0]*r + m[1]*g + m[2]*b
                    let ng = m[3]*r + m[4]*g + m[5]*b
                    let nb = m[6]*r + m[7]*g + m[8]*b
                    r = max(0, nr); g = max(0, ng); b = max(0, nb)
                }
                let chans = [r, g, b]
                for c in 0..<3 {
                    let tm = chans[c] / (1 + chans[c])           // Reinhard tone-map
                    let enc = pow(Double(tm), 1.0 / 2.2)         // sRGB-ish gamma
                    out[di + c] = UInt8(max(0, min(255, enc * 255)))
                }
            }
        }
        return PreviewImage(width: ow, height: oh, rgba: out)
    }

    /// A small downsampled copy of the scene-linear RGB master (interleaved
    /// float, no tone-map). Retained so the grade can be re-applied live without
    /// re-running the whole pipeline. `fromProPhoto` is just carried metadata.
    struct LinearThumb: Sendable {
        let width: Int
        let height: Int
        let rgb: [Float]        // length width*height*3, scene-linear
        let isProPhoto: Bool
    }

    static func makeLinearThumb(rgb: [Float], width: Int, height: Int, isProPhoto: Bool, maxDim: Int = 600) -> LinearThumb {
        let step = max(1, max(width, height) / maxDim)
        let ow = max(1, width / step), oh = max(1, height / step)
        var out = [Float](repeating: 0, count: ow * oh * 3)
        for oy in 0..<oh {
            let sy = oy * step
            for ox in 0..<ow {
                let si = (sy * width + ox * step) * 3
                let di = (oy * ow + ox) * 3
                out[di] = rgb[si]; out[di+1] = rgb[si+1]; out[di+2] = rgb[si+2]
            }
        }
        return LinearThumb(width: ow, height: oh, rgb: out, isProPhoto: isProPhoto)
    }

    /// Render a display thumbnail from a LinearThumb with the ASC-CDL grade
    /// applied. Pipeline: scene-linear → Reinhard tone-map → [0,1] →
    /// applyLook (SAME operator the .cube bakes → preview ≡ cube) → ProPhoto→sRGB
    /// → gamma. Pass look=nil for the ungraded view.
    static func renderGraded(_ t: LinearThumb, look: bk_look_params_t?) -> PreviewImage {
        let n = t.width * t.height
        var disp = [Float](repeating: 0, count: n * 3)
        for i in 0..<n * 3 {
            let v = max(0, t.rgb[i])
            disp[i] = v / (1 + v)              // Reinhard → [0,1] (the PS "document")
        }
        if let look { applyLook(&disp, look: look) }   // grade in ProPhoto [0,1]
        let m = proPhotoToSRGB
        var out = [UInt8](repeating: 255, count: n * 4)
        for px in 0..<n {
            let s = px * 3, d = px * 4
            var r = disp[s], g = disp[s+1], b = disp[s+2]
            if t.isProPhoto {                  // display-convert ProPhoto → sRGB
                let nr = m[0]*r + m[1]*g + m[2]*b
                let ng = m[3]*r + m[4]*g + m[5]*b
                let nb = m[6]*r + m[7]*g + m[8]*b
                r = max(0, nr); g = max(0, ng); b = max(0, nb)
            }
            let chans = [r, g, b]
            for c in 0..<3 {
                let enc = pow(Double(min(1, chans[c])), 1.0 / 2.2)
                out[d + c] = UInt8(max(0, min(255, enc * 255)))
            }
        }
        return PreviewImage(width: t.width, height: t.height, rgba: out)
    }

    // ── Per-frame exposure read-out (RGBT) ─────────────────────────────────
    //
    // The four imported DNGs are the temporal axis (T) of one scene, each
    // exposed differently. Before we fuse them away, we show the user the
    // RGB histogram of every frame so they can judge each one's exposure —
    // whether a channel clipped (tail piled at the right) or sits in the noise
    // floor (tail piled at the left). The binning is owned by the Zig kernel
    // (`bk_channel_histograms`), on the RAW mosaic with no white balance, so
    // the bars read TRUE sensor exposure.

    /// Three per-channel display histograms over the normalized [0,1] range.
    /// Sendable so it can cross from the off-main pipeline to the main actor.
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

    /// Bin a frame's raw mosaic into R/G/B histograms via the Zig kernel.
    static func histograms(of frame: Frame, bins: Int = 128) -> ChannelHistogram {
        var hr = [UInt32](repeating: 0, count: bins)
        var hg = [UInt32](repeating: 0, count: bins)
        var hb = [UInt32](repeating: 0, count: bins)
        frame.samples.withUnsafeBufferPointer { s in
            hr.withUnsafeMutableBufferPointer { pr in
                hg.withUnsafeMutableBufferPointer { pg in
                    hb.withUnsafeMutableBufferPointer { pb in
                        bk_channel_histograms(
                            s.baseAddress, UInt32(frame.width), UInt32(frame.height),
                            frame.cfa, frame.black, frame.white, UInt32(bins),
                            pr.baseAddress, pg.baseAddress, pb.baseAddress)
                    }
                }
            }
        }
        return ChannelHistogram(bins: bins, r: hr, g: hg, b: hb)
    }

    /// Bin a LIVE interleaved 8-bit BGRA video frame (the AVCaptureVideoDataOutput
    /// feed) into R/G/B histograms via the Zig kernel, for the capture screen's
    /// real-time exposure overlay. `rowStride` MUST be the CVPixelBuffer's
    /// bytesPerRow (rows are padded past width*4); the Zig fn strides by it.
    ///
    /// NOTE: this is display-referred 8-bit (/255 in Zig, NO sensor black/white,
    /// NO white balance), so it is NOT directly comparable to `histograms(of:)`
    /// (raw, sensor-level) — it is a relative pre-shutter exposure guide. The
    /// caller passes a downsampled sub-buffer to bound per-frame cost.
    static func liveHistograms(bgra: UnsafePointer<UInt8>, width: Int, height: Int,
                               rowStride: Int, bins: Int = 128) -> ChannelHistogram {
        var hr = [UInt32](repeating: 0, count: bins)
        var hg = [UInt32](repeating: 0, count: bins)
        var hb = [UInt32](repeating: 0, count: bins)
        hr.withUnsafeMutableBufferPointer { pr in
            hg.withUnsafeMutableBufferPointer { pg in
                hb.withUnsafeMutableBufferPointer { pb in
                    bk_rgb_histograms(
                        bgra, UInt32(width), UInt32(height), UInt32(rowStride), UInt32(bins),
                        pr.baseAddress, pg.baseAddress, pb.baseAddress)
                }
            }
        }
        return ChannelHistogram(bins: bins, r: hr, g: hg, b: hb)
    }

    /// One frame's exposure card: a small WB-corrected thumbnail + its raw
    /// RGB histogram. Sendable; the thumbnail becomes a UIImage on the main actor.
    struct FramePreview: Sendable {
        let index: Int           // 0…3 (T axis)
        let thumb: PreviewImage
        let hist: ChannelHistogram
        let stops: Float?        // EV above darkest frame; nil = no EXIF / no bracket
    }

    /// Build a frame's exposure card. The thumbnail is a CHEAP 2×2-Bayer-cell
    /// bin (no full demosaic — this is a glance, not the master), WB-corrected
    /// and tone-mapped so it looks natural; the histogram stays on raw levels.
    static func framePreview(_ frame: Frame, index: Int, stops: Float? = nil, bins: Int = 128, maxDim: Int = 220) -> FramePreview {
        let cellsW = frame.width / 2, cellsH = frame.height / 2
        // A frame too small to form even one 2×2 Bayer cell can't make a
        // thumbnail (the cell loop would read past `samples`). Histograms are
        // size-safe (binned in Zig), so still return them with a 1×1 stub.
        guard cellsW >= 1, cellsH >= 1 else {
            let stub = PreviewImage(width: 1, height: 1, rgba: [0, 0, 0, 255])
            return FramePreview(index: index, thumb: stub,
                                hist: histograms(of: frame, bins: bins), stops: stops)
        }
        let step = max(1, max(cellsW, cellsH) / maxDim)
        let ow = max(1, cellsW / step), oh = max(1, cellsH / step)
        var out = [UInt8](repeating: 255, count: ow * oh * 4)
        let range = max(frame.white - frame.black, 1)
        let isRGGB = frame.cfa == 0

        frame.samples.withUnsafeBufferPointer { s in
            for oy in 0..<oh {
                let cy = oy * step
                let topRow = (2 * cy) * frame.width
                let botRow = topRow + frame.width
                for ox in 0..<ow {
                    let cx = ox * step
                    let xl = 2 * cx
                    let tl = Float(s[topRow + xl]), tr = Float(s[topRow + xl + 1])
                    let bl = Float(s[botRow + xl]), br = Float(s[botRow + xl + 1])
                    // CFA → R, G(avg of two greens), B
                    let rRaw = isRGGB ? tl : br
                    let bRaw = isRGGB ? br : tl
                    let gRaw = (tr + bl) * 0.5
                    var rgb = (r: (rRaw - frame.black) / range * frame.wb.r,
                               g: (gRaw - frame.black) / range * frame.wb.g,
                               b: (bRaw - frame.black) / range * frame.wb.b)
                    rgb.r = max(0, rgb.r); rgb.g = max(0, rgb.g); rgb.b = max(0, rgb.b)
                    let di = (oy * ow + ox) * 4
                    let chans = [rgb.r, rgb.g, rgb.b]
                    for c in 0..<3 {
                        let tm = chans[c] / (1 + chans[c])          // Reinhard
                        let enc = pow(Double(tm), 1.0 / 2.2)        // sRGB-ish gamma
                        out[di + c] = UInt8(max(0, min(255, enc * 255)))
                    }
                }
            }
        }
        let thumb = PreviewImage(width: ow, height: oh, rgba: out)
        return FramePreview(index: index, thumb: thumb, hist: histograms(of: frame, bins: bins), stops: stops)
    }
}
