# BOREAL NN Design — the multi-scale H-JEPA demosaicer

Status 2026-07-17: designed. Input contract is LAW (CycleSet N1-N5, gate
green); output contract is LAW (MS + B laws); runtime research done
(Core AI, WWDC26 sessions 324/325/326/330). Not yet trained.

## 1. What the network is

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

  G-a  trainer loader == cycleset_golden.json (parity)
  G-b  >= +1 dB over CFA-bin per rung, OKLab dE, held-out real bundles
  G-c  bell projection delta small (median |L shift| under a stratum
       width) — the net PROPOSES lawful seeds, projection only trims
  G-d  on-device: warm per-frame latency < the 50 ms cycle budget slice;
       cold-start specialization measured and cached
  G-e  A/B in the preview: NN rungs vs classic rungs, same capture

## 8. Open items (resolve in the Xcode 27 SDK / beta)

  1. NDArray zero-copy: can it wrap MTLBuffer/CVPixelBuffer? (Decides
     integration option a vs the TorchMetalKernel inversion.)
  2. metal-package-builder + .aimodel: does the Metal-4 encoder route
     accept Core AI assets, or is it still Core-ML-package-only?
  3. Tiny-CNN placement + latency on A19 Pro: nobody has published
     sub-megaparam numbers — benchmark our own net in the beta.
