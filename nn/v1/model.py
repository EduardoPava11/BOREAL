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
    2S = 256 the ladder is 4 stride-2 halvings; deeper inputs add more.

    A1 (research doc §8, burst-fusion consensus — Kalantari/KPN/
    AHDRNet): with arbitrate=True the temporal fuse becomes per-pixel
    ATTENTION over the 4 EV-normalized frames — each frame's features
    emit a logit (grouped 1x1), logits are scale-normalized
    (stop-gradient) so the softmax stays exposure-INVARIANT (N4: a
    plain softmax sharpens under input scaling and would break the
    net's 1-homogeneity), and the frame features are weighted-summed
    before the ladder. The fixed 1x1 mix treated the cycle's whole
    data advantage as one linear blend."""

    def __init__(self, d=24, in_side=256, arbitrate=False):
        super().__init__()
        # Stem width follows d (capacity bump 2026-07-18): 2d per-frame
        # features before temporal fusion. d=24 -> 48-wide stem (legacy
        # was 32); d=48 -> 96-wide.
        self.stem = conv(16, 2 * d, groups=4)       # per-frame subnets
        self.arbitrate = arbitrate
        if arbitrate:
            # One logit per frame from that frame's OWN features
            # (groups=4). A1b form (A1a's weighted SUM confounded
            # arbitration with a 4x width bottleneck and lost): the
            # weights SCALE the per-frame blocks, which stay
            # concatenated — a strict superset of the plain 1x1 mix
            # (uniform weights ~ recover it), same fuse width.
            self.arb = conv(2 * d, 4, k=1, groups=4)
        self.fuse = conv(2 * d, d, k=1)             # temporal fusion
        n_down = {256: 4, 512: 5, 1024: 6}[in_side]
        self.ladder = [conv(d, d, stride=2) for _ in range(n_down)]

    def __call__(self, x):
        h = nn.leaky_relu(self.stem(x), 1 / 16)
        if self.arbitrate:
            z = self.arb(h)                          # (B,H,W,4) frame logits
            scale = mx.stop_gradient(
                mx.mean(mx.abs(z), axis=-1, keepdims=True)) + 1e-8
            w = mx.softmax(z / scale, axis=-1)       # exposure-invariant
            b, hh, ww, c = h.shape
            hf = h.reshape(b, hh, ww, 4, c // 4)     # per-frame blocks
            hf = (4.0 * w)[..., None] * hf           # scale, keep width
            h = hf.reshape(b, hh, ww, c)             # (B,H,W,2d)
        h = self.fuse(h)
        for lay in self.ladder:
            h = nn.leaky_relu(lay(h), 1 / 16)
        return h                                     # (B, 16, 16, d)


class PatchPredictor(nn.Module):
    """The learned down-arrow of the jump: cell latents (+ 3x3 context
    via convs) -> each cell's inner 16x16 LAB. Implemented as conv
    mixing on the 16x16 latent map followed by a pixel-shuffle style
    expansion (one shared net, 256 applications == convolution)."""

    def __init__(self, d=24, in_extra=0):
        super().__init__()
        self.mix1 = conv(d + in_extra, d)            # 3x3 neighbor context
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
    def __init__(self, d=24, in_side=256, arbitrate=False,
                 noise_latent=False):
        super().__init__()
        self.encoder = SeedEncoder(d, in_side, arbitrate=arbitrate)
        self.palette = conv(d, 3, k=1)               # the seed proposal
        self.noise_latent = noise_latent
        # E3 (NIB, ICCV 2021): a CNN cannot dither a flat region
        # without a noise source. One noise channel, scale-normalized
        # by the latent's own magnitude (stop-grad) so exposure
        # equivariance survives (N4). Post-stem injection — the N-law
        # input contract is untouched.
        self.patches = PatchPredictor(d, in_extra=1 if noise_latent else 0)

    def __call__(self, x):
        z = self.encoder(x)                          # (B,16,16,d)
        seed = self.palette(z)                       # (B,16,16,3)
        if self.noise_latent:
            b, h, w, _ = z.shape
            scale = mx.stop_gradient(mx.mean(mx.abs(z))) + 1e-8
            noise = mx.random.normal((b, h, w, 1)) * scale
            zp = mx.concatenate([z, noise], axis=-1)
        else:
            zp = z
        ceiling = self.patches(zp)                   # (B,256,256,3)
        return seed, ceiling


def n_params(model):
    return sum(v.size for _, v in mlx.utils.tree_flatten(model.parameters()))


import mlx.utils  # noqa: E402  (used by n_params)
