//! scene.zig — Stage A scene analysis + Stage B exposure planning for the
//! RGBT → HDR pivot (see ../../BOREAL-RGBT-HDR-WORKFLOW.md §1).
//!
//! Pipeline context: ANALYZE → PLAN → CAPTURE → FUSE. This module owns the
//! first two stages — everything that happens BEFORE the shutter:
//!
//!   ANALYZE  build per-channel histograms of the live (UniWB) preview or a
//!            decoded RAW probe, and locate each channel's bright tail.
//!   PLAN     turn those tails into 4 exposure offsets, one per frame, so that
//!            each of R/G/B gets a frame where IT sits just below clip (its own
//!            expose-to-the-right frame), plus a shadow-floor frame for DR.
//!
//! Why per-channel: on a Bayer sensor the channels do not saturate together —
//! green is brightest / highest-SNR and clips first; red and especially blue
//! are darker and noisier. A single exposure that ETTRs green starves R and B.
//! Giving each channel its own ETTR frame maximizes per-channel SNR, and the
//! fusion stage (§2) later picks each channel from the frame where it is best
//! exposed. ETTR practice: push the bright tail to a target just under clip and
//! tolerate clipped specular highlights — hence a high PERCENTILE, not the max.
//!
//! All math here is pure and deterministic — fully unit-testable on synthetic
//! histograms with no camera. Values are normalized so 1.0 == sensor white
//! (the caller divides preview u8 by 255, or RAW codes by the white level).

const std = @import("std");

/// f32 SIMD width for the vectorized analysis scan (matches fuse.zig).
pub const LANES = 8;
const Vf = @Vector(LANES, f32);

// ── Tunable constants (the ETTR policy) ───────────────────────────────────

/// Bins across the normalized [0,1] range. 1024 ≈ 10 bits of tonal precision,
/// finer than any 8-bit preview and plenty for percentile location on RAW.
pub const N_BINS: usize = 1024;

/// ETTR aim point: push a channel's bright tail to 95% of clip, leaving a
/// safety margin so sensor-to-sensor white-level slop never hard-clips it.
pub const ETTR_TARGET: f32 = 0.95;

/// Quantile used as the "bright tail". 0.995 ignores the top 0.5% of pixels —
/// specular highlights that ETTR deliberately allows to clip.
pub const Q_BRIGHT: f32 = 0.995;

/// Quantile used as the "shadow level" when sizing the shadow-floor frame.
pub const Q_SHADOW: f32 = 0.02;

/// A channel whose bright tail is below this is essentially absent (black or
/// pure noise). We do NOT chase it to ETTR — that would just amplify noise to
/// clipping and waste a long exposure. (E.g. a scene with no blue.)
pub const PRESENCE_FLOOR: f32 = 0.02;

/// Where the shadow-floor frame aims to lift the darkest real tones, for SNR.
pub const SHADOW_AIM: f32 = 0.25;

/// Clamp on how far any single ETTR push may go, both directions (stops).
pub const MAX_PUSH: f32 = 5.0;

/// The shadow frame is always at least this many stops beyond the green-ETTR
/// frame (else it is not a distinct frame), and never more than the max.
pub const SHADOW_ADD_MIN: f32 = 1.0;
pub const SHADOW_ADD_MAX: f32 = 4.0;

// ── Histogram primitive ────────────────────────────────────────────────────

/// A fixed-bin histogram over normalized [0,1]. One per color channel.
pub const Histogram = struct {
    bins: [N_BINS]u32 = [_]u32{0} ** N_BINS,
    count: u64 = 0,

    /// Add one normalized sample. Out-of-range values are clamped into the end
    /// bins (negatives → bin 0, ≥1 → top bin) so a stray value never corrupts
    /// the count.
    pub inline fn add(self: *Histogram, value_norm: f32) void {
        const v = std.math.clamp(value_norm, 0.0, 1.0);
        var idx: usize = @intFromFloat(v * @as(f32, @floatFromInt(N_BINS)));
        if (idx >= N_BINS) idx = N_BINS - 1;
        self.bins[idx] += 1;
        self.count += 1;
    }

    /// Value (normalized) at cumulative fraction `q ∈ [0,1]`. Walks the CDF and
    /// returns the center of the bin where the quantile is crossed. f64 cumulant
    /// keeps it exact for large pixel counts. Empty histogram → 0.
    pub fn percentile(self: *const Histogram, q: f32) f32 {
        if (self.count == 0) return 0;
        const target = @as(f64, @floatFromInt(self.count)) * @as(f64, q);
        var cum: f64 = 0;
        var i: usize = 0;
        while (i < N_BINS) : (i += 1) {
            cum += @floatFromInt(self.bins[i]);
            if (cum >= target) return binCenter(i);
        }
        return binCenter(N_BINS - 1);
    }
};

