# ════════════════════════════════════════════════════════════════
# record.py — the N0 training record: {L fractal structure, deltas,
# EV trace} per cycle, IDENTICAL in shape from synth and device.
#
# Mirrors the app exactly (BurstController + CycleReport):
#   fractal.frames[t].seedL     the frame's own 16² seed-L (Q16) —
#                               the 256 options
#   fractal.frames[t].patchesL  the frame's 256² ceiling L (Q16) in
#                               the H2 patch-major ordering: patch
#                               (v,u) outer row-major, inner (j,i)
#                               row-major
#   deltas.list[t]              BA5 defection list between the
#                               cycle's consecutive per-frame index
#                               maps; applyDelta round-trips EXACTLY
#   ev                          plannedBiases / actualRatios / nextPlan
#
# validate() checks either source against the same contract, so a
# device bundle and a synth cycle are interchangeable training food.
# ════════════════════════════════════════════════════════════════

import json
import sys

import numpy as np
import pipeline as P
import synth as S

ORDERING = ("patch-major: patch (v,u) outer row-major, inner (j,i) "
            "row-major (H2/PatchGrid); pos=(v*16+u)*256+(j*16+i)")


# ── The fractal ordering (H2) ──────────────────────────────────────────────

def patch_major(frame_256sq):
    """(256, 256) row-major -> (65536,) patch-major (H2)."""
    f = np.asarray(frame_256sq).reshape(256, 256)
    return f.reshape(16, 16, 16, 16).transpose(0, 2, 1, 3).ravel()


def patch_major_inverse(patches):
    """(65536,) patch-major -> (256, 256) row-major."""
    p = np.asarray(patches).reshape(16, 16, 16, 16)
    return p.transpose(0, 2, 1, 3).reshape(256, 256)


# ── The BA5 temporal delta primitive ───────────────────────────────────────

def frame_delta(a, b):
    a, b = np.asarray(a).ravel(), np.asarray(b).ravel()
    pos = np.nonzero(a != b)[0]
    return pos, b[pos]


def apply_delta(a, pos, new):
    out = np.asarray(a).ravel().copy()
    out[np.asarray(pos, dtype=np.int64)] = new
    return out


# ── Synth leg: the record from the exact pipeline ─────────────────────────

def synth_record(rng, side=512, photons_at_1=4000.0):
    """One cycle -> the N0 record, same shape as report.json's sections.

    Structural mirror of the app: the governing palette is the CYCLE's
    seed (clean fused mosaic); each frame is EV-normalized by its own
    e_t, demosaiced at seed and ceiling, indexed against the governing
    palette. L plane first-class.
    """
    scene = S.make_scene(rng, side)
    clean = S.expose_for_bracket(rng, S.mosaic_of(scene))
    evs = S.DEVICE_EVS                                      # measured ratios

    pal_q16 = P.q16(P.oklab_from_prophoto(P.cfa_rung(clean, 16))).reshape(-1, 3)

    frames, index_maps = [], []
    for e in evs:
        exposed = clean * e
        shot = rng.poisson(np.maximum(exposed, 0) * photons_at_1) / photons_at_1
        mosaic = S.sensor_read(rng, shot) / e               # ADC + EV-normalize (1/e_t)
        seed_q16 = P.q16(P.oklab_from_prophoto(P.cfa_rung(mosaic, 16)))
        ceil_q16 = P.q16(P.oklab_from_prophoto(P.cfa_rung(mosaic, 256)))
        idx = P.index_map(ceil_q16.reshape(-1, 3), pal_q16).reshape(256, 256)
        index_maps.append(idx)
        frames.append({
            "seedL": seed_q16[..., 0].ravel().tolist(),
            "patchesL": patch_major(ceil_q16[..., 0]).tolist(),
        })

    deltas = []
    for t in range(3):
        pos, new = frame_delta(index_maps[t], index_maps[t + 1])
        assert np.array_equal(apply_delta(index_maps[t], pos, new),
                              index_maps[t + 1].ravel()), "BA5 round-trip"
        deltas.append({"from": t, "to": t + 1,
                       "pos": pos.tolist(), "new": new.tolist(),
                       "churn": int(len(pos))})

    return {
        "fractal": {"ordering": ORDERING, "frames": frames},
        "deltas": {"list": deltas},
        "ev": {"plannedBiases": [],
               "actualRatios": evs.tolist(),
               "nextPlan": []},
        "indexMaps": {"256": index_maps},                    # kept for training
    }


# ── Device leg: load a report bundle ──────────────────────────────────────

def load_device_record(report_json_path):
    """report.json -> the same record dict, or None if pre-N0 bundle.

    Refusals are NAMED on stderr (a silent None hid pre-N0 bundles);
    the return contract (None) is unchanged."""
    with open(report_json_path) as f:
        r = json.load(f)
    if "fractal" not in r or "deltas" not in r:
        missing = [k for k in ("fractal", "deltas") if k not in r]
        print(f'REFUSED {report_json_path}: pre-N0 bundle '
              f'(no {"/".join(repr(k) for k in missing)} section) — '
              f're-capture with the current build', file=sys.stderr)
        return None                                          # pre-N0 bundle
    return {"fractal": r["fractal"], "deltas": r["deltas"], "ev": r["ev"]}


# ── The shared contract ────────────────────────────────────────────────────

def validate(rec):
    fr = rec["fractal"]["frames"]
    assert rec["fractal"]["ordering"] == ORDERING, "ordering convention drift"
    assert len(fr) == 4, "a cycle is 4 frames"
    for f in fr:
        assert len(f["seedL"]) == 256 and len(f["patchesL"]) == 65536
    dl = rec["deltas"]["list"]
    assert [(d["from"], d["to"]) for d in dl] == [(0, 1), (1, 2), (2, 3)]
    for d in dl:
        assert len(d["pos"]) == len(d["new"]) == d["churn"]
        assert all(a < b for a, b in zip(d["pos"], d["pos"][1:])), "pos ascending"
    assert set(rec["ev"]) >= {"plannedBiases", "actualRatios", "nextPlan"}
    return True


# ── Self-test ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Ordering: bijection + pure-H (each option's home patch -> one
    # contiguous 256-run) + spot formula (v,u,j,i)=(3,5,7,9).
    ident = np.arange(65536)
    assert np.array_equal(patch_major_inverse(patch_major(ident)), ident.reshape(256, 256))
    y, x = np.mgrid[0:256, 0:256]
    pure_h = (y // 16) * 16 + x // 16
    assert np.array_equal(patch_major(pure_h), np.repeat(np.arange(256), 256))
    assert patch_major(ident)[(3 * 16 + 5) * 256 + 7 * 16 + 9] \
        == (16 * 3 + 7) * 256 + 16 * 5 + 9
    print("  ordering: bijection + pure-H + spot formula OK")

    rng = np.random.default_rng(7)
    rec = synth_record(rng)
    validate(rec)
    churns = [d["churn"] for d in rec["deltas"]["list"]]
    print(f"  synth record: valid; churn per step = {churns}")

    import os
    dev = os.path.expanduser("~/Downloads/report.json")
    if os.path.exists(dev):
        drec = load_device_record(dev)
        if drec is None:
            print("  device: pre-N0 bundle (no fractal/deltas) — re-capture for the device leg")
        else:
            validate(drec)
            print("  device record: valid — synth and device records interchangeable")
    print("RECORD GREEN")
