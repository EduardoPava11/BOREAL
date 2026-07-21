# Core AI on the ANE — verified research + the V3 alignment plan

> Deep-research sweep 2026-07-21: 20 sources, 98 claims extracted, 25
> adversarially verified (24 confirmed, 1 refuted). Primary sources:
> WWDC 2026 sessions 324/325/326 transcripts, Apple ML-research ANE
> articles, coremltools 9.0 docs, one ANE reverse-engineering study
> (arXiv, M1/M5 — A19 not directly measured). Local ground truth
> (this Mac, 2026-07-21): Xcode 26.6 / iOS SDK 26.5, `coremlcompiler`
> present, coremltools 9.0 installed, NO coreai toolchain — the
> Xcode 27 beta is not installed yet. Verification note: several
> sweep legs ran without the safety-review model; every claim used
> here was cross-checked against local tooling or multiple sources.
>
> THE GOAL (Daniel, 2026-07-21): Core AI, running the model on the
> ANE. This doc is the map from where BOREAL stands to that goal.

## 1. What Core AI is  [3-0 ×2]

Real and public since WWDC 2026 (sessions 324/325/326): the inference
framework powering on-device Apple Intelligence, opened to third-party
apps on iOS 27 / Xcode 27. "The next evolution of on-device AI
execution." The sessions never mention Core ML; coremltools (9.0)
never mentions Core AI. **Relationship formally unstated — treat as
sibling-with-successor-trajectory (interpretation, not sourced
fact).** Core ML remains mature and supported.

## 2. The artifact and toolchain  [3-0 ×4]

- **`.aimodel`** — a device-agnostic source representation,
  **specialized on-device at load** (segmented, planned, compiled per
  compute unit), cacheable (`AIModelCache`), or ahead-of-time via
  Xcode / `AIModel.specialize(contentsOf:)`. Specialization is the
  documented launch-latency hazard: keep it OUT of the capture flow.
- **Conversion**: `pip install coreai-torch` → `torch.export` →
  `TorchConverter` → `save_asset("X.aimodel")`. **No MLX or
  safetensors path exists** — MLX weights must be re-hosted in a
  PyTorch `nn.Module` first. `coreai-opt` does compression (fp16
  default; int4/int8/FP4/FP8 weights; QAT on the dev machine).
- **Swift API**: `AIModel(contentsOf:)` → `loadFunction(named:)` →
  `InferenceFunction`; `NDArray` I/O with non-escapable
  `NDArray.MutableView` for **memory-safe zero-copy buffer access**,
  optimal-layout queries and pre-allocated outputs to avoid layout
  conversions. This is the unified-memory story the README commits
  to, in Apple's own API shapes.
- **Verification**: the standalone **Core AI Debugger** runs the op
  graph on a chosen target/compute unit and validates **per-op
  numerics against the PyTorch reference (PSNR)** — Apple's tooling
  independently arrives at the house doctrine (learned path =
  tolerance parity against a reference, judged per op). Plus a Core
  AI Instruments template for load/specialization tracing.

## 3. ANE fit of the V1H architecture  [3-0; hardware claims: one
   reverse-engineering study, M1/M5]

The encoder + palette slice — the ship slice — is **already
ANE-shaped**:

| V1H piece | ANE verdict |
|---|---|
| grouped stem 16→192, g=4, 3×3 | native (groups must divide channels: 4∣16 ✓) |
| four stride-2 3×3, d=96 | native (strided conv first-class) |
| 1×1 palette/fuse heads | Apple explicitly recommends 1×1 conv over linear |
| leaky-ReLU slope 1/16 | native (activations via piecewise-linear tables) |
| bias-free, fp16 weights | fp16 is the safe default (V1HW is already fp16) |

Required changes: **NHWC → NCHW** (layout constraint: 4D
channels-first, wide contiguous 64-byte-aligned last axis — the
256-wide spatial axis last is fine), **static shapes** (256×256×16 —
already static), and avoiding reshape/transpose chains — the ONE
hazard is the patch predictor's pixel-shuffle expansion, which is
**lab-side, not in the ship slice**. If patches ever ship, restructure
the shuffle as convolution.

