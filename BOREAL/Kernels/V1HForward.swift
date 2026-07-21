import Foundation
import Accelerate

/// V1HForward — the V1 ENGINE (Swift/Accelerate), first tier of the
/// runtime ladder: ONE model, ONE V1HW artifact, engines promoted on
/// parity (V1 Accelerate → V2 Metal → V3 Core AI). This is the N4
/// forward-pass slice the V1HWeights loader was waiting for.
///
/// Scope: the ENCODER + PALETTE slice — the model's product job is the
/// 16×16 seed proposal (palette placement); the patch predictor stays
/// lab-side. Layer semantics mirror nn/v1/model.py exactly:
///
///   stem    conv3x3 pad1 groups=4 (16 → 2d), leaky 1/16
///   fuse    conv1x1 (2d → d)                       (no activation)
///   ladder  4 × conv3x3 stride2 pad1 (d → d), leaky 1/16 each
///   palette conv1x1 (d → 3) → (16,16,3) OKLab seed proposal
///
/// Implementation: im2col + cblas_sgemm (Accelerate BLAS), float32,
/// NHWC, weights (C_out, kH, kW, C_in/groups) fp16-widened by the
/// loader. PRECISION CLASS (normative for the learned path): TOLERANCE
/// parity only — reduction order is engine-private, so no engine claims
/// bit-exactness; the gate pins maxAbs against the numpy reference
/// (nn/v1/forward_ref.py → v1h_forward_golden.json), and promotion
/// beyond numeric parity is judged on battle metrics. Classic fallback
/// forever (circuit A2): callers treat nil / rejected parity as
/// "classic seed wins".
extension BorealKernels {

    /// Run the seed slice: `input` is the NHWC (inSide, inSide, 16)
    /// phase-decomposition tensor (Boreal.CycleSet), EV-normalized
    /// upstream. Returns the (16, 16, 3) seed proposal, NHWC-flattened.
    static func v1hSeedForward(_ pkg: V1HPackage, input: [Float],
                               inSide: Int) -> [Float]? {
        guard input.count == inSide * inSide * 16,
              let stem = pkg.tensors["encoder.stem.weight"],
              let fuse = pkg.tensors["encoder.fuse.weight"],
              let pal = pkg.tensors["palette.weight"] else { return nil }
        let nDown: Int
        switch inSide {
        case 256: nDown = 4
        case 512: nDown = 5
        case 1024: nDown = 6
        default: return nil
        }
        var ladder: [V1HTensor] = []
        for i in 0..<nDown {
            guard let t = pkg.tensors["encoder.ladder.\(i).weight"] else { return nil }
            ladder.append(t)
        }

        guard var h = conv2d(input, inSide, inSide, 16, stem,
                             stride: 1, pad: 1, groups: 4) else { return nil }
        leaky(&h.data)
        guard var f = conv2d(h.data, h.h, h.w, h.c, fuse,
                             stride: 1, pad: 0, groups: 1) else { return nil }
        for t in ladder {
            guard let next = conv2d(f.data, f.h, f.w, f.c, t,
                                    stride: 2, pad: 1, groups: 1) else { return nil }
            f = next
            leaky(&f.data)
        }
        guard f.h == 16, f.w == 16,
              let seed = conv2d(f.data, 16, 16, f.c, pal,
                                stride: 1, pad: 0, groups: 1) else { return nil }
        return seed.data                                  // (16,16,3)
    }

    /// leaky_relu(x, 1/16) in place — 1/16 is exact in every float.
    private static func leaky(_ x: inout [Float]) {
        for i in x.indices where x[i] < 0 { x[i] *= 0.0625 }
    }

    /// NHWC conv via im2col + sgemm. Weight (Cout, kH, kW, Cin/groups),
    /// rows flattened (ky, kx, ci) — the im2col column order matches, so
    /// out = cols(M×K) · Wᵍᵀ(K×cog) per group.
    private static func conv2d(_ x: [Float], _ H: Int, _ W: Int, _ Cin: Int,
                               _ wt: V1HTensor, stride: Int, pad: Int,
                               groups: Int)
        -> (data: [Float], h: Int, w: Int, c: Int)? {
        guard wt.shape.count == 4 else { return nil }
        let Cout = wt.shape[0], kH = wt.shape[1], kW = wt.shape[2], Cg = wt.shape[3]
        guard Cin == Cg * groups, Cout % groups == 0,
              wt.values.count == Cout * kH * kW * Cg else { return nil }
        let Ho = (H + 2 * pad - kH) / stride + 1
        let Wo = (W + 2 * pad - kW) / stride + 1
        guard Ho > 0, Wo > 0 else { return nil }
        let cog = Cout / groups
        let K = kH * kW * Cg
        let M = Ho * Wo

        // Zero-padded input copy (only when pad > 0).
        let Hp = H + 2 * pad, Wp = W + 2 * pad
        var xp: [Float]
        if pad == 0 {
            xp = x
        } else {
            xp = [Float](repeating: 0, count: Hp * Wp * Cin)
            x.withUnsafeBufferPointer { src in
                xp.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<H {
                        memcpy(dst.baseAddress! + ((y + pad) * Wp + pad) * Cin,
                               src.baseAddress! + y * W * Cin,
                               W * Cin * MemoryLayout<Float>.size)
                    }
                }
            }
        }

        var out = [Float](repeating: 0, count: M * Cout)
        var cols = [Float](repeating: 0, count: M * K)
        var tmp = groups > 1 ? [Float](repeating: 0, count: M * cog) : []

        for g in 0..<groups {
            cols.withUnsafeMutableBufferPointer { cp in
                xp.withUnsafeBufferPointer { sp in
                    for oy in 0..<Ho {
                        for ox in 0..<Wo {
                            let row = (oy * Wo + ox) * K
                            for ky in 0..<kH {
                                let iy = oy * stride + ky
                                for kx in 0..<kW {
                                    let ix = ox * stride + kx
                                    memcpy(cp.baseAddress! + row + (ky * kW + kx) * Cg,
                                           sp.baseAddress! + (iy * Wp + ix) * Cin + g * Cg,
                                           Cg * MemoryLayout<Float>.size)
                                }
                            }
                        }
                    }
                }
            }
            // C(M×cog) = cols(M×K) · Wᵍ(cog×K)ᵀ
            wt.values.withUnsafeBufferPointer { wp in
                cols.withUnsafeBufferPointer { cp in
                    if groups == 1 {
                        out.withUnsafeMutableBufferPointer { op in
                            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                        Int32(M), Int32(cog), Int32(K), 1,
                                        cp.baseAddress!, Int32(K),
                                        wp.baseAddress!, Int32(K),
                                        0, op.baseAddress!, Int32(cog))
                        }
                    } else {
                        tmp.withUnsafeMutableBufferPointer { tp in
                            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                        Int32(M), Int32(cog), Int32(K), 1,
                                        cp.baseAddress!, Int32(K),
                                        wp.baseAddress! + g * cog * K, Int32(K),
                                        0, tp.baseAddress!, Int32(cog))
                        }
                    }
                }
            }
            if groups > 1 {
                out.withUnsafeMutableBufferPointer { op in
                    tmp.withUnsafeBufferPointer { tp in
                        for i in 0..<M {
                            memcpy(op.baseAddress! + i * Cout + g * cog,
                                   tp.baseAddress! + i * cog,
                                   cog * MemoryLayout<Float>.size)
                        }
                    }
                }
            }
        }
        return (out, Ho, Wo, Cout)
    }
}
