#!/usr/bin/env python3
"""
categorize-bcube.py — re-runnable statistical categorizer for a BOREAL
session bundle.

Usage:
    python3 categorize-bcube.py <path-to-session-*.bcube>

Emits a structured text report covering 8 dimensions of the captured
statistical cube. The final section ("NN-LABEL INDEX") names the
supervised / self-supervised pretext tasks each dimension can power for
a future 64×64×64 cyclical NN trained on these cubes.

The .bcube format is fully documented in
    /Users/daniel/BOREAL/BOREAL/Container/SessionPack.swift
The .bvox v3 format is fully documented in
    /Users/daniel/BOREAL/BOREAL/Container/VoxelPack.swift

This script is intentionally standalone: stdlib + numpy only, no
BOREAL Swift dependencies. Run on any Mac with a .bcube in reach.
"""
import json
import struct
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

# ──────────────────────────────────────────────────────────────────────
# Constants — must match SessionPack.swift / VoxelPack.swift exactly.
# ──────────────────────────────────────────────────────────────────────
BCUBE_MAGIC = b"BCUB"
BVOX_MAGIC  = b"BVOX"
SLOW_MAGIC  = b"SLOW"
SET_COUNT   = 16
BIN_GRID    = 64                  # 64×64 spatial bins per set
SPATIAL_BINS = BIN_GRID * BIN_GRID  # 4096
FRAMES_PER_SET = 4
HEADER_BCUBE = 32
HEADER_BVOX  = 96
TRAILER_BVOX = 64
COL_BYTES    = SPATIAL_BINS * 4   # every column is 16,384 B
BVOX_V3_SIZE = 229_536            # header + 14*col + trailer
BVOX_V4_SIZE = 344_224            # header + 21*col + trailer
SLOW_HEADER_BYTES = 56
SLOW_COLUMN_BYTES = COL_BYTES
SLOW_BODY_BYTES   = 10 * SLOW_COLUMN_BYTES
SLOW_FOOTER_BYTES = 4 * 4
SLOW_BLOCK_BYTES  = SLOW_HEADER_BYTES + SLOW_BODY_BYTES + SLOW_FOOTER_BYTES

SHAPE_CLASS_NAMES = ["SYMMETRIC", "LEFT_SKEW", "RIGHT_SKEW", "BIMODAL"]
SHAPE_CLASS_GLYPHS = ["·", "◐", "◑", "●"]   # ASCII heatmap legend


def crc64_iso3309(data):
    """ISO 3309 reflected CRC64 — matches VoxelPack.crc64 in Swift."""
    poly = 0xC96C5795D7870F42
    table = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ poly if c & 1 else c >> 1
        table.append(c)
    crc = 0xFFFFFFFFFFFFFFFF
    for byte in data:
        crc = (crc >> 8) ^ table[(crc ^ byte) & 0xFF]
    return crc ^ 0xFFFFFFFFFFFFFFFF


# ──────────────────────────────────────────────────────────────────────
# Section 1 — Header / manifest summary
# ──────────────────────────────────────────────────────────────────────
def section_header(b, manifest, stored_crc, computed_crc):
    magic    = b[0:4]
    version  = struct.unpack("<H", b[4:6])[0]
    setCnt   = struct.unpack("<H", b[6:8])[0]
    pyrHash  = struct.unpack("<Q", b[8:16])[0]
    tsNs     = struct.unpack("<q", b[16:24])[0]
    ts       = datetime.fromtimestamp(tsNs / 1e9, tz=timezone.utc)
    mOff     = struct.unpack("<I", b[24:28])[0]
    mLen     = struct.unpack("<I", b[28:32])[0]

    crc_ok = "OK ✓" if stored_crc == computed_crc else "FAIL ✗"
    magic_ok = "OK ✓" if magic == BCUBE_MAGIC else "FAIL ✗"

    print("=" * 70)
    print("SECTION 1 — Header & integrity")
    print("=" * 70)
    print(f"  magic           : {magic.decode('ascii', errors='replace'):>6}   {magic_ok}")
    print(f"  version         : {version}")
    print(f"  setCount        : {setCnt} (expected {SET_COUNT})")
    print(f"  pyramidHash     : 0x{pyrHash:016x}")
    print(f"  timestamp       : {ts.isoformat()}")
    print(f"  manifestOffset  : {mOff:,}")
    print(f"  manifestLen     : {mLen:,} B")
    print(f"  file total      : {len(b):,} B")
    print(f"  stored CRC64    : 0x{stored_crc:016x}")
    print(f"  computed CRC64  : 0x{computed_crc:016x}   {crc_ok}")
    print(f"  session_id      : {manifest['sessionId']}")
    print(f"  device_model    : {manifest['deviceModel']}")
    print(f"  iOS             : {manifest['iosVersion']}")
    print(f"  pyramid         : {manifest['pyramid']}")
    print()


