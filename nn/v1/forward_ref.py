# ════════════════════════════════════════════════════════════════
# forward_ref.py — the V1 engine's reference forward + fixture.
#
# THE RUNTIME LADDER (signal-ladder doc): ONE model, ONE V1HW
# artifact, engines promoted on parity — V1 Swift/Accelerate is the
# first ship tier. This file is V1's reference: a numpy-only
# (no MLX at inference) float32 forward of the ENCODER + PALETTE
# slice — the model's product job is the seed proposal — mirroring
# the layer semantics of model.py exactly:
#
#   stem  conv3x3 pad1 groups=4 (16 -> 2d), leaky 1/16
#   fuse  conv1x1 (2d -> d)                       (no activation)
#   ladder 4x conv3x3 stride2 pad1 (d -> d), leaky 1/16 each
#   palette conv1x1 (d -> 3)  -> (16,16,3) seed proposal
#
# Weight layout (MLX Conv2d, NHWC): (C_out, kH, kW, C_in/groups).
# fp16 payload widened to f32; all math float32 (the engine's
# precision class — the learned path claims NO bit-exactness, only
# tolerance parity; promotion beyond that is judged on metrics).
#
# Fixture: fixtures/v1h_forward_golden.json. The 256x256x16 input is
# NOT stored — it regenerates from the house LCG convention (exactly
# like the homeShare golden): s_{k+1} = s_k*6364136223846793005 +
# 1442695040888963407 (wrapping u64), s_0 = 12345, value_k =
# ((s_k >> 16) mod 4096)/4096, k row-major over (y, x, c). Only the
# 768-value seed output ships, plus maxAbs tolerance.
#
# Regenerate (after a new champion export):
#   python3 nn/v1/forward_ref.py [runs/<champion>.weights.bin]
# and copy the champion package to fixtures/v1h_d96.weights.bin.
# ════════════════════════════════════════════════════════════════
import json
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, '..', '..', 'fixtures')

MASK = (1 << 64) - 1


def load_package(path):
    d = open(path, 'rb').read()
    magic, ver, count = struct.unpack_from('<IHH', d, 0)
    assert magic == 0x56314857 and ver == 1
    cfglen, = struct.unpack_from('<I', d, 8)
    cfg = json.loads(d[12:12 + cfglen])
    off = 12 + cfglen
    tensors = {}
    for _ in range(count):
        nl, = struct.unpack_from('<H', d, off); off += 2
        name = d[off:off + nl].decode(); off += nl
        dt, nd = struct.unpack_from('<BB', d, off); off += 2
        dims = struct.unpack_from(f'<{nd}I', d, off); off += 4 * nd
        bl, = struct.unpack_from('<I', d, off); off += 4
        a = np.frombuffer(d[off:off + bl], dtype=np.float16); off += bl
        tensors[name] = a.astype(np.float32).reshape(dims)
    return cfg, tensors


def lcg_input(side, channels, seed=12345):
    n = side * side * channels
    out = np.empty(n, dtype=np.float32)
    s = seed
    for k in range(n):
        out[k] = ((s >> 16) % 4096) / 4096.0
        s = (s * 6364136223846793005 + 1442695040888963407) & MASK
    return out.reshape(side, side, channels)


def conv2d(x, w, stride=1, pad=1, groups=1):
    """NHWC x (H,W,Cin); w (Cout, kH, kW, Cin/groups); float32."""
    H, W, Cin = x.shape
    Cout, kH, kW, Cg = w.shape
    xp = np.pad(x, ((pad, pad), (pad, pad), (0, 0))).astype(np.float32)
    Ho, Wo = (H + 2 * pad - kH) // stride + 1, (W + 2 * pad - kW) // stride + 1
    out = np.empty((Ho, Wo, Cout), dtype=np.float32)
    cog = Cout // groups
    for g in range(groups):
        xg = xp[:, :, g * Cg:(g + 1) * Cg]
        # im2col rows = output pixels, cols ordered (ky, kx, ci).
        cols = np.empty((Ho * Wo, kH * kW * Cg), dtype=np.float32)
        i = 0
        for ky in range(kH):
            for kx in range(kW):
                patch = xg[ky:ky + Ho * stride:stride,
                           kx:kx + Wo * stride:stride, :]
                cols[:, i * Cg:(i + 1) * Cg] = patch.reshape(Ho * Wo, Cg)
                i += 1
        wg = w[g * cog:(g + 1) * cog].reshape(cog, -1)   # (cog, K)
        out[:, :, g * cog:(g + 1) * cog] = \
            (cols @ wg.T).reshape(Ho, Wo, cog)
    return out


def leaky(x, slope=1.0 / 16):
    return np.where(x > 0, x, x * np.float32(slope)).astype(np.float32)


def seed_forward(tensors, x):
    h = leaky(conv2d(x, tensors['encoder.stem.weight'], groups=4))
    h = conv2d(h, tensors['encoder.fuse.weight'], pad=0)
    for i in range(4):
        h = leaky(conv2d(h, tensors[f'encoder.ladder.{i}.weight'], stride=2))
    return conv2d(h, tensors['palette.weight'], pad=0)   # (16,16,3)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(HERE, 'runs', 'v1h_e5_d96_rep.weights.bin')
    cfg, tensors = load_package(src)
    side, d = cfg['in_side'], cfg['d']
    x = lcg_input(side, 16)
    seed = seed_forward(tensors, x)
    fixture = {
        'conventions': {
            'input': 'NOT stored — regenerate: s0=12345, value_k = ((s>>16) mod 4096)/4096, s = wrapping-u64 s*6364136223846793005 + 1442695040888963407, k row-major over (y,x,c) at (in_side, in_side, 16)',
            'forward': 'float32 encoder+palette slice: stem conv3x3 pad1 g4 + leaky 1/16; fuse 1x1; 4x ladder conv3x3 stride2 pad1 + leaky 1/16; palette 1x1 -> (16,16,3); weights (Cout,kH,kW,Cin/g) fp16 widened f32',
            'parity': 'learned path: TOLERANCE parity (maxAbs), never bit-exact — reduction order is engine-private; promotion beyond numeric parity is judged on battle metrics',
        },
        'package': 'v1h_d96.weights.bin (the e5 d96 replicate champion)',
        'sourceConfig': cfg,
        'inSide': side,
        'd': d,
        'lcgSeed': 12345,
        'seedOut': [float(v) for v in seed.reshape(-1)],
        'maxAbsTolerance': 1e-3,
    }
    out = os.path.join(FIXTURES, 'v1h_forward_golden.json')
    with open(out, 'w') as f:
        json.dump(fixture, f, sort_keys=True)
    print(f'wrote {out}')
    print(f'seed out: shape (16,16,3), range [{seed.min():.4f}, {seed.max():.4f}]')


if __name__ == '__main__':
    main()
