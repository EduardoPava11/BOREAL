# BOREAL GIF-ISP Workflow

North star: **the app is capture -> GIF.** A custom ISP whose native output
is GIF structure — index maps + a palette seeded by the 16x16 — emitted as
**64 frames of 256x256**. The custom-ISP identity: **demosaic at every
scale** (each rung is its own demosaic of the mosaic, not a resize of a
full-resolution demosaic).

Non-goals (RETIRED as product, 2026-07-17): HDR TIFF master, Photoshop
.cube LUT, grade UI. The decode/fuse/color kernels they proved remain the
ISP's foundation; the TIFF/LUT surfaces leave the app.

Standing constraints: camera code is compile-checked in the sim; device
runs happen when signed (first real run 2026-07-17, c386663 — Mac replay
bit-exact); spec-first discipline for every new kernel (law -> golden ->
oracle -> port); Import-DNGs stays alive in every phase as the
simulator-testability lever.

> STATUS (audit 2026-07-18): Phases 0-5 are EXECUTED (Phase 5 complete,
> the Zig tree is deleted — 1cf045c). Phase 6 is SUPERSEDED by
> `BOREAL-COREAI-TRAINING-WORKFLOW.md` (the four-net program: L-net,
> a-net, b-net, Composer; N0 done, N1 open) — read that doc for the
> model; the bell laws below (B1-B4) remain canon. Code-behind-spec gaps
> still OPEN:
>   G1 Phase 1 — sigma heat overlay toggle never built (sigma is
>      computed and written to report.json only; no UI renders it).
>   G2 Phase 1 — the 64-burst bypasses the preview surface entirely
>      (share-only GIF from BurstController). PARTIALLY CLOSED
>      2026-07-18: the single-cycle GIF now ANIMATES in the preview
>      (Report carries frameIndices; the hero cycles the 4 frames at
>      5 cs through the product decode — no second rendering path);
>      the burst still doesn't route into the preview.
>   G3 Phase 4 — LCT-per-cycle behind a flag never built (D1's GCT
>      default is hardcoded).
>   G4 Phase 4 — the round-trip exit law (decode-with-system-decoder ==
>      our decode) is verified nowhere; verify-swift pins encode bytes
>      against the golden but no harness runs a system decoder.
>   G5 Test program — BOREALTests target still absent; root
>      `make test-xcode` runs xcodebuild test against a project with no
>      test target.
>   G6 Circuit A3 — the 64-burst emits NO report bundle (only the
>      single-cycle path writes one); registered 2026-07-18, blocks
>      the corpus valve and the Mac-side model-vs-classic judge.
>   G7 Gate coverage — the EvPlan mapping laws (P1-P4) have no
>      emitted fixture; SceneKernel's ETTR planner is gated only by
>      its ported self-test (registered 2026-07-18).
> CLOSED 2026-07-18: the geometry contract now carries the
> DEVICE-VERIFIED facts (decoded mosaic 4032x3024 — NOT the 4224
> pre-crop tile raster — BGGR, black 528, white 4095, 12-bit; c386663)
> and the crop DERIVATION as law (CS1 derives, CS6 case table, CS7
> even-origin, CS8 device facts); the app's canonicalSide/cropOrigin
> moved to Kernels/GeometryKernel.swift and the swift-verify leg
> replays the fixture's crop-case table against them — the crop math
> is gate-protected end to end. The orphaned S-transform pyramid leg
> (EmbeddedPyramid.hs, Boreal.Pyramid, pyramid_golden.json) is
> RETIRED from the gate (superseded by MultiScale; archive branches +
> git history preserve it).

---

## Phase 0 — Graceful retirement (the refocus)

Goal: one product surface. The round shutter captures FOR THE GIF pipeline;
nothing in the UI mentions TIFF or LUT.

- Archive, don't delete: move the HDR/LUT surface (ReviewView grade UI,
  GradeControls, TIFF/LUT share actions, PipelineModel's TIFF tail) to
  `archive/hdr-lut` branch. (Historical note: `tiff.zig`/`lut.zig` stayed
  in the Zig kernel at the time; since M5 deleted the Zig tree, they
  survive only on `archive/zig-kernel` and `archive/hdr-lut`.)