# ──────────────────────────────────────────────────────────────────────
# .bvox column decoders
# ──────────────────────────────────────────────────────────────────────
def f32_col(bv, i):
    off = HEADER_BVOX + i * COL_BYTES
    return np.frombuffer(bv[off : off + COL_BYTES], dtype=np.float32).copy()


def u32_col(bv, i):
    off = HEADER_BVOX + i * COL_BYTES
    return np.frombuffer(bv[off : off + COL_BYTES], dtype=np.uint32).copy()


def decode_set(bv):
    """Decode one .bvox blob into a dict of named arrays + reconstructed LAB.
    Handles v3 and v4 — v4 adds 7 fast-scale columns + 4 trailer scalars."""
    L_min, L_max, L_mean = f32_col(bv, 0), f32_col(bv, 1), f32_col(bv, 2)
    a_min, a_max, a_mean = f32_col(bv, 3), f32_col(bv, 4), f32_col(bv, 5)
    b_min, b_max, b_mean = f32_col(bv, 6), f32_col(bv, 7), f32_col(bv, 8)
    cf = u32_col(bv, 9)
    L_code = (cf & 0xFF).astype(np.uint8)
    a_code = ((cf >> 8) & 0xFF).astype(np.uint8)
    b_code = ((cf >> 16) & 0xFF).astype(np.uint8)
    flags  = ((cf >> 24) & 0xFF).astype(np.uint8)
    L_shape = u32_col(bv, 10)
    a_shape = u32_col(bv, 11)
    b_shape = u32_col(bv, 12)
    intra_sigma = f32_col(bv, 13)
    L_class = ((L_shape >> 30) & 0x3).astype(np.uint8)
    L_chi2  = ((L_shape >> 24) & 0x3F).astype(np.float32) / 2.0       # u6 ×2 scale
    L_sigma = (L_shape & 0xFF).astype(np.float32) / 2.0                # u8 ×2 scale
    # Skewness γ₃ is signed i8 with ×64 scale.
    L_gamma3 = np.frombuffer(((L_shape >> 8) & 0xFF).astype(np.uint8).tobytes(),
                             dtype=np.int8).astype(np.float32) / 64.0

    version = struct.unpack("<H", bv[4:6])[0]
    out = {
        "version": version,
        "L_min": L_min, "L_max": L_max, "L_mean": L_mean,
        "a_min": a_min, "a_max": a_max, "a_mean": a_mean,
        "b_min": b_min, "b_max": b_max, "b_mean": b_mean,
        "L_code": L_code, "a_code": a_code, "b_code": b_code,
        "flags": flags, "L_class": L_class, "L_chi2": L_chi2,
        "L_sigma": L_sigma, "L_gamma3": L_gamma3,
        "intra_sigma": intra_sigma,
    }

    # v4 fast-scale columns (14..20) + trailer scalars.
    if version >= 4:
        out["fast_cov_La"]      = f32_col(bv, 14)
        out["fast_cov_Lb"]      = f32_col(bv, 15)
        out["fast_cov_ab"]      = f32_col(bv, 16)
        out["fast_nbr_rho_L"]   = f32_col(bv, 17)
        out["fast_nbr_rho_a"]   = f32_col(bv, 18)
        out["fast_nbr_rho_b"]   = f32_col(bv, 19)
        out["fast_motion_mag"]  = f32_col(bv, 20)
        # Trailer scalars at trailer + 48..63.
        body_bytes = 17 * COL_BYTES + 4 * COL_BYTES   # 17 f32 + 4 u32 columns
        t_start = HEADER_BVOX + body_bytes
        out["trailer_rho1_L"] = struct.unpack("<f", bv[t_start+48:t_start+52])[0]
        out["trailer_rho1_a"] = struct.unpack("<f", bv[t_start+52:t_start+56])[0]
        out["trailer_rho1_b"] = struct.unpack("<f", bv[t_start+56:t_start+60])[0]
        out["trailer_kl_L"]   = struct.unpack("<f", bv[t_start+60:t_start+64])[0]
    return out