inline fn binCenter(i: usize) f32 {
    return (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(N_BINS));
}

/// Stops of exposure change to bring a bright tail at `p_hi` up to `target`.
/// Positive = channel is dark, needs more light; negative = near clip, pull
/// down. Clamped to ±MAX_PUSH. A floor on `p_hi` avoids log of zero.
pub inline fn roomStops(p_hi: f32, target: f32) f32 {
    const p = @max(p_hi, 1.0e-4);
    return std.math.clamp(@log2(target / p), -MAX_PUSH, MAX_PUSH);
}

// ── SIMD analysis scan (the vectorized "analyse" primitive) ───────────────

/// Result of a single linear pass over a planar channel.
pub const ChannelScan = extern struct {
    min: f32,
    max: f32,
    mean: f32,
    /// Fraction of samples at/above `clip_level` — feeds presence + the
    /// "is this channel near saturation?" decision faster than a histogram.
    clip_fraction: f32,
};

/// Strong-SIMD linear scan of a planar (single-channel) normalized [0,1] array:
/// vectorized min / max / sum and near-clip count via `@reduce`, plus a scalar
/// remainder. This is the cheap companion to the histogram percentile — used on
/// the RAW-probe path where each CFA channel forms a plane. No allocation.
pub fn scanChannel(vals: []const f32, clip_level: f32) ChannelScan {
    const n = vals.len;
    if (n == 0) return .{ .min = 0, .max = 0, .mean = 0, .clip_fraction = 0 };

    var vmin: Vf = @splat(std.math.floatMax(f32));
    var vmax: Vf = @splat(-std.math.floatMax(f32));
    var vsum: Vf = @splat(0.0);
    var vclip: Vf = @splat(0.0);
    const clipv: Vf = @splat(clip_level);
    const one: Vf = @splat(1.0);
    const zero: Vf = @splat(0.0);

    var i: usize = 0;
    while (i + LANES <= n) : (i += LANES) {
        const v: Vf = vals[i..][0..LANES].*;
        vmin = @min(vmin, v);
        vmax = @max(vmax, v);
        vsum += v;
        vclip += @select(f32, v >= clipv, one, zero);
    }
    var rmin = @reduce(.Min, vmin);
    var rmax = @reduce(.Max, vmax);
    var rsum = @reduce(.Add, vsum);
    var rclip = @reduce(.Add, vclip);
    while (i < n) : (i += 1) {
        const v = vals[i];
        rmin = @min(rmin, v);
        rmax = @max(rmax, v);
        rsum += v;
        if (v >= clip_level) rclip += 1.0;
    }
    const fn_: f32 = @floatFromInt(n);
    return .{ .min = rmin, .max = rmax, .mean = rsum / fn_, .clip_fraction = rclip / fn_ };
}

// ── Stage A output ───────────────────────────────────────────────────────

/// Per-channel ETTR headroom for the current scene, plus the shadow-frame
/// depth. C-ABI mirror for Swift (`extern`).
pub const SceneClips = extern struct {
    /// Stops to push each channel's bright tail to ETTR_TARGET. Green is
    /// normally the smallest (it clips first). 0 for an absent channel.
    room_r: f32,
    room_g: f32,
    room_b: f32,
    /// Additional stops, beyond the green-ETTR frame, for the shadow-floor
    /// frame f4. Clamped to [SHADOW_ADD_MIN, SHADOW_ADD_MAX].
    shadow_depth: f32,
    /// Whether each channel carries real signal (bright tail ≥ PRESENCE_FLOOR).
    /// An absent channel gets no dedicated ETTR frame from measurement — the
    /// planner falls back to the white-balance prior instead.
    present_r: bool,
    present_g: bool,
    present_b: bool,
};