- Keep and re-point: decode/fuse/demosaic/color facade, Import path
  (now feeds the GIF pipeline), live histogram overlay, camera lifecycle.
- UI after Phase 0: shutter = capture one 4-frame cycle -> GIF preview
  (Phase 1); "64" = full burst; LAB report button stays (verification).
- Exit gate: sim build green; Import 4 DNGs lands in the GIF path;
  no TIFF/LUT strings anywhere in the UI.

## Phase 1 — Preview surface (unblocks human testing)

The reason the app "cannot be tested" today: the pipeline produces bands
and reports, but the user sees nothing. Fix before all else.

- In-app preview = EXACTLY what the GIF will be: index map x palette,
  rendered per rung (16 -> 256), animated across frames when a burst
  exists. No second rendering path — the preview IS the product decode
  (the CycleReport PNG renderer generalized to a live SwiftUI surface,
  nearest-neighbor upscale, no smoothing).
- Show: the 256 preview large; rung strip 16/32/64/128; palette swatch
  grid (the seed 16x16 AS a 16x16 grid — A2 made visible); sigma heat
  overlay toggle.
- Exit gate: capture (device) or Import (sim) -> the user SEES the target
  GIF frames and the palette. This is the acceptance surface for every
  later phase.

## Phase 2 — The 4-frame cycle analysis + EV recalculation (FIRST focus)

Each 4-frame cycle must recalculate EV for the next. This is the analysis
core and comes before multi-scale work.

- Wire the dormant ETTR brain: cycle k's mosaics -> channel clip stats
  (`bk_analyze_scene` path or the existing per-mosaic channel histograms)
  -> `bk_solve_ettr_exposures` -> exposure-bias vector for cycle k+1.
  Replaces the `planBiases` stub; the loop already has the hook.
- Per-frame vs per-cycle roles, made explicit:
    frame  = one exposure; normalized by ITS OWN e_t (exact, EV1-EV5) —
             the unit of GIF output (64 frames).
    cycle  = 4 frames; the unit of ANALYSIS — EV re-plan, palette seed,
             fuse (fuse remains the analysis/denoise reference, no longer
             the only render path).
- Spec addition: a law tying the planner to the capture loop (planned
  biases bounded by device min/max; darkest-frame anchoring preserved
  across cycles).
- Exit gate: device log shows per-cycle bias vectors changing with the
  scene; report.json carries planned-vs-EXIF-actual EV per cycle.

## Phase 3 — Multi-scale demosaic (the custom-ISP core)

Demosaic AT each scale, not full-res-then-box. This redefines the pyramid:

- Per rung r in {16,32,64,128,256}: produce rung image r^2 DIRECTLY from
  the (cycle or frame) mosaic — CFA-aware reduction to the rung's own
  mosaic geometry + demosaic at that scale. Baseline per rung = CFA-bin
  ("picking colors" at that scale); custom/learned path replaces it later.
  This dissolves the two-baselines ambiguity: the baseline IS per-rung.
- Pyramid becomes a RESIDUAL pyramid between independently demosaiced
  scales: band0 = 16^2 demosaic; detail level s = rung-2s image minus the
  exact upsample of rung s. Prefix-decode law CHANGES meaning (spec first):
  OLD EP3: prefix == floor-mean coarsen of the ceiling.
  NEW MS3: prefix at rung r == THE RUNG-r DEMOSAIC, exactly.
  Back-trace and prefix properties survive (still exact integer bands);
  what a prefix decodes TO is now scale-native, which is the whole point.
- Spec work: `Boreal.MultiScale` module + law file (MS1 residual round
  trip; MS2 band accounting unchanged; MS3 prefix = rung demosaic; MS4
  consistency envelope between rungs — deliberately NOT equality); new
  goldens; oracle; kernels.
- Exit gate: spec gate green with MS laws; rung previews (Phase 1 surface)
  visibly sharper at 64/128/256 than the box-reduce path on device photos.

## Phase 4 — GIF wire: 64 frames x 256x256

- Export contract: GIF89a, 64 frames (one per captured frame), 256x256,
  5cs delay (20 fps, house convention), infinite loop.