Refuted (0-3), do not rely on: "ANE arithmetic is provably fp16
end-to-end." Exact ANE datapath precision is unverified — one more
reason the learned path's tolerance-parity doctrine (never
bit-exactness) is correct.

## 4. What Core AI does NOT have (verified absences, sessions only)

- **No compute-unit placement / ANE-residency API** (no MLComputeUnits
  equivalent documented). The Debugger's run-on-specific-hardware mode
  is the closest residency check. → the runtime-ladder promotion gate
  stays JUDGED metrics + measured latency, not a residency flag.
- **No on-device training/fine-tuning** in any session — Core AI as
  documented is inference-only. The personalization north star
  (on-device look-learning) stays on MLX-on-device or waits; open
  question registered.
- **No latency/power numbers** for small CNNs on A19 — B6 measures.

## 5. The plan: B6 split into V3a / V3b

**V3a — Core ML now (Xcode 26.6, this Mac, today):**
1. Re-host V1H encoder+palette in PyTorch, NCHW, load V1HW fp16
   weights; parity vs `nn/v1/forward_ref.py` (the same tolerance gate
   the V1 engine passed).
2. `coremltools` → `.mlpackage`; `MLComputePlan` on this Mac's ANE →
   **empirical per-op residency for OUR architecture** without waiting
   for Xcode 27.
3. This PyTorch re-host is not throwaway: it is the exact input
   `coreai-torch` needs, and the Core AI Debugger validates against
   the same PyTorch reference. One artifact feeds both paths.

**V3b — Core AI when the Xcode 27 beta lands:**
4. `pip install coreai-torch`; `torch.export` → `.aimodel`;
   Debugger per-op PSNR vs the PyTorch reference.
5. Swift: CoreAI framework behind the V3 tier — `AIModel` specialized
   at app launch (cached, never in the capture flow), `NDArray`
   pre-allocated in the queried optimal layout (zero-copy with the
   binned input the BC theorem defines).
6. Promotion V1 → V3 by the standing rule: judged-metric parity vs
   the V1 Accelerate engine + measured latency/power in the bundle's
   perf block. V2 Metal remains in the ladder but may be SKIPPED if
   V3a/V3b arrive first — promotion is by need, and the ladder never
   promised all rungs would ship.

## V3a EXECUTED (2026-07-21, same day)

`nn/v1/torch_host.py` — the keystone, run end-to-end on this Mac:

1. **PyTorch re-host** (NCHW, bias-free, V1HW fp16 weights permuted
   (C_out,kH,kW,C_in/g) → (C_out,C_in/g,kH,kW)): parity vs the numpy
   reference **maxAbs 6.26e-7** — the same gate the V1 engine answers
   to, passed with three orders of headroom.
2. **`.mlpackage`** (coremltools, fp16, static 1×16×256×256,
   iOS17 target): `runs/v1h_slice.mlpackage` (regenerated by the
   script; not a tracked artifact).
3. **MLComputePlan verdict: 12/12 costed ops NeuralEngine-preferred**
   — every conv (grouped stem included) and every leaky-ReLU 1/16,
   zero CPU/GPU fallbacks. The §3 predictions confirmed empirically.
4. **Measured latency** (M-series ANE, macOS): **1.99 ms/inference**
   with compute units ALL vs 4.80 ms CPU-only — vs 69 ms on the V1
   Accelerate engine: **~35× over the shipping tier**. (A19 numbers
   still pending a device measurement — open question 2 stands.)

The same PyTorch module is the `coreai-torch` input and the Core AI
Debugger reference for V3b, unchanged.

## Open questions (carried)

1. Residency/placement API in the shipping iOS 27 SDK docs (vs the
   sessions)?
2. A19 latency/power for ~1M-param 256×256×16 CNN under Core AI;
   does specialization caching matter per-capture?
3. MLX → .aimodel path, or a formal Core ML succession statement?
4. Any sanctioned on-device personalization path in 2026 (the north
   star depends on it)?

## Refuted during verification

- ANE fp16-end-to-end arithmetic with pre-multiply dequantization
  (0-3) — quantization is storage/bandwidth, arithmetic precision
  unverified.
