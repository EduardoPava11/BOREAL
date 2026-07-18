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

So the trainer maximizes carried signal per emitted bit: drive chi^2
toward 0 under the bell's L allocation, spend dE only where chroma buys
it. The binomial lives in L; chroma is the cost.

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

## R3 — Compression (the theorem takes over)
Anneal: decay the warm anchor (x0.5 per 2k steps), raise chi^2 + serve
weights, cool tau (0.1 -> 0.02). The rate term now does the work T3
licenses it to do. Bell penalty held constant (projection stays exact
at eval; G-c watches the projection delta).
EXIT: hard H >= 7.5 bits (chi^2 correspondingly small) AND dE <= classic
on held-out synth.

## R4 — Dominate the classic (gate G-b for V1)
Joint fine-tune, no anchor. EXIT: STRICT dominance over the classic seed
on held-out synthetic: dE < classic AND chi^2 < classic AND homeShare >
classic, all three simultaneously, 95% of scenes.

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

## Literature grounding (research in flight; fold citations here)
  - luminance-carries-signal / chroma-as-cost (vision + coding practice)
  - chi^2 <-> KL second-order (the T3 bridge's citation)
  - codebook-usage entropy losses + VQ collapse remedies (the R2/R3
    parallels in VQ-VAE practice)
  - compression-as-pretraining (MDL / infomax)
