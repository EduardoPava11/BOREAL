# ════════════════════════════════════════════════════════════════
# train.py — V1-H training loop (MLX, Mac). N1: the L-structure
# seed (the 16x16 debayer) under the regimen R1-R4.
#
# Losses (the V1 judgment, differentiable forms):
#   L_ceiling  mse(pred ceiling LAB, classic ceiling LAB) — the
#              jump's latent-prediction target (OKLab IS the latent)
#   L_serve    soft-assignment dE: the target ceiling soft-indexed
#              against the PREDICTED seed (palette must serve the
#              scene) — softmax(-d^2/tau) weighted distances
#   L_chi2     rate penalty on soft usage. Two forms:
#                default   chi2_soft / n  (legacy: pulls to uniform)
#                --band-chi2  relu(chi2_soft - 400) / n — the V1f
#                CORRECTION: beauty is FIT TO THE BINOMIAL; the band
#                (150-400) is the target, chi^2 = 0 is sterile.
#   L_bell     sorted seed L vs the exact bell quantile targets
#   L_home     R2 arrangement: soft mass on the HOME option
#   L_battle   (--battle-every K) cross-entropy toward the BATTLE
#              EQUILIBRIUM indices: every K steps the current hard
#              assignment settles by BA4 defections under a dE
#              budget (battle.equilibrium, raw OKLab space — same
#              space as the soft weights) and the settled territory
#              becomes the assignment target. Evolution proposes,
#              gradients follow, laws judge.
#
# Curriculum (--sigma-curriculum): per-pixel weights from the cell
# sigma (|base256 - up(base16)|, the coarse-vs-fine disagreement) —
# the debayer earns its keep where scales disagree (R2's queued
# sigma lever).
#
# Standing rules enforced here: the 255n collapse tripwire aborts
# loudly; clean AND noisy classic baselines always printed; judgment
# is the hard law'd metrics on HELD-OUT probe scenes (rng 1234,
# never trained on), with battle-refined columns for model and
# classic alike (like against like).
# ════════════════════════════════════════════════════════════════
import argparse
import math
import os
import sys
import time

import numpy as np
import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
import mlx.utils

sys.path.insert(0, os.path.dirname(__file__))
import battle  # noqa: E402
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

BAND_HI = battle.BAND[1]


def _gen_batch(seed, n, side):
    """Worker-side batch generation (module-level for pickling). Each
    batch gets its own child rng — reproducible per (seed) regardless
    of worker scheduling."""
    return synth.batch(np.random.default_rng(seed), n=n, side=side)


class Prefetcher:
    """Parallel scene synthesis: the measured step is ~64 ms GPU but
    ~250 ms single-threaded numpy generation — the M3 Max GPU idles
    76% of the time. A process pool with a few batches in flight
    keeps the queue ahead of the GPU (10 P-cores; scenes are
    independent)."""

    def __init__(self, workers, n, side, base_seed=1_000_000):
        from concurrent.futures import ProcessPoolExecutor
        self.pool = ProcessPoolExecutor(max_workers=workers)
        self.n, self.side = n, side
        self.next_seed = base_seed
        self.futures = []
        for _ in range(workers + 2):                   # prefetch depth
            self._submit()

    def _submit(self):
        self.futures.append(
            self.pool.submit(_gen_batch, self.next_seed, self.n, self.side))
        self.next_seed += 1

    def get(self):
        batch = self.futures.pop(0).result()
        self._submit()
        return batch

    def close(self):
        self.pool.shutdown(wait=False, cancel_futures=True)


def sigma_weights(b16, b256):
    """Per-pixel curriculum weights from the coarse-vs-fine sigma:
    cell sigma = mean |base256 - nearest-up(base16)| per 16x16 cell,
    normalized to mean 1 per item, blended 0.5 uniform + 0.5 sigma
    (nothing starves), clipped. Returns (B, 256, 256, 1) float32."""
    up = np.repeat(np.repeat(b16, 16, axis=1), 16, axis=2)
    cell = np.abs(b256 - up).mean(axis=-1)                     # (B,256,256)
    cell = cell.reshape(-1, 16, 16, 16, 16).mean(axis=(2, 4))  # (B,16,16)
    cell = cell / (cell.mean(axis=(1, 2), keepdims=True) + 1e-12)
    w = 0.5 + 0.5 * np.repeat(np.repeat(cell, 16, axis=1), 16, axis=2)
    return np.clip(w, 0.25, 4.0)[..., None].astype(np.float32)


