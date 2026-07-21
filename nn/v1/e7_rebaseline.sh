#!/bin/bash
# ════════════════════════════════════════════════════════════════
# E7 — the d96 RE-BASELINE under the T3 regime (2026-07-21).
#
# The noise-policy boundary (commit 588e6bc): synth noise is now the
# per-frame TAG model at POST-BIN level, and --likelihood-loss weights
# the objective by the physical inverse variance (tempered). Classic
# baselines MOVED (~16x cleaner noise), so the e5 champion's numbers
# (19,247 / 0.336 / 0.0082, eq 1,240) no longer compare. This run
# re-establishes the champion configuration as the NEW-REGIME
# baseline every future challenger (in_side 512, arbitration,
# real-photon fine-tunes) is judged against.
#
# Recipe: the champion's exactly (d96, lr 1e-3 default, band-chi2
# w0.1, 20k steps) + --likelihood-loss. Judge at the anneal tail only;
# per-run printed baselines are the comparison, not history.
#
#   watch: python3 nn/v1/watch.py nn/v1/runs/run_e7_d96_t3.log --follow
# ════════════════════════════════════════════════════════════════
set -u
cd "$(dirname "$0")"
R=runs
STEPS=20000
COMMON="--steps $STEPS --batch 2 --eval-every 250 --battle-eval-every 1000
        --workers 6 --band-chi2 --w-chi2 0.1 --ckpt-every 500"

echo "[e7] $(date) — d=96 re-baseline under T3 (tag noise + likelihood loss)"
python3 train.py $COMMON --d 96 --likelihood-loss \
    --save $R/v1h_e7_d96_t3.safetensors \
    > $R/run_e7_d96_t3.log 2>&1
python3 - <<PY
import export_model
export_model.export('$R/v1h_e7_d96_t3.safetensors',
                    config={'d': 96, 'in_side': 256, 'steps': $STEPS,
                            'arch': 'V1H',
                            'regime': 'T3: tag-noise post-bin + likelihood loss',
                            'note': 'e7 new-regime d96 baseline'})
PY
echo "[e7] $(date) — done (the new-regime baseline; judge challengers against THIS)"
