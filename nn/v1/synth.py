# ════════════════════════════════════════════════════════════════
# synth.py — the synthetic cycle generator: procedural linear-RGB
# scenes -> RGGB mosaics -> 4-frame EV cycles with shot noise.
# Ground truth is exact because we own the scene. Default geometry
# is the V1-H training shape: mosaic 512 -> tensor (16, 256, 256),
# seed 16^2, ceiling 256^2 — the (16x16)x(16x16) jump.
#
# Sensor model = the MEASURED device facts (first real run, iPhone
# 17 Pro): 12-bit ADC, black 528 / white 4095, EV ratios
# [1, 3.66, 15, 62.5] from EXIF; Poisson shot noise + Gaussian read
# noise in DN; highlights SATURATE at white (so high-EV shadow
# frames clip realistically — the reason EV planning exists).
# CFA stays RGGB here (the stem is positional/CFA-agnostic, N laws);
# BGGR flip is an N2 item when chroma meaning starts to matter.
# ════════════════════════════════════════════════════════════════
import numpy as np

import pipeline as P

BLACK_DN, WHITE_DN = 528.0, 4095.0          # device-measured, 12-bit
DEVICE_EVS = np.array([1.0, 3.66, 15.0, 62.5])   # EXIF ratios, first run


def make_scene(rng, side=512, blobs=24):
    """Linear-'ProPhoto' RGB with REAL dynamic range: deep-shadow floor
    (~0.008, where only the high-EV frames see signal) up to ~1.2
    (clips in every frame above base). Gaussian color blobs over a
    global gradient, occasional hard edge; a squared ramp keeps most
    area in the low stops, photograph-like."""
    yy, xx = (np.mgrid[0:side, 0:side] / side).astype(np.float32)
    rgb = np.stack([0.008 + 0.06 * xx ** 2, 0.008 + 0.06 * yy ** 2,
                    0.008 + 0.06 * (1 - xx) ** 2], axis=-1)
    for _ in range(blobs):
        cy, cx = rng.random(2)
        sig = 0.03 + 0.15 * rng.random()
        amp = (rng.random(3) * (0.8 * rng.random() ** 2)).astype(np.float32)
        g = np.exp(-(((yy - np.float32(cy)) ** 2 + (xx - np.float32(cx)) ** 2)
                     / np.float32(2 * sig ** 2)))
        rgb += g[..., None] * amp[None, None, :]
    if rng.random() < 0.5:                      # a hard edge into shadow
        cut = int(side * (0.25 + 0.5 * rng.random()))
        rgb[:, cut:] *= 0.1 + 0.3 * rng.random()
    return np.clip(rgb, 0.0, 1.2)


def mosaic_of(rgb):
    """RGGB Bayer-sample a linear RGB image (side x side x 3)."""
    m = np.empty(rgb.shape[:2])
    m[0::2, 0::2] = rgb[0::2, 0::2, 0]
    m[0::2, 1::2] = rgb[0::2, 1::2, 1]
    m[1::2, 0::2] = rgb[1::2, 0::2, 1]
    m[1::2, 1::2] = rgb[1::2, 1::2, 2]
    return m


def expose_for_bracket(rng, clean, evs=DEVICE_EVS):
    """ETTR coupling: the device PLANNED its EVs for its scene. Mimic by
    exposing the scene so that frame e=lift is the ETTR-correct one
    (peak ~0.9), lift log-uniform over the bracket — cycles range from
    "base well exposed, high frames clip" to "base deep, top frame ETTR"."""
    lift = np.exp(rng.uniform(0.0, np.log(float(np.max(evs)))))
    return clean * (0.9 / max(clean.max(), 1e-6) / lift)


def sensor_read(rng, linear, read_noise_dn=2.0):
    """Linear light (1.0 = nominal white) through the measured ADC:
    scale to DN over the black..white range, add read noise, quantize
    to integer DN, SATURATE at white, subtract black back out."""
    span = WHITE_DN - BLACK_DN
    dn = BLACK_DN + linear * span
    dn = dn + rng.normal(0.0, read_noise_dn, dn.shape)
    dn = np.clip(np.rint(dn), 0.0, WHITE_DN)
    return (dn - BLACK_DN) / span


def make_cycle(rng, side=512, photons_at_1=4000.0, evs=DEVICE_EVS):
    """One training sample.
    Returns: tensor (16, side/2, side/2) f32  — the NN input (N laws)
             target_lab (256, 256, 3) f64     — classic ceiling OKLab
             seed_lab (16, 16, 3) f64         — classic seed OKLab
    """
    scene = make_scene(rng, side)
    clean = expose_for_bracket(rng, mosaic_of(scene), evs)
    frames = []
    for e in evs:
        exposed = clean * e
        shot = rng.poisson(np.maximum(exposed, 0) * photons_at_1) / photons_at_1
        raw = sensor_read(rng, shot)                   # 12-bit ADC + clip
        frames.append((raw / e).astype(np.float32))    # EV-normalize (exact role)
    tensor = P.cycle_tensor(frames).astype(np.float32)
    target_lab = P.oklab_from_prophoto(P.cfa_rung(clean, 256))
    seed_lab = P.oklab_from_prophoto(P.cfa_rung(clean, 16))
    # The INFERENCE-AVAILABLE classic bases (N3: identity is already a
    # demosaicer): classic seed/ceiling from the mean of the NOISY
    # frames — what the net's residual heads add to. No ground truth.
    noisy_mean = np.mean(frames, axis=0)
    base16 = P.oklab_from_prophoto(P.cfa_rung(noisy_mean, 16))
    base256 = P.oklab_from_prophoto(P.cfa_rung(noisy_mean, 256))
    return tensor, target_lab, seed_lab, base16, base256


def batch(rng, n=4, side=512):
    ts, tl, sl, b16, b256 = zip(*[make_cycle(rng, side) for _ in range(n)])
    return (np.stack(ts), np.stack(tl), np.stack(sl),
            np.stack(b16), np.stack(b256))