/// Core Stage A: three per-channel histograms → SceneClips. Pure; the buffer
/// driver below just fills the histograms first.
pub fn solveClips(hr: *const Histogram, hg: *const Histogram, hb: *const Histogram) SceneClips {
    const hi_r = hr.percentile(Q_BRIGHT);
    const hi_g = hg.percentile(Q_BRIGHT);
    const hi_b = hb.percentile(Q_BRIGHT);

    const present_r = hi_r >= PRESENCE_FLOOR;
    const present_g = hi_g >= PRESENCE_FLOOR;
    const present_b = hi_b >= PRESENCE_FLOOR;

    const room_g = if (present_g) roomStops(hi_g, ETTR_TARGET) else 0.0;

    // Shadow-floor frame: lift the dark tail (green is the luminance proxy —
    // highest SNR, dominates luma) toward SHADOW_AIM, measured BEYOND the
    // green-ETTR push the f1 frame already applies.
    const lo_g = hg.percentile(Q_SHADOW);
    const want_total = roomStops(@max(lo_g, 1.0e-4), SHADOW_AIM); // stops from base to put shadows at the aim
    const shadow_depth = std.math.clamp(want_total - room_g, SHADOW_ADD_MIN, SHADOW_ADD_MAX);

    return .{
        .room_r = if (present_r) roomStops(hi_r, ETTR_TARGET) else 0.0,
        .room_g = room_g,
        .room_b = if (present_b) roomStops(hi_b, ETTR_TARGET) else 0.0,
        .shadow_depth = shadow_depth,
        .present_r = present_r,
        .present_g = present_g,
        .present_b = present_b,
    };
}

// ── Stage B output ──────────────────────────────────────────────────────

/// The 4-frame plan: absolute exposure offsets (stops, EV) from the base
/// preview exposure, applied via shutter time only so radiometric ratios stay
/// exact. C-ABI mirror.
pub const ExposurePlan = extern struct {
    ev_green: f32, // f1 — green ETTR
    ev_red: f32, // f2 — red ETTR
    ev_blue: f32, // f3 — blue ETTR
    ev_shadow: f32, // f4 — shadow floor
};

/// Stage B: SceneClips → ExposurePlan. For a present channel, its frame sits at
/// that channel's own measured room. For an ABSENT channel (no measured tail),
/// fall back to the white-balance prior: the channel needing the larger WB
/// multiplier is darker in raw, so it needs `log2(wb_c/wb_g)` more stops than
/// green. `extra_shadow` adds to the shadow frame (caller knob; 0 = use clips).
pub fn planExposures(clips: SceneClips, wb_mult: [3]f32, extra_shadow: f32) ExposurePlan {
    const wb_g = @max(wb_mult[1], 1.0e-4);
    const ev_g = clips.room_g;

    const ev_r = if (clips.present_r)
        clips.room_r
    else
        ev_g + std.math.clamp(@log2(@max(wb_mult[0], 1.0e-4) / wb_g), -MAX_PUSH, MAX_PUSH);

    const ev_b = if (clips.present_b)
        clips.room_b
    else
        ev_g + std.math.clamp(@log2(@max(wb_mult[2], 1.0e-4) / wb_g), -MAX_PUSH, MAX_PUSH);

    return .{
        .ev_green = ev_g,
        .ev_red = ev_r,
        .ev_blue = ev_b,
        .ev_shadow = ev_g + clips.shadow_depth + extra_shadow,
    };
}

// ── Buffer driver (the C ABI export wrappers live in root.zig, matching the
//    house pattern where leaf modules stay pure and root.zig owns `export fn`) ──

/// Analyze an interleaved RGB frame (3 floats/pixel, normalized [0,1]) → clips.
pub fn analyzeFrame(rgb: [*]const f32, width: u32, height: u32) SceneClips {
    var hr = Histogram{};
    var hg = Histogram{};
    var hb = Histogram{};
    const n: usize = @as(usize, width) * @as(usize, height);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const base = i * 3;
        hr.add(rgb[base + 0]);
        hg.add(rgb[base + 1]);
        hb.add(rgb[base + 2]);
    }
    return solveClips(&hr, &hg, &hb);
}

/// Analyze a RAW Bayer mosaic directly → ETTR clips (GIF-ISP Phase 2: the
/// inter-cycle planner runs on the cycle's own mosaic, no demosaic needed).
/// Same CFA walk as `channelHistograms` — green at the off-diagonal sites,
/// red/blue at the corners (swapped for BGGR) — normalized by the sensor's
/// black/white (NO white balance, so tails read TRUE per-channel exposure),
/// fed into the owned `Histogram` and resolved by `solveClips`.
pub fn analyzeMosaic(
    samples: [*]const u16,
    width: u32,
    height: u32,
    cfa: u32, // 0 = RGGB, 1 = BGGR
    black: f32,
    white: f32,
) SceneClips {
    var hr = Histogram{};
    var hg = Histogram{};
    var hb = Histogram{};
    const range = @max(white - black, 1.0);
    const inv = 1.0 / range;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const is_rggb = cfa == 0;

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const py = y & 1;
        const row = y * w;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const s: f32 = @floatFromInt(samples[row + x]);
            const v = std.math.clamp((s - black) * inv, 0.0, 1.0);
            const px = x & 1;
            if (py == 0 and px == 0) {
                if (is_rggb) hr.add(v) else hb.add(v);
            } else if (py == 1 and px == 1) {
                if (is_rggb) hb.add(v) else hr.add(v);
            } else {
                hg.add(v);
            }
        }
    }
    return solveClips(&hr, &hg, &hb);
}

