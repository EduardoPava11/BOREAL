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
- GATES (all vs classic on held-out synth + bundles; REDEFINED
  2026-07-18 at the EQUILIBRIUM LAYER — the band is a property of the
  settled territory, not the raw argmin; judge = the pinned
  equilibrium judge in BOREAL-TRAINING-REGIMEN-WORKFLOW.md /
  nn/v1/battle.py): dE_eq < classic's dE_eq; chi^2_eq in the beauty
  band (150-400) and closer to its center than classic's;
  homeShare_raw > classic's. Collapse tripwire 255n standing.

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

## The on-device boundary (Core AI cannot train — and needn't)

Core AI has NO training API (research-verified; MLX is Apple's
training story). The architecture absorbs this because only ONE of
its three verbs needs gradients: evolution proposes, the JEPA
PREDICTS (gradients, Mac), the laws judge. Three tiers:

  tier 1  PER CAPTURE, ON DEVICE — the battle. Defections, walk
          swaps, churn: discrete moves, fitness = the hard law'd
          metrics, BA4 gives Delta-chi^2 in O(1). No weights, no
          autograd — pure Swift/Metal kernels. Untouched by the
          limitation.
  tier 2  PER USER, ON DEVICE — adapt AROUND the frozen model,
          never inside it. (a) Archive SELECTION: the .aimodel
          carries a small variant archive (multi-function assets);
          the phone selects per scene, judged by the laws —
          selection is inference + bookkeeping. (b) The theta-up
          pattern (house-proven): a tiny owned adapter (~tens of
          params, per-user scale/bias on the latents) trained with
          HAND-WRITTEN gradients in our own kernels, applied in
          Q16 space around the frozen trunk. Core AI never knows.
  tier 3  GLOBAL, ON THE MAC — MLX gradient training on the N0
          fractal-record corpus (the federated ROTAS/SATOR72
          topology: phone captures bundles -> Mac trains ->
          re-export -> phone). The .aimodel refresh ships as DATA
          (asset load, AIModelCache), not as an app release.

  Boundary rule: the archive's SELECTION runs on device; its
  MUTATION (weight perturbation + retraining) runs on the Mac.
  Per-user weight adaptation beyond selection = owned adapter in
  our kernels, NEVER inside the .aimodel.

## N4 — Ship: Core AI

- Export: MLX weights → safetensors → PyTorch mirror → torch.export
  → coreai-torch → ONE .aimodel, FOUR entry points (L, a, b,
  compose) → xcrun coreai-build compile --platform iOS.
- Static shapes, channels-first, conv-only (authoring guidance);
  one ComputeStream; classic path remains the deterministic
  fallback and reference forever (determinism policy unchanged).
- Model-vs-classic judged in DATA, not UI (Daniel's decree
  2026-07-18: NO A/B surface — the app captures from DNGs and shows
  THE GIF, one surface): the report bundle records both paths'
  metrics per capture; the Mac-side judge compares. The three SDK
  questions (NDArray zero-copy, metal-package-builder, tiny-net
  placement) answered in the beta.

## N5 — Evolution at the archive (the outer loop)

- MAP-Elites over net variants (dimensions: beauty distance, dE,
  churn naturalness); the archive is the population, bundles are
  the environment, and every device capture adds selective
  pressure. This is the loop Daniel has run before — now with the
  JEPA predictor telling it where the landscape is interesting.
- Split per the boundary rule above: device = selection among the
  shipped archive (tier 2a); Mac = mutation + retraining (tier 3);
  captures flow back as fractal records and become the next
  generation's environment.

## Session sunset — 2026-07-18 (state of play)

Where this session left the program (commits 0389f82 -> d8c95c8;
gate 16 law files / 87 laws + oracle + Swift harness green; sim
build green; tree clean) [count note 2026-07-18: the S-transform
pyramid law file was retired from the gate later the same day —
CORE is now 15 law files]:

  DONE
  - N0: the app emits the fractal training record. FractalKernel
    (patchMajor + BA5 delta primitives, golden-verified), Outcome
    .frameL, report.json "fractal" + "deltas" (round-trip asserted
    at write time), nn/v1/record.py = the one contract for synth
    and device records.
  - The three-tier boundary (section above): battle on device,
    adapters/selection around the frozen .aimodel, gradients on
    the Mac. Selection on device, mutation on the Mac.
  - Synth is device-real: 12-bit ADC (black 528 / white 4095),
    read noise, saturation, EV ratios [1, 3.66, 15, 62.5], deep
    shadows, ETTR coupling. Churn varies naturally (54-94%).
  - Trainer: residual-to-classic (N3 as architecture; step-1 hard
    metrics == noisy baseline exactly), scale-adaptive tau + R3
    anneal, R2 home term, bell-consistent judge (the bell is the
    OUTPUT TONAL SPACE; targets histogram-specified through the
    induced monotone map; baselines judged identically).
  - 400-step evidence: dE 0.0086 -> 0.0066-0.0074 vs clean-classic
    0.0067 (denoising gap recovered); chi2 66.7k -> 17-21k (clean
    14.3k); homeShare 0.306 -> 0.338 (clean 0.352).

  NEXT SESSION, IN ORDER
  1. ONE device re-capture with this build — the first real
     fractal bundle (the in-hand bundle is pre-N0; record.py
     detects it). It becomes the held-out eval.
  2. N1 gates: chi2 and homeShare still trail clean classic.
     Levers queued: longer runs, sigma-guided curriculum, the
     battle inner loop (defection dynamics on the index
     territory), lr schedule.
  3. C0 logbook telemetry (capture -> encoding trace in bundles).
  4. Then N2 (chroma pair vs the 55% aliasing share) per phases.

  OPEN DECISIONS carried: D1 GCT-vs-LCT, D6 bell<->tesseract,
  3 Core AI SDK questions (Xcode 27 beta).

## Standing rules

  laws judge, losses train . classic always printed . 255n tripwire
  . G-a before belief . bell projection exact at every eval . D6
  (bell↔tesseract) still open and blocks nothing above.
