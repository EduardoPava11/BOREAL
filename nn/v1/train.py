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
#   L_home     the R2 ARRANGEMENT term: cross-entropy pulling each
#              ceiling pixel's soft assignment toward its HOME cell
#              (patch (v,u) -> option v*16+u). This is the H prior —
#              the pure-H fixed point where binomial ideal and
#              home-centering meet; small weight, evidence may
#              overrule locally (the battle), but the palette must
#              be spatially ARRANGED, not just distributionally right.
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

# Residual gain: predictions = classic base + RES_GAIN * net output, so
# a fresh net starts AT the classic baseline (small random perturbation).
RES_GAIN = 0.1

# Home option per ceiling pixel (row-major 256x256): (y//16)*16 + x//16.
_yy, _xx = np.mgrid[0:256, 0:256]
HOME = mx.array(((_yy // 16) * 16 + _xx // 16).ravel())     # (65536,)


def losses(model, x, target_lab, seed_lab, base16, base256,
           tau=0.1, w_home=0.05):
    # RESIDUAL-TO-CLASSIC (N3: the input contains the classic baseline
    # verbatim — identity is already a demosaicer). The net predicts
    # residuals; predictions START at classic-on-noisy performance.
    s_res, c_res = model(x)                           # (B,16,16,3) (B,256,256,3)
    seed = base16 + RES_GAIN * s_res
    ceiling = base256 + RES_GAIN * c_res
    l_ceiling = mx.mean((ceiling - target_lab) ** 2)

    pal = seed.reshape(-1, 256, 3)                    # (B, 256, 3)
    tgt = target_lab.reshape(-1, 65536, 3)
    d2 = ((tgt[:, :, None, :] - pal[:, None, :, :]) ** 2).sum(-1)   # (B, n, 256)
    # Scale-adaptive temperature: normalize by the batch's own mean d2
    # (stop-gradient), so softmax selectivity is EXPOSURE-INDEPENDENT
    # (N4 equivariance) — a fixed tau goes flat on dark scenes.
    scale = mx.stop_gradient(mx.mean(d2, axis=(1, 2), keepdims=True)) + 1e-12
    w = mx.softmax(-d2 / (tau * scale), axis=-1)
    l_serve = mx.mean((w * d2).sum(-1))

    usage = w.sum(axis=1)                             # (B, 256) soft counts
    n = 65536.0
    l_chi2 = mx.mean(((usage - n / 256) ** 2).sum(-1) * 256 / n) / n

    seed_l = mx.sort(seed.reshape(-1, 256, 3)[:, :, 0], axis=-1)
    l_bell = mx.mean((seed_l - BELL_T[None, :]) ** 2)

    # R2 arrangement: each pixel's soft weight on its HOME option.
    w_at_home = mx.take_along_axis(
        w, mx.broadcast_to(HOME[None, :, None], (w.shape[0], 65536, 1)),
        axis=-1)[..., 0]                               # (B, 65536)
    l_home = -mx.mean(mx.log(w_at_home + 1e-8))

    # Supervised warm anchor (house lesson: warmup beats collapse) — the
    # classic seed is a lawful, competent starting point (N3).
    l_seed = mx.mean((seed - seed_lab) ** 2)

    total = (l_ceiling + 1.0 * l_seed + 0.1 * l_serve
             + 0.01 * l_chi2 + 0.1 * l_bell + w_home * l_home)
    return total, (l_ceiling, l_seed, l_serve, l_chi2, l_bell, l_home)


def judged(seed_lab_256x3, target_flat):
    """Bell-consistent judgment. The bell is the OUTPUT TONAL SPACE
    (the targets are absolute — the palette's L multiset is a
    scene-independent constant, per the T laws). So: exact rank
    projection on the palette L, AND the induced monotone tone map
    (sorted seed L -> bell targets, piecewise-linear = histogram
    specification) applied to the target's L. Model and baselines
    are judged through this SAME map — like against like."""
    pal = seed_lab_256x3.astype(np.float64).copy()
    src_l = np.sort(pal[:, 0], kind='stable')
    pal[:, 0] = P.bell_project_L(pal[:, 0])            # exact projection (G-c)
    tgt = target_flat.astype(np.float64).copy()
    tgt[:, 0] = np.interp(tgt[:, 0], src_l, P.bell_quantile_targets())
    pal_q16 = P.q16(pal)
    tgt_q16 = P.q16(tgt)
    idx = P.index_map(tgt_q16, pal_q16)
    d = (tgt_q16 - pal_q16[idx]).astype(np.float64) / 65536
    return {
        'chi2': P.chi_square(idx),
        'homeShare': P.home_share(idx),
        'dE': float(np.sqrt((d ** 2).sum(1)).mean()),
    }


def hard_metrics(model, x_np, target_lab_np, base16_np):
    """The law'd judgment: exact pipeline ops on the model's outputs."""
    s_res, _ = model(mx.array(x_np))
    seed = base16_np[0] + RES_GAIN * np.array(s_res)[0]   # residual + base
    return judged(seed.reshape(256, 3), target_lab_np[0].reshape(-1, 3))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--steps', type=int, default=60)
    ap.add_argument('--batch', type=int, default=2)
    ap.add_argument('--side', type=int, default=512)
    ap.add_argument('--lr', type=float, default=1e-3)
    ap.add_argument('--w-home', type=float, default=0.05)
    args = ap.parse_args()

    rng = np.random.default_rng(17)
    model = V1H(d=24, in_side=args.side // 2)
    opt = optim.Adam(learning_rate=args.lr)
    lg = nn.value_and_grad(
        model,
        lambda m, x, t, sl, b16, b256, tau: losses(
            m, x, t, sl, b16, b256, tau=tau, w_home=args.w_home)[0])

    xs, tl, sl, b16, b256 = synth.batch(rng, n=args.batch, side=args.side)
    x_fix, t_fix, sl_fix = xs.copy(), tl.copy(), sl.copy()   # fixed probe batch
    b16_fix, b256_fix = b16.copy(), b256.copy()
    print('baseline (CLEAN classic seed on probe): ',
          {k: round(v, 4) for k, v in classic_baseline(t_fix).items()})
    print('baseline (NOISY classic seed on probe): ',
          {k: round(v, 4) for k, v in noisy_baseline(t_fix, b16_fix).items()})

    t0 = time.time()
    for step in range(1, args.steps + 1):
        # R3 compression anneal: warm (soft, forgiving) -> sharp
        # (near-hard assignment) geometrically across the run.
        tau = 0.5 * (0.05 / 0.5) ** ((step - 1) / max(args.steps - 1, 1))
        xs, tl, sl, b16, b256 = synth.batch(rng, n=args.batch, side=args.side)
        x, t = mx.array(np.moveaxis(xs, 1, -1)), mx.array(tl)
        slm = mx.array(sl)
        loss, grads = lg(model, x, t, slm, mx.array(b16), mx.array(b256), tau)
        opt.update(model, grads)
        mx.eval(model.parameters(), opt.state)
        if step % 20 == 0 or step == 1:
            m = hard_metrics(model, np.moveaxis(x_fix, 1, -1), t_fix, b16_fix)
            _, parts = losses(model, mx.array(np.moveaxis(x_fix, 1, -1)),
                              mx.array(t_fix), mx.array(sl_fix),
                              mx.array(b16_fix), mx.array(b256_fix), tau=tau,
                              w_home=args.w_home)
            names = ('ceil', 'seed', 'serve', 'chi2', 'bell', 'home')
            pstr = ' '.join(f'{n}={float(v):.4f}' for n, v in zip(names, parts))
            print(f'step {step:4d}  loss {float(loss):.5f}  tau {tau:.3f}  '
                  f'chi2 {m["chi2"]:9.1f}  homeShare {m["homeShare"]:.4f}  '
                  f'dE {m["dE"]:.4f}  [{pstr}]  ({time.time() - t0:.1f}s)')


def noisy_baseline(target_lab, base16):
    """What the INFERENCE-AVAILABLE classic seed (noisy mean) scores —
    the residual model's true starting point and the bar to beat."""
    return judged(base16[0].reshape(256, 3), target_lab[0].reshape(-1, 3))


def classic_baseline(target_lab):
    """What the classic seed (cfaBin 16 of the same scene) scores."""
    tgt = target_lab[0]
    seed = tgt.reshape(16, 16, 16, 16, 3).mean(axis=(1, 3)).reshape(256, 3)
    return judged(seed, tgt.reshape(-1, 3))


if __name__ == '__main__':
    main()
