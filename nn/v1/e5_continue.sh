#!/bin/bash
# E5 continuation — d=96 REPLICATE (ledger rule: no promotion without
# one) then the next capacity rung d=144 (~1.3M params), both on the
# champion config, both exported to V1HW packages. Durable in runs/.
#   watch: python3 nn/v1/watch.py nn/v1/runs/run_e5_d96_rep.log --follow
set -u
cd "$(dirname "$0")"
R=runs
STEPS=20000
COMMON="--steps $STEPS --batch 2 --eval-every 250 --battle-eval-every 1000
        --workers 6 --band-chi2 --w-chi2 0.1 --ckpt-every 500"

echo "[e5c] $(date) — run 1/2: d=96 REPLICATE, $STEPS steps"
python3 train.py $COMMON --d 96 --save $R/v1h_e5_d96_rep.safetensors \
    > $R/run_e5_d96_rep.log 2>&1
python3 -c "
import export_model
export_model.export('$R/v1h_e5_d96_rep.safetensors',
                    config={'d': 96, 'in_side': 256, 'steps': $STEPS,
                            'arch': 'V1H', 'replicate': True,
                            'champion': 'band-chi2 w0.1 clock-anneal'})"

echo "[e5c] $(date) — run 2/2: d=144 (~1.3M params), $STEPS steps"
python3 train.py $COMMON --d 144 --save $R/v1h_e5_d144.safetensors \
    > $R/run_e5_d144.log 2>&1
python3 -c "
import export_model
export_model.export('$R/v1h_e5_d144.safetensors',
                    config={'d': 144, 'in_side': 256, 'steps': $STEPS,
                            'arch': 'V1H',
                            'champion': 'band-chi2 w0.1 clock-anneal'})"

echo "[e5c] $(date) — CONTINUATION COMPLETE"
