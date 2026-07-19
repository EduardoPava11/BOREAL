#!/bin/bash
# E5 overnight driver — capacity to Gharbi-class (d=96, ~597k params)
# plus a same-horizon d=24 control, on the champion config
# (--band-chi2 --w-chi2 0.1, clock anneal). Everything lands in
# nn/v1/runs/ (durable): logs, metrics.jsonl (the watch.py cockpit),
# rolling checkpoints every 500 steps, final weights, and the V1HW
# app package (export_model.py) after each run.
#
#   watch:  python3 nn/v1/watch.py nn/v1/runs/run_e5_d96.log --follow
set -u
cd "$(dirname "$0")"
R=runs
mkdir -p $R
STEPS=20000
COMMON="--steps $STEPS --batch 2 --eval-every 250 --battle-eval-every 1000
        --workers 6 --band-chi2 --w-chi2 0.1 --ckpt-every 500"

echo "[e5] $(date) — run 1/2: d=96 (~597k params), $STEPS steps"
python3 train.py $COMMON --d 96 --save $R/v1h_e5_d96.safetensors \
    > $R/run_e5_d96.log 2>&1
python3 -c "
import export_model
export_model.export('$R/v1h_e5_d96.safetensors',
                    config={'d': 96, 'in_side': 256, 'steps': $STEPS,
                            'arch': 'V1H', 'arbitrate': False,
                            'noise_latent': False,
                            'champion': 'band-chi2 w0.1 clock-anneal'})"

echo "[e5] $(date) — run 2/2: d=24 horizon control, $STEPS steps"
python3 train.py $COMMON --d 24 --save $R/v1h_e5h_d24.safetensors \
    > $R/run_e5h_d24.log 2>&1
python3 -c "
import export_model
export_model.export('$R/v1h_e5h_d24.safetensors',
                    config={'d': 24, 'in_side': 256, 'steps': $STEPS,
                            'arch': 'V1H', 'arbitrate': False,
                            'noise_latent': False,
                            'champion': 'band-chi2 w0.1 clock-anneal'})"

echo "[e5] $(date) — OVERNIGHT COMPLETE"