- Palette decision (open): one global color table from the burst's seed
  vs per-cycle local color tables (16 palettes). Start GCT-from-first-
  cycle for simplicity; LCT-per-cycle behind a flag; measure banding on
  device captures via the Phase 1 preview.
- Encoder: BOREAL-owned LZW in the OneSix pattern (spec GifWire laws +
  byte-exact goldens; OneSix's uncompressed-LZW + general decoder design
  is the reference implementation to re-derive, not import blindly).
- Frame path: per frame — EV-normalize -> multi-scale demosaic (Phase 3)
  -> OKLab Q16 -> index map vs the governing palette -> LZW.
- Exit gate: a burst on device produces one .gif file; decode-with-
  system-decoder == our decode (round-trip law); AirDrop shares it.

## Phase 5 — Swift + Metal migration (COMPLETE 2026-07-17)

Daniel's call, made twice (SixFour precedent, reaffirmed 2026-07-17):
this is a Swift and Metal app. Not a benchmark question. The spec +
goldens are language-neutral by design, so every port was gated bit-exact
before cutover. Never propose Zig for BOREAL again.

- M1 (DONE 2026-07-17, c202639): the live 16-LAB kernels ported to pure
  Swift `BOREAL/Kernels/` (enum BorealKernels): owned cbrt + OKLab + Q16,
  multi-scale encode/decode, normalize, index map, sRGB display path
  (generated SRGBTable.swift), GIF89a wire. Verified by the
  `make -C spec swift-verify` gate leg (swiftc harness against the SAME
  goldens). App facade switched; the product path is Swift.
- M2 (DONE 2026-07-17, 2265b0b): MetalIndexMapper — inline-source
  compute shader, i64 in-shader, strict-less ties-lowest preserved, GPU
  bit-identical to CPU (gate runs it on the Mac GPU, loud skip without
  Metal); msEncode rung means multicore via concurrentPerform (per-cell
  f64 unchanged, bit-identical). Metal has no f64, so the encode
  reduction stays CPU-exact; a GPU integer-sum variant (M2b) would need
  a spec change first, only if device numbers demand it.
- M3 (DONE 2026-07-17, 68eeed3): fuse, scene (ETTR), color ported to
  Swift (FuseKernel, SceneKernel).
- M4 (DONE 2026-07-17, 68eeed3): the DNG/LJPEG decoder ported
  (DNGKernel.swift, ~1400 lines; DefaultCrop now applied at decode —
  deliberate behavior change, proven on the real device bundle). The
  6teen3 CVPixelBuffer capture route remains an option to take the
  decoder off the hot path later; Import/sim uses the Swift decoder.
- M5 (DONE 2026-07-17, 1cf045c): the Zig tree, build scripts, xcfilelist
  and bridging header are DELETED; fixtures moved to repo-root
  `fixtures/`; `archive/zig-kernel` preserves everything including the
  binomial.zig WIP. Parity club after M5: Haskell = Python oracle =
  Swift kernels (+ nn/v1 NumPy pipeline as the 4th independent
  implementation), all bit/byte-exact.

## Phase 6 — Training (the learned ISP)

> SUPERSEDED (2026-07-18): the model is no longer ONE network. The
> current architecture is the FOUR-NET program — L-net (H-JEPA level 1
> on L, battle laws BA1-BA6 as its dynamics), a-net + b-net (chroma
> pair), Composer — shipped as one multi-function .aimodel, with the
> three-tier no-train-on-device boundary. Source of truth:
> `BOREAL-COREAI-TRAINING-WORKFLOW.md` (N0 done, N1 open), governed by
> `BOREAL-TRAINING-REGIMEN-WORKFLOW.md` and gated by
> `BOREAL-TILING-INVESTIGATIONS.md` (I0-I8, still OPEN). The bell
> requirement below (B1-B4) remains canon; the per-rung +1 dB dE
> check remains as a DIAGNOSTIC only — the SHIP gate is the
> equilibrium-layer dominance test (redefined 2026-07-18; see the
> regimen doc's "equilibrium judge" section);
> the one-network framing below is kept as the historical seed of that
> design.

THE MODEL (decided 2026-07-17): ONE H-JEPA-trained network that demosaics
the square Bayer pattern and "sees" at every partition — 16x16, 32x32,
64x64, 128x128, 256x256 — predicting directly into the LAB latent. Doing
it at ALL levels is what makes the seed work: the 16x16 = 256 seeds the
palette AND the coarsest view the model reasons from; the finer partitions
are the JEPA's prediction targets (deterministic residual pyramid = the
target; learned down = the model).