test "analyzeMosaic: flat mid-gray mosaic → all channels present, room > 0" {
    var m: [64 * 64]u16 = undefined;
    @memset(&m, 8000); // mid-range for black=512, white=16383
    const clips = analyzeMosaic(&m, 64, 64, 0, 512, 16383);
    try std.testing.expect(clips.present_r and clips.present_g and clips.present_b);
    try std.testing.expect(clips.room_g > 0); // dark of ETTR target → push up
    try std.testing.expectApproxEqAbs(clips.room_r, clips.room_g, 1e-4);
}

test "analyzeMosaic: clipped green pulls its room negative" {
    var m: [64 * 64]u16 = undefined;
    // RGGB: saturate the two green sites, keep R/B mid.
    for (0..64) |y| {
        for (0..64) |x| {
            const green = ((y & 1) + (x & 1)) == 1;
            m[y * 64 + x] = if (green) 16383 else 8000;
        }
    }
    const clips = analyzeMosaic(&m, 64, 64, 0, 512, 16383);
    try std.testing.expect(clips.room_g < 0); // at clip → pull down
    try std.testing.expect(clips.room_r > 0);
}

// ── Per-channel display histograms (the exposure read-out) ─────────────────

/// Build three per-channel histograms straight from a RAW Bayer mosaic, for the
/// UI's per-frame exposure read-out. Unlike `analyzeFrame` (which works on a
/// demosaiced, normalized RGB frame and returns ETTR clips), this bins the raw
/// photosites themselves — green at the two off-diagonal CFA sites, red/blue at
/// the corners (swapped for BGGR). Values are normalized by the sensor's own
/// black/white levels (NO white balance) so the bars read TRUE exposure: a tail
/// piled into the top bin means that channel clipped on this frame.
///
/// Scalar scatter, matching the owned `Histogram` above — a binning increment
/// (`out[idx] += 1`) is a gather/scatter that does not vectorize cleanly, so
/// SIMD here would be ceremony, not speed. `n_bins` is caller-chosen (e.g. 128
/// for a compact on-screen plot). Each `out_*` buffer holds `n_bins` u32s.
pub fn channelHistograms(
    samples: [*]const u16,
    width: u32,
    height: u32,
    cfa: u32, // 0 = RGGB, 1 = BGGR
    black: f32,
    white: f32,
    n_bins: u32,
    out_r: [*]u32,
    out_g: [*]u32,
    out_b: [*]u32,
) void {
    const nb: usize = @intCast(n_bins);
    if (nb == 0) return;
    @memset(out_r[0..nb], 0);
    @memset(out_g[0..nb], 0);
    @memset(out_b[0..nb], 0);

    const range = @max(white - black, 1.0);
    const inv = 1.0 / range;
    const scale = @as(f32, @floatFromInt(n_bins));
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const is_rggb = cfa == 0;

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const py = y & 1;
        const row = y * w;
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const s: f32 = @floatFromInt(samples[row + x]);
            const v = std.math.clamp((s - black) * inv, 0.0, 1.0);
            var idx: usize = @intFromFloat(v * scale);
            if (idx >= nb) idx = nb - 1;

            const px = x & 1;
            if (px != py) {
                out_g[idx] += 1; // both off-diagonal sites are green
            } else if (px == 0) {
                // (0,0) corner: R for RGGB, B for BGGR
                if (is_rggb) out_r[idx] += 1 else out_b[idx] += 1;
            } else {
                // (1,1) corner: B for RGGB, R for BGGR
                if (is_rggb) out_b[idx] += 1 else out_r[idx] += 1;
            }
        }
    }
}

// ── Live preview display histograms (interleaved BGRA, the pre-shutter feed) ─