def losses(model, x, target_lab, seed_lab, base16, base256,
           tau=0.1, w_home=0.05, w_seed=1.0, band_chi2=False,
           pix_w=None, y_star=None, w_battle=0.0):
    # RESIDUAL-TO-CLASSIC (N3: the input contains the classic baseline
    # verbatim — identity is already a demosaicer). The net predicts
    # residuals; predictions START at classic-on-noisy performance.
    s_res, c_res = model(x)                           # (B,16,16,3) (B,256,256,3)
    seed = base16 + RES_GAIN * s_res
    ceiling = base256 + RES_GAIN * c_res
    sq = (ceiling - target_lab) ** 2
    if pix_w is not None:
        sq = sq * pix_w                               # sigma curriculum
    l_ceiling = mx.mean(sq)

    pal = seed.reshape(-1, 256, 3)                    # (B, 256, 3)
    tgt = target_lab.reshape(-1, 65536, 3)
    # GEMM form of the squared distances (|t|^2 + |p|^2 - 2 t.p): same
    # math, 3x less memory traffic than the broadcast-subtract form —
    # measured 78 -> 64 ms/step on M3 Max. (Training is not in the
    # bit-exact domain; the judge stays exact in numpy.)
    d2 = ((tgt ** 2).sum(-1, keepdims=True)
          + (pal ** 2).sum(-1)[:, None, :]
          - 2.0 * (tgt @ pal.transpose(0, 2, 1)))     # (B, n, 256)
    # Scale-adaptive temperature: normalize by the batch's own mean d2
    # (stop-gradient), so softmax selectivity is EXPOSURE-INDEPENDENT
    # (N4 equivariance) — a fixed tau goes flat on dark scenes.
    scale = mx.stop_gradient(mx.mean(d2, axis=(1, 2), keepdims=True)) + 1e-12
    w = mx.softmax(-d2 / (tau * scale), axis=-1)
    served = (w * d2).sum(-1)                         # (B, n)
    if pix_w is not None:
        served = served * pix_w.reshape(-1, 65536)
    l_serve = mx.mean(served)

    usage = w.sum(axis=1)                             # (B, 256) soft counts
    n = 65536.0
    chi2_soft = ((usage - n / 256) ** 2).sum(-1) * 256 / n   # (B,)
    if band_chi2:
        # V1f: the band is the target — no penalty inside it, no pull
        # to the sterile floor.
        l_chi2 = mx.mean(mx.maximum(chi2_soft - BAND_HI, 0.0)) / n
    else:
        l_chi2 = mx.mean(chi2_soft) / n

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

    # Battle target, two modes (2026-07-18 lesson: per-pixel CE at
    # diffuse w is ~log256 and swamps the loss — gate it late or use
    # the 256-dim usage form, which has no magnitude blowup):
    #   ce     cross-entropy toward the settled per-pixel indices
    #   usage  match soft usage to the equilibrium's usage counts
    #          (chi^2-style normalization — same scale as l_chi2)
    if y_star is not None and w_battle > 0.0:
        if y_star.ndim == 2 and y_star.shape[-1] == 256:   # usage counts
            l_battle = mx.mean(
                ((usage - y_star) ** 2).sum(-1) * 256 / n) / n
        else:                                              # per-pixel indices
            w_at_star = mx.take_along_axis(
                w, y_star[..., None], axis=-1)[..., 0]
            l_battle = -mx.mean(mx.log(w_at_star + 1e-8))
    else:
        l_battle = mx.zeros(())

    total = (l_ceiling + w_seed * l_seed + 0.1 * l_serve
             + 0.01 * l_chi2 + 0.1 * l_bell + w_home * l_home
             + w_battle * l_battle)
    return total, (l_ceiling, l_seed, l_serve, l_chi2, l_bell, l_home, l_battle)


