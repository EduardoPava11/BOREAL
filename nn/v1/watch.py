#!/usr/bin/env python3
# ════════════════════════════════════════════════════════════════
# watch.py — the training watch CLI (stdlib only).
#
#   python3 watch.py <run.log | run.metrics.jsonl | dir>   one shot
#   python3 watch.py <target> --follow                     live view
#
# Reads, in order of preference:
#   1. <save>.metrics.jsonl  (structured; emitted per eval, flushed)
#   2. the run's stdout log  (parsed; only if the run flushes —
#      runs started before the line-buffering fix show empty logs)
#   3. degraded mode: process table + rolling-checkpoint mtime —
#      enough to answer "is it alive and moving?"
#
# Shows: liveness, step/ETA, latest hard metrics vs the CLEAN
# classic baselines (raw + equilibrium columns), a chi^2 sparkline,
# and the final dominance verdict when the run has ended.
# ════════════════════════════════════════════════════════════════
import argparse
import json
import math
import os
import re
import subprocess
import sys
import time

SPARK = '▁▂▃▄▅▆▇█'

# Float pattern that survives divergence: negatives, exponents, nan,
# ±inf — the old [\d.]+ dropped eval lines exactly when a run went bad.
FLOAT = r'(?:[-+]?(?:[\d.]+(?:e[-+]?\d+)?|nan|inf))'

STEP_RE = re.compile(
    r'step\s+(\d+)\s+loss\s+(' + FLOAT + r')\s+tau\s+(' + FLOAT + r')\s+'
    r'w_seed\s+' + FLOAT + r'\s+'
    r'chi2\s+(' + FLOAT + r')\s+homeShare\s+(' + FLOAT + r')\s+'
    r'dE\s+(' + FLOAT + r')'
    r'(?:.*?battle:\s+chi2\s+(' + FLOAT + r')\s+homeShare\s+(' + FLOAT
    + r')\s+dE\s+(' + FLOAT + r'))?')
BASE_RE = re.compile(
    r'baseline (CLEAN|NOISY) classic:\s+chi2\s+([\d.]+)\s+homeShare\s+'
    r'([\d.]+)\s+dE\s+([\d.]+)(?:.*?battle:\s+chi2\s+([\d.]+)\s+'
    r'homeShare\s+([\d.]+)\s+dE\s+([\d.]+))?')
DOM_RE = re.compile(r'dominance vs clean classic.*:\s+(\d+)/(\d+)')


def spark(vals, width=32):
    vals = [v for v in vals if math.isfinite(v)]     # nan/inf poison min/max
    if not vals:
        return ''
    vals = vals[-width:]
    lo, hi = min(vals), max(vals)
    span = (hi - lo) or 1.0
    return ''.join(SPARK[int((v - lo) / span * 7)] for v in vals)


def parse_jsonl(path):
    rows, start, final = [], None, None
    for line in open(path):
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get('event') == 'start':
            start = r
        elif r.get('event') == 'eval':
            rows.append(r)
        elif r.get('event') == 'final':
            final = r
    return start, rows, final


def parse_log(path):
    start = {'clean': None, 'noisy': None}
    rows, final = [], None
    for line in open(path, errors='replace'):
        m = BASE_RE.search(line)
        if m:
            key = m.group(1).lower()
            start[key] = {'chi2': float(m.group(2)),
                          'homeShare': float(m.group(3)),
                          'dE': float(m.group(4))}
            if m.group(5):
                start[key].update({'chi2_battle': float(m.group(5)),
                                   'homeShare_battle': float(m.group(6)),
                                   'dE_battle': float(m.group(7))})
            continue
        m = STEP_RE.search(line)
        if m:
            row = {'step': int(m.group(1)), 'loss': float(m.group(2)),
                   'tau': float(m.group(3)), 'chi2': float(m.group(4)),
                   'homeShare': float(m.group(5)), 'dE': float(m.group(6))}
            if m.group(7):
                row.update({'chi2_battle': float(m.group(7)),
                            'homeShare_battle': float(m.group(8)),
                            'dE_battle': float(m.group(9))})
            rows.append(row)
            continue
        m = DOM_RE.search(line)
        if m:
            final = {'dominance': int(m.group(1)), 'scenes': int(m.group(2))}
    st = None
    if start['clean']:
        st = {'clean': start['clean'], 'noisy': start['noisy']}
    return st, rows, final


def run_token(target):
    """The run's identifying token: basename, extensions and a leading
    'run_' stripped — used to scope process/checkpoint discovery so
    watching one run never shows a different run's state."""
    b = os.path.basename(target)
    for suf in ('.metrics.jsonl', '.ckpt.safetensors', '.safetensors',
                '.log'):
        if b.endswith(suf):
            b = b[:-len(suf)]
            break
    for pre in ('run_', 'v1h_'):
        if b.startswith(pre):
            b = b[len(pre):]
    return b


def find_processes(token=None):
    try:
        out = subprocess.run(
            ['pgrep', '-fl', 'train.py'], capture_output=True, text=True
        ).stdout.strip()
    except OSError:
        return []
    procs = []
    for line in out.splitlines():
        if token and token not in line:
            continue
        pid = line.split()[0]
        try:
            et = subprocess.run(['ps', '-o', 'etime=', '-p', pid],
                                capture_output=True, text=True).stdout.strip()
        except OSError:
            et = '?'
        procs.append((pid, et, line))
    return procs


