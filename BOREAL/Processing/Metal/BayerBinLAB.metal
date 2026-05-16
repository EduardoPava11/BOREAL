//
//  BayerBinLAB.metal
//
//  Phase 2 Stage 3: bin a cropped 2944×2944 BGGR mosaic into a 64×64×3
//  LAB tensor. Per-pixel kernel — one thread per output bin position;
//  4096 threads total per dispatch.
//
//  Pipeline: 46×46 box-average per channel (BGGR-aware sample selection)
//            → linearize via (raw - black) / (white - black)
//            → linear sRGB → XYZ (D65) via BT.709 matrix
//            → XYZ → CIE L*a*b* via standard f(t) cube-root-or-linear
//            → write 3 floats per output pixel (interleaved per-bin LAB)
//
//  BGGR channel layout in the 2×2 unit cell:
//      (row=0, col=0) = B    (even, even)
//      (row=0, col=1) = G    (even, odd)
//      (row=1, col=0) = G    (odd,  even)
//      (row=1, col=1) = R    (odd,  odd)
//
//  Per 46×46 block, 23² = 529 R-photosites, 529 B-photosites, and
//  23² + 23² = 1058 G-photosites (Gr + Gb combined).

#include <metal_stdlib>
using namespace metal;

// ----------------------------------------------------------------------------
// Geometry constants — match BayerCropPlan in Swift.
// ----------------------------------------------------------------------------

constant uint kBlockSize = 46u;
constant uint kBinCount  = 64u;
constant uint kCropSize  = kBinCount * kBlockSize;       // 2944
constant uint kHalfBlock = kBlockSize / 2u;              // 23

// Per-channel sample counts in a 46×46 block.
constant uint kSamplesR  = kHalfBlock * kHalfBlock;       // 529
constant uint kSamplesB  = kHalfBlock * kHalfBlock;       // 529
constant uint kSamplesG  = 2u * kHalfBlock * kHalfBlock;  // 1058 (Gr + Gb)

// ----------------------------------------------------------------------------
// Color-space matrices — BT.709 sRGB primaries → CIE XYZ (D65).
// Stored column-major per Metal float3x3 convention.
// ----------------------------------------------------------------------------

constant float3x3 kRGBtoXYZ = float3x3(
    float3(0.4124564f, 0.2126729f, 0.0193339f),  // column 0 (R)
    float3(0.3575761f, 0.7151522f, 0.1191920f),  // column 1 (G)
    float3(0.1804375f, 0.0721750f, 0.9503041f)   // column 2 (B)
);

constant float3 kD65 = float3(0.95047f, 1.0f, 1.08883f);

// ----------------------------------------------------------------------------
// CIE L*a*b* — standard f(t) auxiliary function.
//
//   f(t) = t^(1/3)             if t > (6/29)^3
//   f(t) = t / (3 * (6/29)^2) + 4/29   otherwise
// ----------------------------------------------------------------------------

inline float labF(float t) {
    constexpr float delta = 6.0f / 29.0f;
    constexpr float delta3 = delta * delta * delta;
    if (t > delta3) {
        return pow(t, 1.0f / 3.0f);
    }
    return t / (3.0f * delta * delta) + 4.0f / 29.0f;
}

inline float3 xyzToLab(float3 xyz) {
    float3 norm = xyz / kD65;
    float fx = labF(norm.x);
    float fy = labF(norm.y);
    float fz = labF(norm.z);
    return float3(116.0f * fy - 16.0f,
                  500.0f * (fx - fy),
                  200.0f * (fy - fz));
}

// ----------------------------------------------------------------------------
// Kernel.
// ----------------------------------------------------------------------------

kernel void bayerBinLAB_BGGR(
    device const ushort *mosaic     [[buffer(0)]],   // 2944×2944 u16 BGGR row-major
    device float        *outLAB     [[buffer(1)]],   // 64×64×3 f32 LAB row-major
    constant float      &blackLevel [[buffer(2)]],
    constant float      &whiteLevel [[buffer(3)]],
    uint2                gid        [[thread_position_in_grid]]
) {
    if (gid.x >= kBinCount || gid.y >= kBinCount) return;

    // 46×46 box bin starting at (blockX, blockY) in the mosaic.
    const uint blockX = gid.x * kBlockSize;
    const uint blockY = gid.y * kBlockSize;

    // Per-channel u32 accumulators. Max value: 2116 × 65535 ≈ 1.4e8 < 2^32. Safe.
    uint sumB  = 0u;
    uint sumGb = 0u;
    uint sumGr = 0u;
    uint sumR  = 0u;

    for (uint dy = 0u; dy < kBlockSize; ++dy) {
        const uint srcY = blockY + dy;
        const bool yEven = (dy & 1u) == 0u;
        const uint rowBase = srcY * kCropSize + blockX;
        for (uint dx = 0u; dx < kBlockSize; ++dx) {
            const ushort sample = mosaic[rowBase + dx];
            const bool xEven = (dx & 1u) == 0u;
            // BGGR phase:
            //   yEven && xEven → B   (even, even)
            //   yEven && !xEven → Gb (even, odd)
            //   !yEven && xEven → Gr (odd,  even)
            //   !yEven && !xEven → R (odd,  odd)
            if (yEven) {
                if (xEven) sumB  += sample;
                else       sumGb += sample;
            } else {
                if (xEven) sumGr += sample;
                else       sumR  += sample;
            }
        }
    }

    // Per-channel mean (raw counts in [0, 2^bits-1] domain).
    const float meanB = float(sumB)  / float(kSamplesB);
    const float meanG = float(sumGb + sumGr) / float(kSamplesG);
    const float meanR = float(sumR)  / float(kSamplesR);

    // Linearize: (raw - black) / (white - black), clamp to [0, 1].
    const float invSpan = 1.0f / max(whiteLevel - blackLevel, 1.0f);
    const float lr = saturate((meanR - blackLevel) * invSpan);
    const float lg = saturate((meanG - blackLevel) * invSpan);
    const float lb = saturate((meanB - blackLevel) * invSpan);

    // Linear sRGB → XYZ → LAB.
    const float3 xyz = kRGBtoXYZ * float3(lr, lg, lb);
    const float3 lab = xyzToLab(xyz);

    // Output: row-major (gid.y first), interleaved [L, a, b] per bin.
    const uint outIdx = (gid.y * kBinCount + gid.x) * 3u;
    outLAB[outIdx + 0u] = lab.x;
    outLAB[outIdx + 1u] = lab.y;
    outLAB[outIdx + 2u] = lab.z;
}