def decode_slow_block(b, off):
    """Decode the .bcube v2 SLOW block at byte offset `off`. Returns None
    if the magic doesn't match (i.e. the file is v1 with no slow block)."""
    if b[off:off+4] != SLOW_MAGIC:
        return None
    p = off + SLOW_HEADER_BYTES
    cols = {}
    for name in ("L_mean", "a_mean", "b_mean",
                 "L_var",  "a_var",  "b_var",
                 "cov_La", "cov_Lb", "cov_ab",
                 "motion"):
        cols[name] = np.frombuffer(b[p:p+COL_BYTES], dtype=np.float32).copy()
        p += COL_BYTES
    cols["slowRho1_L"] = struct.unpack("<f", b[p:p+4])[0]
    cols["slowRho1_a"] = struct.unpack("<f", b[p+4:p+8])[0]
    cols["slowRho1_b"] = struct.unpack("<f", b[p+8:p+12])[0]
    cols["nu_L"]       = struct.unpack("<f", b[p+12:p+16])[0]
    return cols


# ──────────────────────────────────────────────────────────────────────
# Section 2 — Per-set statistics table
# ──────────────────────────────────────────────────────────────────────
def section_per_set(sets):
    print("=" * 70)
    print("SECTION 2 — Per-set statistics")
    print("=" * 70)
    hdr = (f"  {'set':>3}  {'L*_mean':>7}  {'a*':>6}  {'b*':>6}  "
           f"{'BEAUTY%':>7}  {'STATIC%':>7}  {'χ²_mean':>7}  {'intra_σ':>7}  "
           f"{'SYM':>4} {'L_SK':>4} {'R_SK':>4} {'BI':>4}")
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for i, s in enumerate(sets):
        beauty_pct = float((s["flags"] >> 7).sum()) / SPATIAL_BINS * 100
        static_pct = float((s["flags"] & 1).sum()) / SPATIAL_BINS * 100
        cls_counts = np.bincount(s["L_class"], minlength=4)
        print(f"  {i:3d}  {s['L_mean'].mean():7.2f}  "
              f"{s['a_mean'].mean():+6.2f}  {s['b_mean'].mean():+6.2f}  "
              f"{beauty_pct:6.2f}%  {static_pct:6.2f}%  "
              f"{s['L_chi2'].mean():7.2f}  {s['intra_sigma'].mean():7.1f}  "
              f"{cls_counts[0]:4d} {cls_counts[1]:4d} "
              f"{cls_counts[2]:4d} {cls_counts[3]:4d}")
    print()