def resolve(target):
    """Return (jsonl_path|None, log_path|None, ckpt_path|None)."""
    if os.path.isdir(target):
        js = sorted(f for f in os.listdir(target)
                    if f.endswith('.metrics.jsonl'))
        lg = sorted(f for f in os.listdir(target) if f.endswith('.log'))
        ck = sorted(f for f in os.listdir(target)
                    if f.endswith('.ckpt.safetensors'))
        j = os.path.join(target, js[-1]) if js else None
        l = os.path.join(target, lg[-1]) if lg else None
        c = os.path.join(target, ck[-1]) if ck else None
        return j, l, c
    if target.endswith('.metrics.jsonl'):
        return target, None, None
    if target.endswith('.log'):
        d = os.path.dirname(target) or '.'
        tok = run_token(target)
        js = sorted(f for f in os.listdir(d)
                    if f.endswith('.metrics.jsonl') and tok in f)
        cks = sorted(f for f in os.listdir(d)
                     if f.endswith('.ckpt.safetensors') and tok in f)
        j = os.path.join(d, js[-1]) if js else None
        c = os.path.join(d, cks[-1]) if cks else None
        return j, target, c
    return None, target, None


def render(target, total_steps=None):
    j, l, c = resolve(target)
    start, rows, final = (None, [], None)
    src = None
    if j and os.path.exists(j) and os.path.getsize(j):
        start, rows, final = parse_jsonl(j)
        src = j
    elif l and os.path.exists(l) and os.path.getsize(l):
        start, rows, final = parse_log(l)
        src = l

    out = []
    out.append('BOREAL train watch — '
               + os.path.basename(src or l or target))
    procs = find_processes(run_token(target))
    if procs:
        for pid, et, _ in procs:
            out.append(f'process: RUNNING  pid {pid}  elapsed {et}')
    else:
        out.append('process: not running'
                   + ('  (final verdict below)' if final else ''))
    if c and os.path.exists(c):
        age = time.time() - os.path.getmtime(c)
        out.append(f'checkpoint: {os.path.basename(c)}  '
                   f'({os.path.getsize(c) // 1024} KB, {age:.0f}s ago'
                   + (', STALE — run may be stuck' if age > 600 and procs
                      else '') + ')')

    if start:
        cl = start['clean'] if 'clean' in start else start.get('clean')
        if isinstance(start, dict) and 'clean' in start and start['clean']:
            cl = start['clean']
            line = (f"clean classic: chi2 {cl['chi2']:9.1f}  "
                    f"hs {cl['homeShare']:.4f}  dE {cl['dE']:.4f}")
            if 'chi2_battle' in cl:
                line += (f"  | eq: chi2 {cl['chi2_battle']:7.1f}  "
                         f"dE {cl['dE_battle']:.4f}")
            out.append(line)
    if rows:
        r = rows[-1]
        total = total_steps or (start or {}).get('steps')
        prog = f"step {r['step']}"
        if total:
            prog += f"/{total}  ({100 * r['step'] / total:.0f}%)"
            if len(rows) > 1 and 'elapsed' in rows[-1] and 'elapsed' in rows[0]:
                rate = ((rows[-1]['elapsed'] - rows[0]['elapsed'])
                        / max(rows[-1]['step'] - rows[0]['step'], 1))
                eta = (total - r['step']) * rate
                if math.isfinite(eta):               # nan rows must not crash
                    prog += f'  ETA {eta / 60:.0f}m'
        out.append(prog)
        line = (f"latest:  loss {r['loss']:.4f}  chi2 {r['chi2']:9.1f}  "
                f"hs {r['homeShare']:.4f}  dE {r['dE']:.4f}")
        if 'chi2_battle' in r:
            line += (f"  | eq: chi2 {r['chi2_battle']:7.1f}  "
                     f"dE {r['dE_battle']:.4f}")
        out.append(line)
        out.append(f"chi2 trend: {spark([x['chi2'] for x in rows])}")
        out.append(f"dE   trend: {spark([x['dE'] for x in rows])}")
    elif not final:
        out.append('no metrics yet (run started pre-fix and is buffered; '
                   'liveness above is from ps + checkpoint mtime)')
    if final:
        out.append(f"FINAL: dominance {final.get('dominance')}/"
                   f"{final.get('scenes')} scenes (equilibrium-layer gate)")
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('target', help='run .log / .metrics.jsonl / directory')
    ap.add_argument('--follow', '-f', action='store_true')
    ap.add_argument('--interval', type=float, default=10.0)
    ap.add_argument('--steps', type=int, default=None,
                    help='total steps (for ETA when log lacks it)')
    args = ap.parse_args()
    if not args.follow:
        print(render(args.target, args.steps))
        return
    try:
        while True:
            sys.stdout.write('\x1b[2J\x1b[H')
            print(render(args.target, args.steps))
            print(f'\n(refreshing every {args.interval:.0f}s — ctrl-c to exit)')
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
