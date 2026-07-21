# ════════════════════════════════════════════════════════════════
# torch_host.py — V3a keystone (BOREAL-COREAI-ANE-RESEARCH.md §5).
#
# ONE PyTorch re-host of the V1H ship slice (encoder + palette),
# NCHW, feeding BOTH deployment paths:
#   V3a (today):    coremltools -> .mlpackage -> MLComputePlan
#                   per-op ANE residency on this machine's ANE
#   V3b (Xcode 27): torch.export -> coreai-torch -> .aimodel, with
#                   this module as the Core AI Debugger's reference
#
# Weights come from the V1HW package (fp16, MLX layout
# (C_out, kH, kW, C_in/groups)) — permuted to PyTorch's
# (C_out, C_in/groups, kH, kW). Parity is the SAME gate the V1
# Accelerate engine answers to: the LCG input convention and the
# numpy reference (forward_ref.py), maxAbs tolerance — the learned
# path's precision class, engine-private reduction order.
#
#   python3 torch_host.py [runs/<champ>.weights.bin]
#     step 1: parity vs forward_ref (tolerance 1e-3, expect ~1e-4)
#     step 2: convert to fp16 .mlpackage (static 1x16x256x256)
#     step 3: MLComputePlan — print per-op supported devices +
#             estimated cost; summarize ANE coverage
# ════════════════════════════════════════════════════════════════
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

import forward_ref

HERE = os.path.dirname(os.path.abspath(__file__))

SLOPE = 1.0 / 16


class V1HSlice(nn.Module):
    """The ship slice: SeedEncoder + palette head, NCHW, bias-free —
    layer-for-layer the model.py architecture (no arbitration, no
    noise latent — the d96 champion's config)."""

    def __init__(self, d=96, n_down=4):
        super().__init__()
        self.stem = nn.Conv2d(16, 2 * d, 3, padding=1, groups=4, bias=False)
        self.fuse = nn.Conv2d(2 * d, d, 1, bias=False)
        self.ladder = nn.ModuleList(
            [nn.Conv2d(d, d, 3, stride=2, padding=1, bias=False)
             for _ in range(n_down)])
        self.palette = nn.Conv2d(d, 3, 1, bias=False)

    def forward(self, x):
        h = F.leaky_relu(self.stem(x), SLOPE)
        h = self.fuse(h)
        for lay in self.ladder:
            h = F.leaky_relu(lay(h), SLOPE)
        return self.palette(h)                        # (B, 3, 16, 16)


def load_from_v1hw(model, path):
    """V1HW fp16 tensors, MLX (C_out, kH, kW, C_in/g) → PyTorch
    (C_out, C_in/g, kH, kW)."""
    cfg, tensors = forward_ref.load_package(path)
    def put(mod, name):
        w = torch.from_numpy(tensors[name].copy()).permute(0, 3, 1, 2)
        mod.weight.data = w.contiguous()
    put(model.stem, 'encoder.stem.weight')
    put(model.fuse, 'encoder.fuse.weight')
    for i, lay in enumerate(model.ladder):
        put(lay, f'encoder.ladder.{i}.weight')
    put(model.palette, 'palette.weight')
    return cfg


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(HERE, 'runs', 'v1h_e5_d96_rep.weights.bin')
    model = V1HSlice(d=96).eval()
    cfg = load_from_v1hw(model, src)
    print(f'weights: {os.path.basename(src)}  (d={cfg["d"]}, in_side={cfg["in_side"]})')

    # ── step 1: parity vs the numpy reference (the shared gate) ──
    side = cfg['in_side']
    x_nhwc = forward_ref.lcg_input(side, 16)                 # (S, S, 16)
    ref = forward_ref.seed_forward(
        dict(forward_ref.load_package(src)[1]), x_nhwc)      # (16, 16, 3)
    x = torch.from_numpy(np.ascontiguousarray(
        np.transpose(x_nhwc, (2, 0, 1))[None]))              # (1, 16, S, S)
    with torch.no_grad():
        out = model(x).numpy()[0]                            # (3, 16, 16)
    got = np.transpose(out, (1, 2, 0))                       # (16, 16, 3)
    max_abs = float(np.abs(got - ref).max())
    print(f'parity vs forward_ref: maxAbs {max_abs:.3e} '
          f'({"OK" if max_abs <= 1e-3 else "FAIL"} @ 1e-3)')
    if max_abs > 1e-3:
        sys.exit(1)

    # ── step 2: convert to .mlpackage (fp16, static shape) ──────
    import coremltools as ct
    traced = torch.jit.trace(model, x)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name='phases', shape=(1, 16, side, side))],
        outputs=[ct.TensorType(name='seed')],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS17,
    )
    pkg = os.path.join(HERE, 'runs', 'v1h_slice.mlpackage')
    ml.save(pkg)
    print(f'wrote {pkg}')

    # ── step 3: MLComputePlan — per-op device support + cost ────
    from coremltools.models.compute_plan import MLComputePlan
    from coremltools.models.ml_program.experimental.perf_utils import \
        MLModelBenchmarker  # noqa: F401  (import proves perf tooling exists)
    compiled = ml.get_compiled_model_path()
    plan = MLComputePlan.load_from_path(
        path=compiled, compute_units=ct.ComputeUnit.ALL)
    program = plan.model_structure.program
    ops = program.functions['main'].block.operations
    total = ane = 0
    print('\nop            type                     devices (usage→preferred)')
    for op in ops:
        usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
        cost = plan.get_estimated_cost_for_mlprogram_operation(op)
        if usage is None:
            continue
        total += 1
        names = [type(d).__name__.replace('ML', '').replace('ComputeDevice', '')
                 for d in usage.supported_compute_devices]
        pref = type(usage.preferred_compute_device).__name__ \
            .replace('ML', '').replace('ComputeDevice', '')
        if 'NeuralEngine' in pref:
            ane += 1
        w = f'{cost.weight:.3f}' if cost is not None else '  —  '
        print(f'  {op.operator_name:22s} cost {w}  {names} → {pref}')
    print(f'\nANE-preferred: {ane}/{total} costed ops')


if __name__ == '__main__':
    main()
