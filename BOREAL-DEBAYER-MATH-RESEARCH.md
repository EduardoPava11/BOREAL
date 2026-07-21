# The Mathematics of De-Bayering — verified research survey

> Deep-research sweep 2026-07-19: 5 search angles, 24 sources fetched,
> 119 claims extracted, top 25 adversarially verified (3 independent
> refuters per claim; 2/3 refutes kill). 23 confirmed, 2 refuted.
> Confidence labels below reflect that process. Sections the
> verification did NOT cover (AHD, residual interpolation, joint
> demosaic-denoise, learned) are marked OPEN — do not cite them from
> this doc.
>
> Why this doc exists: BOREAL demosaics by EXACT per-channel box means
> at every rung (16…256 from the 2048² mosaic). This survey pins what
> that preserves and discards relative to the state of the art, in the
> literature's own mathematics. Companion ledger:
> BOREAL-SIGNAL-LADDER-WORKFLOW.md (SNR side); this doc is the
> frequency-domain side.

## 1. The sampling model, and why demosaicing is ill-posed  [3-0]

The Bayer CFA measures green on a **quincunx lattice** (half the
pixels) and red/blue on rectangular lattices (a quarter each) — green
oversampled because HVS luminance sensitivity peaks at medium
wavelengths (Gunturk et al., IEEE SP Magazine survey). One channel per
pixel ⇒ two of three values missing everywhere ⇒ reconstruction is
ill-posed without image priors. The channel asymmetry shapes the
per-channel Nyquist regions: green's is the diamond |f₁|+|f₂| ≤ ½,
red/blue's the square of half side.

Source: https://www.ece.lsu.edu/gunturk/Topics/Demosaicking-1.pdf

## 2. THE core theorem: the mosaic is a frequency multiplex  [3-0 ×5, 2-0 ×1]

Exact algebraic identity (Alleysson/Süsstrunk/Hérault TIP 2005; Dubois
SPL 2005; Leung/Jeon/Dubois "LSLCD" TIP 2011) — for Bayer phase with G
on the even diagonal:

    f_CFA[n1,n2] = f_L[n]  +  f_C1[n]·(−1)^(n1+n2)  +  f_C2[n]·((−1)^n1 − (−1)^n2)

    f_L  = ¼ f_R + ½ f_G + ¼ f_B     baseband LUMA, full resolution, unmodulated
    f_C1 = −¼ f_R + ½ f_G − ¼ f_B    chroma-1, modulated to (½, ½) c/px (corner)
    f_C2 = ¼ (f_B − f_R)             chroma-2, TWO opposite-sign copies at (½,0) and (0,½)

Equivalently the CFA masks are cosine modulations
m_R = (1+cosπx)(1+cosπy)/4, m_G = (1−cosπx·cosπy)/2,
m_B = (1−cosπx)(1−cosπy)/4, whose transforms are Dirac impulses: ALL
of the mosaic's energy lives in nine spectral islands — luma at the
center, chroma at the borders and corners.

So a raw Bayer frame is not "an image with holes" — it is a
**perfectly ordinary multiplexed transmission**: one full-resolution
luma channel plus two opponent-chroma channels AM-modulated onto
spatial carriers. Demosaicing = demodulation.

Caveats (verifier-confirmed): "luma at every pixel" means unmodulated,
not independently observable; luma/chroma spectra overlap for
high-frequency saturated content, so exact separation still needs
image assumptions (this is where the ill-posedness reappears); C2 sign
convention depends on Bayer phase.

Sources: https://hal.science/hal-00204920/file/AlleyssonetalTIP05.pdf ·
https://www.site.uottawa.ca/~edubois/lslcd/article/TIP-06195-2010.R1_2col.pdf ·
https://www.researchgate.net/publication/3343363

## 3. Demosaicing as demultiplexing; optimal linear filters  [3-0 ×5]

Because the bands are (mostly) disjoint, pure linear frequency-
selective filtering demosaics well:

- **Alleysson pipeline** (TIP 2005 §III-D): low-pass estimate luma
  (~11×11 support, ~69 ops/px), chroma = the high-pass residual,
  demultiplex by multiplying with the carriers, bilinearly interpolate
  the subsampled opponent chroma (HVS chromatic acuity is low), sum.
- **Dubois adaptive demultiplexing**: the two C2 copies suffer
  ASYMMETRIC crosstalk with luma (horizontal luma detail corrupts the
  (½,0) copy, vertical the (0,½) copy). Combine them with local weight
  **w = e_Y/(e_X + e_Y)** from Gaussian-bandpass energies near
  (0.375, 0) and (0, 0.375) c/px — favor the LESS corrupted copy.
  (One claim with the inverted formula w = e_X/(e_X+e_Y) was REFUTED
  1-2; the form above is the confirmed one.)