/// Build three per-channel display histograms straight from an interleaved 8-bit
/// BGRA video frame (the live `AVCaptureVideoDataOutput` feed), for the capture
/// screen's real-time exposure overlay. Unlike `channelHistograms` (which bins a
/// RAW Bayer mosaic by sensor black/white levels), this bins display-referred
/// 8-bit video: each channel is simply normalized by /255 — there is NO sensor
/// black/white level and NO white balance, because the preview is already a
/// gamma-encoded display image. The two histograms are therefore NOT directly
/// comparable in absolute terms (this one is display/gamma space, the RAW one is
/// linear-ish sensor space); this is a relative pre-shutter exposure guide. Do
/// NOT "fix" it to use black/white levels.
///
/// `row_stride` is the buffer's bytesPerRow IN BYTES — a CVPixelBuffer almost
/// always pads each row past width*4 for alignment, so we MUST stride by
/// `row_stride`, not width*4, or the histogram corrupts and reads past the end.
/// Byte order is BGRA: at pixel offset o, B=bgra[o], G=bgra[o+1], R=bgra[o+2],
/// A=bgra[o+3] (alpha skipped).
///
/// Scalar scatter, matching the owned `Histogram` and `channelHistograms` above —
/// a binning increment (`out[idx] += 1`) is a gather/scatter that does not
/// vectorize cleanly, so SIMD here would be ceremony, not speed; the per-channel
/// /255 normalization is the only vectorizable part and it folds into the read.
/// `n_bins` is caller-chosen (e.g. 128 for a compact on-screen plot). Each
/// `out_*` buffer holds `n_bins` u32s; all three are zeroed first.
pub fn rgbHistograms(
    bgra: [*]const u8,
    width: u32,
    height: u32,
    row_stride: u32,
    n_bins: u32,
    out_r: [*]u32,
    out_g: [*]u32,
    out_b: [*]u32,
) void {
    const nb: usize = @intCast(n_bins);
    if (nb == 0) return;
    @memset(out_r[0..nb], 0);
    @memset(out_g[0..nb], 0);
    @memset(out_b[0..nb], 0);

    const inv255: f32 = 1.0 / 255.0;
    const scale = @as(f32, @floatFromInt(n_bins));
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const stride: usize = @intCast(row_stride);

    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row_base = y * stride; // BYTES — honors CVPixelBuffer row padding
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const o = row_base + x * 4;
            const b: f32 = @as(f32, @floatFromInt(bgra[o + 0])) * inv255;
            const g: f32 = @as(f32, @floatFromInt(bgra[o + 1])) * inv255;
            const r: f32 = @as(f32, @floatFromInt(bgra[o + 2])) * inv255;
            // A = bgra[o + 3] — skipped.
            out_b[binIdx(b, scale, nb)] += 1;
            out_g[binIdx(g, scale, nb)] += 1;
            out_r[binIdx(r, scale, nb)] += 1;
        }
    }
}

/// Map a normalized [0,1] value to a bin index, clamping ≥1 (and the top bin) so
/// a clipped (255) sample piles into the last bin where ClipDots reads it.
inline fn binIdx(v: f32, scale: f32, nb: usize) usize {
    const cl = std.math.clamp(v, 0.0, 1.0);
    var idx: usize = @intFromFloat(cl * scale);
    if (idx >= nb) idx = nb - 1;
    return idx;
}

// ── Tests (spec-first: each encodes a law from §1) ────────────────────────

const testing = std.testing;

fn deltaHist(value: f32, n: u32) Histogram {
    var h = Histogram{};
    var k: u32 = 0;
    while (k < n) : (k += 1) h.add(value);
    return h;
}

test "scanChannel: min/max/mean correct, handles ragged tail" {
    // n not a multiple of LANES, to exercise both vector loop and remainder.
    var buf: [LANES * 2 + 3]f32 = undefined;
    for (0..buf.len) |i| buf[i] = @as(f32, @floatFromInt(i)) / 100.0;
    const s = scanChannel(&buf, 2.0); // clip_level above all → 0 clipped
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.min, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, @as(f32, @floatFromInt(buf.len - 1)) / 100.0), s.max, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), s.clip_fraction, 1e-6);
}

test "scanChannel: clip_fraction counts near-saturation samples" {
    var buf: [16]f32 = [_]f32{0.1} ** 16;
    buf[0] = 0.99;
    buf[1] = 1.00;
    buf[2] = 0.985;
    const s = scanChannel(&buf, 0.98);
    try testing.expectApproxEqAbs(@as(f32, 3.0 / 16.0), s.clip_fraction, 1e-6);
}

test "histogram: delta at v → every percentile ≈ v" {
    var h = deltaHist(0.5, 1000);
    try testing.expectApproxEqAbs(@as(f32, 0.5), h.percentile(0.01), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), h.percentile(0.5), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), h.percentile(0.995), 0.01);
}

