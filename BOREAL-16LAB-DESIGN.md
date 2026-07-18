# BOREAL 16-LAB: Engineering Design

> ★ REFOCUS 2026-07-17 (Daniel): **the app is capture -> GIF.** The HDR-TIFF
> + LUT product is RETIRED (technical debt; archive per Phase 0). The ISP is
> custom because it **demosaics at every scale**; the product is **64 frames
> of 256x256** GIF; the 4-frame cycle with per-cycle EV recalculation is the
> first analysis focus; Swift SIMT/Metal vs Zig is under evaluation for the
> hot path. Execution plan: `BOREAL-GIF-ISP-WORKFLOW.md` (Phases 0-6).
> Sections below describing L2 as demosaic-then-box predate the refocus and
> are superseded by Phase 3 (multi-scale residual pyramid, MS laws).

64-frame Bayer burst to a 16x16 OKLab latent with exact back-trace.
Status 2026-07-17 (late): layers 0 and 4 fully landed and gated (26 laws);
layer 1 landed compile-checked (16-cycle burst loop, ETTR hook stubbed);
layer 2 COMPOSED end-to-end in `BurstController.reduce` — decode -> crop S²
(largest 256·2^j <= sensor, even-aligned) -> EV-aware fuse -> demosaic ->
ProPhoto -> `bk_box_reduce_rgb` (new kernel, spec'd CQ7/CQ8 + bit-exact
golden) -> OKLab Q16 -> 3 pyramids -> sigma head; per-cycle product =
`Bands{L,a,b,sigma}` (~768 KB), 16/burst. Swift glue (crop, deinterleave,
sigma indexing) is compile-checked only — DEVICE RUN PENDING, and a
synthetic-DNG harness for reduce() is the natural next verification.
Layer 3 latent head now produced; the GIF TARGET is now spec'd and landed
(`Boreal.GifTarget`, laws G1-G6: palette = seed 16x16 verbatim; index map =
i64 Q16 argmin ties-lowest; display = Ottosson inverse + a GENERATED
normative sRGB encode table `src/srgb_table.zig` - never pow at runtime;
Zig `bk_index_map` + `bk_oklab_q16_to_srgb8` fixture-gated). Verification
artifact: the LAB button captures one 4-DNG cycle and AirDrops a report
bundle (report.json with bands/palette/sigma/index-maps, palette-mapped
rung_N.png = previews of the target GIF frames, plus the 4 source DNGs so
the Mac oracle can replay the same photons). DEVICE RUN PENDING. Record
format still open. Layers 5-6 designed, not started.

```
                 ┌──────────────────────────────────────────────────────┐
 sensor 4224x3024│ L1 CAPTURE   16 cycles x 4 EV frames @ ~20fps (~3.2s)│ Swift/AVF
 14-bit Bayer    │   ETTR planner re-plans EVs between cycles           │
                 └──────────────┬───────────────────────────────────────┘
                                │ CVPixelBuffer ring (6 deep, ~150 MB), no DNG
                 ┌──────────────▼───────────────────────────────────────┐
                 │ L2 CLASSIC REDUCTION (per cycle, Zig)                │
                 │  crop 2048² -> fuse(4) -> demosaic -> cam_to_pp      │
                 │  -> linear box 2048²->256² -> OKLab Q16 -> pyramid   │
                 └──────────────┬───────────────────────────────────────┘
                                │ 3 band buffers (L,a,b), 256² i32 each, prefix layout
                 ┌──────────────▼───────────────────────────────────────┐
                 │ L3 LATENT    16 frames of 16x16x4 (L,a,b,σ)          │
                 │  = band0 prefix + subtree energy; palette-grid SOM   │
                 └──────────────┬───────────────────────────────────────┘
                                │
                 ┌──────────────▼──────────────┐  ┌──────────────────────┐
                 │ L5 NN (replaces demosaic+   │  │ L6 H-JEPA            │
                 │ downsample; residual over   │  │ deterministic up /   │
                 │ L2 classic path per rung)   │  │ learned down + time  │
                 └─────────────────────────────┘  └──────────────────────┘

 L0 SPEC GATE (under everything): Haskell laws -> golden JSON -> Python
 oracle -> Zig fixture tests -> Swift link. One command: make -C spec gate.
```

