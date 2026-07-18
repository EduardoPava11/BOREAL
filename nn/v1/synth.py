# ════════════════════════════════════════════════════════════════
# synth.py — the synthetic cycle generator: procedural linear-RGB
# scenes -> RGGB mosaics -> 4-frame EV cycles with shot noise.
# Ground truth is exact because we own the scene. Default geometry
# is the V1-H training shape: mosaic 512 -> tensor (16, 256, 256),
# seed 16^2, ceiling 256^2 — the (16x16)x(16x16) jump.
# ════════════════════════════════════════════════════════════════
import numpy as np

import pipeline as P


def make_scene(rng, side=512, blobs=24):
    """Smooth linear-'ProPhoto' RGB in [0, ~1.2): gaussian color blobs
    over a global gradient, occasional hard edge."""
    yy, xx = np.mgrid[0:side, 0:side] / side
    rgb = np.stack([0.12 + 0.25 * xx, 0.12 + 0.25 * yy,
                    0.12 + 0.25 * (1 - xx)], axis=-1)
    for _ in range(blobs):
        cy, cx = rng.random(2)
        sig = 0.03 + 0.15 * rng.random()
        amp = rng.random(3) * 0.8
        g = np.exp(-(((yy - cy) ** 2 + (xx - cx) ** 2) / (2 * sig ** 2)))
        rgb += g[..., None] * amp[None, None, :]
    if rng.random() < 0.5:                      # a hard edge
        cut = int(side * (0.25 + 0.5 * rng.random()))
        rgb[:, cut:] *= 0.35 + 0.4 * rng.random()
    return np.clip(rgb, 0.0, 1.2)


def mosaic_of(rgb):
    """RGGB Bayer-sample a linear RGB image (side x side x 3)."""
    m = np.empty(rgb.shape[:2])
    m[0::2, 0::2] = rgb[0::2, 0::2, 0]
    m[0::2, 1::2] = rgb[0::2, 1::2, 1]
    m[1::2, 0::2] = rgb[1::2, 0::2, 1]
    m[1::2, 1::2] = rgb[1::2, 1::2, 2]
    return m


def make_cycle(rng, side=512, photons_at_1=4000.0):
    """One training sample.
    Returns: tensor (16, side/2, side/2) f32  — the NN input (N laws)
             target_lab (256, 256, 3) f64     — classic ceiling OKLab
             seed_lab (16, 16, 3) f64         — classic seed OKLab
    """
    scene = make_scene(rng, side)
    clean = mosaic_of(scene)
    evs = np.array([1.0, 2.0, 4.0, 8.0])        # green/red/blue/shadow-ish
    frames = []
    for e in evs:
        exposed = clean * e
        shot = rng.poisson(np.maximum(exposed, 0) * photons_at_1) / photons_at_1
        frames.append((shot / e).astype(np.float32))   # EV-normalize (exact role)
    tensor = P.cycle_tensor(frames).astype(np.float32)
    target_lab = P.oklab_from_prophoto(P.cfa_rung(clean, 256))
    seed_lab = P.oklab_from_prophoto(P.cfa_rung(clean, 16))
    return tensor, target_lab, seed_lab


def batch(rng, n=4, side=512):
    ts, tl, sl = zip(*[make_cycle(rng, side) for _ in range(n)])
    return (np.stack(ts), np.stack(tl), np.stack(sl))