- **LSLCD** (TIP 2011): design the demultiplexing filters by
  closed-form least squares (normal equations) over a natural-image
  corpus; 11×11 LS filters match hand-windowed 21×21 designs; 5×5 and
  9×3/3×9 variants are near-optimal. "Adaptive" throughout means
  space-varying LINEAR filtering.

Sources: Alleysson PDF above · https://www.site.uottawa.ca/~edubois/CFA/ ·
LSLCD PDF above

## 4. Artifact mathematics: four classes, each a bandwidth error  [3-0 ×3]

In the multiplex picture every classical artifact is **spectral
crosstalk between specific bands** (Alleysson et al. — "four kinds of
reconstruction artifacts, two more than described by Töpfer et al."):

| artifact | mechanism |
|---|---|
| blurring | luma low-pass too NARROW (discards real luma) |
| grid effect | chroma carriers leak INTO the luma estimate |
| false color | high-frequency luma leaks INTO a too-wide chroma band |
| watercolor / bleeding | chroma band too NARROW |

Bilinear demosaicing is poor precisely because each channel is
interpolated independently — no demultiplexing at all — so carriers
alias freely both ways; the channel misalignment near edges IS the
zipper/false-color mechanism (Getreuer, IPOL 2011, verbatim).
Zipper/false color can also arise from wrong directional choices and
genuine sub-Nyquist aliasing even in good methods.

Sources: Alleysson PDF · https://www.ipol.im/pub/art/2011/g_mhcd/article.pdf

## 5. Hamilton-Adams: gradient correction = alias cancellation  [3-0 ×3, 2-1]

The 1997 Kodak method (US 5,652,621). Green at a red site, horizontal:

    Ĝ = (G_left + G_right)/2 + (2R₀ − R_left₂ − R_right₂)/4

i.e. directional green mean **plus ¼ of the co-sited chroma channel's
second difference** along the same axis; direction chosen by
classifiers |chroma Laplacian| + 2·|green gradient| (H vs V vs
isotropic). Missing R/B = mean of two nearest same-color samples plus
half the second difference of the reconstructed green.

The mechanism is exact in 1-D z-transform (Gunturk survey §2.1.4):

    Ĝ(z) = G_s(z)·H1(z) + R_s(z)·H2(z),   H1 = [½ 1 ½],  H2 = [−¼ 0 ½ 0 −¼]
    |H1(ω)| = 1 + cos ω,   |H2(ω)| = sin²ω... → aliasing terms
    ½G(−z)H1(z) − ½R(−z)H2(z) CANCEL where |H1| = |H2| (above π/2)

The red Laplacian literally reconstructs green's high frequencies from
red samples — valid exactly insofar as R and G share high-frequency
content (the spectral-correlation prior). Caveats: the quoted patent
embodiment has a third bias-corrected classifier term often omitted in
citations; the 2× gradient weight is specific to US 5,652,621 (sibling
US 5,629,734 uses unit weights).

Sources: https://patents.google.com/patent/US5652621A/en · Gunturk survey

## 6. Malvar-He-Cutler: support-constrained linear MMSE  [3-0 ×5]

MHC (ICASSP 2004) = bilinear + gain-weighted 5-point Laplacian
cross-channel correction (Pei-Tam lineage), e.g. green at a red site:

    Ĝ = bilinear₄(G) + α·∇²R,   with α = ½, β = ⅝, γ = ¾

Gains chosen by MSE minimization over the Kodak suite, then rounded to
dyadic rationals (bit-shift friendly). The resulting eight fixed 5×5
filters are **within 5% MSE of the optimal 5×5 Wiener filters** — MHC
is, to good approximation, the support-constrained linear-MMSE
demosaicker. Purely linear (periodically shift-variant over the four
Bayer phases), +5.68 dB mean over bilinear on Kodak (protocol-
dependent; ~4-5 dB under other protocols).

REFUTED 0-3: "outperforms most nonlinear algorithms" — it does not;
MHC is a strong linear BASELINE, below good adaptive/nonlinear methods.

Sources: IPOL article above (reference implementation) ·
https://www.microsoft.com/en-us/research/publication/high-quality-linear-interpolation-for-demosaicing-of-bayer-patterned-color-images/

## 7. What BOREAL's box-mean demosaic is, in this framework  [derived; medium]

(Synthesis grounded in the confirmed identities — the verifier for the
Dubois spectrum claim explicitly confirmed per-channel box averaging
"falls under this LSI filter analysis"; the comparative magnitudes
below were NOT measured by any surviving source.)

Per-channel exact box means over a k×k Bayer cell = a linear
shift-variant **demodulator whose analysis filter is the 2-D boxcar**,
frequency response sinc(k f₁)·sinc(k f₂) per axis (channel sublattices
make the effective supports k/2 per channel for R/B, quincunx-k²/2 for
G).

- **(a)** The boxcar's slow sinc rolloff + sidelobes only weakly
  reject the chroma carriers at ½ c/px and pass luma above the cell
  Nyquist as aliasing: box demosaic is neither an ideal luma low-pass
  nor an ideal chroma band-reject — it mixes the nine islands
  according to the sinc sampled at the carrier offsets.
- **(b) Coarse rungs (16-64 from 2048²)**: carriers fall many
  sidelobes out; chroma leakage → small; per-channel means approach
  unbiased band-limited R/G/B with k²/4-to-k²/2-fold noise averaging.
  Excellent SNR, and structurally IMMUNE to directional-interpolation
  zipper/false color (there is no directional guess to get wrong).
  This is the regime where BOREAL's design is near-optimal — and it
  agrees with the SIGNAL-LADDER ledger's +18-42 dB binning entries.
- **(c) Fine rungs (256 from 2048² = 8×8 cells, 4×4 samples per R/B)**:
  what box means DISCARD is precisely the high-frequency baseband luma
  that demultiplexing (or HA/MHC cross-channel Laplacians) recovers
  from the full mosaic before downsampling. Box means never form the
  luma/chroma split, so they cannot exploit inter-channel correlation
  — the one prior every state-of-the-art method is built on.
- **(d)** Demosaic-then-downsample with a good demultiplexer retains
  more luma detail per output pixel with proper anti-aliasing, at the
  cost of baking the demosaicker's own crosstalk artifacts in before
  averaging.

Design reading for BOREAL: the ladder's coarse rungs are on solid
ground; the 256 ceiling is the contested regime, and the contest is
specifically over baseband luma above the cell Nyquist. If the ceiling
ever needs more detail, the literature's answer is not a fancier
interpolant — it is ONE luma/chroma demultiplexing step (even LSLCD's
5×5 least-squares filters) before the final reduction, or an
HA-style co-sited Laplacian correction added to the cell means.

## 8. OPEN — not covered by verified claims

No claims on these survived the 3-vote panel (mostly source-access
attrition, not refutation); treat as unresearched here:

- AHD (Hirakawa-Parks homogeneity-directed): direction chosen by
  CIELAB metric-neighborhood homogeneity maps. (Paper fetched:
  photo-lovers.org/pdf/hirakawa05mndemosaictip.pdf — unverified.)
- Residual interpolation (Kiku et al. GBTF/RI/MLRI): interpolate in
  the residual domain after a guided-filter tentative estimate.
- Joint demosaic-denoise: y = Mx + n observation models (M singular
  diagonal binary), MAP/variational objectives, and the noise-alias
  interaction. (Jin & Hirakawa's EURASIP 2012 binning analysis — the
  same paper in the SIGNAL-LADDER sweep — was fetched here too:
  binned superpixels form a Bayer CFA again on a distorted lattice,
  binning = filter+downsample with quantified alias terms; extracted
  but not among the verified 25.)
- Learned demosaicing (Gharbi et al. SIGGRAPH Asia 2016 onward):
  CNN as learned demultiplexer, trained on hard-mined mosaics.

## E1 — the crossover experiment (EXECUTED 2026-07-19)

Open question 2 answered by measurement. Harness:
`scripts/e1-crossover/main.swift` (run instructions in its header;
compiles against the app's own kernels — the product path is literally
msEncode/msDecode). Reference = Hamilton-Adams full-res demosaic
(§5's verified math: unit-weight classifiers, alias-cancelling
Laplacian; chroma by color-difference interpolation) → exact k×k box
downsample → the same camToPP→OKLab→Q16 tail. ΔE = Euclidean OKLab
(JND ≈ 0.01-0.02); L-RMS in Q16 units.

Real device scene (fused 4-DNG cycle, 2026-07-19 capture, post-NT-fix):

    rung |  mean ΔE |  p95 ΔE |  max ΔE | L-RMS(Q16)
      16 |  0.00035 | 0.00156 | 0.00610 |    8.5
      32 |  0.00043 | 0.00182 | 0.00793 |   11.3
      64 |  0.00057 | 0.00248 | 0.00838 |   15.6
     128 |  0.00078 | 0.00330 | 0.02715 |   22.5
     256 |  0.00118 | 0.00447 | 0.07649 |   37.1

Gray zone plate (every frequency to mosaic Nyquist — worst case):

    rung |  mean ΔE |  p95 ΔE |  max ΔE | L-RMS(Q16)
      16 |  0.00005 | 0.00017 | 0.00228 |    3.5
      32 |  0.00114 | 0.00453 | 0.02800 |   60.2
      64 |  0.00180 | 0.00697 | 0.13141 |  120.6
     128 |  0.00637 | 0.01914 | 1.96161 |  419.1
     256 |  0.02073 | 0.05389 | 2.02526 |  896.3

**Verdict:**
- **Real scenes: the box-mean ladder is vindicated at every rung.**
  Mean ΔE at the 256 ceiling is 0.0012 — an order of magnitude below
  JND; even p95 (0.0045) is invisible. The ceiling is NOT
  luma-detail-limited on typical content. This is the frequency-domain
  twin of the SIGNAL-LADDER ledger's "demosaic-at-scale = 0 dB" entry.
- **Worst-case full-spectrum content diverges at 128/256 exactly as
  the multiplex theory predicts**: mean ΔE 0.021 ≈ JND, p95 0.054
  visible, max 2.0. Visually (e1_zone PNGs): BOTH paths alias after
  8× decimation, but the box path grows EXTRA false-color moiré at
  the chroma carrier sites — edge midpoints (½,0)/(0,½) and corners
  (½,½) — where gray luma demodulates into chroma through the boxcar
  sidelobes; the HA reference confines damage to genuine sub-Nyquist
  corners. The failure signature is FALSE COLOR on fine gray detail,
  not lost luma sharpness.
- **Decision: keep box means as the product demosaic** (iterative
  discipline; device-verified; near-optimal on real scenes with free
  k²-fold noise averaging and structural zipper immunity). The
  HA-style ceiling correction is now a SPEC'D OPTION, not a need —
  justified only if real bundles show fine-gray-texture scenes
  (fabric, screens, print) with the carrier-site false-color
  signature. E1 is the standing judge: rerun it on any suspect
  cycle's 4 DNGs.

**E1-extension (2026-07-19, same session): the ceiling question under
the 4-frame product.** With the burst-of-4 direction (one cycle = the
GIF), the ceiling should carry as much of the captured 2048² as the
bins honestly can. Measured at k = 4 and k = 2 (`e1x`, same harness
semantics; box path generalized via tbChannelMeans, asserted
bit-identical to the product path at 256):

    rung |  k | mean ΔE (real) | p95 (real) | mean ΔE (zone) 
     256 |  8 |    0.00118     |  0.00447   |    0.02073
     512 |  4 |    0.00203     |  0.00657   |    0.06287
    1024 |  2 |    0.00422     |  0.01187   |    0.18513

**Verdict: 512 in, 1024 out.** k=4 stays sub-JND on real scenes and
keeps a 2×2 sample grid per chroma channel (the last even cell with
real averaging); its new fine-scale chroma risk sits ABOVE the Mullen
chromatic-acuity cutoff at phone distance while the luma gain is
visible (256² is ~4.6× upscaled on screen). k=2 touches JND at p95 on
a real scene and abandons averaging (1 R, 1 B per bin — raw
pick-the-colors).

**LADDER EXTENDED (landed 2026-07-19):** rungs = 16…512;
**renderRung 512** (the GIF frame) vs **ceilingRung 256** (the MODEL
ceiling — gridSide², the H2/N0/bell domain, unchanged as a stack
prefix so nothing the nets consume moves). CS2 revised to the
two-ceiling shape; geometry.json carries renderRung; msDirect
(generalized fast path) renders {seed, 256, 512} in 3 mosaic passes
(3.9 ms/frame Mac); full gate + build green.

**σ gets a theory (applied):** BOREAL's σ head (per-cell summed
|residual| across scales) is, in this framework, a direct measure of
spectral energy near the cell Nyquist — exactly where box aliasing
lives. High-σ cells are the cells where the box/demultiplex gap
concentrates (E1's max-ΔE cells). So σ is the correct GATE for any
future ceiling correction (correct only high-σ cells), and the correct
prior for the dither budget it already drives — one number, two jobs,
now with a frequency-domain justification.

## Open questions (carried)

1. Exact AHD / residual-interpolation objectives vs box means at
   BOREAL's rung scales.
2. ~~The crossover question~~ — ANSWERED by E1 above: real scenes
   fine at all rungs; worst-case gray detail shows carrier-site false
   color at 128/256.
3. How joint demosaic-denoise changes the noise-alias tradeoff vs box
   averaging's free k²-fold denoising.
4. Does Dubois's two-copy C2 asymmetry have a cheap box-scale
   analogue — local directional energy correcting residual chroma
   leakage in small cells without a full filter bank? (If the ceiling
   correction is ever built, σ-gated per-cell directional energy is
   the natural first design — see σ note above.)

## Refuted during verification

- w = e_X/(e_X+e_Y) as Dubois's adaptive weight (1-2) — correct form
  is w = e_Y/(e_X+e_Y).
- "MHC outperforms most nonlinear algorithms" (0-3).
