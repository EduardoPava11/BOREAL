# ════════════════════════════════════════════════════════════════
# battle.py — the battle inner loop: defection dynamics on the
# index territory (Boreal.Battle, BA1-BA6).
#
# The framing (BA1): options = species, pixels = territory, usage =
# populations. The argmin index map is the EVIDENCE-optimal prior;
# the beauty band (BA3: E[chi^2] = 255 under neutral drift, V1f band
# 150-400) is the lawful equilibrium. A defection (one pixel moving
# p -> q) changes chi^2 by the BA4 closed form
#
#     delta_chi2 = 512 * (c_q - c_p + 1) / n        [BA4, law'd]
#
# so the whole settle is O(1) per move. BA6's price signal — toward
# the crowd costs, toward sparsity pays — selects which defections
# happen; the ΔE budget bounds how much evidence a pixel may
# sacrifice to the law (prior yields to evidence only where evidence
# is cheap). Greedy order = cheapest evidence sacrifice first.
#
# Self-check: assert the BA4 increment against full recomputation on
# every equilibrium() call in selftest(); G-a spirit — the law'd
# closed form is the contract, the loop must agree with it exactly.
# ════════════════════════════════════════════════════════════════
import numpy as np

import pipeline as P

BAND = (150.0, 400.0)                     # V1f: the beauty band


def equilibrium(idx, d2, band=BAND, de_budget=0.03, alts=8):
    """Settle an index territory toward the beauty band.

    idx: (n,) initial assignment (argmin prior; ties-lowest upstream)
    d2:  (n, 256) float64 squared distances in OKLab (evidence)
    de_budget: max allowed INCREASE in per-pixel distance sqrt(d2)
               for one defection (float OKLab units)
    alts: how many nearest alternatives each pixel may defect to

    Returns (idx_eq, info) where info carries chi2 before/after,
    moves made, and the total dE paid.
    """
    n, k = d2.shape
    idx = np.asarray(idx).astype(np.int64).copy()
    counts = np.bincount(idx, minlength=k).astype(np.int64)
    e = n / k
    chi2 = float(((counts - e) ** 2).sum() * k / n)
    chi2_0 = chi2

    d = np.sqrt(d2)
    home_d = d[np.arange(n), idx]
    # Candidate defections: each pixel's `alts` nearest options
    # (argpartition: the set is what matters — candidates are ordered
    # globally by evidence cost below, not per-pixel).
    near = np.argpartition(d2, min(alts, k - 1), axis=1)[:, :alts]
    cand_i = np.repeat(np.arange(n), alts)
    cand_q = near.ravel()
    keep = cand_q != idx[cand_i]                       # not the current home
    cand_i, cand_q = cand_i[keep], cand_q[keep]
    dcost = d[cand_i, cand_q] - home_d[cand_i]         # evidence sacrifice
    within = dcost <= de_budget
    cand_i, cand_q, dcost = cand_i[within], cand_q[within], dcost[within]
    order = np.argsort(dcost, kind='stable')           # cheapest first

    moved = np.zeros(n, dtype=bool)
    moves = 0
    de_paid = 0.0
    lo, hi = band
    for j in order:
        if chi2 <= hi:
            break
        i = cand_i[j]
        if moved[i]:
            continue                                   # one defection per pixel
        p, q = idx[i], cand_q[j]
        dchi = 512.0 * (counts[q] - counts[p] + 1) / n     # BA4 closed form
        if dchi >= 0.0:
            continue                                   # BA6: toward crowd costs
        idx[i] = q
        counts[p] -= 1
        counts[q] += 1
        chi2 += dchi
        moved[i] = True
        moves += 1
        de_paid += max(dcost[j], 0.0)
    return idx.astype(np.uint8), {
        'chi2_before': chi2_0,
        'chi2_after': chi2,
        'moves': moves,
        'movedShare': moves / n,
        'dePaid': de_paid,
    }


def judged_battle(seed_lab_256x3, target_flat, de_budget=0.03, alts=8):
    """The bell-consistent judgment (train.judged conventions) with the
    battle equilibrium appended: metrics for the argmin prior AND for
    the settled territory, from ONE distance computation. Baselines
    must be judged through this same function — like against like."""
    pal = seed_lab_256x3.astype(np.float64).copy()
    src_l = np.sort(pal[:, 0], kind='stable')
    pal[:, 0] = P.bell_project_L(pal[:, 0])
    tgt = target_flat.astype(np.float64).copy()
    tgt[:, 0] = np.interp(tgt[:, 0], src_l, P.bell_quantile_targets())
    pal_q16 = P.q16(pal)
    tgt_q16 = P.q16(tgt)
    idx = P.index_map(tgt_q16, pal_q16)                # EXACT (matches judged())
    # Float distances for the battle's evidence costs (matmul form —
    # judging-only; the exact int argmin above is the law'd prior).
    tq = tgt_q16.astype(np.float64) / 65536
    pq = pal_q16.astype(np.float64) / 65536
    d2 = ((tq ** 2).sum(1)[:, None] + (pq ** 2).sum(1)[None, :]
          - 2.0 * tq @ pq.T)
    np.maximum(d2, 0.0, out=d2)
    de_raw = float(np.sqrt(d2[np.arange(len(idx)), idx.astype(np.int64)]).mean())
    idx_eq, info = equilibrium(idx, d2, de_budget=de_budget, alts=alts)
    de_eq = float(np.sqrt(d2[np.arange(len(idx_eq)), idx_eq.astype(np.int64)]).mean())
    return {
        'chi2': P.chi_square(idx),
        'homeShare': P.home_share(idx),
        'dE': de_raw,
        'chi2_battle': P.chi_square(idx_eq),
        'homeShare_battle': P.home_share(idx_eq),
        'dE_battle': de_eq,
        'movedShare': info['movedShare'],
    }, idx_eq


def selftest(rng=None):
    """BA4 exactness: the incremental chi^2 the loop maintains must equal
    a full recomputation on the settled indices, bit-for-float."""
    rng = rng or np.random.default_rng(7)
    n, k = 4096, 256
    d2 = rng.random((n, k))
    idx = np.argmin(d2, axis=1)
    idx_eq, info = equilibrium(idx, d2, de_budget=1.0, alts=8)
    full = P.chi_square(idx_eq) if n == 65536 else \
        float(((np.bincount(idx_eq, minlength=k) - n / k) ** 2).sum() * k / n)
    assert abs(info['chi2_after'] - full) < 1e-6, \
        f"BA4 incremental drift: {info['chi2_after']} vs {full}"
    assert info['chi2_after'] <= info['chi2_before'], 'battle raised chi^2'
    return True


if __name__ == '__main__':
    selftest()
    print('battle selftest GREEN (BA4 incremental == full recomputation)')