# ──────────────────────────────────────────────────────────────────────
# Section 3 — Global LAB histograms
# ──────────────────────────────────────────────────────────────────────
def section_lab_histograms(sets):
    """10-bucket histograms over the FULL reconstructed cube
    (16 sets × 4 frames × 4096 bins = 262,144 cells per channel)."""
    print("=" * 70)
    print("SECTION 3 — Global LAB histograms (262,144 cells per channel)")
    print("=" * 70)
    # Reconstruct per-frame LAB values via the base-4 codes.
    all_L, all_a, all_b = [], [], []
    for s in sets:
        for f in range(FRAMES_PER_SET):
            qL = (s["L_code"] >> (2 * f)) & 0x3
            qa = (s["a_code"] >> (2 * f)) & 0x3
            qb = (s["b_code"] >> (2 * f)) & 0x3
            L = s["L_min"] + (qL / 3.0) * (s["L_max"] - s["L_min"])
            a = s["a_min"] + (qa / 3.0) * (s["a_max"] - s["a_min"])
            b = s["b_min"] + (qb / 3.0) * (s["b_max"] - s["b_min"])
            all_L.append(L); all_a.append(a); all_b.append(b)
    L = np.concatenate(all_L); a = np.concatenate(all_a); b = np.concatenate(all_b)
    for name, arr in [("L*", L), ("a*", a), ("b*", b)]:
        counts, edges = np.histogram(arr, bins=10)
        print(f"  {name}  range=[{arr.min():+7.2f}, {arr.max():+7.2f}]   mean={arr.mean():+6.2f}")
        for j in range(10):
            bar_len = int(50.0 * counts[j] / counts.max())
            print(f"    [{edges[j]:+7.2f}, {edges[j+1]:+7.2f})  {counts[j]:7d}  "
                  f"{'█' * bar_len}")
        print()


# ──────────────────────────────────────────────────────────────────────
# Section 4 — Spatial shape-class map (majority vote across sets)
# ──────────────────────────────────────────────────────────────────────
def section_spatial_class_map(sets):
    print("=" * 70)
    print(f"SECTION 4 — Spatial L-channel shape-class map ({BIN_GRID}×{BIN_GRID})")
    print("=" * 70)
    classes = np.stack([s["L_class"] for s in sets], axis=0)   # (16, 4096)
    # Per-bin majority class across 16 sets.
    dominant = np.zeros(SPATIAL_BINS, dtype=np.uint8)
    for i in range(SPATIAL_BINS):
        c = np.bincount(classes[:, i], minlength=4)
        dominant[i] = c.argmax()
    grid = dominant.reshape(BIN_GRID, BIN_GRID)
    print("  Legend:  " + "   ".join(f"{g} = {n}" for g, n in
                                     zip(SHAPE_CLASS_GLYPHS, SHAPE_CLASS_NAMES)))
    print()
    for y in range(BIN_GRID):
        row = "".join(SHAPE_CLASS_GLYPHS[grid[y, x]] for x in range(BIN_GRID))
        print(f"  {row}")
    print()


# ──────────────────────────────────────────────────────────────────────
# Section 5 — Top-10 temporal codes
# ──────────────────────────────────────────────────────────────────────
def section_top_codes(sets):
    print("=" * 70)
    print("SECTION 5 — Top-10 most-frequent L-channel temporal codes")
    print("=" * 70)
    all_codes = np.concatenate([s["L_code"] for s in sets])
    counts = Counter(int(c) for c in all_codes)
    total = sum(counts.values())
    print(f"  total samples: {total:,}   unique codes used: {len(counts)} / 256")
    print()
    print(f"  {'rank':>4}  {'code':>4}  {'hex':>4}  {'q-tuple':>14}  {'count':>10}  {'pct':>6}")
    for rank, (code, n) in enumerate(counts.most_common(10), start=1):
        q = tuple((code >> (2 * k)) & 0x3 for k in range(4))
        print(f"  {rank:4d}  {code:4d}  0x{code:02x}  {str(q):>14}  "
              f"{n:10,}  {n*100/total:5.2f}%")
    print()


