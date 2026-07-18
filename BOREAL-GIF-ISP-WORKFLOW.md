# BOREAL GIF-ISP Workflow

North star: **the app is capture -> GIF.** A custom ISP whose native output
is GIF structure — index maps + a palette seeded by the 16x16 — emitted as
**64 frames of 256x256**. The custom-ISP identity: **demosaic at every
scale** (each rung is its own demosaic of the mosaic, not a resize of a
full-resolution demosaic).

Non-goals (RETIRED as product, 2026-07-17): HDR TIFF master, Photoshop
.cube LUT, grade UI. The decode/fuse/color kernels they proved remain the
ISP's foundation; the TIFF/LUT surfaces leave the app.

Standing constraints: camera code is compile-only until a device run
(signing: DEVELOPMENT_TEAM empty); spec-first discipline for every new
kernel (law -> golden -> oracle -> port); Import-DNGs stays alive in every
phase as the simulator-testability lever.

---

## Phase 0 — Graceful retirement (the refocus)

Goal: one product surface. The round shutter captures FOR THE GIF pipeline;
nothing in the UI mentions TIFF or LUT.

- Archive, don't delete: move the HDR/LUT surface (ReviewView grade UI,
  GradeControls, TIFF/LUT share actions, PipelineModel's TIFF tail) to
  `archive/hdr-lut` branch; master keeps kernels (`tiff.zig`/`lut.zig` stay
  in the kernel — tested, harmless, unreferenced by the app).
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

## Phase 5 — Runtime evaluation: Swift SIMT + Metal vs Zig

Direction to evaluate (Daniel's lean: Swift SIMT/Metal better for iPhone;
SixFour executed exactly this pivot). Do it with numbers, not vibes, and
NOT as a big bang:

- Measure first (device, Phase 2-4 workloads): per-64-frame-burst cost of
  (a) index maps 64 x 65k px x 256 palette, (b) multi-scale demosaic,
  (c) OKLab Q16, in current Zig vs a Metal compute port vs Swift+SIMD.
- Expected split (to be confirmed by the numbers):
    Metal compute  — per-pixel parallel hot path (demosaic, index map,
                     OKLab) at 64x256^2 scale; integer ops stay integer
                     in-shader so determinism holds (DeterministicRenderer
                     precedent); golden parity via the same fixtures.
    Swift + SIMD   — glue, per-cycle analysis, anything MainActor-adjacent.
    Zig stays      — DNG parse/LJPEG decode (1554 device-proven lines,
                     cold path, porting = all risk no gain — the same
                     argument that kept dng.zig through the last pivot).
- The Haskell spec + goldens are language-neutral BY DESIGN — a port
  target change costs re-porting kernels, never re-deriving contracts.
  Fixture tests gate any migrated kernel bit-exact before cutover.
- Exit gate: a one-page decision record with measured numbers; migrate
  only kernels the numbers indict.

## Phase 6 — Training (the learned ISP)

- Per-rung NN demosaic replacing Phase 3's classic path, gated per rung:
  >= +1 dB over the rung's CFA-bin baseline, judged in OKLab dE.
- MLX on Mac; data = LAB-report bundles (real photons, replayable) +
  synthetic mosaicked OKLab gradients; bias-free nets (exact exposure
  equivariance composes with Phase 2's per-frame normalization).
- Deploy per Phase 5's decision (Metal kernel with baked weights is the
  proven pattern).

---

## Cross-cutting: the test program (bugs are assumed)

Runs through every phase, not after them:

1. `make -C spec gate` + `zig build test -Drequire_fixtures=true` — every
   turn, already standing.
2. Sim path: Import 4 DNGs -> full GIF pipeline -> Phase 1 preview. No
   camera needed; this is the daily driver.
3. Device path: LAB report bundle -> **Mac replay script** (to build,
   Phase 1-adjacent): re-runs the pipeline on the bundled DNGs with the
   oracle conventions and asserts equality with the phone's own
   report.json — end-to-end bit-exactness with real photons.
4. Swift-glue harness: crop alignment, deinterleave, sigma indexing get
   sim-runnable tests once the stale test target is revived (Phase 0
   cleans the target list; add BOREALTests back then).

## Decision points (Daniel)

- D1 Phase 4 palette: GCT-from-burst vs LCT-per-cycle (default: GCT first).
- D2 Phase 5: migration threshold — what measured speedup justifies a port.
- D3 Phase 3: the MS4 consistency envelope (how far adjacent rungs may
  disagree before it's a defect, not a feature).
- D4 Retirement depth: archive branch only, or also strip tiff/lut from
  the kernel build (default: keep in kernel, out of app).
