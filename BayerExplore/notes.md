# BayerExplore — block-size math for 64×64 frames

Goal: pick a Bayer macropixel size `B` (in mosaic pixels) so that the active
capture area downsamples cleanly into a **64×64** output frame.
Per output pixel, we want one whole `B×B` block of mosaic samples.

## Inputs (from BOREAL/Capture + Processing)

- Sensor readout: **4032 × 3024** RGGB Bayer (12 MP binned, iPhone 17 Pro).
- DNG crop tag written by `DNGCropTagEditor`:
  - `DefaultCropOrigin` = (504, 0)
  - `DefaultCropSize`   = **3024 × 3024** (centered portrait square)
  - `ActiveArea`        = (0, 504, 3024, 3528)
- Bayer phase at crop origin is preserved because origin x=504 is even
  (and y=0 is even), so the cropped 3024² square is still RGGB-aligned.

## Constraint: "1 Bayer block → 1 output pixel"

A Bayer unit cell is **2×2** (R, Gr, Gb, B). To guarantee every output
pixel covers a whole number of complete unit cells (so each macropixel
carries balanced R/G/B information), `B` must be **even**.

Per output pixel we want:

    B × B  mosaic samples   =   (B/2)²  complete RGGB unit cells

So for 64×64 output covering a square of side `S`:

    S = 64 · B          (with B even)

## Candidate `B` values vs the 3024² active square

| B (block side) | 64·B  | fits in 3024? | slack px / side | RGGB cells / pixel |
|----------------|-------|---------------|-----------------|--------------------|
| 44             | 2816  | yes           | 104             | 22² = 484          |
| **46**         | **2944** | **yes**    | **40**          | **23² = 529**      |
| 47 (odd)       | 3008  | yes           | 8               | breaks Bayer phase |
| 48             | 3072  | **no**        | —               | 24² = 576          |

`3024 / 64 = 47.25` → no integer block fully tiles 3024.
`3024 / 64 = 47.25` is also not even, so the existing crop is **not**
Bayer-aligned for a 64×64 grid. We have to either:

  **(A)** shrink the analysis square to **2944 × 2944** (B = 46), recentered
        inside the 3024² crop with a 40-px margin on each side, **or**

  **(B)** accept B = 47 (odd) and let the Bayer phase rotate inside each
        macropixel — workable if the binning kernel tracks which subpixel
        each sample falls on, but loses the "every output pixel sees a
        whole RGGB tile" property.

### Recommended: option (A), B = 46

- Output frame: 64 × 64
- Source tile per output pixel: **46 × 46 mosaic px = 23 × 23 RGGB cells**
- Active analysis square: **2944 × 2944** (inset 40 px from the 3024²
  DNG crop on all four sides; still centered on the original sensor)
- Bayer phase inside every macropixel is identical → simple per-channel
  averaging (or any Bayer-aware kernel) works without phase bookkeeping.

In mosaic coordinates of the **full 4032×3024 sensor**, the analysis
square's top-left is:

    x0 = 504 + 40 = 544        (even → R row/col start preserved)
    y0 =   0 + 40 =  40        (even → R row/col start preserved)
    x1 = 544 + 2944 = 3488
    y1 =  40 + 2944 = 2984

Both origins are even, so RGGB phase is preserved.

## Per-channel sample budget per output pixel (B = 46)

Each 46×46 macropixel contains 23×23 = 529 RGGB unit cells, i.e.:

  - 529 R   samples
  - 1058 G  samples (Gr + Gb)
  - 529 B   samples
  - 2116 total photodetectors averaged into one output pixel

That's a √2116 ≈ 46× SNR boost vs. a single sample, before any
debayering / WB / tone work.

## If we ever want a different output size

For an output of `N × N` from a square crop of side `S`, the smallest
even `B` that tiles cleanly satisfies:

    S' = N · B,   B even,   S' ≤ S

Useful neighbors of 64:

| N   | from 3024² crop | best even B | S'   | slack / side |
|-----|-----------------|-------------|------|--------------|
| 32  | 3024 / 32 = 94.5 | 94         | 3008 | 8            |
| 48  | 3024 / 48 = 63.0 | 62         | 2976 | 24           |
| 64  | 3024 / 64 = 47.25| 46         | 2944 | 40           |
| 84  | 3024 / 84 = 36.0 | 36         | 3024 | 0 ✓          |
| 126 | 3024 /126 = 24.0 | 24         | 3024 | 0 ✓          |
| 168 | 3024 /168 = 18.0 | 18         | 3024 | 0 ✓          |

Note: **84, 126, 168 tile 3024 perfectly** with an even Bayer block.
64 does not. If frame size is negotiable later, those numbers come for
free with the existing crop tag.