# ──────────────────────────────────────────────────────────────────────
# Section 6 — χ² distribution
# ──────────────────────────────────────────────────────────────────────
def section_chi2_distribution(sets):
    print("=" * 70)
    print("SECTION 6 — L-channel χ² (Bin(3, ½) distance) distribution")
    print("=" * 70)
    all_chi2 = np.concatenate([s["L_chi2"] for s in sets])
    counts, edges = np.histogram(all_chi2, bins=10, range=(0, 32))
    total = all_chi2.size
    for j in range(10):
        bar_len = int(50.0 * counts[j] / counts.max())
        print(f"  [{edges[j]:5.2f}, {edges[j+1]:5.2f})  {counts[j]:7d}  "
              f"({counts[j]*100/total:5.2f}%)  {'█' * bar_len}")
    print()
    print(f"  pct < 1.33  (uniform-ramp territory)  : "
          f"{(all_chi2 < 1.33).sum()*100/total:.2f}%")
    print(f"  pct < 4.00  (FLAG_BEAUTY threshold)   : "
          f"{(all_chi2 < 4.00).sum()*100/total:.2f}%")
    print(f"  pct ≥ 12.00 (bimodal-like)            : "
          f"{(all_chi2 >= 12.00).sum()*100/total:.2f}%")
    print()


# ──────────────────────────────────────────────────────────────────────
# Section 7 — Cross-correlations
# ──────────────────────────────────────────────────────────────────────
def section_correlations(sets):
    print("=" * 70)
    print("SECTION 7 — Cross-correlations")
    print("=" * 70)
    # Flatten all (16 × 4096) samples.
    L_range = np.concatenate([s["L_max"] - s["L_min"] for s in sets])
    a_range = np.concatenate([s["a_max"] - s["a_min"] for s in sets])
    b_range = np.concatenate([s["b_max"] - s["b_min"] for s in sets])
    chi2    = np.concatenate([s["L_chi2"] for s in sets])
    isigma  = np.concatenate([s["intra_sigma"] for s in sets])
    cls     = np.concatenate([s["L_class"] for s in sets])
    flags   = np.concatenate([s["flags"] for s in sets])
    beauty  = ((flags >> 7) & 1).astype(bool)
    symm    = (cls == 0)

    def pearson(x, y):
        x = x.astype(np.float64); y = y.astype(np.float64)
        if x.std() == 0 or y.std() == 0:
            return float("nan")
        return float(np.corrcoef(x, y)[0, 1])

    print(f"  Pearson r (L-range  vs a-range)       : {pearson(L_range, a_range):+.4f}")
    print(f"  Pearson r (L-range  vs b-range)       : {pearson(L_range, b_range):+.4f}")
    print(f"  Pearson r (L-chi²   vs intra_σ)       : {pearson(chi2, isigma):+.4f}")
    print(f"  Pearson r (L-range  vs intra_σ)       : {pearson(L_range, isigma):+.4f}")
    n = beauty.size
    print()
    print(f"  BEAUTY ∩ SYMMETRIC                    : "
          f"{int((beauty & symm).sum()):>7,} / {n:,}  "
          f"({(beauty & symm).sum()*100/n:.2f}%)")
    print(f"  BEAUTY only                           : "
          f"{int((beauty & ~symm).sum()):>7,} / {n:,}  "
          f"({(beauty & ~symm).sum()*100/n:.2f}%)")
    print(f"  SYMMETRIC only                        : "
          f"{int((~beauty & symm).sum()):>7,} / {n:,}  "
          f"({(~beauty & symm).sum()*100/n:.2f}%)")
    print()


# ──────────────────────────────────────────────────────────────────────
# Section 8 — NN-LABEL INDEX
# ──────────────────────────────────────────────────────────────────────
def section_v4_fast_covariance(sets):
    """v4 §9 — fast cross-channel covariance distribution per set."""
    if "fast_cov_La" not in sets[0]:
        print("(v3 file — no fast covariance columns; section 9 skipped)\n")
        return
    print("=" * 70)
    print("SECTION 9 — v4 fast cross-channel covariance (per-bin)")
    print("=" * 70)
    print(f"  {'set':>3}  {'|cov_La|':>10}  {'|cov_Lb|':>10}  {'|cov_ab|':>10}  "
          f"{'rho1_L':>7}  {'rho1_a':>7}  {'rho1_b':>7}  {'kl_L':>6}")
    for i, s in enumerate(sets):
        print(f"  {i:3d}  "
              f"{np.mean(np.abs(s['fast_cov_La'])):10.3f}  "
              f"{np.mean(np.abs(s['fast_cov_Lb'])):10.3f}  "
              f"{np.mean(np.abs(s['fast_cov_ab'])):10.3f}  "
              f"{s['trailer_rho1_L']:7.3f}  "
              f"{s['trailer_rho1_a']:7.3f}  "
              f"{s['trailer_rho1_b']:7.3f}  "
              f"{s['trailer_kl_L']:6.3f}")
    print()