## L0 Verification architecture (LANDED)

Single-source discipline: pure kernels live in `spec/Boreal/*.hs`; the law
files AND the golden emitter import the same modules, so spec and fixtures
cannot drift. Chain per algorithm:

1. `spec/` law file proves the algebraic laws (runghc, `make test`, 5 files
   / 24 laws green).
2. `spec/emit/EmitGoldens.hs` writes `zig/borealkernel/fixtures/*.json`.
3. `spec/oracle/validate_goldens.py` re-derives everything FROM THE WRITTEN
   CONVENTIONS (not the Haskell source) and asserts agreement.
4. `tests/*_fixtures.zig` assert the Zig port agrees; run with
   `-Drequire_fixtures=true` so absence fails instead of skipping.

Exactness domains (deliberate, per data type):
- integers (pyramid, Q16): BIT-EXACT everywhere.
- f64 color path: BIT-EXACT via owned cbrt + pinned op order (below).
- rationals (EV ratios, normalization): exact over Q in spec; dyadic /128
  test mosaics chosen so the f64 port is also bit-exact.
- transcendental seeds (palette OKLab): tolerance 1e-9.
- physical anchors (white through Bradford): tolerance 1e-3 (4-decimal
  published matrices bound the achievable precision).

## L1 Capture (bracket LANDED, burst loop TO GRAFT)

Hardware path: iPhone 17 Pro rear wide, 12MP quad-binned Bayer readout
4224x3024, 14-bit samples in 16-bit containers. Naked Bayer RAW only:
`isAppleProRAWEnabled = false`, format via `isBayerRAWPixelFormat`,
`photoQualityPrioritization = .speed` (device-verified: `.balanced` throws
on Bayer capture).

