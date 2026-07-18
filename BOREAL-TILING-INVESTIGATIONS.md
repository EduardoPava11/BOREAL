# BOREAL Tiling Investigations — de-Bayer is a tiling problem

Status 2026-07-17: OPEN. The V1-Cube workflow is NOT SETTLED until these
resolve — every structure in the stack is a tiling someone chose, and
tilings have alternatives, seams, aliasing, and symmetries we have been
treating as given:

  CFA quad tiling of Z^2 (the problem itself) . phase cosets (N laws) .
  k x k cfaBin cells per rung . the 2x2 nearest-up tiles . V1-H's 16x16
  patches . the palette grid . the cube's 16^3 sub-cubes . cycle tiling
  of the burst in time.

## I0 — First measurements (DONE, on the real device bundle)

Instrument: residual-stack forensics on report.json (parity classes
within up-tiles; luma/chroma energy split per level).

FINDING A — up-tile anisotropy: left-column parity classes (px = 0)
carry systematically more |residual| than right at EVERY level; up to
~85% relative spread in chroma at level 32, decaying to ~12-16% at 256.
The nearest-up tiling is not isotropic in practice. Cause unknown:
scene structure vs CFA-phase interplay vs readout vs our cell walk.

FINDING B — chroma aliasing made visible: chroma's share of residual
energy RISES with scale: 36.5% (level 32) -> 55.0% (level 256). Fine
inter-scale disagreement is chroma-dominated — the Bayer tiling's
modulated-chroma aliasing (Alleysson) surviving our box means. This is
the NN's biggest quantified win condition, and it is a TILING artifact.

## I1 — Anisotropy attribution (extends I0-A)

Q: is the up-tile anisotropy systematic (tiling/CFA) or scene?
Method: (a) more bundles, varied scenes/orientations (rotate the phone
90 deg — a scene cause rotates with it, a tiling cause does not);
(b) synthetic isotropic scenes through the exact pipeline (the trainer
generator — zero-cost control); (c) BGGR vs RGGB comparison.
Decides: whether the up-arrow needs an anti-seam form (I5) and whether
K3's frame-hold analog inherits a bias.

## I2 — Chroma demultiplexing at fine scales (extends I0-B)

Q: how much of the 55% fine-level chroma residual is recoverable
aliasing vs true chroma detail?
Method: zone-plate + colored-edge synthetic scenes; compare cfaBin
rungs against a frequency-domain demultiplexer (Dubois-style) at the
finest rungs; measure aliasing energy per lattice frequency band.
Decides: the NN's fine-scale head design (does it need explicit
phase-frequency features?) and MS4b's envelope realism.

## I3 — The green quincunx

Q: green samples a quincunx lattice — do square rungs waste it?
Method: implement a quincunx-aware G-plane reduction (diamond tiles)
as a reference; compare G-channel rung fidelity vs square cfaBin at
equal coefficient budget, on bundles + synthetics.
Decides: whether the ladder stays square-only or G gets a lattice-true
path (a REAL design fork for the cube; the (16^k)^2 squaring law works
for either — the tiling shape is the free variable).

## I4 — Symmetry & equivariance

Q: which tiling symmetries should the model respect by construction?
The CFA breaks translation to 2Z^2, has reflections that swap Gr/Gb,
and RGGB<->BGGR is a coset shift (tonight's device is BGGR).
Method: enumerate the phase-permutation group; test the classic path's
equivariance empirically (transform mosaic, compare outputs); specify
weight-tying for V1 (shift-by-2, Gr/Gb swap) as laws.
Decides: V1 weight constraints; whether one net truly serves both CFA
phases (currently metadata-only — verify it is enough).

## I5 — Seams (patches, cells, cycles)

Q: where do tiled estimators leave seams, and at what energy?
Method: seam-vs-interior residual statistics at every tiling boundary
(16x16 patch grid for V1-H, k x k cells per rung, cycle boundaries in
the burst GIF's index churn); overlap/lapped-window prototypes (Malvar
lineage) if seams are hot.
Decides: whether V1-H's patch predictor needs overlap context beyond
3x3 latent mixing; whether the cube's temporal tiles (cycles) seam.

## I6 — Tiling in time

Q: is the cycle tiling of the burst (16 x 4, and the x4 frame-hold)
the right temporal tiling, and what do bursts buy de-Bayering?
Method: multi-frame literature (handheld SR: Bayer accumulation
without demosaicing — frames as jittered lattice samples!); measure
inter-frame sub-pixel shift statistics in bundles (handheld jitter =
free lattice diversity); the C0 log's cadence data.
Decides: whether temporal generation (C3) should also ALIGN (jitter
as extra CFA samples — potentially a bigger de-Bayer win than any
spatial cleverness), and the K-laws' temporal form.

## I7 — The dither tiling

Q: L3's displacement dither is a tiling coloring — what structure
(blue-noise tiles? STBN lineage) should govern it at the cube scale?
Method: after I5; house 6teen3 STBN precedent; defer until V1 lands.

## I8 — Literature synthesis (agent in flight)

Lattice/polyphase demosaicking (Alleysson, Dubois, Gunturk), CFA
design as frequency packing (Hirakawa & Wolfe), quincunx pyramids,
group-equivariant mosaicking, lapped transforms, multi-frame Bayer SR.
Output: the design levers, folded here with citations; each mapped to
I1-I7.

## What is frozen vs open while investigating

Frozen (laws, unaffected): phases-as-cosets (N), exact color path
(CQ), the wire (W), the statistics (V/H/T), the regimen's judging.
OPEN (the investigations' verdicts): square-vs-quincunx reductions,
up-arrow form, V1 weight symmetry, patch overlap, temporal alignment,
and therefore the FINAL shape of the K-laws and the cube workflow.
