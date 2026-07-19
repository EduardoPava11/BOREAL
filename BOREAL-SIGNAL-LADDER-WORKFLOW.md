# BOREAL Signal Ladder — the maximum-signal path DNG -> GIF, and the V1/V2/V3 runtime ladder

Date: 2026-07-19. Two questions, answered together (Daniel's ask):
(1) what is the maximum-signal/noise sequence of steps from a 4-DNG
cycle to the GIF, with the SNR arithmetic of every stage cited; and
(2) how the SAME trained model runs at three engine tiers — V1
Swift/Accelerate, V2 Metal, V3 Core AI — and which pipeline stages
belong to which tier. Sources: two primary-verified research sweeps
(EMVA 1288, Hasinoff CVPR'10 + HDR+ TOG'16, Jin-Hirakawa EURASIP'12,
Alleysson CIC'02, Burns-Berns CIC6'98; Schuchman'64,
Lipshitz-Wannamaker-Vanderkooy JAES'92, Anastassiou'89,
Zador'82/Gersho'79, Mullen'85, Wolfe EGSR'22, Welch'84). Agent
reports carry the full equations; the load-bearing numbers are here.

---

## Part A — the signal ledger (where every dB comes from and goes)

### Capture half (photons -> linear latent)

| # | stage | law of the stage | BOREAL delta |
|---|-------|------------------|--------------|
| C0 | photon arrival | SNR = sqrt(photons) (Poisson; EMVA 1288) | baseline; small-pixel ceiling ~36-38 dB at white |
| C1 | read/dark/PRNU | sigma_y^2 = K^2(sigma_d^2+sigma_e^2)+sigma_q^2 | shot-limited except deep shadows |
| C2 | 12-bit ADC | sigma_q = q/sqrt(12) = 0.289 DN | ~0 dB (negligible vs read noise); device-verified black 528/white 4095 |
| C3 | 4-frame EV fuse [1,3.7,15,62] | inverse-variance weights; SNR^2 sums per frame (Hasinoff'10 eq 4-7) | shadows +19.1 dB; highlights +0 dB but +5.95 STOPS of range |
| C4 | mosaic-domain 8x8 bin -> 256^2 | SNR + 10log10(M), M=64 (Jin-Hirakawa eq 6) — VALID ONLY BEFORE DEMOSAIC (noise still white) | +18.1 dB |
| C5 | demosaic AT the rung scale | luma baseband + chroma on carriers (Alleysson) | +0 dB info; correlates noise; aliasing floor at edges only |
| C6 | CCM to working space | Sigma_out = M Sigma M^T (Burns-Berns) | -3 to -6 dB on CHROMA channels — the ledger's one big loss; MUST run after binning |
| C7 | 16^2 seed (128x bin) | +10log10(16384) | +42.1 dB — hits the PRNU ceiling (~46 dB @0.5%) |

Net (shadows, photons -> 256^2 latent): **+31 to +34 dB over the base
frame's pixel**. THE ORDER IS THE THEOREM: fuse -> bin (mosaic
domain) -> demosaic-at-scale -> CCM. Every permutation loses dB —
demosaic-first correlates the noise so binning collects < sqrt(M);
CCM-first pays its chroma amplification at full-resolution SNR. This
is the information-theoretic PROOF of "demosaic at every scale" and
of msEncode's existing per-cell-mean -> matrix -> OKLab order. The
pipeline we shipped is the maximum-signal order.

### Render half (linear latent -> wire)

| # | stage | law of the stage | BOREAL delta |
|---|-------|------------------|--------------|
| R1 | perceptual map (OKLab) | Jacobian noise propagation; quantize in a uniform space | ~0; makes Q16 error perceptually even |
| R2 | 256-color palette VQ | D ~ G3 sigma^2 K^(-2/3) (Zador/Gersho); K=256 -> sigma^2/40 | THE dominant, irreducible loss; 512 colors would buy only 2 dB |
| R3 | dither walk (spatial) | power-neutral noise SHAPING: +3 to +4.8 dB noise power (RPDF/TPDF), error pushed above the CSF (Schuchman; LWV'92; Anastassiou = sigma-delta in 2-D) | banding -> invisible-ish noise |
| R4 | temporal dither (64 frames) | eye integrates ~100 ms (Bloch); STBN masks: variance /M within the window; FRC precedent 6bit+FRC~8bit | up to ~6 effective bits back IF frame-to-frame dither is BLUE IN TIME |
| R5 | fixed-9-bit LZW -> GIF89a | lossless (Welch'84); decode==encode identity | 0 dB — a FILE-SIZE lever only; all quality is decided before the wire |

Phone-viewing geometry (30 cm, ~7 cm image): dither noise near the
256-grid Nyquist sits at ~9.6 cyc/deg — ABOVE the chromatic CSF
cutoff (~11-12, Mullen'85) and far below the luminance one (~50).
**Chroma dither is perceptually free at phone distance; luminance is
where the budget goes** — psychophysics re-deriving T4 (chroma is
the cost) from the other end.

### The five design rules the ledger fixes

  1. BIN IN THE MOSAIC DOMAIN, DEMOSAIC AT SCALE (C4/C5) — already
     law (MS); now also the max-SNR order. Never reorder.
  2. CCM AFTER BINNING (C6) — already what msEncode does; pin it.
  3. AUDIT THE FUSE WEIGHTS vs Hasinoff's inverse-variance optimum
     (t_k^2 [unclipped] / g_k^2 Var) — FuseKernel's SNR-x-rolloff
     weighting is close in spirit; a spec check (EV-law addendum)
     decides if the gap is real dB or noise. (D11)
  4. PALETTE PLACEMENT DOMINATES THE DITHER KERNEL (R2 vs R3): the
     VQ floor is the only irreversible render loss — which is why
     the MODEL'S one job is the palette, and why d=96's gate-layer
     win matters more than any walk tuning.
  5. THE WALK'S TEMPORAL AXIS MUST BE BLUE (R4): STBN-style
     frame-to-frame decorrelation, gated by the churn spectrum —
     the third independent derivation of blue-in-time this program
     has hit (Composer gate, GIF canon, now the ledger). (D12)

---

## Part B — the runtime ladder: ONE model, three engines

The model is V1H (d=96, 597k weights, trained in MLX on the Mac).
Its knowledge is ONE artifact: the V1HW package
(`nn/v1/runs/v1h_e5_d96.weights.bin`, fp16, loader
`Kernels/V1HWeights.swift` — landed, round-trip proven). The tiers
differ ONLY in which engine performs the multiply-adds:

  V1  Swift + Accelerate (CPU). The forward pass as plain code
      (vDSP/BNNS conv or hand loops). Runs TODAY-buildable; async
      after capture — licensed by QUALITY OVER CADENCE (no latency
      budget exists). The first ship tier.
  V2  Metal compute kernels (GPU). The house-proven pattern — the
      index map ALREADY runs at this tier, bit-identical to CPU,
      gate-verified (M2). Promotion when measured need, not taste.
  V3  Core AI .aimodel (ANE). The B6 export chain
      (safetensors -> torch mirror -> coreai-torch -> .aimodel);
      gated on the Xcode 27 beta SDK answers. Ships as DATA
      (AIModelCache), never as an app release.

Promotion gates (the parity ladder): each tier must reproduce the
previous tier's outputs on the fixture bundles within a stated
tolerance, judged AFTER the exact substrate (projection + index +
settle) — the learned path claims no bit-exactness (determinism
policy), but the substrate collapses small float drift, so the
parity criterion is the JUDGED metrics (chi^2_eq / dE_eq /
homeShare), not raw floats. A tier that shifts judged metrics does
not promote.

### Stage-to-tier map (the whole pipeline)

| stage | exact? | engine today | ladder? |
|-------|--------|--------------|---------|
| DNG decode (DNGKernel) | exact | CPU Swift | no — stays CPU (cold path) |
| crop/EV/fuse/normalize | exact, law'd | CPU Swift (+Accelerate free) | no |
| msEncode demosaic | exact (f64 sums) | CPU multicore | V2 candidate (M2b needs a spec change first — integer sums) |
| V1H MODEL (palette proposal) | statistical (fp16 fine) | none yet | **THE ladder: V1 -> V2 -> V3** |
| bell projection, index map | exact | CPU / METAL (index map already V2) | done |
| dither walk / battle settle | exact, sequential | not in product yet — THE missing slice | CPU by nature (DW6 windowing is its speed story) |
| GIF wire (LZW) | exact, byte-golden | CPU Swift | no |

Only ONE box rides the ladder. Everything exact stays in law'd
kernels at whatever engine the gate has verified — the ladder is a
model-deployment concept, not a pipeline rewrite.

---

## Part C — execution order (folds in the 2026-07-19 design verdict)

  1. THE WALK KERNEL into the product path (spec-first: DW walk-loop
     law -> golden -> Swift). Worth ~14x chi^2 for CLASSIC captures
     today, no ML required; precondition for the model's measured
     advantage (which lives at the equilibrium layer) to exist on
     device at all.
  2. V1 TIER: the plain Swift/Accelerate forward pass consuming
     V1HW, async after capture. Small scope: convs + leaky-relu +
     pixel-shuffle mirroring model.py; parity-checked against an
     MLX-side fixture (input tensor + expected latents in the
     package manifest).
  3. G6: the burst emits bundles (the corpus valve) — the data door
     is the binding constraint now; synth is mined out.
  4. V2 TIER for the model + msEncode Metal — only on measured need
     (quality-over-cadence makes this optional polish).
  5. V3 TIER when the Xcode 27 SDK answers land (B6 chain).
  Standing above all of it: the ONE DEVICE RE-CAPTURE — first real
  fractal bundle, unblocks R5, real-photon judging, A1's fair test.

## Decision points (Daniel)

  D11  fuse-weight audit vs Hasinoff optimum: spec addendum to the
       EV laws, or accept the current rolloff weighting as-is.
  D12  the walk's temporal axis: adopt STBN-style blue-in-time as a
       DW-law extension (the churn-spectrum gate), or leave temporal
       decorrelation to the Composer when it lands.