Burst structure: 64 frames = 16 cycles x 4 EV frames.
- Within a cycle: one 4-frame `AVCapturePhotoBracketSettings` RAW bracket
  (today's device-proven single-shot path, reused as the cycle primitive).
- Between cycles: `bk_analyze_scene` on cycle k stats feeds
  `bk_solve_ettr_exposures` to plan cycle k+1 biases (the previously
  unwired scene.zig ETTR brain becomes the inter-cycle controller).
- Loop mechanics grafted from 6teen3 `CameraManager`: fire-next-capture
  BEFORE processing current (overlaps ISP with reduction), 45s watchdog,
  AE/WB locked inside a cycle.

Frame handoff (the load-bearing decision): CVPixelBuffer, never DNG, on the
hot path. `RAWCaptureDelegate` (6teen3 lift) supplies BlackLevel[4],
WhiteLevel, AsShotNeutral -> WB gains, ForwardMatrix from `photo.metadata`.
A 6-deep ring (~25 MB/frame, ~150 MB) holds raw frames; each frame must be
reduced before its slot recycles. 64 full-res frames (~1.5 GB) is not a
viable alternative on a 12 GB device sharing memory with the ISP.

Failure policy: a cycle with <4 frames is dropped whole (fuse is 4-ary);
burst succeeds with >=14/16 cycles (adapts 6teen3's 60/64 rule to cycle
granularity). Missing EXIF inside a cycle -> exposure ratios fall back to
{1,1,1,1} = temporal-denoise cycle (existing fuse fallback, EV3 law).

## L2 Classic reduction pipeline (ALL KERNELS EXIST, COMPOSITION PENDING)

Per cycle, on the reduction queue. This is the TEACHER/BASELINE path; the
NN (L5) later replaces steps 3-5 jointly and must beat it per rung.

| # | step | kernel | in -> out | notes |
|---|------|--------|-----------|-------|
| 1 | crop | (Swift ptr math) | 4224x3024 -> 2048² u16 | center, even-aligned to preserve RGGB phase; 2048 = 256·2^3 (CS1) |
| 2 | ratios | `bk_relative_exposures` | EXIF x4 -> e_t f32[4] | darkest=1, clamp [1,256], EV1-EV3 laws |
| 3 | fuse | `bk_fuse_mosaics` | 4x u16 2048² -> f32 2048² | scene-linear, SNR+saturation weighted, SIMD 8-lane |
| 4 | demosaic | `bk_demosaic_full` | mosaic -> f32 RGB 2048² | Malvar-He-Cutler, SIMD columns |
| 5 | color | `bk_apply_color_matrix` | camera RGB -> linear ProPhoto | cam_to_pp = XYZ_TO_PROPHOTO · FM · diag(wb) |
| 6 | downsample | NEW `bk_box_reduce_rgb` | 2048² -> 256² f32 RGB | 8x8 box mean IN LINEAR LIGHT (averaging photons is only correct pre-OETF); f32 sum order pinned row-major |
| 7 | to LAB | `bk_oklab_q16_from_prophoto` | 256² f32 RGB -> 256²x3 i32 | owned cbrt, f64 math, bit-exact gated |
| 8 | pyramid | `bk_pyramid_analyze` x3 | 256² i32 -> 256² i32 bands | per channel L,a,b; scratch 32Ki32 |

Budgets per cycle (target: << 200 ms at 20 fps cadence):
- compute: steps 3-5 are already device-proven at FULL 4224x3024 in the
  one-shot pipeline; at 2048² (0.35x the pixels) the whole chain is
  comfortably sub-frame. Step 7 is 65k px of f64 (3 cbrt each): ~1-2 ms
  scalar, SIMD later if needed. Step 8 is ~90k integer quad transforms.
- transient memory: fused mosaic 16.8 MB + RGB 50 MB + ProPhoto in place +
  256² buffers ~1 MB. Peak ~70 MB transient on top of the ring.
- persistent per burst: 16 cycles x 3 channels x 256 KB bands = 12.3 MB.

## L3 The latent and its buffer (PYRAMID LANDED, HEAD PENDING)

Band buffer (per channel, per cycle): side² i32 in PREFIX layout. Top band
(16², row-major) at [0, 256); detail level with quad-grid side s occupies
[s², 4s²) as interleaved (LH, HL, HH) per quad, levels coarse to fine.
Closed form: the offset of level s IS s². Consequences:
- `bands[0..256)` is the 16x16 latent frame. No extraction step.
- `bands[0..r²)` is the exact rung-r encoding for r in {16,32,64,128,256}.
- back-trace = `bk_pyramid_synthesize` on a prefix: exact integer inverse
  (S-transform pair l=floor((a+b)/2), h=a-b is a bijection on Z²).

The 16x16x4 latent head per cycle: (L, a, b) from the three band0s, sigma =
subtree |detail| energy per cell (EP5 law: sigma=0 iff the cell's 16x16
block is constant). Sigma is the dither budget and the resolution gate.

Palette-grid SOM (L1-L3 laws, seed landed): 256 = 16x16, index = v*16+u,
rows = lightness strata, columns = hue at chroma 0.10. Laws: home-centering
(occurrences within Chebyshev r, centroids within r+1/2), neighbor ΔE <=
K=0.06, dither = grid displacement with ΔE <= K·(|du|+|dv|). Dither fields
are mostly-zero displacement vectors: LZW-friendly by construction.

## L4 Color math (LANDED, bit-exact in 3 languages)

ProPhoto(D50) -> Bradford -> XYZ(D65) -> M1 -> LMS -> owned cbrt -> M2 ->
OKLab -> Q16. One baked 3x3 (PROPHOTO_TO_LMS) composed at Zig comptime on
TYPED f64 (typed comptime floats use f64 rounding; fixture-proven equal to
Haskell's runtime composition).

Owned cbrt (never libm; libm differs by ulps across languages and flips
Q16 ties): x = f·2^e with f in [1,2) via IEEE bits; y0 = 0.75 + f/4;
exactly 4 Newton steps y = (2y + f/(y·y))/3; result = scalb(y·CORR[e mod 3],
e div 3), CORR = {1, 2^(1/3), 2^(2/3)} as f64 literals. Accuracy ~1 ulp,
determinism absolute.

Q16: q(x) = floor(x·65536 + 0.5) as i32. L in [0, 65536]; a,b in about
[-26k, +26k]. Detail bands grow bounded (each S-transform level at most
doubles magnitude; 4 levels from Q16 stays far inside i32).

## L5 NN (DESIGNED; Tesseract debayer proven as seed)

Replaces steps 4-6 of L2 jointly (demosaic + downsample; predicting
directly in the latent's own color space is the open-research corner).
- Input per cycle: 4 EV-normalized frames (divide by e_t pre-NN; bias-free
  net keeps 1-homogeneity so exposure equivariance is exact, EV4 law),
  phase-split RGGB -> 16ch x 1024².
- Body: grouped strided convs down the dyadic ladder, residual over the
  classic path at every rung (the classic pyramid is computed anyway; the
  NN only learns the correction, Tesseract's 5.6k-param pattern).
- Heads: 256² OKLab ceiling (feeds the same Q16+pyramid) and the 16x16x4
  latent directly.
- Training: MLX on Mac; data = real bursts + synthetic Bayer (procedural
  OKLab gradients mosaicked through CFA + noise model: exact ground truth
  at every rung). Loss: per-rung log-MSE with chroma reweighting (both
  documented Tesseract traps). Ship gate: >= +1 dB over the classic path
  per rung, judged in OKLab ΔE (BR5 pattern).
- Deploy: hand-written Metal kernel with baked weights (proven 0.52 ms
  @256² for 5.6k params); on-device continual step via MPSGraph wrapping
  the SAME MTLBuffers zero-copy (MLX has no zero-copy bridge).

## L6 H-JEPA (DESIGNED)

Deterministic up / learned down (OneSix contract): the exact integer
pyramid is the TARGET; the model predicts the next detail band from the
prefix (spatial) and the next cycle's latent from history (temporal, 16
steps). LeJEPA recipe (no EMA teacher, single hyperparameter) on in-domain
bursts. The FP tensor units (A19 GPU neural accelerators) serve only the
learned direction; the exact encoder stays integer.

## ABI summary (all caller-owns-memory, C ABI via BorealKernel.h)

```
bk_status_t bk_pyramid_analyze  (const i32 *img,   u32 side, u32 base, i32 *bands, i32 *scratch)
bk_status_t bk_pyramid_synthesize(const i32 *bands, u32 side, u32 base, i32 *img,   i32 *scratch)
            // side, base powers of two, base <= side; scratch = side²/2 elems
void        bk_oklab_q16_from_prophoto(const f32 *rgb, size_t n_px, i32 *out)   // 3*n_px each
// existing, device-proven: bk_decode_dng_to_mosaic, bk_relative_exposures,
// bk_fuse_mosaics, bk_demosaic_full, bk_apply_color_matrix,
// bk_analyze_scene, bk_solve_ettr_exposures, bk_channel_histograms
// TO BUILD: bk_box_reduce_rgb (L2 step 6)
```

## Open decisions

1. Record format for the 12.3 MB/burst band data: sidecar container vs GIF
   application-extension (S4GX pattern). Prefix property means a truncated
   record is still a valid coarser burst; the format should preserve that.
2. On-device retention: full 256² bands vs 64² prefix (16x less) once the
   NN is the producer; sigma head only needs energies, not coefficients.
3. Detail-band narrowing to i16 with a saturation law (halves the record;
   needs an overflow-impossibility proof per level first).
4. NN parameter budget (20-60k working assumption) and whether the 16x16x4
   head shares the trunk or reads the pyramid.

## Gate commands

```
make -C spec gate                                  # laws + emit + oracle
cd zig/borealkernel && zig build test -Drequire_fixtures=true
make build                                         # sim app link check
```
