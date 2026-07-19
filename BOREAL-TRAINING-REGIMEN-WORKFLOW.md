# BOREAL Training Regimen — V1-H under Maximum Signal Compression

Governing principle (THE THEOREM, spec/theorem/MaxSignalLaws.hs, green):
pretraining the ISP to encode DNG data MUST follow maximum signal
compression. Formally:

  RATE    the index stream attains its 8 bits/px capacity iff usage is
          balanced (chi^2 = 0, the binomial ideal)              [T1,T2]
  PRICE   bits lost to imbalance = chi^2 / (2 ln 2) per frame,
          to second order — the chi^2 loss IS the rate penalty     [T3]
  COST    the bell fixes luminance by exact rank projection, so all
          remaining representational freedom — and therefore all
          distortion spending — is CHROMATIC                        [T4]

So the trainer maximizes carried signal per emitted bit — CORRECTED
2026-07-17 (Daniel): the target is NOT chi^2 = 0. Beauty is FIT TO THE
BINOMIAL (V1f): usage fluctuating like a fair draw, chi^2 in the band
around 255 — flat uniformity (0) is sterile, concentration (the device
capture's 20205) is collapse. The rate price of beauty over perfection
is ~184 bits/frame = 0.003 bits/px: beauty is almost free. The bell
governs L; chroma is the cost; the WALK surfaces raw-DNG detail as
dither (DW laws) — de-Bayer done with the GIF frame target in mind:
the 16x16 pixels are OPTIONS, the dither is how 256 options express
more signal than 256 colors.

Standing rules (every phase):
  - G-a runs before anything is believed (nn/v1/goldens_test.py).
  - Judgment is ALWAYS the hard law'd metrics (exact chi^2, homeShare,
    dE after exact bell projection) — soft losses train, laws judge.
  - The classic seed's numbers on the same data are always printed;
    a phase that loses to classic on its own exit metric does not exit.
  - Collapse tripwire: chi^2 at 255*n (the V1d closed form) aborts the
    run loudly.

## R0 — Parity (DONE, standing)
The trainer pipeline is bit-exact vs the goldens (G-a GREEN). Re-runs on
every pipeline.py change, forever.

## R1 — Warm anchor (DONE in smoke)
Supervised: seed -> classic seed, ceiling -> classic ceiling. The house
collapse lesson applied (first smoke collapsed exactly as memory warned;
the anchor fixed it). EXIT: stable descent, hard dE within 2x classic,
no collapse over 1k steps. Current: dE 0.069 vs classic 0.0106 at 60
steps — R1 completes with a longer run.

## R2 — Arrangement (homeShare climbs)
Add the home term: patch p's soft-assignment mass should sit on color p
(L_home = -mean_p log w_p(patch p) over soft assignments), teaching the
(16x16)x(16x16) alignment the warm anchor only hints at. sigma-guided
crops: sample training patches where coarse disagrees with fine.
EXIT: homeShare >= classic (~0.37 on synth) with dE <= 1.5x classic.

## The equilibrium judge (REDEFINITION 2026-07-18, Daniel's call)

Measured fact (held-out synth, this date): raw argmin against ANY
competent palette sits ~13k-29k chi^2 — 50x outside the band; no
palette closes that. The settled territory does: BA4 defections under
a dE budget take clean classic 13.1k -> 469 for +0.0025 dE. THE BAND
IS AN EQUILIBRIUM-LAYER PROPERTY (BA3: E[chi^2]=255 is neutral
DRIFT's signature — an equilibrium statistic, never a raw-argmin
one). The walk (DW laws) is the product-side realization.

The judge, pinned (nn/v1/battle.py `judged_battle`, BA4/BA6-derived):
  - prior = exact argmin index map (ties-lowest), bell-consistent
    conventions (rank projection + induced monotone tone map);
  - defections: each pixel may defect ONCE to one of its 8 nearest
    palette options, only where BA6 pays (delta chi^2 < 0, BA4 closed
    form), only within the dE budget 0.03, cheapest evidence
    sacrifice first, stopping at band-hi 400;
  - chi^2_eq / dE_eq are judged on the settled territory; homeShare
    stays RAW (arrangement is a palette property — defections
    legitimately leave home; the walk's DW3 locality governs the
    product path instead).
Classic baselines are ALWAYS judged through the same equilibrium.

## R3 — Compression (the theorem takes over)
Anneal: raise chi^2 + serve weights, cool tau (0.1 -> 0.02). The rate
term now does the work T3 licenses it to do. Bell penalty held
constant (projection stays exact at eval; G-c watches the projection
delta). ANCHOR STAYS FULL (measured 2026-07-18: anchor decay lost to
full anchor on held-out judgment — the classic seed is load-bearing
supervision, not scaffolding).
EXIT: chi^2_eq INSIDE THE BEAUTY BAND (150-400, V1f) at the
equilibrium layer AND dE_eq <= classic's dE_eq on held-out synth.
(Not chi^2-minimal: sterile flats fail.)

