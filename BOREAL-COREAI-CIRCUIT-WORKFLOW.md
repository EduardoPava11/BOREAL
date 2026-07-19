# BOREAL Core AI Circuit — capture encodes, Core AI composes, the regimen learns

Date: 2026-07-18. The workflow that CLOSES THE LOOP the other docs
describe in pieces: the app encodes what it captures and SUBMITS it to
Core AI on the phone; every capture feeds a training regimen
sophisticated enough to deserve the data; the refreshed model ships
back as data. Two requirements anchor the design (Daniel):

  REQ-1  the app encodes the DNG and submits to Core AI
  REQ-2  the training regimen is sophisticated — a real curriculum
         with lineage, judges, and an outer loop, not a script

Standing canon referenced, not duplicated: the four nets + three-tier
boundary (BOREAL-COREAI-TRAINING-WORKFLOW.md), the regimen R0-R6 +
equilibrium judge (BOREAL-TRAINING-REGIMEN-WORKFLOW.md), the N-law
input contract (Boreal.CycleSet, cycleset_golden.json), the fractal
record (N0, nn/v1/record.py), determinism policy (learned path claims
no bit-exactness; classic = exact reference and fallback forever).

---

## Part A — REQ-1: the app encodes the DNG and submits to Core AI

The encode is ALREADY LAW; this part wires it to the model runtime.

### A1 — Encode (device, exact substrate; landed pieces)

Per 4-frame cycle, on the phone, in our kernels (never inside the
.aimodel — the exact substrate stays ours):

  DNG x4 --DNGKernel--> mosaics (BGGR, 12-bit, black 528/white 4095)
    --GeometryKernel--> canonical crop (CS laws; 4032x3024 -> 2048^2,
                        even origin — gate-verified vs geometry.json)
    --FuseKernel------> EV ratios (exact, EV laws) + per-frame
                        normalize (1/e_t — N4 equivariance input)
    --CycleSet--------> the 16ch phase tensor (N1-N5; cfaBin keystone:
                        the input CONTAINS the classic baseline)
    --FractalKernel---> the (16x16)x(16x16) record + BA5 deltas (N0)

Exit gate A1: the device tensor replayed on the Mac equals the
trainer's loader bit-exact (cycleset golden + record.py contract —
G-a's device leg). Needs the ONE re-capture (standing).

### A2 — Submit (device, Core AI runtime)

- Asset: ONE .aimodel, FOUR entry points (L, a, b, compose), loaded
  via AIModelCache; all four on one serialized ComputeStream.
- Call graph per cycle (budget ~200 ms at the 4-frame cadence):
  tensor -> NDArray -> L-net -> (a-net, b-net conditioned on frozen L
  latents) -> Composer -> {seed latents, ceiling latents, temporal
  deltas}. fp16 NDArray acceptable (learned path claims no
  bit-exactness); the three SDK questions (zero-copy MTLBuffer,
  metal-package-builder, tiny-net latency) resolve in the Xcode 27
  beta — until then the classic path IS the product path.
- The exact substrate closes the loop OUTSIDE the model: bell
  projection (B laws) in our kernel, index decisions walk-windowed
  (DW/TG2), BA5 delta lists re-derived and round-trip-asserted, GIF
  wire byte-exact (W laws). The .aimodel proposes; the laws dispose.
- Classic A/B standing: every Core AI cycle renders BOTH paths in the
  Phase-1 preview (composed rungs vs classic rungs, same capture);
  classic remains the deterministic fallback on any load/latency
  failure — the app NEVER requires the model to produce a GIF.

Exit gate A2: one device capture -> composed 64x256^2 GIF via the
.aimodel with classic A/B visible; kill-switch verified (asset absent
=> classic path, no UI degradation).

### A3 — The corpus valve (device -> Mac)

- Every burst auto-emits the report bundle (fractal records + EV trace
  + binomial/homeShare readouts = recorded classic baselines).
- Transport: AirDrop now (manual, works today); iCloud drive folder
  when volume justifies it (D8, Daniel).
- Mac ingest: record.py validates (one schema, synth == device);
  invalid/pre-N0 bundles are named and refused, never silently
  dropped.

Exit gate A3: a bundle captured today trains tomorrow's run with zero
hand-editing; the loader's refusal messages are the only manual step.

---

## Part B — REQ-2: the sophisticated regimen (beyond R0-R6)

R0-R6 + the equilibrium judge remain governing. This part adds the
discipline that five controlled runs (2026-07-18) proved necessary.