def battle_targets(model, x, base16, target_lab, de_budget, alts=8):
    """The inner loop, training side: current predicted seed (no grad)
    -> hard argmin territory in RAW OKLab (the space the soft weights
    live in) -> BA4 defection equilibrium -> (B, 65536) index targets."""
    s_res, _ = model(x)
    seeds = np.array(base16) + RES_GAIN * np.array(s_res)     # (B,16,16,3)
    tgts = np.array(target_lab).reshape(len(seeds), -1, 3)
    out = np.empty((len(seeds), 65536), dtype=np.int64)
    for b, (s, t) in enumerate(zip(seeds, tgts)):
        pal = s.reshape(256, 3).astype(np.float64)
        t64 = t.astype(np.float64)
        d2 = ((t64 ** 2).sum(1)[:, None] + (pal ** 2).sum(1)[None, :]
              - 2.0 * t64 @ pal.T)
        np.maximum(d2, 0.0, out=d2)
        idx = np.argmin(d2, axis=1)
        idx_eq, _ = battle.equilibrium(idx, d2, de_budget=de_budget, alts=alts)
        out[b] = idx_eq.astype(np.int64)
    return mx.array(out)


def judged(seed_lab_256x3, target_flat):
    """Bell-consistent judgment (see battle.judged_battle for the
    battle-refined variant sharing these conventions)."""
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


def model_seeds(model, x_np, base16_np):
    s_res, _ = model(mx.array(x_np))
    return base16_np + RES_GAIN * np.array(s_res)      # (B,16,16,3)


def probe_metrics(model, probe, with_battle=False, de_budget=0.03):
    """Mean hard metrics over the held-out probe scenes; optionally the
    battle-refined columns (model side)."""
    x_np, t_np, _, b16_np, _ = probe
    seeds = model_seeds(model, np.moveaxis(x_np, 1, -1), b16_np)
    rows = []
    for b in range(len(seeds)):
        s = seeds[b].reshape(256, 3)
        t = t_np[b].reshape(-1, 3)
        if with_battle:
            m, _ = battle.judged_battle(s, t, de_budget=de_budget)
        else:
            m = judged(s, t)
        rows.append(m)
    return {k: float(np.mean([r[k] for r in rows])) for k in rows[0]}, rows


def baseline_rows(probe, which='clean', with_battle=True, de_budget=0.03):
    x_np, t_np, sl_np, b16_np, _ = probe
    rows = []
    for b in range(len(t_np)):
        t = t_np[b].reshape(-1, 3)
        if which == 'clean':
            # Law'd classic seed = linear-light cfaBin seed (synth's sl);
            # the old OKLab-mean of the ceiling was a Jensen-gap bug
            # (fixed 2026-07-18 review).
            seed = sl_np[b].reshape(256, 3)
        else:
            seed = b16_np[b].reshape(256, 3)
        if with_battle:
            m, _ = battle.judged_battle(seed, t, de_budget=de_budget)
        else:
            m = judged(seed, t)
        rows.append(m)
    return {k: float(np.mean([r[k] for r in rows])) for k in rows[0]}, rows