def section_v4_slow_block(slow):
    """v4 §10 — slow-scale per-bin variance + motion."""
    if slow is None:
        print("(no SLOW block — file is v1 .bcube; section 10 skipped)\n")
        return
    print("=" * 70)
    print("SECTION 10 — v2 SLOW block (per-bin 16-set statistics)")
    print("=" * 70)
    print(f"  slow_L_var      : mean={slow['L_var'].mean():7.2f}  "
          f"min={slow['L_var'].min():7.2f}  max={slow['L_var'].max():7.2f}")
    print(f"  slow_a_var      : mean={slow['a_var'].mean():7.2f}  "
          f"min={slow['a_var'].min():7.2f}  max={slow['a_var'].max():7.2f}")
    print(f"  slow_b_var      : mean={slow['b_var'].mean():7.2f}  "
          f"min={slow['b_var'].min():7.2f}  max={slow['b_var'].max():7.2f}")
    print(f"  slow_motion_mag : mean={slow['motion'].mean():7.2f}  "
          f"min={slow['motion'].min():7.2f}  max={slow['motion'].max():7.2f}")
    print(f"  cov_La/Lb/ab    : mean={np.mean(np.abs(slow['cov_La'])):.2f} / "
          f"{np.mean(np.abs(slow['cov_Lb'])):.2f} / "
          f"{np.mean(np.abs(slow['cov_ab'])):.2f}")
    print()


def section_v4_fast_vs_slow_motion(sets, slow):
    """v4 §11 — compare fast motion magnitudes to slow motion."""
    if "fast_motion_mag" not in sets[0] or slow is None:
        print("(missing v4 fast or slow columns; section 11 skipped)\n")
        return
    print("=" * 70)
    print("SECTION 11 — Fast vs slow motion magnitudes")
    print("=" * 70)
    fast_means = [s["fast_motion_mag"].mean() for s in sets]
    print(f"  mean fast_motion across 16 sets : {np.mean(fast_means):7.3f}")
    print(f"  per-set spread (min..max)       : {min(fast_means):7.3f} .. {max(fast_means):7.3f}")
    print(f"  slow_motion (16-set drift) mean : {slow['motion'].mean():7.3f}")
    print(f"  slow_motion max bin             : {slow['motion'].max():7.3f}")
    print()


def section_v4_hierarchical(slow):
    """v4 §12 — Theorem 6 hierarchical decomposition: ν + slow ρ₁."""
    if slow is None:
        print("(no SLOW block; section 12 skipped)\n")
        return
    print("=" * 70)
    print("SECTION 12 — Hierarchical statistics (Fahmy Theorem 6, Ch.1)")
    print("=" * 70)
    print(f"  ν_L (between/within ratio) : {slow['nu_L']:6.3f}")
    print(f"    ~ 1 ⇒ all variance lives BETWEEN sets (signature-rich)")
    print(f"    ~ 0 ⇒ all variance lives WITHIN  sets (drifting, ambient)")
    print(f"  slow_rho1_L (16-set seq)   : {slow['slowRho1_L']:+6.3f}")
    print(f"  slow_rho1_a (16-set seq)   : {slow['slowRho1_a']:+6.3f}")
    print(f"  slow_rho1_b (16-set seq)   : {slow['slowRho1_b']:+6.3f}")
    print()


