# BOREAL Metal-Precision Workflow — the precision descent

North star: **the ISP core moves DOWN — from f64 CPU Swift to a
fixed-point integer Metal pipeline with a PROVED precision budget per
stage.** Nothing about the product changes (capture → GIF, 64 frames of
256×256, demosaic at every scale). What changes is WHERE the math runs
and HOW its exactness is guaranteed: today bit-exactness is a property
we inherit from f64 on the CPU; after this workflow it is a property we
prove at the Q16 quantization boundary, which frees the implementation
to be integer Metal — faster, cooler, and exact by construction.

Standing constraints carry over unchanged: spec-first for every kernel
(law → golden → oracle → port), Import-DNGs as the sim lever, camera
code compile-checked in sim, device runs when signed. The CPU Swift
kernels are NEVER deleted — they remain the reference the gate replays
(the MetalIndexMapper precedent: GPU result bit-identical to
`BorealKernels.indexMap`, CPU as fallback).

Why this workflow exists (honest note to self): these five phases are
also the five sentences of the Camera Imaging Software Engineer story —
measure latency/power, define a precision contract, move the ISP to
Metal, gate the budgets, fuse the NN into the GPU pass. Every phase
ends in a number a report bundle carries, not an adjective.

> STATUS (2026-07-19): **P0 EXECUTED** (gate green, sim build green).
>   • Perf collector landed (Pipeline/Perf.swift): os_signpost intervals on
>     every facade stage (com.daniel.boreal/perf), wall-clock samples,
>     thermal trajectory, phys_footprint peak; `perf` block now rides BOTH
>     report bundles.
>   • **G6 CLOSED**: the 64-burst writes a bundle — burst.json (EV traces,
>     per-frame χ²/homeShare, churn counts, σ, seedL, perf) + frames.bin
>     (the 64 index maps, u8) + fractal.bin (patch-major L, Int32 LE) +
>     burst.gif; DNGs stay out (the 1.6 GB cliff). Share surface wired.
>   • P2 slice pulled forward: MetalIndexMapper pools its buffers (grow-only,
>     zero steady-state allocation; was 7 makeBuffer copies per frame),
>     palettes ride setBytes into `constant` space, exact d==0 early exit;
>     GPU ms recorded per dispatch. Gate parity still bit-exact (Mac GPU).
>   • Latency: per-frame fast path `msSeedAndCeiling` (seed + ceiling rungs
>     computed directly; residual stack telescopes away — MS3 corollary,
>     parity gate-checked) replaced msEncode+3×msDecode in the burst render:
>     **5.09 ms → 1.68 ms (3.03×) per frame at 2048², Mac M-series,
>     bit-identical** (device numbers pending next signed run's bundle).
>   Still open in P0: MTLCounterSampleBuffer timestamps (command-buffer
>   gpuStart/EndTime is the current source), the one-tap .gputrace toggle,
>   and budgets.json (P3 — needs a device baseline bundle first).

---

## The precision ladder (current state, for orientation)

    sensor    u16    12-bit mosaic, black 528, white 4095 (device-verified, c386663)
    normalize f32    (s − black) · invE · scale        CPU
    demosaic  f64    per-cell CFA means, y-outer walk  CPU (concurrentPerform)
    color     f64    camToPP · ProPhoto → OKLab, owned cbrt (4 Newton steps)
    quantize  Q16    Int32 planes — THE contract boundary
    indexMap  i64    exact integer, ties→lowest        GPU (the one Metal kernel)
    wire      u8     GIF89a indices + GCT

Everything above the Q16 line is f64 because f64 was free on CPU. Apple
GPUs have NO f64. The insight this workflow is built on: **the contract
never needed f64 — it needs any arithmetic that lands the same Q16
bucket.** Sums of ≤ 128² samples of 12-bit data fit exactly in i32;
squares and dot products fit in i64; the only genuinely hard op is cbrt.

## Phase P0 — Instrumentation floor (measure before touching anything)

No optimization claim without a before/after pair. This phase produces
the "before".

- `os_signpost` intervals around every pipeline stage: decodeDNG,
  normalizeMosaic, msEncode (per rung — the 256 rung will dominate),
  indexMap, gifEncode, cycle-reduce, whole-burst. Subsystem
  `com.daniel.boreal`, category `perf`; visible in Instruments.
- GPU-side truth: `MTLCounterSampleBuffer` timestamp sampling around the
  index-map dispatch (and every kernel P2 adds). Command-buffer
  `gpuStartTime`/`gpuEndTime` as the coarse fallback.
- Thermal + memory: `ProcessInfo.thermalState` sampled at burst start /
  every 4 cycles / end; peak footprint via `task_vm_info.phys_footprint`
  (the number Jetsam actually kills on).
- report.json grows a `perf` block: per-stage ms (median over the
  burst's 16 cycles), GPU ms, thermal trajectory, peak footprint. The
  burst report bundle (G6 — must close as part of this phase) carries it.
- Programmatic GPU capture: a debug-menu toggle that wraps ONE cycle in
  `MTLCaptureManager` → .gputrace on device, so shader debugging is one
  tap, not an Xcode ritual.

Exit gate: a signed device 64-burst produces report.json with the full
perf block, and an Instruments trace shows the named intervals. These
numbers are the baseline every later phase is judged against.

## Phase P1 — The integer contract (the precision law, before any Metal)

Re-found the demosaic→OKLab chain on integer/fixed-point arithmetic with
a proved error budget. Spec-first: this is a Haskell law + golden before
it is a Swift or Metal line.

- **IC1 (contract boundary law).** Conformance is defined at the Q16
  planes: an implementation is correct iff its Q16 L/a/b match the
  golden exactly. Everything upstream is free.
- **IC2 (exact accumulation).** Per-cell CFA sums are exact integers:
  Σ of k² samples, k ≤ 128, sample < 2¹² ⇒ sum < 2²⁶ — fits i32 with
  headroom; carry the mean as the rational (sum, count), never divide
  early. Black subtraction in integer: Σ(s) − n·black.
- **IC3 (fixed-point color).** camToPP and the OKLab matrix chain in
  Q-format (Q2.30 coefficients, i64 dot products); EV normalization as
  one rational scale per frame folded into the final Q16 conversion —
  ONE rounding site per plane value, not five.
- **IC4 (owned integer cbrt).** The one hard op. Two candidate designs,
  decided by oracle, not preference:
    (a) integer Newton on Q16.48 with a proved monotone bracket, or
    (b) 12-bit LUT + one Newton polish step, with an exhaustive sweep
        proving the Q16 result matches ownedCbrt(f64) on the ENTIRE
        reachable input domain (the domain is finite — LMS values are
        bounded by the matrix norms times the 12-bit range; enumerate).
  "Bit-exact everywhere" stops meaning "same IEEE ops in 4 languages"
  and starts meaning "same integers, no IEEE anywhere".
- Oracle: Python/Haskell integer reference; goldens regenerated ONCE
  from the f64 path, then frozen — the integer path must hit them. If
  any Q16 value differs, the law says which rounding site to fix; if it
  is genuinely unreachable, THAT becomes a documented golden revision
  with the delta enumerated (expected: zero or single-ULP cbrt edges).

Exit gate: `make -C spec gate` green with the integer oracle; a written
precision-budget table (per stage: representation, max error in ULPs of
Q16, rounding site) checked into spec/. This table is the artifact —
the interview answer to "how do you know your GPU port is right".

## Phase P2 — The Metal ISP (one command buffer per frame)

Port the IC kernels to Metal. Integer math on GPU is exact (the
MetalIndexMapper comment already states the law), so P1 makes this port
mechanical rather than heroic.

- Kernels (one .metal source, still compiled-from-string at init so the
  CLI harness and the app share one source of truth):
    `rung_reduce`   — per-cell CFA sums via threadgroup reduction; one
                      dispatch per rung, mosaic read ONCE per rung from
                      device memory (later: one read total, all rungs
                      accumulated in a single pass — measure first).
    `color_oklab`   — IC3+IC4 in registers; writes Q16 planes.
    `index_map`     — existing kernel, optimized: palette in `constant`
                      address space (256×3 i32 = 3 KB — lives in the
                      constant cache instead of device loads per pixel),
                      planes packed int3 for coalescing, early-exit on
                      d == 0. Tie law and ascending order UNCHANGED.
- Scheduling: per frame, ONE command buffer: upload mosaic →
  rung_reduce ×5 → color_oklab → index_map → readback indices. No CPU
  round-trips inside a frame; cycles stay serial (the existing
  memory-cliff discipline).
- Memory discipline (the JD's "memory-sensitive environment", made
  concrete):
    - `MTLHeap` sized once per burst; all per-frame buffers suballocated
      and aliased — frame n+1 reuses frame n's allocations. Zero
      steady-state allocation inside the burst loop (today
      MetalIndexMapper calls makeBuffer 7× per frame — six of those are
      copies of arrays we already own).
    - Mosaic upload via `makeBuffer(bytesNoCopy:)` on page-aligned
      storage (unified memory: the GPU reads the decoder's output, no
      blit, no copy).
    - Law: peak phys_footprint during a 64-burst < 350 MB (baseline from
      P0; tighten once measured).
- Fallback law unchanged: Metal unavailable or any kernel fails → CPU
  reference; the gate replays BOTH paths against the goldens on the Mac.

Exit gate: device burst where the entire per-frame pipeline after DNG
decode runs on GPU; P0's perf block shows the before/after (target,
stated up front and revised only with data: cycle-reduce time −50%,
thermal trajectory strictly cooler at equal work); gate green on CPU
and GPU legs.

## Phase P3 — Budget laws (perf regressions become gate failures)

Turn P0's measurements into laws, so performance is CI-checked culture,
not a one-time sprint.

- Latency laws (device, canonical 2048 mosaic): per-stage budgets in a
  checked-in `spec/perf/budgets.json`; the device verify leg
  (spec/verify-device) compares report.json's perf block against them.
- Power proxies: whole-burst GPU-busy ms and thermal end-state as gated
  budgets; MetricKit (`MXMetricPayload`) subscription logs cumulative
  CPU/GPU time per day of field use — the honest long-horizon power
  story, since instantaneous watts aren't exposed.
- The G4 round-trip law closes here too (system ImageIO decoder == our
  decode on the emitted GIF) — correctness and perf gates ride the same
  report bundle.

Exit gate: an intentionally-pessimized build (e.g. force CPU path) FAILS
the perf gate; the normal build passes. A gate that cannot fail is
decoration.

## Phase P4 — The net joins the command buffer (DNN × GPU-ISP fusion)

The COREAI program (L-net, a-net, b-net, Composer — N0 done) currently
lives in MLX on the Mac. This phase ships inference on device INSIDE the
P2 command buffer — the palette head runs as one more compute pass
between color_oklab and index_map.

- Export: weights from nn/v1 → Q15 (or int8 with per-channel scales —
  decide by parity measurement, not taste) in a versioned binary blob;
  loader validates shape/version/checksum.
- Inference kernel: hand-written MSL matmul/conv for the seed-encoder +
  palette-head sizes (they are tiny — V1H is (16×16)×(16×16); an MPS
  dependency would be heavier than the kernel). Accumulate i32, requant
  to Q15 per layer, precision budget documented in the P1 table style.
- Parity harness: Mac MLX f32 output vs device Metal quantized output;
  law states the tolerance (Tesseract precedent: MLX→Metal debayer at
  2.98e-7 — this repo's bar is stated numerically the same way) and the
  gate replays it against a fixture cycle.
- Product wiring: model palette vs classic 16×16 seed, judged per
  report bundle on the Mac (the corpus valve G6 feeds this) — the
  model earns its slot with chi²/homeShare/dE numbers, exactly the
  battle.py discipline, now with device-computed outputs.

Exit gate: a device burst where the palette head ran on GPU between the
ISP passes; report.json carries model-vs-classic metrics AND the perf
block shows the net's added ms (budget: the net must fit inside the
cycle's existing idle — no burst slowdown).

---

## Order and effort

P0 is days and unblocks everything (do G6 inside it). P1 is the real
thinking (the cbrt design and the rounding-site audit); P2 is mechanical
once P1's goldens exist. P3 is small. P4 is its own arc but its Metal
side is small once P2's buffer/heap scaffolding exists.

Dependency spine: P0 → P1 → P2 → P3, P4 (P3 and P4 independent).

## What this buys outside the repo (the JD crosswalk, kept honest)

Every claim below becomes provable from report bundles and the gate —
no invented credentials, numbers only after they are measured:

- "GPU-based image processing algorithms using Metal" — P2: a five-
  kernel integer Metal ISP, bit-exact against a spec'd contract.
- "optimize the pipeline for reduced latency and power" — P0+P3:
  signpost/counter instrumentation, budget gates, before/after numbers.
- "performance- and memory-sensitive environment" — P2: MTLHeap
  aliasing, zero-copy unified-memory uploads, phys_footprint law.
- "implement and optimize deep neural networks ... combine them with
  GPU-based image processing" — P4: quantized on-device inference fused
  into the ISP command buffer, MLX↔Metal parity harness.
- "debugging techniques on embedded mobile platforms" — P0: signposts,
  programmatic .gputrace capture, thermal telemetry; plus the standing
  golden-gate culture.
- "strong programming skills in Objective-C or C++" — MSL IS C++14;
  after P2 the hot path of this codebase is C++-family GPU code.