### B1 — The experiment ledger (one axis per run)

- Every run is a CONTROLLED experiment: one axis changes, flags are
  the record, the champion config is explicit (currently: plain
  anchored, anchor FULL — decay lost; battle-CE lost at diffuse w;
  late-CE and usage-matching are a wash — all on record in c5f7c9a).
- Every run emits metrics.jsonl (start/eval/final events, flushed) +
  a rolling checkpoint; watch.py is the cockpit (`--follow`).
- NEGATIVE results are ledger entries, not embarrassments — they
  freeze dead axes so no session re-walks them.

### B2 — The capacity ladder (the live axis)

- All loss-shaping variants plateaued at dE ~0.0104 => the regime is
  capacity/data-bound. Ladder: d=24 (52k) -> d=48 (169k, in flight)
  -> d=96 IF AND ONLY IF the d=48 10k run moves the plateau; then
  depth (stem 3-conv) before width beyond 96. RES_GAIN is the second
  rung of the same axis (0.1 -> 0.3 in flight; learned gain only if
  static gains plateau).
- Promotion rule: a rung is promoted only on the equilibrium-layer
  gate vs the SAME held-out probe (never against a moving target).

### B3 — Data regiment (synth annealing into real)

- Synth stays device-real (12-bit ADC, measured EV ratios, ETTR
  coupling) with the perf floor from cf6bf83 (worker pool — the M3
  Max was 76% idle; now GPU-bound).
- Real photons anneal in 80:20 -> 20:80 (R5) once bundles flow (A3);
  the device's OWN binomial/homeShare readouts are the per-bundle
  classic baselines — the bar travels with the data.
- Augmentation: phase-preserving only (BayerUnifyAug coset shifts +
  flips, I4); anything that breaks CFA phase is forbidden by law, not
  by taste.
- sigma-guided sampling returns WHEN real bundles exist (real sigma
  from reports; the synth sigma-curriculum lost as a loss weight —
  it may yet win as a SAMPLER).

### B4 — The judges (three, never fewer)

  1. G-a parity — the trainer's ops == the goldens, every change.
  2. The equilibrium judge — chi^2_eq / dE_eq / homeShare_raw vs
     clean classic, held-out, per-scene, 95% dominance (R4). The
     collapse tripwire (255n) aborts loudly.
  3. The device judge — verify-device replay + on-device A/B in the
     preview (A2): the ONLY judge that can retire the classic path,
     and it never fully does (fallback forever).

### B5 — The outer loop (evolution over nets — N5, operationalized)

- MAP-Elites archive over net variants; dimensions: band-distance_eq,
  dE_eq, churn naturalness. Mutation + retraining on the Mac; the
  shipped .aimodel carries a small variant archive; the phone SELECTS
  per scene (tier 2a — selection is inference + bookkeeping).
- Every device capture adds selective pressure: its bundle scores the
  incumbent archive and seeds the next generation's environment.

### B6 — Ship (the refresh is data, not a release)

  MLX weights -> safetensors -> PyTorch mirror -> torch.export ->
  coreai-torch -> ONE .aimodel (4 entry points) -> xcrun coreai-build
  -> AIModelCache refresh on device.
- Parity smoke at the mirror: the cycleset golden pushed through the
  PyTorch mirror must match the MLX forward within fp tolerance
  BEFORE export (the G-a idea, applied to the bridge).
- A refreshed .aimodel that loses the on-device A/B does not ship —
  the archive keeps the incumbent (B5 selection handles regression).

---

## Order of execution

  1. (Daniel) ONE device re-capture -> first real fractal bundle
     (unblocks A1's exit gate, B3's real leg, B4's device judge).
  2. d=48/RES_GAIN-0.3 10k verdict (in flight) -> B2 ladder decision.
  3. C0 logbook telemetry (capture->encode trace in bundles) — the
     circuit's flight recorder.
  4. A2 submit path behind the Xcode 27 beta (SDK questions); classic
     A/B preview surface first (it's also gap G2's fix — the burst
     must route into the preview for A/B to mean anything).
  5. B5 archive once TWO variants beat noisy-classic on the gate.

## Decision points (Daniel)

- D8  corpus transport: AirDrop manual vs iCloud auto (default:
      AirDrop until >1 bundle/day).
- D9  NDArray precision on device: fp16 (default) vs fp32.
- D10 cadence: Core AI per cycle (4 frames) vs per burst (16 cycles)
      — per cycle is the design; per burst is the fallback if the
      200 ms budget fails on hardware.