def section_nn_label_index():
    print("=" * 70)
    print("SECTION 8 — NN-LABEL INDEX (candidate training signals)")
    print("=" * 70)
    rows = [
        ("shape_class (col_L_shape bits 30..31)",
         "per-bin 4-way classification",
         "CE loss"),
        ("FLAG_BEAUTY (codesFlags bit 31)",
         "per-bin binary classification",
         "BCE loss"),
        ("intra_sigma_avg (col 13, f32)",
         "per-bin scalar regression",
         "MSE / L1 loss"),
        ("L_chi2 (col_L_shape bits 24..29)",
         "per-bin scalar regression OR binary",
         "(above/below BEAUTY_THRESHOLD)"),
        ("L_code (codesFlags bits 0..7)",
         "per-bin 256-way categorical",
         "autoregressive along temporal axis"),
        ("temporal trajectory (q[0..3])",
         "next-frame prediction from prior",
         "self-supervised, sliding window"),
        ("L_mean / a_mean / b_mean",
         "per-bin LAB regression",
         "L2 loss in LAB or OKLab"),
        ("dominant spatial class map (sec 4)",
         "global texture classification",
         "image-level CE"),
    ]
    print(f"  {'feature':<42}  {'task type':<32}  {'loss'}")
    print("  " + "-" * 92)
    for feat, task, loss in rows:
        print(f"  {feat:<42}  {task:<32}  {loss}")
    print()
    print("  See ~/.claude/projects/-Users-daniel/memory/boreal-nn-roadmap.md")
    print("  for how each label feeds the planned 64×64×64 cyclical NN core.")
    print()


# ──────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────
def main():
    if len(sys.argv) != 2:
        print("usage: python3 categorize-bcube.py <session-*.bcube>", file=sys.stderr)
        sys.exit(2)
    src = Path(sys.argv[1])
    if not src.exists():
        print(f"file not found: {src}", file=sys.stderr)
        sys.exit(1)

    b = src.read_bytes()
    if len(b) < HEADER_BCUBE + 8:
        print(f"file too small: {len(b)} bytes", file=sys.stderr)
        sys.exit(1)
    if b[:4] != BCUBE_MAGIC:
        print(f"bad magic: {b[:4]!r}, expected {BCUBE_MAGIC!r}", file=sys.stderr)
        sys.exit(1)

    # Header
    mOff = struct.unpack("<I", b[24:28])[0]
    mLen = struct.unpack("<I", b[28:32])[0]
    manifest = json.loads(b[mOff : mOff + mLen])
    stored_crc = struct.unpack("<Q", b[-8:])[0]
    computed_crc = crc64_iso3309(b[:-8])

    # Decode all 16 sets
    sets = []
    end_of_body = HEADER_BCUBE
    for entry in manifest["sets"]:
        bv = b[entry["offset"] : entry["offset"] + entry["size"]]
        if bv[:4] != BVOX_MAGIC:
            print(f"set-{entry['setIdx']:02d}: bad BVOX magic", file=sys.stderr)
            sys.exit(1)
        sets.append(decode_set(bv))
        end_of_body = max(end_of_body, entry["offset"] + entry["size"])

    # v2: attempt to parse a SLOW block between body and manifest offset.
    slow = None
    if mOff > end_of_body and mOff - end_of_body >= SLOW_BLOCK_BYTES:
        slow = decode_slow_block(b, end_of_body)

    # Emit all sections (8 legacy + 4 new v4)
    section_header(b, manifest, stored_crc, computed_crc)
    section_per_set(sets)
    section_lab_histograms(sets)
    section_spatial_class_map(sets)
    section_top_codes(sets)
    section_chi2_distribution(sets)
    section_correlations(sets)
    section_v4_fast_covariance(sets)
    section_v4_slow_block(slow)
    section_v4_fast_vs_slow_motion(sets, slow)
    section_v4_hierarchical(slow)
    section_nn_label_index()


if __name__ == "__main__":
    main()
