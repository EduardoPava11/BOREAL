# BOREAL

**A camera ISP built like a proof, aimed at Apple silicon: the ANE and
CPU/GPU shared memory.**

BOREAL is an iPhone camera app and a custom image signal processor. The
shutter captures a 4-frame RAW exposure bracket (12-bit Bayer DNGs) and
the pipeline — decode, maximum-likelihood fusion, multi-scale demosaic,
palette quantization — emits an animated GIF whose structure *is* the
ISP's native output: index maps against a scene-derived 256-color seed.
Every kernel is specified as law before it is code, and every port is
held bit-exact against shared goldens across four implementations
(Haskell spec, Python oracle, Swift, Metal).

## Where this is going: the ANE and unified memory

The end state is a pipeline where **the CPU, GPU, and Apple Neural
Engine work on the same bytes** — no copies, no format forks, one
artifact per model, one contract per kernel.

**Unified memory (CPU ↔ GPU) — in progress.** Apple silicon's shared
memory means the GPU can read the decoder's output in place. The Metal
index-map kernel already runs this way: pooled `storageModeShared`
buffers (grow-once, zero steady-state allocation), palettes in constant
memory, and pure-integer math so the GPU result is **bit-identical** to
the CPU reference — parity is proved by the gate on every run, not
assumed. The roadmap (`BOREAL-METAL-PRECISION-WORKFLOW.md`) drives the
rest of the ISP the same way: an integer/fixed-point contract at the
Q16 quantization boundary (P1) so demosaic + color can move onto the
GPU exactly (P2), with `MTLHeap` aliasing and page-aligned
`bytesNoCopy` uploads — one command buffer per frame, no CPU
round-trips, no staging copies.

**The ANE — the model's destination.** The trained seed network (V1H)
ships as a single fp16 weights package (`V1HW`) and climbs a runtime
ladder: **V1** Swift/Accelerate (landed — `im2col` + BLAS, gate-pinned
against a NumPy reference), **V2** Metal compute (the inference pass
joins the ISP's command buffer), **V3** Core AI on the **Apple Neural
Engine**. One artifact, three engines; promotion between tiers is gated
on judged-metric parity, because the learned path claims *tolerance*
correctness, never bit-exactness — the precision class is explicit in
the gate. The fp16 payload and the tiny bias-free convolutional
architecture are ANE-shaped on purpose.

Why this split matters: the ISP's math is exact and belongs to the
CPU/GPU integer domain; the model's math is statistical and belongs to
the ANE. BOREAL keeps both honest by giving each its own verification
contract instead of pretending they are the same kind of computation.

## The mathematics

- **The mosaic is a frequency multiplex** (Alleysson/Dubois): baseband
  luma plus chroma AM-modulated onto spatial carriers. The ladder's
  even-cell law is exactly the carrier-nulling condition; the render
  splits luma (512² rung) from chroma (128² rung — its own demosaic,
  16× larger cells, measured 3.5× less alias energy on screen moiré).
- **The Bin-Commutation Theorem** (`spec/Boreal/BinContract.hs`,
  machine-checked in exact ℚ): per-channel cell means factor through
  per-phase binning — `cfaBin ∘ β_b == cfaBin` at every aligned rung.
  Consequence: the 4×-binned mosaic is a *sufficient statistic* for
  every model rung, so the network's input contract has zero
  train/inference skew by proof, and quad-binned sensor readout is
  spec-legal by the same theorem.
- **The Neutral Test law** (NT): any composed camera→ProPhoto matrix
  must map `AsShotNeutral` to gray. One line of math that catches every
  white-balance/matrix composition error; verified on-device on every
  capture (`ntSpread` in each bundle, ~1e-7 in the field).
- **The fuse is the physical likelihood**: raw DNs obey
  `var(DN) = a·(DN − black) + b` (Poisson-Gaussian), the DNG
  `NoiseProfile` tag carries the calibrated `(a, b)` per frame
  (including dual-conversion-gain breaks, measured on real hardware),
  and bracket fusion uses the exact inverse-variance MLE weights with
  censored clipping — gradient descent on the sensor's own likelihood.
- **Temporal statistics**: the 4-frame cycle is a per-bin experiment —
  a noise meter, an alias discriminator (true chroma is stable under
  handheld tremor; aliased chroma flips), and a σ_time attention head
  for the model.

Research surveys with adversarially verified citations:
`BOREAL-DEBAYER-MATH-RESEARCH.md`, `BOREAL-RAW-LIKELIHOOD-RESEARCH.md`.

## The verification stack

| layer | what | strength |
|---|---|---|
| Laws | 20 Haskell suites (`spec/*/`), exact ℚ or pinned-order f64 | property / theorem |
| Goldens | one emitter → `fixtures/*.json` | canon |
| Oracle | independent Python recomputation | bitwise |
| Swift harness | kernels + Metal GPU parity (`spec/verify-swift`) | bitwise |
| Xcode suite | same legs through the iOS toolchain (`BOREALTests`) | bitwise |
| Trainer | NumPy pipeline vs the same goldens | bitwise |
| V1 engine | Accelerate forward vs NumPy reference | tolerance (declared) |
| Field | every capture bundle self-verifies (NT, fuse path, perf, manifest) | telemetry |

A device capture produces a bundle with a self-contained
`preview.html` (verdict lights, the product GIF, σ heatmaps, a perf
Gantt), binary planes, a SHA-256 manifest, and a narrated `log.txt`;
`tools/replay verify <bundle>` replays it on a Mac **bit-exactly**
(seed palette 256/256 on every bundle tested).

## Build & test

```
make setup        # xcodegen → BOREAL.xcodeproj
make build        # simulator build (camera code is compile-checked in sim)
make test         # the full gate: laws → goldens → oracle → Swift/Metal
                  #   parity → trainer parity, then the Xcode suite
make replay ARGS="verify <bundle-dir>"   # Mac replay of a device capture
```

Requires Xcode 26+, GHC (runghc), Python 3. Device runs need signing;
the run scheme is Release (perf numbers from Debug builds are
compiler-flag measurements, and the bundles stamp which one they are).

## Repo map

```
spec/            the laws (Haskell), golden emitter, Python oracle,
                 Swift/Metal parity harness
BOREAL/Kernels/  the pure-Swift + Metal kernel core (gate surface)
BOREAL/…         the app: capture, pipeline facade, preview, bundles
BOREALTests/     the same proofs through Xcode's toolchain
fixtures/        goldens + the pinned V1HW champion weights
nn/              the MLX training lab + NumPy parity
tools/replay     the Mac verdict CLI
scripts/         checked-in experiments (E1 demosaic crossover)
BOREAL-*.md      workflow docs and verified research surveys —
                 written as lab notes, statuses and dead ends included
```

The workflow documents are the honest history: what was measured before
it was built, which estimates were wrong, and which bugs the laws
caught (including a white-balance double-count that shipped in every
render until the NT law made it impossible).
