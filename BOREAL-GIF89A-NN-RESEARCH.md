# BOREAL GIF89a NN Research — how others built networks that end in a GIF

Date: 2026-07-18. Four-lens literature sweep (palettization+dither /
codebook design / paletted-video temporal / RAW-to-discrete ISPs),
every claim tagged PRIMARY-VERIFIED (PV: paper/PDF/code read) or
SECONDARY (SEC: abstract/snippet only) by the research agents. This
doc maps the findings onto BOREAL's components and ends with the
ordered experiment queue. Focus per Daniel's directive: the app is a
custom ISP, DNG in, GIF89a out — the network designs that matter are
the ones that terminate in palette + index map + dither + wire.

## 0. The verdict in one paragraph

The field has solved BOREAL's differentiability problems (soft
projection over palette distances; predict-the-error-image instead of
backprop-through-scan; soft-then-hard staging) and its codebook-health
problems (Kohonen-EMA updates, stratified k-means warm starts,
constrained dead-code revival). It has NOT done three things BOREAL's
laws already pin: (1) a palette constrained to a spatially arranged
2-D grid with grid-local dither steps, (2) a usage target that is a
FLUCTUATION BAND (chi^2 in 150-400) rather than exact uniformity —
every published regularizer pulls to uniform, which our V1f law calls
sterile, and the fixed-rate ECVQ corner (equal code lengths <=> the
9-bit wire) is the only theory that even touches it, and (3) any
temporal/animated GIF learning at all — GIFnets (CVPR 2020) is
single-image; GIF2Video solves only the inverse. THE COMPOSER IS
"GIFNETS + TIME," and that direction is unclaimed. (Bonus: our
mid-anneal chi^2 hump is undocumented in the literature; DALL-E's
dVAE schedule is the only published mitigation pattern.)

## 1. The palette head (the 16x16 seed)

- **GIFnets** (Yoo/Luo/Wang/Yang/Milanfar, CVPR 2020, arXiv:2006.13434
  — PV, full PDF read): PaletteNet predicts the whole palette
  feed-forward; **soft projection** Proj_s = sum_j w_j P[j],
  w = softmax(-d^2/T) over palette entries, hard at inference — the
  drop-in training-time relaxation of our index map, and the SAME
  operator as Agustsson's soft-to-hard VQ (NeurIPS 2017, PV). Their
  three-stage schedule (palette first, dither with palette frozen,
  short joint fine-tune — joint-from-scratch collapses color count)
  is a documented answer to palette-vs-dither co-training instability.
  Caveat measured by them: at 256 colors their fidelity gains over
  Floyd-Steinberg mostly vanish — the edge at OUR palette size must
  come from arrangement + temporal structure, not raw dE.
- **ColorCNN** (Hou/Zheng/Gould, CVPR 2020, arXiv:2003.07848 — PV):
  per-pixel softmax over C color classes; palette = probability-
  weighted mean of pixels per class; confidence regularizer + color
  jitter instead of temperature annealing. **ColorCNN+**
  (arXiv:2208.08438 — abstract PV): pure end-to-end palettes DEGRADE
  at large palette counts; fixed by imitation of classical
  quantizers. Field-independent validation of our RESIDUAL-TO-CLASSIC
  anchor — at 256 colors, anchor on the classic seed or lose.
- **Kohonen-VAE** (Irie/Csordás/Schmidhuber, ICANN 2024,
  arXiv:2302.07950 — PV): SOM locality moved INTO the EMA update rule
  (neighborhood-weighted counts/sums), no loss term spent; improves
  utilization, robust to non-random init. The cleanest recipe for our
  grid: bell-projected Kohonen-EMA updates give L1-L3-style locality
  for free and leave the loss budget to reconstruction + the band.
  (**SOM-VAE**, ICLR 2019 — SEC: the loss-term ancestor; note its
  neighborhood pull CORRELATES adjacent codes and biases chi^2 UP at
  fixed entropy — budget the band for it.)
