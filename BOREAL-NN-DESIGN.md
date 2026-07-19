# BOREAL NN Design — the multi-scale H-JEPA demosaicer

> PARTIALLY SUPERSEDED (banner added 2026-07-18): the ONE-network
> framing below is the historical seed of the FOUR-NET architecture
> (L-net, a-net, b-net, Composer) — current model source of truth is
> `BOREAL-COREAI-TRAINING-WORKFLOW.md`, execution loop is
> `BOREAL-COREAI-CIRCUIT-WORKFLOW.md`. The contracts named here
> (CycleSet N laws, MS + B laws, Binomial V1) remain LAW. The ship
> gates in §7 are REVISED IN PLACE per the 2026-07-18 decrees (no A/B
> surface; quality over cadence) and the equilibrium-gate
> redefinition — read §7 as amended, not the git history.

Status 2026-07-17: designed; V1 SCOPED (below). Input contract is LAW
(CycleSet N1-N5); output contract is LAW (MS + B laws); the V1 objective
is LAW (Binomial V1a-V1e); runtime research done (Core AI, WWDC26
sessions 324/325/326/330). Not yet trained.

## 0. The frame: a stack of EQUIVALENT ENCODERS, and V1 bare bones

The rungs are not levels of one encoder — they are a FAMILY of
equivalent encoders of the same scene at different debayer resolutions
(each rung its own demosaic; MS laws). The H-JEPA is the WIRING between
them: deterministic up (nearest replication), learned down (predict the
finer encoding from the coarser), latent prediction never pixel
reconstruction. What is learned, concretely, is GIF structure: build an
index map, use the 16x16 color palette.

**THE SHAPE (Daniel, 2026-07-17): (16x16) x (16x16) = 256x256 — V1 IS
H.** The ceiling frame factorizes exactly as a 16x16 outer grid of
16x16 inner patches (y = 16v+j, x = 16u+i), and the outer grid IS the
seed's grid: each seed cell is the coarse latent OF ITS OWN PATCH (A2,
squared). The arithmetic closes: balanced usage gives every color
n/256 = 256 pixels = one patch's area — the binomial ideal and
home-centering meet at one fixed point (patch p speaking mostly color
p), and the deterministic up-arrow maps level-0 perfection to level-1
perfection (up of the identity seed == the perfect-H ceiling, law H4).
Landed as laws H1-H5 (Boreal.PatchGrid); the report's binomial section
now carries homeShare at the ceiling — every capture measures how H
the classic path already is.

So V1 is not a flat palette head — it is the SMALLEST H-JEPA: two
levels of the same 16x16 shape, one jump. A seed encoder produces 256
cell latents; the palette head reads a color off each; a SHARED patch
predictor (one network, 256 applications) predicts each cell's inner
16x16 in latent — the JEPA's learned down at the seed->ceiling jump —
and the assembled prediction is indexed against the palette. Middle
rungs (32/64/128) are V2 refinements of the SAME jump; nothing about
V1's two-level interface moves.

**V1 does ONE thing very, very well: the binomial approximation at
16x16 colors** — judged by these numbers:

  1. χ² of the ceiling index map's usage histogram vs B(n, 1/256)
     (Binomial laws; 0 = balanced = the A2 permutation ideal). Balanced
     usage = maximal entropy of the 8-bit index stream = the palette
     EARNS all 256 codes — V1 optimizes the rate of the pipeline's one
     lossy stage.
  2. Bell admissibility of the seed's luminance (B laws; exact rank
     projection downstream keeps it lawful by construction).
  3. Mean ΔE of the ceiling frame indexed against the seed (quality).

Everything else — per-rung residual heads, temporal prediction, latent
reasoning — is V2+, and the wiring below is designed so V1's interfaces
never move: perfect the 16x16 per frame first; latent reasoning then has
a substrate whose every frame is a near-permutation of its own palette,
which is exactly when reasoning over indices IS reasoning over the
scene. The report.json "binomial" section already measures today's
classic seeds per rung — V1's baseline numbers come from every capture.

## 1. What the network is (the full design V1 grows into)

ONE network that demosaics the square Bayer pattern by "seeing" at every
partition 16/32/64/128/256, seeded by the 16x16 = 256, predicting directly
into the LAB latent. It replaces the classic per-rung CFA-bin path of the
multi-scale ISP; everything around it (EV normalization, Q16, index maps,
GIF wire) stays in the exact Swift/Metal substrate.

## 2. I/O contract (already law)

INPUT (N1-N5): the 4-DNG cycle tensor — 4 EV-normalized mosaics (each
divided by its own e_t; exact) → 4 positional phase planes each →
**16 channels x 1024 x 1024**, frame-major (c = 4*frame + phase). CFA
meaning is metadata (RGGB/BGGR = label swap, one architecture).
  - N3 keystone: the input CONTAINS the finest classic baseline verbatim
    (cfaBin k=2 == {phase-R, mean(phase-Gs), phase-B}); identity is
    already a demosaicer, so residual learning starts from competence.
  - N4: the map is 1-homogeneous → with a BIAS-FREE network, exposure
    equivariance is a theorem (Tesseract-proven trick), not a hope.

OUTPUT: per channel (L,a,b) the multi-scale RESIDUAL STACK (MS laws):
[rung16 | rung32-up(rung16) | ... | rung256-up(rung128)] = 87,296 floats
per channel, quantized to Q16 by OUR exact kernel downstream. The
256-entry seed prefix must be BELL-ADMISSIBLE (B1-B4).

