# BOREAL — RGBT → HDR TIFF + Photoshop LUT (Pivot Workflow)

> RETIRED AS PRODUCT (banner added 2026-07-18): the HDR-TIFF + `.cube`
> LUT product this doc pivots to was retired by the GIF-ISP refocus
> (2026-07-17); the grade UI lives on `archive/hdr-lut`, the Zig kernels
> on `archive/zig-kernel`. The decode/fuse/scene(ETTR) work this pivot
> proved survives — ported to Swift — as the foundation of the GIF ISP.
> Current source of truth: `BOREAL-GIF-ISP-WORKFLOW.md`.

**Status:** design / not yet built. Supersedes the 64-frame `.bcube` → GIF mission in `SETUP.md` — and is itself superseded per the banner above.
**Date:** 2026-06-16.

## 0. The pivot in one paragraph

BOREAL stops being a 64×64 statistical-GIF camera and becomes a **maximum-fidelity
RAW-fusion engine**. It captures **4 RAW DNGs on a tripod**, each exposed to give
**one color channel its own expose-to-the-right (ETTR) frame**, then fuses them in
the **scene-linear RAW domain** with a **new Zig + SIMD core** (the only code carried
over from old BOREAL is the **capture logic**; everything downstream is rebuilt — see §6).
Two artifacts come out:

1. **A 32-bit float HDR TIFF** at native sensor resolution, scene-linear, wide-gamut.
2. **A 64³ 32-bit-precision `.cube` LUT** authored for the ProPhoto RGB working space —
   the best LUT Adobe Photoshop is *guaranteed* to load (its Color Lookup layer's own
   max "High" quality is 64 grid points). See §4.

`RGBT` = the per-pixel sample tensor: channels **R, G, B** observed at **T = {f1, f2, f3, f4}**.
The 4 DNGs *are* the T axis. Tripod ⇒ the 4 frames are spatially registered, so there is
**no alignment / optical-flow stage** — every (x,y) maps to the same scene point across T.

---

## 1. Capture spec — analyze → plan → capture → fuse

**The pipeline is four ordered stages. Fusion is strictly post-capture — all 4 DNGs land
first, *then* the RGBT framework runs.** Exposure intelligence lives *before* the shutter,
in a live scene-analysis loop, so the 4 exposures are tuned to the actual scene, not a blind
formula.

```
 A. ANALYZE (live)         B. PLAN              C. CAPTURE             D. FUSE (post)
 stream preview frames  →  solve 4 per-channel  →  fire 4 DNGs serially →  §2 scene-linear
 build raw-accurate        ETTR exposures for      at the planned          RGBT merge → TIFF + LUT
 per-channel histograms    THIS scene              shutter times
```

- **A + B are the "analyse the scene then prepare for capture" stage.** They run continuously
  while the user frames the shot; when the shutter is pressed the plan is already solved, so
  capture fires immediately (critical on a tripod for temporal registration).
- **Home for A + B = the salvaged `Capture/ReadinessCoordinatorBridge.swift`** — a readiness
  coordinator is exactly where "scene analyzed, plan ready, safe to capture" belongs. This is
  why the capture logic is the one thing worth keeping (§6).
- **C is a dumb executor:** it just runs the 4 shutter times B handed it.
- **D never touches exposure decisions** — it consumes the 4 DNGs + the recorded exposure
  ratios and fuses (§2).

### 1.1 The problem this solves (research-grounded)

The three color channels of a Bayer sensor **do not saturate together**:

- The **green channel is the brightest and has the highest SNR** in most light, and
  therefore **clips first**; red and especially blue are dimmer and noisier
  ([Green-channel prior, arXiv:2408.05923](https://arxiv.org/pdf/2408.05923);
  [Green Channel Guiding Denoising, Wiley 2014](https://onlinelibrary.wiley.com/doi/10.1155/2014/979081)).
- A **single** exposure that ETTRs green leaves R and B underexposed — they waste well
  depth and carry more shot noise (signal/noise ~ √signal).
- **ETTR maximizes per-channel SNR** because photons land with most precision in the
  bright end, and the rule is *push each channel's histogram to — but not into — clip*,
  read on a **UniWB** preview so the per-channel histogram reflects raw, not WB-scaled, data
  ([Exposing to the right, Wikipedia](https://en.wikipedia.org/wiki/Exposing_to_the_right);
  [Thom Hogan, What is ETTR](https://www.bythom.com/technique/taking-photos-techniques/what-is-ettr.html);
  [RAW dynamic range extraction, PanoTools](https://wiki.panotools.org/RAW_dynamic_range_extraction)).
- Radiance-linear fusion in the **RAW domain beats ISP-domain HDR** for structure
  preservation and downstream tasks
  ([HDR Merging of RAW Exposure Series, J. Imaging 2025](https://doi.org/10.3390/jimaging11120442)).

### 1.2 Stage A — live scene analysis

While framing, stream the preview (`AVCaptureVideoDataOutput`) and maintain **raw-accurate
per-channel histograms**. To make the histogram reflect raw sensor levels rather than WB-scaled
preview, analyze under **UniWB** (unity WB multipliers) — the standard ETTR technique
([Exposing to the right](https://en.wikipedia.org/wiki/Exposing_to_the_right);
[Thom Hogan](https://www.bythom.com/technique/taking-photos-techniques/what-is-ettr.html)).
Per channel `c`, track the **measured clip point** `clip_c` = the exposure (in stops, relative
to the current preview exposure) at which channel `c`'s bright tail first hits saturation for
*this* scene. Optionally refine with a single quick RAW "probe" frame decoded by `bk_decode_dng`
when framing settles, for true raw histograms.

Output of Stage A (continuously updated, held by the readiness coordinator):
`{ clip_R, clip_G, clip_B, shadow_depth }` for the current scene.

### 1.3 Stage B — the 4-frame exposure plan

Give **each channel a frame where it owns the full well**, plus a shadow-DR frame:

| Frame | Exposed for | Shutter (EV vs green-ETTR) | Purpose |
|------:|-------------|------------------|---------|
| f1 | **Green ETTR** | 0 (shortest) | green just below clip; green saturates first |
| f2 | **Red ETTR**   | +Δ_R          | red pushed to its own measured clip |
| f3 | **Blue ETTR**  | +Δ_B          | blue pushed to its own measured clip |
| f4 | **Shadow floor** | +Δ_S (longest) | deepest exposure for shadow SNR / DR floor |

**Scene-adaptive, with a deterministic seed.** The EV offset for each channel is set so that
channel reaches ~95% of clip *for this scene*:

```
Δ_channel  = clip_green − clip_channel          // from Stage A's MEASURED per-channel clip points
Δ_S        = clip_green + shadow_depth           // push shadows up to the noise-floor target
```

**Seed / fallback** (used before Stage A converges, or in flat light): the white-balance
multipliers, since the channel needing the largest WB gain is the darkest in raw —
`Δ_channel ≈ log2(wb_mult[c]/wb_mult[green])`. E.g. daylight `(R,G,B)=(2.0,1.0,1.5)` ⇒
`Δ_R≈+1.0, Δ_B≈+0.58`. Stage A's measured clips override this seed whenever available, so a
scene with no bright blue won't waste a long blue frame. Per-shutter scale factors can be
jointly refined again at merge time ([all-sky RAW-HDR study](https://doi.org/10.3390/jimaging11120442)).

### 1.4 Stage C — capture mechanics

Tripod, lowest native ISO, electronic shutter, **fixed focus + fixed WB**, serial burst.
Vary **shutter time only** to hit the planned EV offsets (aperture/ISO fixed ⇒ the radiometric
exposure ratios `e_t` are exact and known, which Stage D relies on). Fire all 4 back-to-back
to minimize any scene change between frames.

> Open knob: f4 can instead be a **second green frame** for pure temporal denoise if scenes are
> low-DR. Default = shadow-floor, since "max DR" is the stated goal.

---

## 2. Fusion core — scene-linear, per-channel, Zig + SIMD

For each output pixel `p` and channel `c ∈ {R,G,B}` we hold up to 4 samples `x_c(t)`:

1. **Radiometric align:** divide each frame by its exposure ratio `e_t` → common scene-linear scale.
2. **Saturation-aware + noise-aware weight** per sample:
   - `w → 0` as the sample approaches the per-channel clip point (drop blown samples).
   - `w → 0` in deep noise (low SNR), `w` peaks where the channel is bright-but-unclipped.
   - This is inverse-variance / Kalman fusion — BOREAL's existing combiner family
     (`μ, med, μ_w, tr` in `SessionConfig`); reuse `μ_w` as the default.
3. **Merge:** `out_c(p) = Σ_t w_c(t)·x_c(t)/e_t  /  Σ_t w_c(t)` → 32-bit float, scene-linear.

This is exactly the `@Vector(4, f32)` reduction already in `binomial.zig` (`@reduce(.Add/.Min/.Max)`),
applied per channel at **full resolution** instead of per 64×64 bin. The 4 DNGs map to 4 SIMD
lanes; one NEON FMA chain does the weighted sum.

**Architectural change vs today:** replace the *decimating* bin in `bayer.zig` with a
**full-resolution demosaic** (the merge happens per Bayer channel pre-demosaic, then a
high-quality demosaic — AHD/Menon — runs on the merged mosaic, so demosaic noise sees the
fused, low-noise data).

---

## 3. Output A — HDR TIFF (max fidelity)

| Property | Value | Why |
|---|---|---|
| Bit depth | **32-bit IEEE float** (TIFF `SampleFormat=3`) | full precision, no quantization of the fused signal |
| Resolution | **native demosaiced** (full sensor, e.g. ~8K on 48MP) | "largest size" — no binning |
| Encoding | **scene-linear** | preserves the merged radiance for grading |
| Gamut | wide working space (ProPhoto RGB or linear Rec.2020/ACEScg) | holds the full captured gamut |
| Compression | none, or lossless ZIP w/ float predictor | no lossy step anywhere |
| Profile | **embedded ICC** | Photoshop reads it correctly |

A display-referred **16-bit** companion TIFF (tone-mapped to the working space) is optional
for quick viewing; the float master is the deliverable.

---

## 4. Output B — the best LUT Photoshop can use

Goal: the highest-fidelity LUT that Photoshop is **guaranteed** to load, not the highest-fidelity
LUT in the abstract. Three hard constraints from how Photoshop's Color Lookup actually works set
the ceiling — exceed any of them and the LUT either fails to load, gets silently resampled, or
produces wrong color.

### 4.1 The three Photoshop constraints (research-grounded)

1. **Grid ceiling = 64.** Photoshop's own Color Lookup export tops out at **64 grid points
   ("High")**, so **64³ is the largest grid it natively authors and round-trips**. Color-grading
   tools emit 65³/129³, but those are *not* guaranteed in Photoshop — it may refuse or downsample.
   → **Author 64³.** ([Adobe — export color lookup tables](https://helpx.adobe.com/photoshop/using/export-color-lookup-tables.html);
   [SMPTE — 3D-LUT performance, on why grid drives quality](https://journal.smpte.org/conferences/SMPTE%202018/13/))
2. **Domain is [0,1] and clamps.** A 3D LUT maps `[0,1]→[0,1]`; inputs outside the unit cube are
   clamped, so the LUT is **display-referred, not scene-linear HDR**. It bottles the *rendered look*,
   not the raw radiance. ([3D LUT format / `LUT_3D_SIZE`, DOMAIN_MIN/MAX](https://en.wikipedia.org/wiki/3D_lookup_table);
   [Color management in VFX — LUT](https://jianyucheng.medium.com/color-management-in-vfx-lut-a6928fa20fef))
3. **Applied in the working space.** Photoshop applies the LUT in the **document's working space**,
   so it must be **authored for that exact space**; PS's built-in tables assume sRGB/Adobe RGB and
   are wrong for wide gamut. **ProPhoto RGB** is the broadest standard PS working space ⇒ author there.
   ([Kasson — Adobe LUT-based profiles](https://blog.kasson.com/the-last-word/adobe-perceptual-and-relative-color-mapping-for-lut-based-profiles/);
   [ProPhoto→sRGB LUT pack](https://github.com/Ragnarokkr/ProPhotoRGB-to-sRGB-LUTs))

### 4.2 The BOREAL LUT spec

| Property | Value | Reason |
|---|---|---|
| Format | **`.cube`** (3D) | human-readable, high-precision decimal, most universally loaded; `.look` is legacy SpeedGrade |
| Grid | **64³** | Photoshop's max guaranteed tier (§4.1-1) |
| Precision | **full 32-bit float decimals** written per entry | `.cube` stores text floats — no quantization in the file itself |
| Domain | **ProPhoto RGB, gamma-encoded, [0,1]** (`DOMAIN_MIN 0 0 0` / `DOMAIN_MAX 1 1 1`) | what PS feeds the LUT (§4.1-2,3) |
| Range | display-referred render, ProPhoto RGB [0,1] | the look, viewable |
| Encodes | BOREAL's deterministic tone + color transform derived from the fused HDR | the "look" |

**The LUT is the display-referred bottling of the same transform that renders the float TIFF.**
Because it's for Photoshop **stills**, the domain is a photo working space — **not** Log3G10/Rec.709
(that was the video/R3D path; out of scope). Law to preserve — **★preview ≡ cube**: applying the
64³ LUT to a ProPhoto-encoded `[0,1]` image == BOREAL's own display render of the scene-linear
master, to within 64³-grid interpolation error.

> The 32-bit float HDR TIFF (§3) remains the lossless scene-linear master; the LUT is the
> reproducible display look layered on top. Two deliverables, one transform.

---

## 5. Zig C-ABI (as built)

The owned kernel C ABI (all in `root.zig`, mirrored in `BorealKernel.h`):
```
bk_decode_dng_to_mosaic(bytes, len, *Mosaic)                     // REUSED+extended: DNG/LJPEG → u16 mosaic + WB
bk_analyze_scene(rgb, w, h, *SceneClips)                         // §1.2 Stage A — per-channel ETTR clips (SIMD scan avail.)
bk_solve_ettr_exposures(*SceneClips, wb_mult[3], extra_shadow, *ExposurePlan)  // §1.3 Stage B planner
bk_fuse_mosaics(f0..f3, n, *FuseParams, out_f32)                 // §2 scene-linear RGBT merge (@Vector(8,f32))
bk_demosaic_full(mosaic_f32, w, h, cfa, out_rgb_f32)             // §2 MHC full-res demosaic (SIMD)
bk_build_cube_lut(*LookParams, grid, out_f32) / bk_emit_cube(...)// §4 64³ LUT baker + .cube emit
bk_write_tiff_f32(w,h, pixels, icc, icc_len, buf, buf_len) / bk_tiff_size(...)  // §3 owned HDR TIFF
```
**DNG decode is REUSED, not rebuilt.** `dng.zig` + `ljpeg.zig` (1,554 lines, on-device-verified tiled
multi-component LJPEG Bayer RAW; ProRAW is deliberately NOT captured) already return a full-sensor u16 mosaic — the *decimating bin* was the
64×64-era code, not the decoder, and the decoder is owned hand-written Zig. It was surgically EXTENDED
with **AsShotNeutral** (tag 50728) → green-normalized `wb_r/wb_g/wb_b` on the mosaic, feeding §1.3's WB
prior. (Rewriting a working LJPEG decoder from scratch would be all risk, no design gain.)

---

## 6. Salvage vs rebuild (decided)

**Salvage — carried over:**
- **Capture logic:** `Capture/` (AVFoundation interop: `CaptureService`, `DeviceConfig`,
  `ReadinessCoordinatorBridge`), `Burst/` FSM, `Models/CapturedFrame.swift`, `Services/{Storage,Logging}`.
  → Retarget from a 64-frame serial burst to a **4-frame burst driven by the §1.2 EV-offset solver**.
- **DNG decoder:** `dng.zig` + `ljpeg.zig` — owned, on-device-verified, resolution-agnostic. KEPT and
  extended with AsShotNeutral (§5). NOT rebuilt.

**Rebuild from scratch — everything else (the 64×64-era processing):**
- All of `Processing/` (Bayer bin, BinomialEncoder, SlowFold, Quantization, PaletteEditor, ReRoll,
  look/tone math) → replaced by the §2 full-res fusion + §4 LUT baker.
- All `Container/` formats (`.bvox`, `.bcube`) → replaced by **HDR TIFF** (+ optional stats sidecar, §8.2).
- All `Phase2/`, `UI/LooksLab/*`, `UI/FrameGridView`, `UI/Phase2ProgressRow`, `scripts/categorize-bcube.py`.
- UI → a new minimal flow: **capture 4 → fuse → preview → export TIFF + `.cube`**.

---

## 7. Phase plan (spec-first, per BOREAL convention)

| Phase | Deliverable | Gate |
|------:|-------------|------|
| 0a | ✅ **DONE** (Zig core, branch `feat/rgbt-hdr-pivot`). `scene.zig`: `Histogram`/`percentile`/`roomStops`/`solveClips`/`analyzeFrame` + `SceneClips`. C ABI `bk_analyze_scene` in `root.zig` + `BorealKernel.h`. **12/12 tests green**; symbol in archive; C/Zig struct parity (20 B). Swift `ReadinessCoordinatorBridge` wiring (live preview loop + RAW probe) still TODO. |
| 0b | ✅ planner DONE (`scene.planExposures` / `bk_solve_ettr_exposures`, scene-clips + WB-prior fallback for absent channels; covered by tests). TODO: retarget salvaged burst FSM to fire the 4 planned shutters. |
| 1 | ✅ **DONE** (`demosaic.zig`, owned + strong SIMD). Malvar–He–Cutler high-quality linear demosaic (4 fixed ÷8 kernels); BGGR = RGGB with R/B output swap; SIMD interior (column-vectorized, even/odd `@select`) + scalar clamped border. C ABI `bk_demosaic_full` (cfa 0=RGGB/1=BGGR). **5/5 tests**: flat-field exact (kernels Σ=1), green-site passthrough, **SIMD≡scalar RGGB & BGGR (ragged)**. **Full pipeline validated via C ABI: raw→fuse→demosaic→TIFF, tifffile reads float32 (64,64,3), center math hand-checked.** |
| 2 | ✅ **DONE** (`fuse.zig`, owned + strong SIMD). `fuse()` = channel-agnostic saturation+SNR-weighted merge, `@Vector(8,f32)` over pixels × 4 frames unrolled, scalar remainder. C ABI `bk_fuse_mosaics` (params 32 B, C/Zig parity). **6/6 tests**: denoise identity, radiometric alignment, clip rejection, all-clipped fallback, weight monotonicity, and **SIMD≡scalar bit-parity incl. ragged tail**. Also `scene.scanChannel` SIMD analysis scan (min/max/mean/clip-fraction via `@reduce`). |
| 3 | ✅ **DONE** (`tiff.zig`, owned — zero TIFF libs). Baseline LE TIFF, 32-bit IEEE float (SampleFormat=3), RGB chunky, single uncompressed strip, optional embedded ICC (caller blob), pixel payload = LE memcpy. C ABI `bk_write_tiff_f32` + `bk_tiff_size`. **5/5 tests** (header/tags/round-trip/ICC/size). **Validated end-to-end via C ABI by TWO external readers** — `tifffile` (float32, B=1.5>1.0 HDR preserved) AND libtiff `tiffinfo` ("Sample Format: IEEE floating point"). ICC profile bytes still to be sourced (ProPhoto/linear). |
| 4 | ✅ **DONE** (`lut.zig`, owned + strong SIMD). ASC-CDL look operator (slope/offset/power/sat); `bakeLattice` vectorizes the red axis (`@Vector(8,f32)`, green/blue hoisted) + scalar tail; hand-rolled `.cube` emitter (no std.io). C ABI `bk_build_cube_lut` + `bk_emit_cube` (params 52 B). **8/8 tests**: identity-LUT, sat=0→mono, CDL monotone, [0,1] containment, **SIMD≡scalar (grid 16 & ragged 13)**, emitter header/line-count + buffer-too-small. **Verified end-to-end via C ABI: real 64³ → 262,148-line 7.08 MB .cube.** Look-operator tuning (the actual grade) is the remaining design knob. |
| 5 | New minimal capture→export UI; update `SETUP.md` | `make test` green (Zig + Swift); end-to-end on device |

> Phase 0 reuses salvaged `Capture/`+`Burst/`; Phases 1–5 are greenfield (§6).

---

## 8. Open decisions

1. **f4 role:** shadow-floor (max DR, **default**) vs second-green (max denoise). *Pending.*
2. ~~Working space~~ — **DECIDED: ProPhoto RGB.** It's the broadest standard Photoshop working
   space, and §4.1-3 requires the LUT be authored in the document working space. Linear
   Rec.2020/ACEScg is rejected: not a native PS RGB working space, so the LUT couldn't be applied
   correctly in Photoshop. (The float TIFF master may still carry a wider/linear profile; the *LUT*
   is ProPhoto.)
3. **Stats sidecar:** export a per-pixel statistics file (σ, per-channel SNR, clip maps) alongside
   the TIFF, or drop it? *Pending — default drop, since "everything else rebuilt."*

---

## Sources

- [HDR Merging of RAW Exposure Series for All-Sky Cameras (J. Imaging 2025)](https://doi.org/10.3390/jimaging11120442)
- [Exposing to the right (Wikipedia)](https://en.wikipedia.org/wiki/Exposing_to_the_right)
- [Thom Hogan — What is ETTR](https://www.bythom.com/technique/taking-photos-techniques/what-is-ettr.html)
- [RAW dynamic range extraction (PanoTools)](https://wiki.panotools.org/RAW_dynamic_range_extraction)
- [Image Denoising Using Green Channel Prior (arXiv:2408.05923)](https://arxiv.org/pdf/2408.05923)
- [Green Channel Guiding Denoising on Bayer Image (Wiley 2014)](https://onlinelibrary.wiley.com/doi/10.1155/2014/979081)
- [Adobe — Export color lookup tables](https://helpx.adobe.com/photoshop/using/export-color-lookup-tables.html)
- [SMPTE — 3D-LUT performance in 10/12-bit HDR BT.2100 PQ](https://journal.smpte.org/conferences/SMPTE%202018/13/)
- [Kasson — Adobe perceptual/relative LUT-based profiles](https://blog.kasson.com/the-last-word/adobe-perceptual-and-relative-color-mapping-for-lut-based-profiles/)
- [ProPhoto RGB → sRGB LUT pack (GitHub)](https://github.com/Ragnarokkr/ProPhotoRGB-to-sRGB-LUTs)
</content>
</invoke>
