# ════════════════════════════════════════════════════════════════
# train.py — V1-H training loop (MLX, Mac).
#
# Losses (the V1 judgment, differentiable forms):
#   L_ceiling  mse(pred ceiling LAB, classic ceiling LAB) — the
#              jump's latent-prediction target (OKLab IS the latent)
#   L_serve    soft-assignment dE: the target ceiling soft-indexed
#              against the PREDICTED seed (palette must serve the
#              scene) — softmax(-d^2/tau) weighted distances
#   L_chi2     soft chi^2 of the soft usage histogram vs B(n,1/256)
#              (the binomial approximation, made differentiable)
#   L_bell     sorted seed L vs the exact bell quantile targets
#              (the projection downstream is exact; this keeps it
#              small — gate G-c)
#
# Smoke run: `python3 train.py --steps 60` prints the loss curve +
# the EXACT (non-soft) chi^2 / homeShare / dE of the hard pipeline
# applied to the model's outputs, via pipeline.py (the law'd ops).
# ════════════════════════════════════════════════════════════════
import argparse
import os
import sys
import time

import numpy as np
import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim

sys.path.insert(0, os.path.dirname(__file__))
import pipeline as P  # noqa: E402
import synth  # noqa: E402
from model import V1H  # noqa: E402

BELL_T = mx.array(P.bell_quantile_targets())


def losses(model, x, target_lab, seed_lab, tau=0.1):
    seed, ceiling = model(x)                          # (B,16,16,3) (B,256,256,3)
    l_ceiling = mx.mean((ceiling - target_lab) ** 2)

    pal = seed.reshape(-1, 256, 3)                    # (B, 256, 3)
    tgt = target_lab.reshape(-1, 65536, 3)
    d2 = ((tgt[:, :, None, :] - pal[:, None, :, :]) ** 2).sum(-1)   # (B, n, 256)
    w = mx.softmax(-d2 / tau, axis=-1)
    l_serve = mx.mean((w * d2).sum(-1))

    usage = w.sum(axis=1)                             # (B, 256) soft counts
    n = 65536.0
    l_chi2 = mx.mean(((usage - n / 256) ** 2).sum(-1) * 256 / n) / n

    seed_l = mx.sort(seed.reshape(-1, 256, 3)[:, :, 0], axis=-1)
    l_bell = mx.mean((seed_l - BELL_T[None, :]) ** 2)

    # Supervised warm anchor (house lesson: warmup beats collapse) — the
    # classic seed is a lawful, competent starting point (N3).
    l_seed = mx.mean((seed - seed_lab) ** 2)

    total = (l_ceiling + 1.0 * l_seed + 0.1 * l_serve
             + 0.01 * l_chi2 + 0.1 * l_bell)
    return total, (l_ceiling, l_seed, l_serve, l_chi2, l_bell)


def hard_metrics(model, x_np, target_lab_np):
    """The law'd judgment: exact pipeline ops on the model's outputs."""
    seed, _ = model(mx.array(x_np))
    seed = np.array(seed)[0]                          # (16,16,3)
    seed_lab = seed.reshape(256, 3).astype(np.float64)
    seed_lab[:, 0] = P.bell_project_L(seed_lab[:, 0])  # exact projection (G-c)
    pal_q16 = P.q16(seed_lab)
    tgt_q16 = P.q16(target_lab_np[0].reshape(-1, 3))
    idx = P.index_map(tgt_q16, pal_q16)
    d = (tgt_q16 - pal_q16[idx]).astype(np.float64) / 65536
    return {
        'chi2': P.chi_square(idx),
        'homeShare': P.home_share(idx),
        'dE': float(np.sqrt((d ** 2).sum(1)).mean()),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--steps', type=int, default=60)
    ap.add_argument('--batch', type=int, default=2)
    ap.add_argument('--side', type=int, default=512)
    ap.add_argument('--lr', type=float, default=1e-3)
    args = ap.parse_args()

    rng = np.random.default_rng(17)
    model = V1H(d=24, in_side=args.side // 2)
    opt = optim.Adam(learning_rate=args.lr)
    lg = nn.value_and_grad(model, lambda m, x, t, sl: losses(m, x, t, sl)[0])

    xs, tl, sl = synth.batch(rng, n=args.batch, side=args.side)
    x_fix, t_fix = xs.copy(), tl.copy()               # fixed probe batch
    print('baseline (classic seed on probe):',
          {k: round(v, 4) for k, v in classic_baseline(t_fix).items()})

    t0 = time.time()
    for step in range(1, args.steps + 1):
        xs, tl, sl = synth.batch(rng, n=args.batch, side=args.side)
        x, t = mx.array(np.moveaxis(xs, 1, -1)), mx.array(tl)
        slm = mx.array(sl)
        loss, grads = lg(model, x, t, slm)
        opt.update(model, grads)
        mx.eval(model.parameters(), opt.state)
        if step % 10 == 0 or step == 1:
            m = hard_metrics(model, np.moveaxis(x_fix, 1, -1), t_fix)
            print(f'step {step:4d}  loss {float(loss):.5f}  '
                  f'chi2 {m["chi2"]:9.1f}  homeShare {m["homeShare"]:.4f}  '
                  f'dE {m["dE"]:.4f}  ({time.time() - t0:.1f}s)')


def classic_baseline(target_lab):
    """What the classic seed (cfaBin 16 of the same scene) scores."""
    tgt = target_lab[0]
    seed = tgt.reshape(16, 16, 16, 16, 3).mean(axis=(1, 3)).reshape(256, 3)
    pal_q16 = P.q16(seed)
    tgt_q16 = P.q16(tgt.reshape(-1, 3))
    idx = P.index_map(tgt_q16, pal_q16)
    d = (tgt_q16 - pal_q16[idx]).astype(np.float64) / 65536
    return {'chi2': P.chi_square(idx), 'homeShare': P.home_share(idx),
            'dE': float(np.sqrt((d ** 2).sum(1)).mean())}


if __name__ == '__main__':
    main()
