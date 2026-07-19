# ════════════════════════════════════════════════════════════════
# validate_goldens.py — independent Python oracle for the emitted
# fixtures (OneSix pattern: Haskell contract = Python evidence
# = Swift kernel).  Re-implements the crop derivation, CFA binning,
# color path, GIF wire, and statistics FROM THE WRITTEN CONVENTIONS
# (not from the Haskell source) and asserts bit-exact agreement.
# Run from spec/:  python3 oracle/validate_goldens.py
# ════════════════════════════════════════════════════════════════
import json
import math
import os
import struct
import sys

FIXTURES = os.path.join(os.path.dirname(__file__), '..', '..', 'fixtures')


CBRT2 = 1.2599210498948731647672106072782
CBRT4 = 1.5874010519681994747517056392723


def owned_cbrt(x):
    if x == 0:
        return 0.0
    if x < 0:
        return -owned_cbrt(-x)
    m, E = math.frexp(x)         # x = m * 2^E, m in [0.5, 1)
    f = 2.0 * m                  # f in [1, 2), exact
    e = E - 1
    y = 0.75 + f / 4.0
    for _ in range(4):
        y = (2.0 * y + f / (y * y)) / 3.0
    corr = (1.0, CBRT2, CBRT4)[e % 3]
    return math.ldexp(y * corr, e // 3)


def apply3(m, v):
    return tuple(m[3 * i] * v[0] + m[3 * i + 1] * v[1] + m[3 * i + 2] * v[2]
                 for i in range(3))


def mul3(a, b):
    return [a[3 * i] * b[j] + a[3 * i + 1] * b[3 + j] + a[3 * i + 2] * b[6 + j]
            for i in range(3) for j in range(3)]


def q16(x):
    return math.floor(x * 65536 + 0.5)


def main():
    os.chdir(FIXTURES)

    # ── geometry: device facts + the crop derivation, re-derived ─────────
    g = json.load(open('geometry.json'))
    assert g['sensor'] == [4032, 3024], 'decoded mosaic (device-verified c386663)'
    assert g['rasterPreCrop'] == [4224, 3024], 'decoder-internal tile raster'
    dv = g['deviceVerified']
    assert dv['white'] == (1 << dv['adcBits']) - 1 == 4095, '12-bit white'
    assert dv['black'] == 528 and 0 < dv['black'] < dv['white']
    assert dv['cfa'] == 1 and dv['cfaName'] == 'BGGR'
    assert g['rungs'] == [16, 32, 64, 128, 256] and g['ceilingRung'] == 256
    assert g['canonicalSide'] == 2048 and g['cycles'] == 16
    assert g['gridSide'] ** 2 == g['ceilingRung']

    def canonical_side(w, h, cap):
        # largest 256*2^j <= min(w,h), capped; None below the 256 ceiling
        m = min(w, h)
        if m < 256:
            return None
        s = 256
        while s * 2 <= m and s * 2 <= cap:
            s *= 2
        return s

    def crop_origin(dim, side):
        return ((dim - side) // 2) & ~1      # even snap: CFA phase survives

    for c in g['cropCases']:
        s = canonical_side(c['w'], c['h'], g['canonicalSide'])
        assert s == c.get('side'), f"crop side drift at {c}"
        if s is not None:
            assert crop_origin(c['w'], s) == c['x0'], f"x0 drift at {c}"
            assert crop_origin(c['h'], s) == c['y0'], f"y0 drift at {c}"
            assert c['x0'] % 2 == 0 and c['y0'] % 2 == 0, 'odd crop origin'
    assert canonical_side(*g['sensor'], g['canonicalSide']) \
        == g['canonicalSide'], 'device mosaic must yield the canonical side'

    pal = json.load(open('palette_golden.json'))
    assert len(pal['L']) == len(pal['a']) == len(pal['b']) == 256
    i = 0 * 16 + 4                       # (u=4, v=0): theta = pi/2
    assert abs(pal['a'][i]) < 1e-12 and abs(pal['b'][i] - 0.10) < 1e-12
    white = pal['oklabReference'][0]['oklab']
    assert abs(white[0] - 1) < 5e-4 and abs(white[1]) < 5e-4

    e = json.load(open('exposure_golden.json'))
    cases = {c['name']: c for c in e['cases']}
    assert cases['sixStop']['expectedF64'] == [1.0, 4.0, 16.0, 64.0]
    assert max(cases['tenStopClamped']['expectedF64']) == 256.0
    assert cases['badMeta']['expectedF64'] == [1.0] * 4
    assert cases['nearEqual']['expectedF64'] == [1.0] * 4
    for c in e['cases']:                 # exact ℚ == emitted f64
        for (num, den), f64v in zip(c['expected'], c['expectedF64']):
            assert num / den == f64v, f"{c['name']}: ratio f64 drift"
    cb = e['cfaBin']
    side, k = cb['side'], cb['k']
    mos = [cb['mosaicF64'][i * side:(i + 1) * side] for i in range(side)]
    cells = side // k
    for cy in range(cells):
        for cx in range(cells):
            rs, gs, bs = [], [], []
            for r in range(cy * k, cy * k + k):
                for c in range(cx * k, cx * k + k):
                    x = mos[r][c]
                    if r % 2 == 0 and c % 2 == 0:
                        rs.append(x)
                    elif r % 2 == 1 and c % 2 == 1:
                        bs.append(x)
                    else:
                        gs.append(x)
            idx = cy * cells + cx
            assert sum(rs) / len(rs) == cb['cellsR'][idx]
            assert sum(gs) / len(gs) == cb['cellsG'][idx]
            assert sum(bs) / len(bs) == cb['cellsB'][idx]

    # ── colorpath: owned cbrt + matrices + Q16, BIT-EXACT ────────────────
    cp = json.load(open('colorpath_golden.json'))
    mats = cp['matrices']
    composed = mul3(mats['xyzD65toLms'],
                    mul3(mats['bradfordD50toD65'], mats['prophotoToXyzD50']))
    assert composed == mats['prophotoToLms'], 'composed matrix drift'

    for c in cp['cbrt']:
        assert owned_cbrt(c['x']) == c['y'], f"cbrt({c['x']}) bit-drift"

    for s in cp['samples']:
        lms = apply3(mats['prophotoToLms'], s['prophoto'])
        lab = apply3(mats['lmsToLab'], tuple(owned_cbrt(v) for v in lms))
        assert list(lab) == s['oklab'], f"oklab bit-drift at {s['prophoto']}"
        assert [q16(v) for v in lab] == s['q16'], f"q16 drift at {s['prophoto']}"
        for v in s['prophoto']:      # inputs must widen exactly from f32
            assert struct.unpack('f', struct.pack('f', v))[0] == v

    br = cp['boxReduce']
    w, h, k = br['width'], br['height'], br['factor']
    rgb = br['rgb']
    inv = 1.0 / (k * k)
    out = []
    for oy in range(h // k):
        for ox in range(w // k):
            for ch in range(3):
                acc = 0.0
                for sy in range(k):
                    for sx in range(k):
                        acc += rgb[3 * ((oy * k + sy) * w + (ox * k + sx)) + ch]
                out.append(acc * inv)
    assert out == br['out'], 'boxReduce bit-drift'

    # ── giftarget: integer index maps + display path ─────────────────────
    gt = json.load(open('giftarget_golden.json'))
    table = gt['srgbTable']
    assert len(table) == 4096 and table[0] == 0 and table[-1] == 255
    assert all(a <= b for a, b in zip(table, table[1:]))
    for i in (0, 137, 1024, 2048, 4095):     # spot vs recomputed pow, +/-1
        c = i / 4095
        s = 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
        assert abs(table[i] - math.floor(255 * s + 0.5)) <= 1

    pal = list(zip(gt['palette']['q16L'], gt['palette']['q16a'], gt['palette']['q16b']))

    def dist2(p, q):
        return (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2 + (p[2] - q[2]) ** 2

    def nearest(p):
        best, bd = 0, None
        for j, c in enumerate(pal):
            d = dist2(c, p)
            if bd is None or d < bd:
                best, bd = j, d
        return best

    fx = gt['indexFixture']
    probes = list(zip(fx['probes']['q16L'], fx['probes']['q16a'], fx['probes']['q16b']))
    assert [nearest(p) for p in probes] == fx['indices'], 'index map drift'
    assert fx['selfIndices'] == list(range(256)), 'A2 self-indexing broken'

    inv_ab = gt['oklabToLms']
    m_rgb = gt['lmsToSrgb']

    def srgb8_from_q16(q):
        L, a, b = q[0] / 65536, q[1] / 65536, q[2] / 65536
        lp = L + inv_ab[0] * a + inv_ab[1] * b
        mp = L + inv_ab[2] * a + inv_ab[3] * b
        sp = L + inv_ab[4] * a + inv_ab[5] * b
        l, m, s = lp * lp * lp, mp * mp * mp, sp * sp * sp
        out = []
        for r in range(3):
            c = m_rgb[3 * r] * l + m_rgb[3 * r + 1] * m + m_rgb[3 * r + 2] * s
            idx = max(0, min(4095, math.floor(c * 4095 + 0.5)))
            out.append(table[idx])
        return out

    want = gt['palette']['rgb8']
    got = [v for q in pal for v in srgb8_from_q16(q)]
    assert got == want, 'palette rgb8 drift'

    # ── multiscale: per-rung demosaic + residual stack, BIT-EXACT ────────
    ms = json.load(open('multiscale_golden.json'))['fixture']
    side, rungs = ms['side'], ms['rungs']
    mos = [ms['mosaicF64'][i * side:(i + 1) * side] for i in range(side)]

    def cfa_rung(r):
        k = side // r
        out = []
        for cy in range(r):
            for cx in range(r):
                rs, gs, bs = [], [], []
                for y in range(cy * k, (cy + 1) * k):
                    for x in range(cx * k, (cx + 1) * k):
                        v = mos[y][x]
                        if y % 2 == 0 and x % 2 == 0:
                            rs.append(v)
                        elif y % 2 == 1 and x % 2 == 1:
                            bs.append(v)
                        else:
                            gs.append(v)
                out.append((sum(rs) / len(rs), sum(gs) / len(gs),
                            sum(bs) / len(bs)))
        return out

    def oklab_q16(rgb):
        lms = apply3(mats['prophotoToLms'], rgb)
        lab = apply3(mats['lmsToLab'], tuple(owned_cbrt(v) for v in lms))
        return [q16(v) for v in lab]

    planes = {}
    for r in rungs:
        qs = [oklab_q16(c) for c in cfa_rung(r)]
        planes[r] = ([t[0] for t in qs], [t[1] for t in qs], [t[2] for t in qs])

    def upsample(r, img):
        out = []
        for y in range(r):
            row = [v for v in img[y * r:(y + 1) * r] for _ in (0, 1)]
            out += row
            out += row
        return out

    for ch, key in ((0, 'bandsL'), (1, 'bandsA'), (2, 'bandsB')):
        bands, prev, r_prev = [], None, None
        for r in rungs:
            img = planes[r][ch]
            if prev is None:
                bands += img
            else:
                up = upsample(r_prev, prev)
                bands += [a - b for a, b in zip(img, up)]
            prev, r_prev = img, r
        assert bands == ms[key], f'multiscale {key} drift'

    # ── gifwire: re-encode the GIF from the written conventions ──────────
    gw = json.load(open('gifwire_golden.json'))['fixture']
    gside, gdelay = gw['side'], gw['delayCs']
    gpal, gframes = gw['palette'], gw['frames']

    def u16(v):
        return [v & 0xFF, (v >> 8) & 0xFF]

    def pack9(codes):
        out, acc, nbits = [], 0, 0
        for c in codes:
            acc |= c << nbits
            nbits += 9
            while nbits >= 8:
                out.append(acc & 0xFF)
                acc >>= 8
                nbits -= 8
        if nbits:
            out.append(acc & 0xFF)
        return out

    def frame_bytes(indices):
        groups = [indices[i:i + 254] for i in range(0, len(indices), 254)] or [[]]
        codes = [256]
        for g in groups[:-1]:
            codes += g + [256]
        codes += groups[-1] + [257]
        data = pack9(codes)
        blocks = []
        for i in range(0, len(data), 255):
            b = data[i:i + 255]
            blocks += [len(b)] + b
        return [8] + blocks + [0]

    regif = list(b'GIF89a') + u16(gside) + u16(gside) + [0xF7, 0, 0] + gpal
    regif += [0x21, 0xFF, 0x0B] + list(b'NETSCAPE2.0') + [3, 1] + u16(0) + [0]
    for f in gframes:
        regif += [0x21, 0xF9, 0x04, 0x00] + u16(gdelay) + [0, 0]
        regif += [0x2C] + u16(0) + u16(0) + u16(gside) + u16(gside) + [0]
        regif += frame_bytes(f)
    regif += [0x3B]
    assert regif == gw['gifBytes'], 'gifwire bytes drift'

    # ── cycleset: positional phase decomposition (the NN input map) ──────
    cs = json.load(open('cycleset_golden.json'))['fixture']
    cside = cs['side']
    cmos = [cs['mosaicF64'][i * cside:(i + 1) * cside] for i in range(cside)]
    half = cside // 2
    for p, (py, px) in enumerate([(0, 0), (0, 1), (1, 0), (1, 1)]):
        got = [q16(cmos[2 * y + py][2 * x + px])
               for y in range(half) for x in range(half)]
        assert got == cs['phases'][p], f'phase {p} drift'
    # bijection: reassembling the planes recovers the mosaic (positionally)
    for y in range(cside):
        for x in range(cside):
            p = (y % 2) * 2 + (x % 2)
            idx = (y // 2) * half + (x // 2)
            assert q16(cmos[y][x]) == cs['phases'][p][idx]

    # ── binomial: the V1 objective statistic, from the conventions ───────
    bn = json.load(open('binomial_golden.json'))
    for f in bn['fixtures']:
        n = f['n']
        if isinstance(f['indices'], list):
            idx = f['indices']
        else:                                        # 'lcg': re-derive
            idx, s = [], f['seed']
            for _ in range(n):
                idx.append((s // 65536) % 256)
                s = (s * 6364136223846793005 + 1442695040888963407) % (1 << 64)
                s = s - (1 << 64) if s >= (1 << 63) else s
            # Haskell Integer LCG never wraps: recompute unbounded
            idx, s = [], f['seed']
            for _ in range(n):
                idx.append((s // 65536) % 256)
                s = s * 6364136223846793005 + 1442695040888963407
        counts = [0] * 256
        for i in idx:
            counts[i] += 1
        assert counts == f['counts'], f"binomial counts drift: {f['name']}"
        exp = n / 256
        chi2 = sum((c - exp) ** 2 for c in counts) * 256 / n
        assert chi2 == f['chi2F64'], f"binomial chi2 drift: {f['name']}"

    # ── battle: the BA5 temporal delta primitive ─────────────────────────
    bt = json.load(open('battle_golden.json'))['fixture']
    a, b = bt['a'], bt['b']
    delta = [(i, y) for i, (x, y) in enumerate(zip(a, b)) if x != y]
    assert [p for p, _ in delta] == bt['deltaPos'], 'battle deltaPos drift'
    assert [v for _, v in delta] == bt['deltaNew'], 'battle deltaNew drift'
    assert len(delta) == int(bt['churn']), 'battle churn drift'
    applied = list(a)
    for p, v in delta:
        applied[p] = v
    assert applied == b, 'BA5 round-trip drift'

    print('ORACLE GREEN: all fixtures match independent re-computation')


if __name__ == '__main__':
    sys.exit(main())