THE BELL REQUIREMENT: by the 256x256 ceiling, the palette's LUMINANCE
allocation must follow the bell over 16 strata:
  1,1,2,4,8,16,32,64,64,32,16,8,4,2,1,1   (sum = 256)
— ends pinned to exact black and exact white, mid-tones (where the eye
lives) getting 64 colors apiece. Landed as laws B1-B4 (Boreal.Palette
bellPalette + palette/PaletteGrid.hs): shape exact, anchors exact through
Q16, luminance monotone with strict stratum ownership, and the bell seed
still self-indexes as the identity (A2 survives). Training therefore has a
LAWFUL TARGET: the learned seed is admissible only if its L histogram is
the bell — the projection that closes the "real scenes aren't lawful"
gap.

- Per-rung >= +1 dB over the rung's CFA-bin baseline in OKLab dE —
  now a DIAGNOSTIC, not the ship gate (superseded 2026-07-18 by the
  equilibrium-layer judge; see the regimen doc). Bias-free nets (exact exposure equivariance composes with
  Phase 2's per-frame normalization).
- MLX on Mac; data = LAB-report bundles (real photons, replayable) +
  synthetic mosaicked OKLab gradients with bell-lawful ground truth.
- Deploy per Phase 5's decision (Metal kernel with baked weights is the
  proven pattern).

---

## Cross-cutting: the test program (bugs are assumed)

Runs through every phase, not after them:

1. `make -C spec gate` — every turn, standing. Four legs: Haskell laws
   -> emit goldens -> Python oracle -> swift-verify (compiles the app's
   actual Kernels/ against the same fixtures, plus Metal GPU parity).
   (The old `zig build test` leg died with M5.)
2. Sim path: Import 4 DNGs -> full GIF pipeline -> Phase 1 preview. No
   camera needed; this is the daily driver.
3. Device path (BUILT — `spec/verify-device`, `make -C spec
   verify-device DIR=...`): replays a LAB report bundle's DNGs through
   the same Swift kernels on the Mac and asserts bit-exact equality
   with the phone's own report.json. Proven on real photons 2026-07-17
   (c386663: all stack coefficients, index maps, chi^2, homeShare exact).
4. STILL OPEN (gap G5): Swift-glue harness — crop alignment,
   deinterleave, sigma indexing have no sim-runnable tests; the
   BOREALTests target was never added back, and root `make test-xcode`
   currently runs against a project with no test target.

## Decision points (Daniel)

- D1 Phase 4 palette: GCT-from-burst vs LCT-per-cycle — STILL OPEN.
  De facto: GCT-from-first-cycle is hardcoded (governing palette); the
  LCT flag was never built (gap G3). Decide after banding is measured
  on device bursts through the Phase 1 preview.
- D2 Phase 5: MOOT — the migration was decreed, not benchmarked;
  Phase 5 is complete.
- D3 Phase 3: the MS4 consistency envelope — landed as MS4a (linear
  nesting exact over Q) + MS4b (OKLab nesting bounded 32768 Q16 as a
  noise-envelope regression pin). Whether that bound needs tightening
  on real scenes stays open.
- D4 Retirement depth: RESOLVED beyond both options — M5 deleted the
  whole Zig tree; tiff/lut survive only on the archive branches.
- D5 Bell-SOM reconciliation: the bell's sparse extremes are ISOLATED
  colors by construction (one color covering a whole L band), so the
  uniform seed's flat neighbor-Lipschitz bound (L2, K=0.06) cannot hold
  verbatim on a bell-distributed grid. When the bell seed replaces the
  uniform seed as the SOM reference, L2/L3 must become stratum-aware
  (bound = hue term within a stratum + band-width term across strata).
  Until decided, the uniform seed remains the L1-L3 reference and the
  bell is the LUMINANCE-ALLOCATION law set (B1-B4).