def fmt(m):
    parts = [f"chi2 {m['chi2']:9.1f}  homeShare {m['homeShare']:.4f}  dE {m['dE']:.4f}"]
    if 'chi2_battle' in m:
        parts.append(f"| battle: chi2 {m['chi2_battle']:7.1f}  "
                     f"homeShare {m['homeShare_battle']:.4f}  "
                     f"dE {m['dE_battle']:.4f}  moved {m['movedShare']:.3f}")
    return '  '.join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--steps', type=int, default=60)
    ap.add_argument('--batch', type=int, default=2)
    ap.add_argument('--side', type=int, default=512)
    ap.add_argument('--lr', type=float, default=1e-3)
    ap.add_argument('--w-home', type=float, default=0.05)
    ap.add_argument('--d', type=int, default=24,
                    help='latent width (stem = 2d; capacity axis)')
    ap.add_argument('--res-gain', type=float, default=0.1,
                    help='residual scale off the classic base (RES_GAIN)')
    ap.add_argument('--band-chi2', action='store_true',
                    help='V1f band target for the soft chi^2 (150-400)')
    ap.add_argument('--sigma-curriculum', action='store_true',
                    help='weight ceiling/serve by coarse-vs-fine sigma')
    ap.add_argument('--battle-every', type=int, default=0,
                    help='every K steps, train toward the BA4 equilibrium')
    ap.add_argument('--w-battle', type=float, default=0.05)
    ap.add_argument('--battle-mode', choices=['ce', 'usage'], default='ce',
                    help='ce: per-pixel CE target; usage: 256-dim usage match')
    ap.add_argument('--battle-tau-gate', type=float, default=0.0,
                    help='fire the battle term only when tau <= this (0=always)')
    ap.add_argument('--de-budget', type=float, default=0.03,
                    help='max dE a pixel may pay to defect (battle)')
    ap.add_argument('--anchor-half-life', type=int, default=0,
                    help='R3: decay the warm anchor x0.5 every N steps (0=off)')
    ap.add_argument('--cosine-lr', action='store_true')
    ap.add_argument('--probe-scenes', type=int, default=8)
    ap.add_argument('--eval-every', type=int, default=50)
    ap.add_argument('--battle-eval-every', type=int, default=200)
    ap.add_argument('--save', type=str, default='',
                    help='path to save final weights (.safetensors)')
    ap.add_argument('--ckpt-every', type=int, default=500,
                    help='rolling checkpoint cadence (0=off; needs --save)')
    ap.add_argument('--workers', type=int, default=0,
                    help='parallel scene-synthesis workers (0=inline legacy)')
    ap.add_argument('--load', type=str, default='',
                    help='warm-start weights from a .safetensors file')
    args = ap.parse_args()

    # Normalize --save once: without the suffix, the derived-path
    # .replace() calls below are silent no-ops.
    if args.save and not args.save.endswith('.safetensors'):
        args.save += '.safetensors'
        print(f'note: --save normalized to {args.save}')

    sys.stdout.reconfigure(line_buffering=True)        # live logs under nohup
    global RES_GAIN
    RES_GAIN = args.res_gain                           # read by losses/judges
    metrics_path = (args.save.replace('.safetensors', '.metrics.jsonl')
                    if args.save else '')

    def emit(event, **kv):
        if not metrics_path:
            return
        import json
        # 'start' truncates: one run = one stream (re-runs with the
        # same --save must not stack streams under the watcher).
        mode = 'w' if event == 'start' else 'a'
        with open(metrics_path, mode) as f:
            f.write(json.dumps({'event': event, **kv}) + '\n')
    rng = np.random.default_rng(17)
    probe_rng = np.random.default_rng(1234)            # HELD OUT, never trained
    model = V1H(d=args.d, in_side=args.side // 2)
    if args.load:
        model.load_weights(args.load)
        print(f'warm-started from {args.load}')
    opt = optim.Adam(learning_rate=args.lr)
    lg = nn.value_and_grad(
        model,
        lambda m, x, t, sl, b16, b256, tau, ws, pw, ys, wb: losses(
            m, x, t, sl, b16, b256, tau=tau, w_home=args.w_home,
            w_seed=ws, band_chi2=args.band_chi2, pix_w=pw,
            y_star=ys, w_battle=wb)[0])

    probe = synth.batch(probe_rng, n=args.probe_scenes, side=args.side)
    clean_m, clean_rows = baseline_rows(probe, 'clean', with_battle=True,
                                        de_budget=args.de_budget)
    noisy_m, _ = baseline_rows(probe, 'noisy', with_battle=True,
                               de_budget=args.de_budget)
    print(f'probe = {args.probe_scenes} held-out scenes (rng 1234)')
    print('baseline CLEAN classic:', fmt(clean_m))
    print('baseline NOISY classic:', fmt(noisy_m))
    emit('start', steps=args.steps, batch=args.batch, d=args.d,
         res_gain=args.res_gain, workers=args.workers,
         config=vars(args), clean=clean_m, noisy=noisy_m,
         t0=time.time())

    # Prefetcher up front (not lazily at step 1) so the finally below
    # can always reap the pool — tripwire SystemExit / worker exceptions
    # must not leak child processes.
    prefetcher = (Prefetcher(args.workers, args.batch, args.side)
                  if args.workers > 0 else None)
    t0 = time.time()
    try:
        for step in range(1, args.steps + 1):
            # R3 compression anneal: warm (soft, forgiving) -> sharp
            # (near-hard assignment) geometrically across the run.
            tau = 0.5 * (0.05 / 0.5) ** ((step - 1) / max(args.steps - 1, 1))
            w_seed = (0.5 ** (step / args.anchor_half_life)
                      if args.anchor_half_life > 0 else 1.0)
            if args.cosine_lr:
                lr_t = (args.lr / 10
                        + (args.lr - args.lr / 10)
                        * 0.5 * (1 + math.cos(math.pi * (step - 1)
                                              / args.steps)))
                opt.learning_rate = lr_t
            if prefetcher is not None:
                xs, tl, sl, b16, b256 = prefetcher.get()
            else:
                xs, tl, sl, b16, b256 = synth.batch(rng, n=args.batch,
                                                    side=args.side)
            x = mx.array(np.moveaxis(xs, 1, -1))
            t, slm = mx.array(tl), mx.array(sl)
            b16m, b256m = mx.array(b16), mx.array(b256)
            pw = (mx.array(sigma_weights(b16, b256))
                  if args.sigma_curriculum else None)
            battle_on = (args.battle_every > 0
                         and step % args.battle_every == 0
                         and (args.battle_tau_gate <= 0.0
                              or tau <= args.battle_tau_gate))
            if battle_on:
                ys = battle_targets(model, x, b16m, t, args.de_budget)
                if args.battle_mode == 'usage':
                    counts = np.stack([
                        np.bincount(np.array(ys[b]), minlength=256)
                        for b in range(ys.shape[0])]).astype(np.float32)
                    ys = mx.array(counts)                # (B, 256)
                wb = args.w_battle
            else:
                ys, wb = None, 0.0
            loss, grads = lg(model, x, t, slm, b16m, b256m, tau, w_seed,
                             pw, ys, wb)
            opt.update(model, grads)
            mx.eval(model.parameters(), opt.state)

            if step % args.eval_every == 0 or step == 1 or step == args.steps:
                deep_eval = (step % args.battle_eval_every == 0
                             or step == args.steps)
                m, _ = probe_metrics(model, probe, with_battle=deep_eval,
                                     de_budget=args.de_budget)
                # Collapse tripwire (standing rule): 255n is total collapse.
                if m['chi2'] > 0.9 * 255 * 65536:
                    print(f'!!! COLLAPSE TRIPWIRE: chi2 {m["chi2"]:.0f} '
                          f'~ 255n — aborting (V1d closed form)')
                    raise SystemExit(2)
                print(f'step {step:4d}  loss {float(loss):.5f}  '
                      f'tau {tau:.3f}  w_seed {w_seed:.3f}  {fmt(m)}  '
                      f'({time.time() - t0:.1f}s)')
                emit('eval', step=step, loss=float(loss), tau=tau,
                     elapsed=time.time() - t0, **m)
            if (args.save and args.ckpt_every > 0
                    and step % args.ckpt_every == 0):
                ck = args.save.replace('.safetensors', '.ckpt.safetensors')
                mx.save_safetensors(
                    ck, dict(mlx.utils.tree_flatten(model.parameters())))

        # Final judgment: per-scene R4-style dominance vs CLEAN classic.
        final_m, final_rows = probe_metrics(model, probe, with_battle=True,
                                            de_budget=args.de_budget)
        print('final model  :', fmt(final_m))
        print('final classic:', fmt(clean_m))
        # R4 gate, EQUILIBRIUM LAYER (redefined 2026-07-18): the equilibrium
        # must be cheaper (dE_eq), closer to the band's center (chi2_eq),
        # and the palette better arranged pre-battle (homeShare raw).
        dom = 0
        for mr, cr in zip(final_rows, clean_rows):
            if (mr['dE_battle'] < cr['dE_battle']
                    and abs(mr['chi2_battle'] - 255)
                    < abs(cr['chi2_battle'] - 255)
                    and mr['homeShare'] > cr['homeShare']):
                dom += 1
        small_probe = (' (indicative only — R4\'s 95% gate needs >=20 scenes)'
                       if len(final_rows) < 20 else '')
        print(f'dominance vs clean classic (equilibrium layer: dE_eq & '
              f'band-distance_eq & homeShare_raw): '
              f'{dom}/{len(final_rows)} scenes{small_probe}')
        emit('final', dominance=dom, scenes=len(final_rows), **final_m)
        if args.save:
            mx.save_safetensors(
                args.save, dict(mlx.utils.tree_flatten(model.parameters())))
            print(f'weights saved to {args.save}')
    finally:
        if prefetcher is not None:
            prefetcher.close()


if __name__ == '__main__':
    main()
