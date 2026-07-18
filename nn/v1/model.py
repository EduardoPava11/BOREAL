# ════════════════════════════════════════════════════════════════
# model.py — V1-H in MLX: the smallest H-JEPA.
#
#   (16x16) x (16x16) = 256x256 — two levels of one shape, one jump.
#
#   seed encoder    (B, 16, 2S, 2S) tensor -> (B, 16, 16, d) cell
#                   latents (grouped per-frame stem, temporal fuse,
#                   stride-2 ladder down to the 16x16)
#   palette head    1x1 conv d -> 3: the seed's OKLab proposal
#                   (bell projection is applied EXACTLY downstream)
#   patch predictor the learned DOWN-arrow: one shared network
#                   applied over the 16x16 latent map (weight
#                   sharing == convolution), predicting each cell's
#                   inner 16x16 in LAB — assembled to (B,256,256,3)
#
# Bias-free throughout: exposure equivariance is inherited (N4).
# MLX layout: NHWC (channels-last).
# ════════════════════════════════════════════════════════════════
import mlx.core as mx
import mlx.nn as nn


def conv(cin, cout, k=3, stride=1, groups=1):
    return nn.Conv2d(cin, cout, kernel_size=k, stride=stride,
                     padding=k // 2, groups=groups, bias=False)


class SeedEncoder(nn.Module):
    """(B, 2S, 2S, 16) -> (B, 16, 16, d). For the training shape
    2S = 256 the ladder is 4 stride-2 halvings; deeper inputs add more."""

    def __init__(self, d=24, in_side=256):
        super().__init__()
        self.stem = conv(16, 32, groups=4)          # per-frame subnets
        self.fuse = conv(32, d, k=1)                # temporal fusion
        n_down = {256: 4, 512: 5, 1024: 6}[in_side]
        self.ladder = [conv(d, d, stride=2) for _ in range(n_down)]

    def __call__(self, x):
        x = nn.leaky_relu(self.stem(x), 1 / 16)
        x = self.fuse(x)
        for lay in self.ladder:
            x = nn.leaky_relu(lay(x), 1 / 16)
        return x                                     # (B, 16, 16, d)


class PatchPredictor(nn.Module):
    """The learned down-arrow of the jump: cell latents (+ 3x3 context
    via convs) -> each cell's inner 16x16 LAB. Implemented as conv
    mixing on the 16x16 latent map followed by a pixel-shuffle style
    expansion (one shared net, 256 applications == convolution)."""

    def __init__(self, d=24):
        super().__init__()
        self.mix1 = conv(d, d)                       # 3x3 neighbor context
        self.mix2 = conv(d, d)
        self.expand = conv(d, 256 * 3, k=1)          # -> 16*16 inner x 3

    def __call__(self, z):
        h = nn.leaky_relu(self.mix1(z), 1 / 16)
        h = nn.leaky_relu(self.mix2(h), 1 / 16)
        h = self.expand(h)                           # (B, 16, 16, 768)
        b = h.shape[0]
        h = h.reshape(b, 16, 16, 16, 16, 3)          # (B, v, u, j, i, 3)
        h = h.transpose(0, 1, 3, 2, 4, 5)            # (B, v, j, u, i, 3)
        return h.reshape(b, 256, 256, 3)


class V1H(nn.Module):
    def __init__(self, d=24, in_side=256):
        super().__init__()
        self.encoder = SeedEncoder(d, in_side)
        self.palette = conv(d, 3, k=1)               # the seed proposal
        self.patches = PatchPredictor(d)

    def __call__(self, x):
        z = self.encoder(x)                          # (B,16,16,d)
        seed = self.palette(z)                       # (B,16,16,3)
        ceiling = self.patches(z)                    # (B,256,256,3)
        return seed, ceiling


def n_params(model):
    return sum(v.size for _, v in mlx.utils.tree_flatten(model.parameters()))


import mlx.utils  # noqa: E402  (used by n_params)
