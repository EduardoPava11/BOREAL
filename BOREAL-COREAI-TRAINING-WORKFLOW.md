# BOREAL Core AI Training Workflow — the four nets

Daniel's architecture (2026-07-18): a model that KNOWS THE L STRUCTURE,
chroma introduced as TWO other nets, and an OVERARCHING net that
composes the scenes. Four functions, one shipped asset:

  L-net      the structural model — H-JEPA level 1, the
             interpretation of Bayer-structured data, trained on L
             (the battle laws BA1-BA6 are its dynamics)
  a-net      chroma specialist, red-green opponent axis   (D7 → nets)
  b-net      chroma specialist, blue-yellow opponent axis (D7 → nets)
  Composer   the overarching net: composes the scene from the three
             channel latents — seed, ceiling, indices, and the
             temporal deltas (BA5) across the batch

Ship shape (research-verified): ONE .aimodel with four entry-point
functions (Core AI supports multi-function assets — SAM3 ships split
in 3), AOT-compiled, run on one ComputeStream.

## Evolution → H-JEPA: the bridge (you know the left column)

  evolution concept        here, under law
  ─────────────────        ───────────────────────────────────────
  population               MAP-Elites archive of net variants
                           (house lineage: gene archives) AND, at
                           the index level, the 256 options'
                           territory populations (BA1)
  fitness                  the HARD law'd metrics only: dE, chi^2
                           vs the beauty band, homeShare, churn —
                           laws judge, losses train
  mutation                 index level: defections (BA4 gives
                           Delta-chi^2 in O(1) — millions of moves
                           per second); net level: weight
                           perturbation over the archive
  selection                BA6's price signal + the dominance
                           gates; neutral drift IS the beauty band
                           (BA3: E[chi^2] = 255 exactly)
  THE NEW PART:            the H-JEPA predictor. It learns to
  the predictor            PREDICT fine latents from coarse ones.
                           Where it predicts well = redundancy
                           (evolution should NOT spend there).
                           Where it fails = genuine signal — the
                           interesting region of the fitness
                           landscape. The predictor is a learned
                           map of where mutations matter; sigma
                           and churn are its live read-outs.

  One sentence: evolution proposes, the JEPA predicts, the laws
  judge. Gradients (MLX) train the predictor; evolution owns the
  discrete moves gradients cannot reach (index defections, archive
  search); neither touches the exact substrate.

## N0 — Data plumbing (feeds everything)

- The app's fractal-segmentation slice (DONE): capture emits each
  frame as the (16x16)x(16x16) structure — seed + patches — with the
  BA5 delta lists between the batch's frames; L plane first-class.
  FractalKernel (patchMajor + delta primitives, harness-verified vs
  battle_golden.json), Outcome.frameL, report.json fractal + deltas
  sections (BA5 round-trip asserted at write time).
- Synthetic generator (exists) + report bundles (exist; one real
  bundle in hand). Loader parity: G-a, standing. nn/v1/record.py is
  the shared contract: synth_record / load_device_record / validate —
  one schema, both sources.
- Exit MET on the synth leg: a training record = {L fractal
  structure, deltas, EV trace} per cycle, identical from synth and
  device. The device leg needs ONE re-capture (the in-hand bundle is
  pre-N0; loader detects and says so).

## N1 — The L-net (the structure; the regimen R1-R4 governs)

- Input: the cycle tensor's L information (phases; N laws). Output:
  the L seed (bell-projected downstream) + the L ceiling latents.
- Training: the battle as the inner loop — defection dynamics on the
  index territory (BA4 incremental chi^2), the JEPA predictor
  learning coarse→fine L latents, gradients on the predictor,
  evolution on the discrete assignments; sigma-guided curriculum.
- GATES (all vs classic on held-out synth + bundles): dE_L < classic;
  chi^2 in the beauty band (150-400) and closer to it than classic;
  homeShare > classic. Collapse tripwire 255n standing.

## N2 — The chroma pair (a-net, b-net)

- Both CONDITIONED on the frozen L-net's latents (the structure is
  known first — chroma rides on it, as vision and codecs do: the
  I8 lever list; chroma carriers are where the tiling aliases).
- Each net small, bias-free, its own head; judged on its own axis:
  dE_a / dE_b vs classic AND the fine-scale chroma-aliasing share
  (the device-measured 55% at level 256 is the number to beat down).
- D7 (chroma dedicated analysis) is DISCHARGED into these two nets;
  their spec = the I2 investigation's findings (zone-plate harness).

## N3 — The Composer (the overarching net)

- Inputs: the three channel latents + the epoch axis. Outputs: the
  composed SCENE — final seed (bell projection stays exact), final
  index decisions (walk-windowed; TG2 bounds every swap), and the
  temporal composition: the batch's 4 frames + generated inners as
  DELTA LISTS (BA5 round-trip exactness is the contract).
- The Composer is where the battle is actually fought at inference:
  it arbitrates prior-vs-evidence per pixel; its equilibrium is
  gated by the beauty band per frame AND natural churn statistics
  across frames (deltas neither zero nor thrashing).
- GATES: strict dominance over classic on the full-dE, band, and
  homeShare, 95% of scenes, synth AND real.

## N4 — Ship: Core AI

- Export: MLX weights → safetensors → PyTorch mirror → torch.export
  → coreai-torch → ONE .aimodel, FOUR entry points (L, a, b,
  compose) → xcrun coreai-build compile --platform iOS.
- Static shapes, channels-first, conv-only (authoring guidance);
  one ComputeStream; classic path remains the deterministic
  fallback and reference forever (determinism policy unchanged).
- On-device A/B in the preview: composed rungs vs classic rungs,
  same capture; the three SDK questions (NDArray zero-copy,
  metal-package-builder, tiny-net placement) answered in the beta.

## N5 — Evolution at the archive (the outer loop)

- MAP-Elites over net variants (dimensions: beauty distance, dE,
  churn naturalness); the archive is the population, bundles are
  the environment, and every device capture adds selective
  pressure. This is the loop Daniel has run before — now with the
  JEPA predictor telling it where the landscape is interesting.

## Standing rules

  laws judge, losses train . classic always printed . 255n tripwire
  . G-a before belief . bell projection exact at every eval . D6
  (bell↔tesseract) still open and blocks nothing above.
