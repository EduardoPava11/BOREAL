# ════════════════════════════════════════════════════════════════
# goldens_test.py — gate G-a: the TRAINER's pipeline is bit-exact
# against the same golden fixtures the Swift app answers to.
# Run: python3 nn/v1/goldens_test.py   (from the repo root or here)
# ════════════════════════════════════════════════════════════════
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import pipeline as P  # noqa: E402
import record as R    # noqa: E402  (the canonical numpy patch-major)

FIX = os.path.join(os.path.dirname(__file__), '..', '..', 'fixtures')


def load(name):
    with open(os.path.join(FIX, name)) as f:
        return json.load(f)


def die(msg):
    print(f'G-a FAIL: {msg}')
    sys.exit(1)


# colorpath: owned cbrt + full path, BIT-EXACT
cp = load('colorpath_golden.json')
for c in cp['cbrt']:
    if float(P.owned_cbrt(c['x'])) != c['y']:
        die(f"cbrt({c['x']})")
for s in cp['samples']:
    lab = P.oklab_from_prophoto(np.array(s['prophoto']))
    if list(lab) != s['oklab']:
        die(f"oklab at {s['prophoto']}")
    if list(P.q16(lab)) != s['q16']:
        die(f"q16 at {s['prophoto']}")

# cycleset: positional phases, Q16-quantized
cs = load('cycleset_golden.json')['fixture']
side = cs['side']
mos = np.array(cs['mosaicF64']).reshape(side, side)
planes = P.phase_planes(mos)
for p in range(4):
    if list(P.q16(planes[p]).ravel()) != cs['phases'][p]:
        die(f'phase {p}')

# multiscale: the rung stack, all three channels (identity matrix fixture)
ms = load('multiscale_golden.json')['fixture']
mside = ms['side']
mmos = np.array(ms['mosaicF64']).reshape(mside, mside)
stack = P.rung_stack_q16(mmos)
for ch, key in ((0, 'bandsL'), (1, 'bandsA'), (2, 'bandsB')):
    if list(stack[:, ch]) != ms[key]:
        die(f'multiscale {key}')

# giftarget: index maps (probes + the A2 self-indexing identity)
gt = load('giftarget_golden.json')
pal = np.stack([np.array(gt['palette'][k])
                for k in ('q16L', 'q16a', 'q16b')], axis=1)
fx = gt['indexFixture']
probes = np.stack([np.array(fx['probes'][k])
                   for k in ('q16L', 'q16a', 'q16b')], axis=1)
if list(P.index_map(probes, pal)) != fx['indices']:
    die('index map probes')
if list(P.index_map(pal, pal)) != list(range(256)):
    die('A2 self-indexing')

# binomial: chi^2 on stored fixtures
bn = load('binomial_golden.json')
for f in bn['fixtures']:
    if isinstance(f['indices'], list):
        if P.chi_square(f['indices']) != f['chi2F64']:
            die(f"chi2 {f['name']}")
    else:
        counts = np.array(f['counts'], dtype=np.float64)
        n = counts.sum()
        chi2 = float(((counts - n / 256) ** 2).sum() * 256 / n)
        if chi2 != f['chi2F64']:
            die(f"chi2-from-counts {f['name']}")

# battle: patch-major ordering at the emitted spots + the homeShare linking
bt = load('battle_golden.json')
pm = R.patch_major(np.arange(65536).reshape(256, 256))
for s in bt['patchMajorSpots']:
    y, x = 16 * s['v'] + s['j'], 16 * s['u'] + s['i']
    if pm[s['pos']] != y * 256 + x:
        die(f"patch-major spot ({s['v']},{s['u']},{s['j']},{s['i']})")
hs = bt['homeShare']
mask = (1 << 64) - 1
s64 = hs['seed']
idx = np.empty(hs['n'], dtype=np.uint8)
for k in range(hs['n']):
    idx[k] = (s64 >> 16) & 0xFF   # == (s div 65536) mod 256, s positive
    s64 = (s64 * 6364136223846793005 + 1442695040888963407) & mask
if P.home_share(idx) != hs['expected']:
    die('homeShare linking')

# hierarchy: pureH anchors (H laws, re-derived)
pure = np.repeat(np.repeat(np.arange(256).reshape(16, 16), 16, 0), 16, 1).ravel()
assert P.home_share(pure) == 1.0
assert P.chi_square(pure) == 0.0
assert P.home_share(np.zeros(65536, dtype=int)) == 1.0 / 256

# bell: allocation + targets pinned to the emitted fixture (no retyped
# literal), and the projection is lawful by construction
pal_fx = load('palette_golden.json')
if list(P.BELL) != pal_fx['bellCounts']:
    die('BELL != fixture bellCounts')
t = P.bell_quantile_targets()
tf = np.array(pal_fx['bellTargets'], dtype=np.float64)
if float(np.abs(t - tf).max()) > 1e-12:
    die('bell_quantile_targets != fixture bellTargets')
if float(np.abs(P.BELL_TARGETS - tf).max()) != 0.0:
    die('BELL_TARGETS != fixture bellTargets')
rng = np.random.default_rng(7)
proj = P.bell_project_L(rng.random(256))
assert proj.min() == 0.0 and proj.max() == 1.0
assert sorted(proj) == list(t)

print('G-a GREEN: trainer pipeline bit-exact against all goldens')