test "histogram: percentile is monotonic non-decreasing in q" {
    var h = Histogram{};
    var v: f32 = 0;
    while (v < 1.0) : (v += 0.001) h.add(v); // ~uniform
    try testing.expect(h.percentile(0.1) <= h.percentile(0.5));
    try testing.expect(h.percentile(0.5) <= h.percentile(0.9));
}

test "histogram: empty → percentile 0" {
    const h = Histogram{};
    try testing.expectEqual(@as(f32, 0), h.percentile(0.5));
}

test "roomStops: tail already at target → ~0 stops" {
    try testing.expectApproxEqAbs(@as(f32, 0), roomStops(ETTR_TARGET, ETTR_TARGET), 1e-4);
}

test "roomStops: dark tail → positive (push up); near-clip → negative (pull down)" {
    try testing.expect(roomStops(0.45, ETTR_TARGET) > 0);
    try testing.expect(roomStops(0.99, ETTR_TARGET) < 0);
}

test "roomStops: mid-gray 0.5 → ~+0.926 stops" {
    try testing.expectApproxEqAbs(@as(f32, 0.926), roomStops(0.5, ETTR_TARGET), 0.02);
}

test "clips: green brightest ⇒ green needs least room (saturates first)" {
    // g brightest (0.90), b mid (0.60), r darkest (0.45).
    var hg = deltaHist(0.90, 1000);
    var hb = deltaHist(0.60, 1000);
    var hr = deltaHist(0.45, 1000);
    const c = solveClips(&hr, &hg, &hb);
    try testing.expect(c.room_g < c.room_b);
    try testing.expect(c.room_b < c.room_r);
    try testing.expect(c.present_r and c.present_g and c.present_b);
}

test "clips: absent channel (no blue) → not present, room 0, no wasted frame" {
    var hr = deltaHist(0.50, 1000);
    var hg = deltaHist(0.50, 1000);
    var hb = deltaHist(0.001, 1000); // essentially black
    const c = solveClips(&hr, &hg, &hb);
    try testing.expect(!c.present_b);
    try testing.expectEqual(@as(f32, 0), c.room_b);
    try testing.expect(c.present_r and c.present_g);
}

test "clips: shadow_depth clamped to [MIN, MAX]" {
    var hr = deltaHist(0.50, 1000);
    var hg = deltaHist(0.50, 1000);
    var hb = deltaHist(0.50, 1000);
    const c = solveClips(&hr, &hg, &hb);
    try testing.expect(c.shadow_depth >= SHADOW_ADD_MIN - 1e-4);
    try testing.expect(c.shadow_depth <= SHADOW_ADD_MAX + 1e-4);
}

test "plan: green frame at room_g, shadow frame beyond it" {
    const c = SceneClips{
        .room_r = 1.0, .room_g = 0.2, .room_b = 0.6, .shadow_depth = 2.0,
        .present_r = true, .present_g = true, .present_b = true,
    };
    const p = planExposures(c, .{ 2.0, 1.0, 1.5 }, 0);
    try testing.expectApproxEqAbs(@as(f32, 0.2), p.ev_green, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), p.ev_red, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.6), p.ev_blue, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2.2), p.ev_shadow, 1e-5); // room_g + shadow_depth
    try testing.expect(p.ev_shadow > p.ev_green);
}

test "plan: absent channel falls back to WB prior (Δ = log2(wb_c/wb_g))" {
    // Blue absent → blue frame = green frame + log2(1.5/1.0) ≈ +0.585.
    const c = SceneClips{
        .room_r = 1.0, .room_g = 0.0, .room_b = 0.0, .shadow_depth = 1.0,
        .present_r = true, .present_g = true, .present_b = false,
    };
    const p = planExposures(c, .{ 2.0, 1.0, 1.5 }, 0);
    try testing.expectApproxEqAbs(@as(f32, 0.585), p.ev_blue, 0.01);
}

test "channelHistograms: RGGB routes each CFA site to the right channel" {
    // 2×2 RGGB cell: R=0, G=mid, B=top of a [0,255] range, tiled 2×2 cells (4×4).
    const black: f32 = 0;
    const white: f32 = 255;
    // raw codes: R photosite=0, both greens=128, B photosite=255.
    const px = [_]u16{
        0, 128, 0, 128,
        128, 255, 128, 255,
        0, 128, 0, 128,
        128, 255, 128, 255,
    };
    const nb: u32 = 4;
    var hr = [_]u32{0} ** 4;
    var hg = [_]u32{0} ** 4;
    var hb = [_]u32{0} ** 4;
    channelHistograms(&px, 4, 4, 0, black, white, nb, &hr, &hg, &hb);
    // 4 R sites all at 0 → bin 0; 8 G sites at ~0.5 → bin 2; 4 B sites at 1.0 → top bin.
    try testing.expectEqual(@as(u32, 4), hr[0]);
    try testing.expectEqual(@as(u32, 8), hg[2]);
    try testing.expectEqual(@as(u32, 4), hb[nb - 1]);
    // Totals: R=4, G=8, B=4 (G double, as on a Bayer sensor).
    try testing.expectEqual(@as(u32, 4), hr[0] + hr[1] + hr[2] + hr[3]);
    try testing.expectEqual(@as(u32, 8), hg[0] + hg[1] + hg[2] + hg[3]);
}

