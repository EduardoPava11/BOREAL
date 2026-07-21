# BOREAL Temporal-Bayer Workflow — THE PIVOT

North star: **the cycle, not the frame, is the atomic unit of
information.** The bins are exact spatial reducers and they are DONE
(E1 verdict: box means sub-JND on real scenes at every rung; the
even-cell law `(side/r) % 2 == 0` in msRungs IS the whole-Bayer-period
carrier-nulling condition). What the bins concede is known, measured,
and *temporal in nature* — so the model program pivots onto the time
axis. Four EV-bracketed mosaics with handheld tremor are not "4 shots
to fuse"; they are a per-bin noise experiment, an alias discriminator,
and a self-supervision axis that no single mosaic contains.

Foundation (all measured/verified, 2026-07-19):
`BOREAL-DEBAYER-MATH-RESEARCH.md` (multiplex identity, E1 crossover,
σ-as-cell-Nyquist-energy) · `BOREAL-SIGNAL-LADDER-WORKFLOW.md` (fuse
+19.1 dB, bin +18.1 dB@256², ≤6 effective bits ride time if
blue-in-time) · NT law (colors trustworthy from here on — all pre-fix
bundles are color-poisoned and are NOT food).

> STATUS (2026-07-19): **T1 EXECUTED** — Boreal/TemporalBayer.hs (TB1-TB5
> green: static exactness, noise-meter window, 900× alias separation on
> the fixture, exact dyadic EV-relabel invariance, frame-order ≤1e-9),
> `temporalbayer_golden.json` emitted (side-64 cycle: zone plate + flat
> gray + shift-invariant color ramp, LCG shot noise, dyadic-quantized),
> Python oracle bit-exact, Kernels/TemporalKernel.swift bit-exact via
> the harness leg; full gate + sim build green.
> **T2 EXECUTED (wiring)** — reduce() computes per-frame ceiling channel
> means while each mosaic is alive (memory flat) → temporalStats;
> Outcome carries TemporalSummary {gain, sigmaTime 16², dDeciles};
> burst.json cycles[] and single-cycle report.json both carry the
> "temporal" block. Deferred from the T2 sketch: per-bin (mean,var)
> stacks ride only when the trainer consumes them (no speculative
> format).
> **DEVICE FINDING (Mac replay of the 2026-07-19 cycle):** ĝ = 1.37e-1 —
> ~1000× shot-noise scale. On HANDHELD cycles global tremor inflates
> every bin's cross-frame variance, so the robust median reads the
> TEMPORAL FLOOR (noise + typical motion), not pure shot noise (the
> fixture's ≤50%-moving assumption fails globally). D is normalized by
> that same floor and still RANKS correctly (real-cycle deciles: median
> 0.37, p90 15, max 177; σ_time max 51.8 = moving edges / alias-risk
> cells) — the discriminator/gate role stands; the absolute "D≈1 =
> noise-only" calibration and the loss-weighting role need T1b: a
> motion-robust noise estimator (e.g. closest-EV frame pairs, or quiet
> within-frame patches), designed AFTER T0's clean corpus exists.
> Open: T0 (Daniel-gated re-capture), T1b, T3, T4.

## The three temporal signals (the why, in one screen)

1. **Noise meter.** After exact EV normalization the 4 frames are 4
   estimates of one scene-linear value per bin, at 4 points on the
   shot-noise curve (var ∝ signal/EV). Per bin, per cycle: a measured
   mean-variance experiment. Joint demosaic-denoise methods must
   ASSUME this; the cycle MEASURES it.
2. **Alias discriminator.** E1's one failure mode — false color on
   fine gray detail from per-channel sublattice phase offsets — is
   STATIC per frame. Handheld tremor shifts the scene against the
   lattice between frames: true chroma is stable across frames, alias
   chroma flips with sampling phase. Cross-frame chroma variance,
   normalized by the noise meter, separates them. (Temporal analogue
   of Dubois's two-copy C2 asymmetry; same physics as handheld
   multi-frame super-res.)
3. **Self-supervision axis.** Predict frame j's record from frame k's
   + the EV delta; the irreducible residual is noise + motion, and
   everything the model squeezes below that is learned scene
   structure. The H-JEPA jump has a natural unit: the cycle. Palette
   placement + churn allocation (the model's whole job — palette VQ is
   the irreducible loss) are DEFINED on this axis.

Non-goals: touching the bins (ladder/rungs/box means frozen — E1);
HA ceiling correction in-app (remains a σ-gated spec'd option); any
A/B surface in the app (decree — comparisons live in bundles/Mac);
512 rung; CCT interpolation.

Standing constraints unchanged: spec-first (law → golden → oracle →
port), Import-DNGs as sim lever, compile-check camera code, one
product surface (capture → GIF).

---

## Phase T0 — Clean corpus (the gate on everything)

The NT fix means every pre-2026-07-19 bundle is color-poisoned. No
temporal law gets fitted to poisoned chroma.

- Device re-capture: fresh 64-bursts + single cycles across scene
  types — specifically including fine gray texture (fabric, screens,
  print) where the alias discriminator has something to discriminate,
  and low-light where the noise meter earns its keep.
- Bundles land via the G6 valve (burst.json + frames.bin + fractal.bin
  already shipping); single-cycle bundles carry DNGs = full ground
  truth for the Mac oracle.
- Exit gate: ≥ N re-captured bundles on the Mac, NT-clean (report.json
  neutral check green), spanning the scene matrix; record.py detects
  and refuses pre-fix bundles.

## Phase T1 — The temporal laws (Boreal/TemporalBayer.hs, TB laws)

Spec-first math for the three signals. Oracle food: nn/v1/synth.py
already builds 4-frame EV cycles with exact shot noise — extend it
with (a) known sub-pixel shifts, (b) zone-plate scenes, (c) true-chroma
patches. Ground truth is exact by construction.

- **TB1 (unbiased stack):** after exact-rational EV normalization,
  per-bin per-channel means across the 4 frames estimate ONE value;
  on synth, the cross-frame variance regressed on the mean recovers
  the injected shot-noise gain (slope law, exact tolerance).
- **TB2 (noise meter):** per-bin n̂ = predicted variance at the bin
  mean from the cycle's own mean-variance fit; χ² law on synth.
- **TB3 (alias flip):** define D = Var_t(chroma) / n̂ per ceiling bin.
  Law: on synth zone-plate cycles with sub-pixel shifts, D at
  carrier-site bins ≫ 1; on true-chroma patches, D ≈ 1 (noise-
  consistent). Golden carries the D maps + an ROC threshold; the law
  pins separation at the golden threshold.
- **TB4 (σ_time):** D aggregated to the 16² grid = the σ_time head —
  the temporal twin of the existing σ (which is cross-SCALE energy at
  cell Nyquist). Law: σ_time is invariant to global EV scaling and to
  frame order.
- Exit gate: TB laws green in runghc; `temporalbayer_golden.json`
  emitted; Python oracle re-derives bit-exact; Swift port
  (Kernels/TemporalKernel.swift) passes the harness leg; full gate
  green.

## Phase T2 — The record grows time (bundle v2, small)

The corpus valve ships the temporal statistics WITHOUT blowing up
bundle size:

- Burst bundle adds per-cycle: per-bin (mean, var) stacks at 16²
  (tiny), the σ_time grid (256 floats), and n̂. Full-res chroma planes
  do NOT ride the burst bundle (32 MB class) — single-cycle bundles
  already carry DNGs, so the Mac recomputes anything from photons.
- report.json gains "temporal": {noiseFit, sigmaTime, D-stats} beside
  the existing σ and perf blocks.
- Exit gate: a device burst bundle carries the temporal block; Mac
  replay recomputes it bit-exact from the single-cycle DNGs.

## Phase T3 — Training food rewire (nn/v1)

- record.py/synth.py emit the cycle as the sample: 4 × (seedL,
  patchesL) + EV trace + per-bin temporal stats; identical shape from
  synth and device (the standing rule).
- New objective term: cross-frame prediction — embed frame k, predict
  frame j's seed/patch record conditioned on ΔEV(k→j); loss weighted
  by the noise meter (don't pay to predict photons). The supervised
  warm anchor stays (house lesson: collapse otherwise).
- Hard metrics extend: existing χ²/homeShare/ΔE PLUS per-σ_time-decile
  ΔE — the model must be judged WHERE the classic path is weakest.
- Exit gate: G-a stays green (trainer bit-exact on all goldens incl.
  TB); a smoke run trains stably with the temporal term on synth.

## Phase T4 — The judge moves to time (battle v2)

- battle.py: model palette/churn vs classic, scored on real
  re-captured bundles, reported PER σ_time DECILE. The claim to beat:
  classic box + D1 seed is already sub-JND on LOW-σ_time content (E1),
  so the model earns its slot ONLY by winning the high-σ_time tail
  (carrier-site false color, noisy shadows) without losing the body.
- The σ-gated HA ceiling correction (research doc §E1 option) enters
  ONLY if the model does NOT claim that tail and real bundles show the
  false-color signature — one mechanism, not two, gets the job.
- Exit gate: a written verdict per corpus drop: model wins tail
  (ship path: promote model palette), or classic holds (ship path:
  σ-gated correction spec begins, model stays in the lab).

---

## Order and effort

T0 is Daniel-gated (device in hand) and unblocks everything — start
immediately. T1 is the real spec work (the TB laws + synth extensions;
the D/ROC design is the thinking). T2 is small once T1's kernels
exist. T3/T4 are the CoreAI program refocused — they replace "more
training runs on static records" as the next model move.

Dependency spine: T0 → T1 → T2 → T3 → T4 (T2 can overlap T3).

Relation to standing docs: `BOREAL-COREAI-TRAINING-WORKFLOW.md` stays
the model-architecture reference (four-net program, V1H); THIS doc
re-sources its food (cycles, not frames), its objective (cross-frame
prediction, noise-weighted), and its judge (σ_time deciles). The
GIF-ISP workflow's product surface is untouched — the pivot is
capture-record + model program, zero UI.