- **ViT-VQGAN** (Yu et al., ICLR 2022, arXiv:2110.04627 — PV): 96% vs
  4% utilization decided by LOOKUP GEOMETRY (factorized + normalized
  codes), not loss weights. At K=256 we are below the collapse-
  critical size (FSQ's VQ baselines degrade above ~2^11), so the
  load-bearing choices are geometry (match in OKLab — already ours)
  and update rule, not heavy machinery.
- **SoundStream** (arXiv:2107.03312 — PV): k-means-on-first-batch
  init + assignment-EMA dead-code replacement. Ours, stratified: the
  warm-start k-means runs INSIDE each luminance stratum with the bell
  counts (1,1,2,4,...,64,...) as cluster budgets — a bell-lawful init
  that starts inside the band. **Jukebox** (PV): usage-EMA-triggered
  random restarts; ours must be CONSTRAINED revival (re-seed only
  within the dead cell's stratum and grid neighborhood).
- **FSQ** (Mentzer et al., ICLR 2024, arXiv:2309.15505 — PV): no
  codebook, ~100% usage by construction. Reading for us: the bell IS
  a structural quantizer (stratum x within-stratum ~ a product code);
  an FSQ-flavored ablation (fix L per stratum, learn only chroma)
  predicts chi^2 lands BELOW the band (too uniform) — a cheap probe
  of how much of the band the palette vs the territory owns. Also:
  check chi^2 PER STRATUM (expected E = count-1), the stratified
  analogue of RVQ's per-stage health.

## 2. The dither walk (DW laws)

- **GIFnets DitherNet** (PV): predicts a randomized ERROR IMAGE in one
  U-Net pass — nobody backprops through the sequential scan.
  Consistent negative result across the sweep: NO published work
  learns error-diffusion kernels through the serpentine scan (SEC,
  absence claim). The walk stays exact and sequential in the product;
  training-side, predict the error field.
- **RL halftoning** (Jiang et al., IEEE TIP 2023, arXiv:2304.12152 —
  PV): blue-noise induced AS A LOSS (anisotropy-suppressing spectral
  penalty), one FCN forward pass emits the whole halftone. Transfer:
  express the walk's statistics (local index-difference spectrum,
  palette-grid step length under TG2) as differentiable penalties —
  the walk's LAWS become the loss, the walk itself stays law.
- **Noise Incentive Block** (Xia et al., ICCV 2021 — abstract PV): a
  CNN cannot dither a flat region without a noise source; give the
  L-net an explicit noise input for smooth-gradient scenes (our sky
  case).

## 3. Training through the quantizer + the chi^2 band

- Field settlement (Ballé noise-proxy / STE / soft-to-hard; "Soft
  then Hard," ICML 2021 — PV): for CODEBOOK quantization (our case),
  temperature-annealed soft assignment, then freeze-and-fine-tune
  hard. Agustsson (PV/SEC): anneal by the measured soft-vs-hard GAP,
  not by clock — better than our fixed geometric tau schedule.
- **The hump has a published mitigation pattern**: DALL-E dVAE
  (arXiv:2102.12092 — PV) ramps its usage prior (beta: 0 -> 6.6 over
  5k steps) THIRTY TIMES faster than its temperature anneal (150k
  steps), explicitly because early annealing degrades usage.
  Translated: hold the chi^2-band penalty at FULL weight from step 0;
  anneal tau underneath it; never co-anneal. Our mid-anneal chi^2
  excursion (~step 800-1200, all five runs) is UNDOCUMENTED in the
  literature — worth writing up.
- Usage losses in the wild all target exact uniformity: wav2vec 2.0
  diversity (batch-mean entropy, PV), MAGVIT-v2/LFQ two-term entropy
  (confident per-sample + uniform batch, PV; 100% usage at 2^18 in
  Open-MAGVIT2). The two-term SHAPE is the import: keep "confident
  per-pixel index," swap the uniform attractor for the band penalty.
  No published chi^2-band target exists; fixed-rate ECVQ (Chou/
  Lookabaugh/Gray 1989 — SEC) is the corner our 9-bit wire constructs.

## 4. The Composer (temporal — the unclaimed direction)

- **D1 RESOLVED BY THE STANDARDS' PATTERN**: HEVC-SCC palette mode
  (IEEE TCSVT 2016 — PV) uses NEITHER pure global nor pure local — a
  palette PREDICTOR with per-entry REUSE FLAGS, explicit new entries,
  and periodic reinitialization. BOREAL's translation: ONE global
  256 table + per-frame reuse-flag subsets + a predictor-update law
  the Composer can emit. Everything else agrees global-first:
  gifsicle's delta machinery assumes palette stability (PV, man
  page); gifski's local tables survive only behind aggressive
  temporal denoising (PV, denoise.rs read); a fixed vocabulary is
  what makes token-domain prediction tractable (MAGVIT analogy).
- **BA5 delta lists are blessed at every level**: gifsicle -O2
  transparency deltas (PV), gifski per-pixel importance maps (PV),
  SCC COPY_ABOVE index runs = the spatial transpose (PV), masked-
  token prediction = the learned version where CHURN == MASK RATE
  (MAGVIT line, SEC). Two guards the literature demands: ordered/
  blue-noise dither in static regions (ffmpeg's own docs: error
  diffusion churns everything — SEC) and DCVC-FM-style periodic
  context refresh to bound delta-chain drift (SEC).
- **"Churn neither zero nor thrashing" now has a quantitative form**:
  spatiotemporal blue noise (Wolfe et al., EGSR 2022,
  arXiv:2112.09629 — PV): per-pixel index sequences should be BLUE IN
  TIME — white-in-time = thrash, DC = frozen. The Composer's churn
  gate becomes a temporal-spectrum target, not a heuristic. Training
  recipes with precedent: TCVC-style temporal self-regularization
  (SEC) + Sun 2006 temporal error diffusion (SEC) as inductive bias;
  architecture precedent for the gate: NeR-SC's static-frame skip
  (abstract PV) and gifski's perceptibility-thresholded background
  persistence (PV).
- Condition, don't subtract (DCVC lineage — SEC): the Composer
  conditions on previous index maps/features; raw delta prediction
  is the field's abandoned first attempt.
- **GIF2Video** (CVPR 2019 — SEC): the inverse problem exists and can
  serve as a differentiable critic of our outputs later.

## 5. Capacity + pipeline shape (the 169k question)

- Verdict from the ISP sweep: 169k params is NORMAL-to-generous by
  SHIPPING mobile-ISP standards (MicroISP ~40k full RAW->sRGB, PV;
  DynamicISP controllers low-100k, PV; shipped Google burst pipelines
  are deterministic substrate + small learned pieces — Wronski
  SIGGRAPH 2019, PV) but 3-30x BELOW the quality-benchmark demosaic
  literature (Gharbi ~560k computed, PyNET 47.5M). The field's answer
  at small capacity is ARCHITECTURAL, not width: (a) aggressive
  downsampling with learned up (JD3Net, abstract PV — independent
  endorsement of demosaic-at-every-scale), (b) predict the
  COEFFICIENTS of deterministic ops, not pixels (KPN burst kernels,
  DynamicISP parameter steering — both consistent with our exact-
  substrate philosophy), (c) hard-example mining (Gharbi). If those
  fail, Gharbi-class ~500k is squarely within norms.
- BOREAL is a **half-sandwich** (Google sandwiched compression,
  arXiv:2402.05887 — PV: neural pre-processor + standard codec +
  proxy-train/exact-deploy): our soft-projection training against the
  exact substrate at eval is the validated pattern. RAW-level joint
  denoise/demosaic/compress (arXiv:2501.08924 — abstract PV) is the
  closest whole-pipeline precedent and trains Bayer-direct, our lane.
  If the soft proxy proves too stiff, CAS-Net's artifact-SIMULATOR
  net (SEC) is the fallback pattern (a GIF-artifact simulator).
- Burst fusion consensus (Kalantari SIG17, KPN, AHDRNet — PV/SEC):
  exposure-normalize to shared linear radiance + per-pixel attention/
  robustness arbitration; nothing conditions via bias terms, so our
  bias-free equivariance (the cleaner form) conflicts with nothing.

## 6. The ordered experiment queue (evidence-backed)

  E1  DALL-E ordering: band penalty FULL from step 0, tau annealed
      underneath, anneal by measured soft-hard gap not clock. The
      direct next training run — targets the documented hump.
  E2  Kohonen-EMA palette updates (bell-projected after each step) +
      stratified k-means warm start from the first batch. Replaces
      loss-term SOM pressure; leaves budget for the band.
  E3  Walk-statistics losses: anisotropy penalty on the index-
      difference spectrum + explicit noise input to the L-net.
  E4  Hard-example mining over synth scenes (sigma-ranked crops —
      the sampler form of the sigma curriculum that lost as a loss).
  E5  Capacity to Gharbi-class ~500k ONLY if E1-E4 leave the plateau
      (field norms license it; shipping norms don't demand it).
      [VERDICT 2026-07-19: RAN — d=96/597k @ 20k = NEW CHAMPION
      19,603/0.334/0.0081, and chi^2_eq 1,162 BEATS the clean
      oracle's 1,258 — the first oracle-beating column, on the gate
      layer; the d=24 same-horizon control (21,854/0.327/0.0083, eq
      1,903) attributes the equilibrium-layer win to CAPACITY.
      E1 also RAN (won, champion recipe); E2 dead (per-scene
      translation fails); E3 weakly negative; E4 flat. Ledger detail
      in the training memory + commits c5f7c9a..a65abda.]
  E6  Spec-side: D1 redefined as global table + per-frame reuse-flag
      subsets (SCC pattern) — a law + wire extension decision for
      Daniel; churn gate as a temporal-spectrum (blue-in-time) law.
  E7  Later: GIF2Video-style critic; FSQ-flavored bell ablation as a
      diagnostic of palette-vs-territory ownership of the band.

## 7. The unclaimed flags (ours if executed)

  1. SOM-arranged palette grid + grid-local dither as LAW (TG2/DW):
     no published palette lives on a 2-D grid with locality
     guarantees. (Zeger-Gersho pseudo-Gray is the nearest theory;
     our grid is an approximate pseudo-Gray code for free.)
  2. The chi^2 fluctuation-band usage target + the equilibrium-layer
     judge (BA laws): every published regularizer pulls to uniform.
  3. Temporal differentiable GIF — the Composer as "GIFnets + time":
     coherent index streams, BA5 deltas, churn-spectrum gating.
  4. The mid-anneal chi^2 hump: measured, mechanistically explained
     (softmax mass concentration at mid-tau), undocumented anywhere.

## 8. Architecture proposals (2026-07-18, evidence-cited; Daniel decides)

Ordered by evidence strength x cost. Each notes which laws it touches
(spec-first discipline: anything touching a law is spec change FIRST).

  A1  PER-FRAME ARBITRATION HEAD (KPN-lite). Replace the 1x1 temporal
      fuse with per-pixel softmax weights over the 4 EV-normalized
      frames (features -> 4 logits -> weighted sum). The burst-fusion
      consensus (Kalantari SIG17 / KPN / AHDRNet): let attention
      arbitrate saturation/noise per pixel instead of a fixed linear
      mix. Bias-free-compatible (softmax of scale-equivariant logits).
      ~+8k params. Touches no laws. HIGHEST VALUE/COST — the 4-frame
      EV cycle is our whole data advantage and the current fuse
      treats it as one 1x1 conv.
  A2  PREDICT-THE-OPERATOR SEED HEAD (KPN/DynamicISP pattern). The
      palette head emits per-cell COEFFICIENTS of a deterministic op
      on the classic cell statistics (per-cell gain + chroma rotation
      applied to the classic seed) instead of raw OKLab residuals.
      Deepens the residual-to-classic anchor the literature validated
      (ColorCNN+); exposure equivariance holds by construction.
      ~+2k params. Touches no laws.
  A3  NOISE INPUT (NIB, ICCV 2021). One noise plane appended to the
      cycle tensor (16 -> 17ch) so the net CAN dither flat regions —
      a CNN cannot break flat-in/flat-out symmetry without a noise
      source; our sky gradients are the failure case. ~+0.5k params.
      Touches the N-law input contract's CHANNEL COUNT — spec first
      (N1' with a 17th conventions-pinned noise plane) or inject
      post-stem (no law touched; weaker but free).
  A4  RECEPTIVE FIELD BEFORE DEPTH (JD3Net lesson). Two dilated 3x3
      convs at the 32x32 stage of the ladder (dilation 2/4) instead
      of width growth — the 16x16 cell latent currently sees ~31px
      of a 512px mosaic; palette decisions are global-statistics
      decisions. ~+40k params at d=24. Touches no laws.
  A5  KOHONEN-EMA PALETTE (E2's architecture form). The palette
      becomes an EMA codebook updated by the SOM rule from cell
      latents (Kohonen-VAE, ICANN 2024), bell-projected after every
      update; the conv palette head demotes to initializer. Gives
      L1-L3 locality via the update rule, freeing the loss budget.
      Interacts with B laws (projection after EMA — order pinned in
      spec first) and the SOM-vs-band chi^2 bias (budget the band).
  A6  ERROR-FIELD HEAD (DitherNet analog). A third head predicting
      the per-pixel error image added before projection at TRAIN
      time; the product walk stays exact law. Enables E3's walk-
      statistics losses (anisotropy penalty). ~+15k params. Touches
      no product laws (train-side only).
  A7  LOOKUP GEOMETRY (ViT-VQGAN lesson — 96% vs 4% is geometry).
      Train-side experiment: normalized/reweighted OKLab axes for the
      soft-projection distance. The PRODUCT distance is G-law Q16
      argmin — if the experiment wins decisively, changing the wire
      metric is a G-law spec decision (Daniel), not a trainer flag.
  A8  CAPACITY HOLDS at d=24/52k until E1-E4 verdicts; then Gharbi-
      class ~500k (field-licensed), width AFTER A1/A4's architectural
      moves — the literature's answer at small capacity is shape,
      not size.

Full citations with PV/SEC tags live in the four agent reports
(session 2026-07-18); the load-bearing ones are inlined above.