test "channelHistograms: BGGR swaps red/blue corners vs RGGB" {
    const px = [_]u16{ 10, 100, 100, 250 }; // (0,0)=10 (1,1)=250
    var hr = [_]u32{0} ** 4;
    var hg = [_]u32{0} ** 4;
    var hb = [_]u32{0} ** 4;
    // BGGR: (0,0) is blue, (1,1) is red → red tail should be the bright corner.
    channelHistograms(&px, 2, 2, 1, 0, 255, 4, &hr, &hg, &hb);
    try testing.expectEqual(@as(u32, 1), hb[0]); // dark corner → blue
    try testing.expectEqual(@as(u32, 1), hr[3]); // bright corner → red
    try testing.expectEqual(@as(u32, 2), hg[0] + hg[1] + hg[2] + hg[3]);
}

test "channelHistograms: clipped photosites pile into the top bin" {
    const px = [_]u16{ 4095, 2000, 2000, 4095 }; // 14-bit white
    var hr = [_]u32{0} ** 8;
    var hg = [_]u32{0} ** 8;
    var hb = [_]u32{0} ** 8;
    channelHistograms(&px, 2, 2, 0, 0, 4095, 8, &hr, &hg, &hb);
    try testing.expectEqual(@as(u32, 1), hr[7]); // R at white → top bin = clipping
    try testing.expectEqual(@as(u32, 1), hb[7]); // B at white → top bin
}

test "rgbHistograms: known pattern lands in the right per-channel bins (BGRA order)" {
    // 4×2 buffer, every pixel R=200,G=100,B=20, unpadded (row_stride = width*4).
    const w: u32 = 4;
    const h: u32 = 2;
    const n_bins: u32 = 128;
    var buf: [4 * 2 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        buf[i + 0] = 20; // B
        buf[i + 1] = 100; // G
        buf[i + 2] = 200; // R
        buf[i + 3] = 255; // A (skipped)
    }
    var hr = [_]u32{0} ** 128;
    var hg = [_]u32{0} ** 128;
    var hb = [_]u32{0} ** 128;
    rgbHistograms(&buf, w, h, w * 4, n_bins, &hr, &hg, &hb);

    // Expected bins: floor(v * 128) for each channel.
    const bin_r: usize = @intFromFloat((200.0 / 255.0) * 128.0);
    const bin_g: usize = @intFromFloat((100.0 / 255.0) * 128.0);
    const bin_b: usize = @intFromFloat((20.0 / 255.0) * 128.0);
    // All 8 pixels per channel pile into that one bin (proves B@o, R@o+2 — not swapped).
    try testing.expectEqual(@as(u32, 8), hr[bin_r]);
    try testing.expectEqual(@as(u32, 8), hg[bin_g]);
    try testing.expectEqual(@as(u32, 8), hb[bin_b]);
    // And nowhere else (every pixel counted exactly once per channel).
    try testing.expectEqual(@as(u32, 0), sumExcept(&hr, bin_r));
    try testing.expectEqual(@as(u32, 0), sumExcept(&hg, bin_g));
    try testing.expectEqual(@as(u32, 0), sumExcept(&hb, bin_b));
}

fn sumExcept(h: []const u32, skip: usize) u32 {
    var s: u32 = 0;
    for (h, 0..) |v, idx| {
        if (idx != skip) s += v;
    }
    return s;
}

