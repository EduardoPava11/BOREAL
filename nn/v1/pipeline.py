# ════════════════════════════════════════════════════════════════
# pipeline.py — the EXACT reference pipeline in NumPy, for training.
#
# Every operation here mirrors a law'd convention (spec/Boreal/*),
# and goldens_test.py asserts bit-exactness against the same
# fixtures the Swift app answers to (gate G-a). Matrices are LOADED
# from the goldens — one source of truth, no retyped literals.
#
# Conventions honored: positional phase decomposition (N laws),
# owned cbrt + pinned matrix order + Q16 (CQ laws), per-rung CFA
# means (MS laws), i64 argmin ties-lowest (G laws), chi^2 vs
# B(n,1/256) (V laws), homeShare over the (16x16)x(16x16)
# factorization (H laws), bell allocation + exact rank projection
# (B laws).
# ════════════════════════════════════════════════════════════════
import json
import os

import numpy as np

_FIXTURES = os.path.join(os.path.dirname(__file__), '..', '..', 'fixtures')

with open(os.path.join(_FIXTURES, 'colorpath_golden.json')) as f:
    _cp = json.load(f)['matrices']
PROPHOTO_TO_LMS = np.array(_cp['prophotoToLms'], dtype=np.float64).reshape(3, 3)
LMS_TO_LAB = np.array(_cp['lmsToLab'], dtype=np.float64).reshape(3, 3)

try:
    with open(os.path.join(_FIXTURES, 'palette_golden.json')) as f:
        _pal = json.load(f)
    BELL = np.array(_pal['bellCounts'])
    BELL_TARGETS = np.array(_pal['bellTargets'], dtype=np.float64)
except (OSError, KeyError) as _e:
    raise RuntimeError(
        'palette_golden.json with bellCounts/bellTargets is required '
        '(regenerate with `make -C spec emit`): %r' % (_e,))


# ── owned cbrt (ColorPath conventions; vectorized, bit-exact) ──────────────

def owned_cbrt(x):
    x = np.asarray(x, dtype=np.float64)
    sign = np.sign(x)
    ax = np.abs(x)
    m, e = np.frexp(ax)              # ax = m * 2^e, m in [0.5, 1)
    f = 2.0 * m                      # f in [1, 2), exact
    e = e - 1
    y = 0.75 + f / 4.0
    for _ in range(4):
        y = (2.0 * y + f / (y * y)) / 3.0
    corr = np.choose(np.mod(e, 3),
                     [np.float64(1.0),
                      np.float64(1.2599210498948731647672106072782),
                      np.float64(1.5874010519681994747517056392723)])
    out = np.ldexp(y * corr, np.floor_divide(e, 3)) * sign
    return np.where(ax == 0, 0.0, out)


def oklab_from_prophoto(rgb):
    """rgb (..., 3) linear ProPhoto f64 -> OKLab (..., 3)."""
    lms = rgb @ PROPHOTO_TO_LMS.T
    return owned_cbrt(lms) @ LMS_TO_LAB.T


def q16(x):
    return np.floor(np.asarray(x, dtype=np.float64) * 65536 + 0.5).astype(np.int64)


# ── phase decomposition (CycleSet N laws) ──────────────────────────────────

def phase_planes(mosaic):
    """S x S -> (4, S/2, S/2), positional order (0,0),(0,1),(1,0),(1,1)."""
    m = np.asarray(mosaic)
    return np.stack([m[0::2, 0::2], m[0::2, 1::2], m[1::2, 0::2], m[1::2, 1::2]])


def cycle_tensor(frames):
    """4 EV-normalized mosaics -> (16, S/2, S/2), frame-major."""
    return np.concatenate([phase_planes(f) for f in frames])


# ── per-rung CFA demosaic (MultiScale MS laws; RGGB) ───────────────────────

def cfa_rung(mosaic, rung):
    """S x S mosaic -> (rung, rung, 3) linear RGB, exact per-cell means."""
    m = np.asarray(mosaic, dtype=np.float64)
    s = m.shape[0]
    k = s // rung
    cells = m.reshape(rung, k, rung, k).transpose(0, 2, 1, 3)   # (r, r, k, k)
    r_sites = cells[:, :, 0::2, 0::2].mean(axis=(2, 3))
    b_sites = cells[:, :, 1::2, 1::2].mean(axis=(2, 3))
    g1 = cells[:, :, 0::2, 1::2]
    g2 = cells[:, :, 1::2, 0::2]
    g_sites = np.concatenate([g1.reshape(rung, rung, -1),
                              g2.reshape(rung, rung, -1)], axis=2).mean(axis=2)
    return np.stack([r_sites, g_sites, b_sites], axis=-1)


def rungs_for(side):
    return [r for r in (16, 32, 64, 128, 256)
            if side % r == 0 and side // r >= 2 and (side // r) % 2 == 0]


def rung_stack_q16(mosaic, rungs=None):
    """The residual stack per channel (MS laws), identity color matrix."""
    side = np.asarray(mosaic).shape[0]
    rungs = rungs or rungs_for(side)
    planes = {}
    for r in rungs:
        lab = oklab_from_prophoto(cfa_rung(mosaic, r))
        planes[r] = q16(lab)                                   # (r, r, 3)
    bands = []
    prev = None
    for r in rungs:
        cur = planes[r]
        if prev is None:
            bands.append(cur.reshape(-1, 3))
        else:
            up = np.repeat(np.repeat(planes[prev], 2, axis=0), 2, axis=1)
            bands.append((cur - up).reshape(-1, 3))
        prev = r
    return np.concatenate(bands, axis=0)                       # (sum r^2, 3)


# ── GIF target: index map, chi^2, homeShare (G/V/H laws) ───────────────────

def index_map(lab_q16, palette_q16):
    """(n, 3) i64 vs (256, 3) i64 -> (n,) uint8; argmin ties-lowest."""
    d = lab_q16[:, None, :].astype(np.int64) - palette_q16[None, :, :].astype(np.int64)
    dist = (d * d).sum(axis=2)
    return np.argmin(dist, axis=1).astype(np.uint8)            # first min = lowest


def chi_square(indices):
    counts = np.bincount(np.asarray(indices).ravel(), minlength=256).astype(np.float64)
    n = counts.sum()
    e = n / 256
    return float(((counts - e) ** 2).sum() * 256 / n)


def home_share(indices_256sq):
    idx = np.asarray(indices_256sq).reshape(256, 256)
    v = np.arange(256)[:, None] // 16
    u = np.arange(256)[None, :] // 16
    return float((idx == (v * 16 + u)).mean())


# ── bell (B laws): allocation target + exact rank projection ───────────────

def bell_quantile_targets():
    """The 256 lawful L values in rank order (bellPalette's luminances).
    Computed from the fixture-loaded BELL by the B-law formula; the gate
    (goldens_test) asserts equality with the emitted fixture bellTargets."""
    out = []
    for k, c in enumerate(BELL):
        for pos in range(c):
            out.append((k + (pos + 0.5) / c) / 16)
    out[0], out[-1] = 0.0, 1.0
    return np.array(out)


def bell_project_L(seed_L):
    """Exact rank projection: sort the 256 predicted L's, assign the bell
    targets in rank order, ends pinned — B laws hold by construction."""
    order = np.argsort(seed_L, kind='stable')
    out = np.empty(256)
    out[order] = bell_quantile_targets()
    return out
