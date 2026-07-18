# nn/ — the V1-H training lab (MLX, Mac)

V1 is the smallest H-JEPA: (16x16) x (16x16) = 256x256 — a seed encoder,
a palette head, and a shared patch predictor across one jump. See
BOREAL-NN-DESIGN.md.

- `v1/pipeline.py`  the EXACT reference ops (owned cbrt, phases, CFA
  rungs, index maps, chi^2, homeShare, bell projection) — matrices
  loaded from ../fixtures, never retyped.
- `v1/goldens_test.py`  gate G-a: the trainer pipeline bit-exact against
  the same goldens the Swift app answers to. Run it before trusting
  anything else.
- `v1/synth.py`  procedural cycles: scene -> RGGB mosaic -> 4 EV frames
  with shot noise; exact ground truth.
- `v1/model.py`  V1H in MLX (bias-free; NHWC).
- `v1/train.py`  the loop. Hard metrics (exact chi^2/homeShare/dE via
  pipeline.py, bell projection applied) print alongside the loss; the
  classic seed's numbers print as the baseline to beat.

Status 2026-07-17: G-a green; smoke run trains stably with the
supervised warm anchor (house lesson — collapse otherwise); real
training runs, curricula, and report-bundle data are next.