test "rgbHistograms: honors row_stride padding (the classic CVPixelBuffer bug)" {
    // Same pixels as the known-pattern test, but each row padded by 16 junk bytes.
    const w: u32 = 4;
    const h: u32 = 2;
    const n_bins: u32 = 128;
    const pad: u32 = 16;
    const stride: u32 = w * 4 + pad;
    var buf: [(@as(usize, 4) * 4 + 16) * 2]u8 = undefined;
    // Fill the WHOLE buffer with junk first (incl. pad), then write real pixels.
    @memset(&buf, 0xAB);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const o = y * @as(usize, stride) + x * 4;
            buf[o + 0] = 20; // B
            buf[o + 1] = 100; // G
            buf[o + 2] = 200; // R
            buf[o + 3] = 255; // A
        }
    }
    var hr = [_]u32{0} ** 128;
    var hg = [_]u32{0} ** 128;
    var hb = [_]u32{0} ** 128;
    rgbHistograms(&buf, w, h, stride, n_bins, &hr, &hg, &hb);

    const bin_r: usize = @intFromFloat((200.0 / 255.0) * 128.0);
    const bin_g: usize = @intFromFloat((100.0 / 255.0) * 128.0);
    const bin_b: usize = @intFromFloat((20.0 / 255.0) * 128.0);
    // Identical to the unpadded case → the loop strode by row_stride, not width*4,
    // and the 0xAB junk in the pad region was never counted.
    try testing.expectEqual(@as(u32, 8), hr[bin_r]);
    try testing.expectEqual(@as(u32, 8), hg[bin_g]);
    try testing.expectEqual(@as(u32, 8), hb[bin_b]);
    try testing.expectEqual(@as(u32, 0), sumExcept(&hr, bin_r));
    try testing.expectEqual(@as(u32, 0), sumExcept(&hg, bin_g));
    try testing.expectEqual(@as(u32, 0), sumExcept(&hb, bin_b));
}

test "rgbHistograms: clip (255/254/253) piles into the top bin" {
    const w: u32 = 3;
    const h: u32 = 1;
    const n_bins: u32 = 4; // coarse so the whole top quartile (193..255) clips together
    // Three pixels: R = 255, 254, 253 (all in the top bin); G/B = 0.
    var buf = [_]u8{
        0, 0, 255, 255,
        0, 0, 254, 255,
        0, 0, 253, 255,
    };
    var hr = [_]u32{0} ** 4;
    var hg = [_]u32{0} ** 4;
    var hb = [_]u32{0} ** 4;
    rgbHistograms(&buf, w, h, w * 4, n_bins, &hr, &hg, &hb);
    // All three near-white reds land in the top bin → ClipDots lights (255 hits
    // the clamp; 254/253 round into the same final bin).
    try testing.expectEqual(@as(u32, 3), hr[n_bins - 1]);
    // G and B were all 0 → bin 0.
    try testing.expectEqual(@as(u32, 3), hg[0]);
    try testing.expectEqual(@as(u32, 3), hb[0]);
}

test "rgbHistograms: clears output first / total conservation (every pixel once)" {
    const w: u32 = 5;
    const h: u32 = 3;
    const n_bins: u32 = 64;
    var buf: [5 * 3 * 4]u8 = undefined;
    for (0..buf.len) |i| buf[i] = @intCast(i % 256);
    var hr = [_]u32{7} ** 64; // pre-fill with garbage
    var hg = [_]u32{9} ** 64;
    var hb = [_]u32{3} ** 64;
    rgbHistograms(&buf, w, h, w * 4, n_bins, &hr, &hg, &hb);
    var sr: u32 = 0;
    var sg: u32 = 0;
    var sb: u32 = 0;
    for (0..n_bins) |i| {
        sr += hr[i];
        sg += hg[i];
        sb += hb[i];
    }
    // Garbage was zeroed (else sums would carry the pre-fill); each pixel counted once.
    try testing.expectEqual(@as(u32, w * h), sr);
    try testing.expectEqual(@as(u32, w * h), sg);
    try testing.expectEqual(@as(u32, w * h), sb);
}

test "rgbHistograms: n_bins == 0 is a no-op (no write)" {
    var buf = [_]u8{ 1, 2, 3, 255 };
    var hr = [_]u32{42} ** 1;
    rgbHistograms(&buf, 1, 1, 4, 0, &hr, &hr, &hr);
    try testing.expectEqual(@as(u32, 42), hr[0]); // untouched
}

test "end-to-end: analyzeFrame + planExposures on a synthetic frame" {
    // 2×2 interleaved RGB, all pixels (R=0.45, G=0.90, B=0.60).
    const px = [_]f32{
        0.45, 0.90, 0.60, 0.45, 0.90, 0.60,
        0.45, 0.90, 0.60, 0.45, 0.90, 0.60,
    };
    const clips = analyzeFrame(&px, 2, 2);
    try testing.expect(clips.room_g < clips.room_r); // green brightest

    const plan = planExposures(clips, .{ 2.0, 1.0, 1.5 }, 0);
    try testing.expectApproxEqAbs(clips.room_g, plan.ev_green, 1e-5);
    try testing.expect(plan.ev_shadow > plan.ev_green);
}