## R4 — Dominate the classic (gate G-b for V1)
Joint fine-tune. EXIT (equilibrium-layer, per the judge above):
STRICT dominance over the classic seed on held-out synthetic:
  (a) dE_eq < classic's dE_eq        (the equilibrium is cheaper)
  (b) |chi^2_eq - 255| < classic's   (closer to the band's center)
  (c) homeShare_raw > classic's      (better arranged, pre-battle)
all three simultaneously, 95% of scenes.

## R5 — Real photons
Report-bundle loader (rawpy decodes the bundled DNGs; report.json's own
binomial/homeShare numbers are the recorded classic baselines). Mix
synth:real annealing 80:20 -> 20:80. Device baselines come from every
capture's binomial readout.
EXIT: R4's dominance reproduced on held-out REAL bundles.

## R6 — The JEPA door (V2 opens)
Patch-LATENT prediction targets (predict cell latents of finer rungs,
not LAB), temporal: next-cycle seed from history (LeJEPA, no EMA
teacher). Interfaces frozen since V1 — nothing rearchitects.

## Data regiment
  synth: side-512 cycles (seed 16^2 / ceiling 256^2 — the exact V1-H
  jump), EV set {1,2,4,8}, Poisson shot noise; scene mix: blobs +
  gradients + hard edges now; dead-leaves + texture generators when the
  research lands (agents' citations to be folded in here).
  real: LAB report bundles, replayed through the exact pipeline.

## Literature grounding (researched + primary-verified 2026-07-17)

LUMINANCE CARRIES THE SIGNAL, CHROMA IS THE COST (T4's grounding):
  - Mullen 1985 (J. Physiol. 359): chromatic CSF is low-pass, acuity
    cutoff ~11-12 cyc/deg; luminance wins above 0.5 cyc/deg. Luminance
    cutoff ~50-60 cyc/deg is Campbell & Robson 1968 (NOT Mullen).
    Net acuity ratio ~4-5:1.
  - Ruderman, Cronin & Chiao 1998 (JOSA A 15:2036) + Buchsbaum &
    Gottschalk 1983: natural scenes decorrelate into one dominant
    achromatic axis + two opponent chromatic axes (the l-alpha-beta
    lineage). (The oft-quoted "~90% variance on luminance" is NOT
    primary-verified - claim direction, not the number.)
  - Codec practice: 4:2:0 = exactly 50% data reduction, all from
    chroma; JPEG T.81 Annex K tables quantize chroma 2-3.5x coarser
    (46/64 chroma coefficients pinned at 99); HEVC-era luma:chroma
    residual bits ~9:1 (patent-background attestation, secondary).

BALANCED USAGE = MAX RATE - WITH THE CRITICAL FRAMING (T1/T2/T3):
  - Cover & Thomas 2006 Thm 2.6.4: H(X) <= log|X|, equality IFF
    uniform. THE citation for T2.
  - C&T Problem 11.2: chi^2 is twice the first Taylor term of
    D(P||Q) => KL ~ chi^2/(2n ln2) in bits. THE citation for T3
    (bit-form is a one-line textbook derivation, not a quoted eq).
  - CORRECTION (do not misattribute): balanced usage is the
    optimality condition for a FIXED-RATE size-K codebook WITH NO
    ENTROPY CODER - which is EXACTLY our regime, BY CONSTRUCTION:
    the GIF wire's fixed-9-bit LZW (W laws) deliberately does not
    entropy-code, so nothing downstream absorbs imbalance. Do NOT
    cite entropy-constrained VQ (Chou-Lookabaugh-Gray 1989) for
    uniform usage - ECVQ's optimum has NON-uniform probabilities
    absorbed by variable-length codes; fixed-rate MSE-optimal VQ
    equalizes distortion, not probability. Our non-compressing wire
    is what MAKES chi^2 -> 0 the right objective.

CODEBOOK-USAGE ENTROPY AS A LOSS (the R3 term's precedent):
  - wav2vec 2.0 (Baevski 2020): diversity loss = negative entropy of
    batch-averaged codeword softmax (alpha = 0.1) - our L_chi2's
    closest ancestor.
  - MAGVIT-v2 / LFQ (Yu 2023): E[H(q)] - H(E[q]) - sharpen
    per-sample, uniformize average usage; enabled a 2^18 codebook.
  - Our chi^2 term = the SECOND-ORDER SURROGATE of these usage-
    entropy penalties (via the T3 bridge) - cheaper, exact-checkable.
  - VQ collapse remedies (EMA updates VQ-VAE 2017, Jukebox restarts,
    CVQ-VAE online clustering, FSQ) parallel our warm anchor + tripwire.

COMPRESSION AS PRETRAINING (the theorem's banner):
  - Rissanen 1978 (MDL); Hinton & van Camp / Hinton & Zemel 1993;
    Linsker 1988 infomax; Bell & Sejnowski 1995.
  - Deletang 2023 "Language Modeling Is Compression" (ICLR 24);
    Huang 2024 "Compression Represents Intelligence Linearly"
    (Pearson ~ -0.94 across 31 LLMs); Sutskever 2023 (talk).
