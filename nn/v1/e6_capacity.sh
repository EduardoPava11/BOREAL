#!/bin/bash
# ════════════════════════════════════════════════════════════════
# E6 — capacity, re-opened FAIRLY (2026-07-20, "make the model
# bigger — we have the ANE now").
#
# The ANE (V3 runtime tier) removes the inference-cost ceiling, so
# capacity is worth re-testing — but the e5 verdict (d144 WORSE than
# d96 on every column) carried a registered confound: d144 diverged
# at the champion lr 1e-3, and its only completed run used HALF the
# champion's lr (5e-4). A slower-learning model judged at equal
# steps is not a capacity verdict.
#
# Fair re-run, champion recipe throughout (band-chi2 w0.1, built-in
# clock anneal, 20k steps):
#   run 1: d=144 @ lr 7e-4  — the untried middle (1e-3 diverged,
#          5e-4 was the confound)
#   run 2: d=192 @ lr 5e-4  — width-scaled (1e-3 · 96/192); the
#          ANE-scale probe (~2.3M params)
#
# Judge ONLY at the anneal tail (house rule: mid-anneal gaps close).
# Baseline to beat: d96_rep  19,247 / 0.336 / 0.0082, chi2_eq 1,240.
# Ledger rules: a winner needs a REPLICATE before promotion, and a
# new champion is a PINNED-FIXTURE event — fixtures/v1h weights +
# v1h_forward_golden re-emitted together, or the gate refuses it.
# The bigger model's inference cost is V3/ANE's problem, not V1's:
# promotion also waits on the runtime tier that can carry it.
#
#   watch: python3 nn/v1/watch.py nn/v1/runs/run_e6_d144_lr7.log --follow
# ════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")"
R=runs
STEPS=20000
COMMON="--steps $STEPS --batch 2 --eval-every 250 --battle-eval-every 1000
        --workers 6 --band-chi2 --w-chi2 0.1 --ckpt-every 500"

echo "[e6] $(date) — run 1/2: d=144 @ lr 7e-4 (fair middle)"
python3 train.py $COMMON --d 144 --lr 7e-4 \
    --save $R/v1h_e6_d144_lr7.safetensors \
    > $R/run_e6_d144_lr7.log 2>&1
python3 - <<PY
import export_model
export_model.export('$R/v1h_e6_d144_lr7.safetensors',
                    config={'d': 144, 'in_side': 256, 'steps': $STEPS,
                            'arch': 'V1H', 'lr': 7e-4,
                            'note': 'e6 fair capacity re-run (e5 lr confound fixed)'})
PY

echo "[e6] $(date) — run 2/2: d=192 @ lr 5e-4 (width-scaled; the ANE-scale probe)"
python3 train.py $COMMON --d 192 --lr 5e-4 \
    --save $R/v1h_e6_d192.safetensors \
    > $R/run_e6_d192.log 2>&1
python3 - <<PY
import export_model
export_model.export('$R/v1h_e6_d192.safetensors',
                    config={'d': 192, 'in_side': 256, 'steps': $STEPS,
                            'arch': 'V1H', 'lr': 5e-4,
                            'note': 'e6 ANE-scale probe'})
PY

echo "[e6] $(date) — done (judge at the tail, replicate before promotion)"
