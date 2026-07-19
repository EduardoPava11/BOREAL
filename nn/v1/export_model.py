# ════════════════════════════════════════════════════════════════
# export_model.py — package trained V1H weights for the app.
#
#   python3 export_model.py <weights.safetensors> [out.weights.bin]
#
# Emits the BOREAL V1HW package: a little-endian binary the app's
# V1HWeights.swift loader parses (magic 'V1HW', version 1, tensor
# table, fp16 payload) plus a .json manifest for humans. This is the
# DATA half of the ship path (the .aimodel/Core AI chain is B6 and
# waits on the Xcode 27 beta; a baked-weights Metal/Swift forward
# pass is the house-proven fallback — N4). Determinism policy: the
# learned path claims no bit-exactness; fp16 is fine (a precision
# choice, per the circuit doc).
#
# Format (all little-endian):
#   u32 magic = 0x56314857 ('V1HW' read as ASCII bytes V,1,H,W)
#   u16 version = 1
#   u16 tensorCount
#   u32 configLen; configLen bytes of JSON (d, in_side, flags, step…)
#   per tensor:
#     u16 nameLen; nameLen bytes utf-8 name (mlx tree path)
#     u8  dtype (0 = float16)
#     u8  ndim
#     u32 dims[ndim]
#     u32 byteLen; byteLen bytes fp16 payload
# ════════════════════════════════════════════════════════════════
import json
import os
import struct
import sys

import numpy as np
import mlx.core as mx

MAGIC = 0x56314857
VERSION = 1


def export(src, dst=None, config=None):
    weights = mx.load(src)                     # {name: mx.array}
    if dst is None:
        dst = src.replace('.safetensors', '.weights.bin')
    cfg = dict(config or {})
    cfg.setdefault('source', os.path.basename(src))
    names = sorted(weights.keys())
    cfg['tensors'] = len(names)
    cfg_bytes = json.dumps(cfg).encode('utf-8')

    with open(dst, 'wb') as f:
        f.write(struct.pack('<IHH', MAGIC, VERSION, len(names)))
        f.write(struct.pack('<I', len(cfg_bytes)))
        f.write(cfg_bytes)
        manifest = []
        for name in names:
            a = np.array(weights[name]).astype(np.float16)
            nb = name.encode('utf-8')
            f.write(struct.pack('<H', len(nb)))
            f.write(nb)
            f.write(struct.pack('<BB', 0, a.ndim))
            f.write(struct.pack(f'<{a.ndim}I', *a.shape))
            payload = a.tobytes()
            f.write(struct.pack('<I', len(payload)))
            f.write(payload)
            manifest.append({'name': name, 'shape': list(a.shape),
                             'params': int(a.size)})
    total = sum(m['params'] for m in manifest)
    with open(dst.replace('.bin', '.json'), 'w') as f:
        json.dump({'config': cfg, 'totalParams': total,
                   'tensors': manifest}, f, indent=1)
    print(f'exported {total} params in {len(names)} tensors -> {dst} '
          f'({os.path.getsize(dst) // 1024} KB)')
    return dst


if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.exit('usage: export_model.py <weights.safetensors> [out.bin]')
    export(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