## 3. Architecture (~40k params, bias-free throughout)

  stem     conv3x3, groups=4 (per-FRAME subnets), 16 -> 32     (1,152)
  fuse     conv1x1, 32 -> 24 (temporal fusion across frames)     (768)
  trunk    4 x [conv3x3 stride 2, 24 -> 24]  1024 -> 64        (20,736)
           (rungs 256/128/64 tap the trunk at matching sizes)
  heads    per rung r in {256,128,64,32,16}:
           conv1x1 24 -> 3, predicting the LAB RESIDUAL vs the
           exact per-rung CFA-bin baseline (which the input/trunk
           already encodes)                                   (5 x 72)
  seed     the 16 head's output + the trunk's global context; a
           small 1x1 mixer 24 -> 24 -> 3                         (~1.2k)
  sigma    free: |residual| energies of the predicted stack
  total    ~ 24k weights (FP16 ~48 KB; FP32 ~96 KB)

Rationale: groups=4 keeps frames independent until `fuse` (the temporal
unit is explicit); all downsampling is learned stride-2 (the network's
own "demosaic at scale"), residual heads mean every rung's baseline is
the exact classic path — the gate ">= +1 dB over CFA-bin per rung, OKLab
dE" compares like with like by construction.

BELL ADMISSIBILITY is enforced by PROJECTION, not hoped from the loss:
the deployed seed = exact rank-based stratum assignment (sort the 256
predicted L values; assign bell counts 1,1,2,4,...,1 in rank order; pin
ends to exact black/white) implemented in the exact Swift kernel, so
B1-B4 hold by construction on-device; training adds a soft bell-CDF
penalty so the projection is small.

## 4. Training (MLX on the Mac — Apple's blessed training story, WWDC26)

- Data: (a) LAB report bundles (real photons; the bundled DNGs replay
  through the exact pipeline for ground truth at every rung); (b) the
  synthetic generator: procedural OKLab scenes -> mosaic through CFA +
  noise model -> exact bell-lawful ground truth, infinite supply.
- Loader parity: the trainer's phase decomposition is validated against
  cycleset_golden.json (the same fixture the device side answers to).
- Losses: per-rung log-MSE in OKLab with chroma reweighting (both
  documented Tesseract traps), soft bell-CDF penalty on the seed,
  H-JEPA terms: predict level-r details from the prefix (spatial) and
  next-cycle seed from history (temporal), LeJEPA-style (no EMA teacher,
  SIGReg isotropy on seed embeddings).
- sigma supervises nothing: it is derived from predictions, but its map
  (where coarse fails to predict fine) is the curriculum signal — sample
  training crops where sigma is high.

## 5. Shipping (Core AI, iOS 27 — research 2026-07-17)

- Export: MLX weights -> safetensors -> equivalent PyTorch module ->
  `torch.export` -> `coreai-torch` TorchConverter -> `.aimodel` ->
  `xcrun coreai-build compile --platform iOS` (AOT). (No direct MLX
  export exists; the PyTorch bridge is trivial at this size.)
- Authoring guidance followed by construction: static shapes (16x1024x
  1024 fixed), channels-first, conv-only (no Linear). Static shapes
  route to the ANE per third-party benchmarks; `SpecializationOptions`
  can pin `.gpu` if the neural-accelerator path measures better.
- Runtime: `AIModel` -> `InferenceFunction` -> `run(inputs:outputViews:)`
  on ONE `ComputeStream` (serialized, back-pressure-friendly for the
  64-frame loop); pre-allocated NDArray outputs; warm inference after
  first-run specialization (cache via AIModelCache).
- Custom-kernel option: `TorchMetalKernel` can embed OUR MSL (e.g. the
  phase decomposition, Q16 quantize) INSIDE the .aimodel if the copy
  through NDArray proves costly — inverting the integration rather than
  pulling inference into our encoder.

## 6. Determinism policy (explicit)

Core AI documents NO determinism guarantees, and specialization is
per-device. Policy: the LEARNED path is float and makes no bit-exactness
claim across devices; determinism lives where it always has — the exact
substrate quantizes, projects (bell), indexes, and encodes. The classic
CFA-bin path remains the bit-exact reference forever (it is also the
NN's fallback when the model asset is absent). Same-device, same-asset
stability is expected but will be measured, not assumed.

## 7. Gates before the NN touches the product path

(G-d and G-e REVISED 2026-07-18 per the decrees: no A/B surface,
quality over cadence. G-b is superseded as a SHIP gate by the
equilibrium-layer judge — see the regimen doc — and remains a
per-rung diagnostic only.)

  G-a  trainer loader == cycleset_golden.json (parity)
  G-b  (diagnostic, not a ship gate) >= +1 dB over CFA-bin per rung,
       OKLab dE, held-out real bundles; the SHIP gate is the
       equilibrium-layer dominance test (regimen R4)
  G-c  bell projection delta small (median |L shift| under a stratum
       width) — the net PROPOSES lawful seeds, projection only trims
  G-d  on-device: composition COMPLETES and its latency is RECORDED
       as C0 telemetry in the bundle (quality over cadence — there
       is NO latency budget); cold-start specialization measured
       and cached
  G-e  model-vs-classic judged in DATA: the bundle carries both
       paths' metrics per capture and the Mac-side judge compares
       (NO A/B surface in the app — the surface shows THE GIF)

## 8. Open items (resolve in the Xcode 27 SDK / beta)

  1. NDArray zero-copy: can it wrap MTLBuffer/CVPixelBuffer? (Decides
     integration option a vs the TorchMetalKernel inversion.)
  2. metal-package-builder + .aimodel: does the Metal-4 encoder route
     accept Core AI assets, or is it still Core-ML-package-only?
  3. Tiny-CNN placement + latency on A19 Pro: nobody has published
     sub-megaparam numbers — benchmark our own net in the beta.
