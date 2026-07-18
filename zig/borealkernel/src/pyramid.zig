//! pyramid.zig — the embedded S-transform pyramid: the latent buffer where
//! the 16×16 frame is a PREFIX and back-trace is exact inverse transform.
//! Hand-written, zero dependencies — BOREAL owns this algorithm end to end.
//! Ported from the Haskell contract `spec/Boreal/Pyramid.hs`; gated bit-exact
//! by `fixtures/pyramid_golden.json` (see tests/pyramid_fixtures.zig).
//!
//! PORT CONVENTIONS (normative — from the spec):
//!   · pair transform    l = ⌊(a+b)/2⌋ ,  h = a − b        (floor division)
//!   · pair inverse      a = l + ⌊(h+1)/2⌋ ,  b = a − h
//!   · quad order        HORIZONTAL pairs first, then vertical (row-first;
//!                       floor makes the order load-bearing: quad (3,1,0,0)
//!                       coarsens to 1 row-first but 0 column-first)
//!   · band layout       bands[0 .. base²)      = top band, row-major
//!                       bands[s² .. 4·s²)      = detail level with quad-grid
//!                                                side s, per quad row-major,
//!                                                (LH, HL, HH) interleaved
//!                       — prefixes telescope: every prefix IS a rung.
//!
//! Caller owns ALL memory. Both directions need a caller-provided scratch of
//! (side·side)/2 elements (two ping-pong coarse buffers of (side/2)² each).

const std = @import("std");

// ── The exact integer S-transform ──────────────────────────────────────────

pub inline fn stL(a: i32, b: i32) i32 {
    return @divFloor(a + b, 2);
}

pub inline fn stH(a: i32, b: i32) i32 {
    return a - b;
}

pub inline fn stInvA(l: i32, h: i32) i32 {
    return l + @divFloor(h + 1, 2);
}

// ── Band layout helpers ────────────────────────────────────────────────────

/// Offset of the detail level whose quad grid has side `s`: everything
/// coarser occupies exactly s² coefficients, so the level lives at
/// [s², 4·s²). The closed form is what makes the prefix property free.
pub inline fn levelOffset(s: usize) usize {
    return s * s;
}

pub inline fn levelLen(s: usize) usize {
    return 3 * s * s;
}

fn validSides(side: u32, base: u32) bool {
    if (side == 0 or base == 0 or base > side) return false;
    if ((side & (side - 1)) != 0) return false; // power of two
    if ((base & (base - 1)) != 0) return false;
    return true;
}

// ── Analyze: image → bands ─────────────────────────────────────────────────

/// One level: read `cur` (n×n row-major), write the coarse (n/2)² image to
/// `coarse` and the interleaved (LH,HL,HH) details to `details` (3·(n/2)²).
fn analyzeOnce(cur: []const i32, n: usize, coarse: []i32, details: []i32) void {
    const s = n / 2;
    var r: usize = 0;
    while (r < s) : (r += 1) {
        var c: usize = 0;
        while (c < s) : (c += 1) {
            const a = cur[(2 * r) * n + 2 * c];
            const b = cur[(2 * r) * n + 2 * c + 1];
            const cc = cur[(2 * r + 1) * n + 2 * c];
            const d = cur[(2 * r + 1) * n + 2 * c + 1];
            const l0 = stL(a, b);
            const h0 = stH(a, b);
            const l1 = stL(cc, d);
            const h1 = stH(cc, d);
            coarse[r * s + c] = stL(l0, l1);
            const q = 3 * (r * s + c);
            details[q + 0] = stH(l0, l1); // LH
            details[q + 1] = stL(h0, h1); // HL
            details[q + 2] = stH(h0, h1); // HH
        }
    }
}

/// Full analyze: `img` (side² row-major) → `bands` (side², prefix layout).
/// `scratch` must hold (side·side)/2 elements. Returns false on bad sides.
pub fn analyze(img: []const i32, side: u32, base: u32, bands: []i32, scratch: []i32) bool {
    if (!validSides(side, base)) return false;
    const nside: usize = side;
    const nbase: usize = base;
    if (img.len < nside * nside or bands.len < nside * nside) return false;
    if (nside > nbase and scratch.len < (nside * nside) / 2) return false;

    if (nside == nbase) {
        @memcpy(bands[0 .. nside * nside], img[0 .. nside * nside]);
        return true;
    }

    const half = (nside / 2) * (nside / 2);
    var cur: []const i32 = img;
    var n = nside;
    var ping = true;
    while (n > nbase) : (n /= 2) {
        const s = n / 2;
        const coarse = if (ping) scratch[0..half] else scratch[half .. half + half];
        analyzeOnce(cur, n, coarse[0 .. s * s], bands[levelOffset(s) .. levelOffset(s) + levelLen(s)]);
        cur = coarse[0 .. s * s];
        ping = !ping;
    }
    @memcpy(bands[0 .. nbase * nbase], cur[0 .. nbase * nbase]);
    return true;
}

// ── Synthesize: bands → image ──────────────────────────────────────────────

/// One level up: read `coarse` (s²) + `details` (3·s² interleaved), write the
/// (2s)² image to `out`.
fn synthesizeOnce(coarse: []const i32, s: usize, details: []const i32, out: []i32) void {
    const n = 2 * s;
    var r: usize = 0;
    while (r < s) : (r += 1) {
        var c: usize = 0;
        while (c < s) : (c += 1) {
            const q = 3 * (r * s + c);
            const ll = coarse[r * s + c];
            const lh = details[q + 0];
            const hl = details[q + 1];
            const hh = details[q + 2];
            const l0 = stInvA(ll, lh);
            const l1 = l0 - lh;
            const h0 = stInvA(hl, hh);
            const h1 = h0 - hh;
            const a = stInvA(l0, h0);
            const b = a - h0;
            const cc = stInvA(l1, h1);
            const d = cc - h1;
            out[(2 * r) * n + 2 * c] = a;
            out[(2 * r) * n + 2 * c + 1] = b;
            out[(2 * r + 1) * n + 2 * c] = cc;
            out[(2 * r + 1) * n + 2 * c + 1] = d;
        }
    }
}

/// Full synthesize: `bands` (side², prefix layout) → `img` (side² row-major).
/// Exact inverse of `analyze`. Same scratch contract.
pub fn synthesize(bands: []const i32, side: u32, base: u32, img: []i32, scratch: []i32) bool {
    if (!validSides(side, base)) return false;
    const nside: usize = side;
    const nbase: usize = base;
    if (bands.len < nside * nside or img.len < nside * nside) return false;
    if (nside > nbase and scratch.len < (nside * nside) / 2) return false;

    if (nside == nbase) {
        @memcpy(img[0 .. nside * nside], bands[0 .. nside * nside]);
        return true;
    }

    const half = (nside / 2) * (nside / 2);
    var s = nbase;
    var cur: []const i32 = bands[0 .. nbase * nbase];
    var ping = true;
    while (s < nside) : (s *= 2) {
        const details = bands[levelOffset(s) .. levelOffset(s) + levelLen(s)];
        if (2 * s == nside) {
            synthesizeOnce(cur, s, details, img[0 .. nside * nside]);
            cur = img[0 .. nside * nside];
        } else {
            const target = if (ping) scratch[0..half] else scratch[half .. half + half];
            synthesizeOnce(cur, s, details, target[0 .. 4 * s * s]);
            cur = target[0 .. 4 * s * s];
            ping = !ping;
        }
    }
    return true;
}

// ── Spec LCG (shared with the fixtures; normative in the golden JSON) ──────

pub fn lcgNext(s: i64) i64 {
    return s *% 6364136223846793005 +% 1442695040888963407;
}

pub fn lcgSample(s: i64) i32 {
    return @intCast(@mod(@divFloor(s, 65536), 4097) - 2048);
}

/// Fill `buf` with the deterministic spec image for `seed` (row-major).
pub fn lcgFill(seed: i64, buf: []i32) void {
    var s = seed;
    for (buf) |*v| {
        v.* = lcgSample(s);
        s = lcgNext(s);
    }
}

// ── Tests (pure; cross-language fixtures live in tests/pyramid_fixtures.zig)

const testing = std.testing;

test "quad S-transform is a bijection on a dense cube" {
    var a: i32 = -4;
    while (a <= 4) : (a += 1) {
        var b: i32 = -4;
        while (b <= 4) : (b += 1) {
            var c: i32 = -4;
            while (c <= 4) : (c += 1) {
                var d: i32 = -4;
                while (d <= 4) : (d += 1) {
                    const cur = [4]i32{ a, b, c, d };
                    var bands: [4]i32 = undefined;
                    var coarse: [1]i32 = undefined;
                    analyzeOnce(&cur, 2, &coarse, bands[1..4]);
                    bands[0] = coarse[0];
                    var back: [4]i32 = undefined;
                    synthesizeOnce(bands[0..1], 1, bands[1..4], &back);
                    try testing.expectEqualSlices(i32, &cur, &back);
                }
            }
        }
    }
}

test "round-trip synthesize(analyze(img)) == img at 64² (base 16)" {
    const side = 64;
    var img: [side * side]i32 = undefined;
    lcgFill(1, &img);
    var bands: [side * side]i32 = undefined;
    var scratch: [(side * side) / 2]i32 = undefined;
    var back: [side * side]i32 = undefined;
    try testing.expect(analyze(&img, side, 16, &bands, &scratch));
    try testing.expect(synthesize(&bands, side, 16, &back, &scratch));
    try testing.expectEqualSlices(i32, &img, &back);
}

test "prefix-decode: top band == independent row-first floor-mean coarsen" {
    const side = 64;
    var img: [side * side]i32 = undefined;
    lcgFill(11, &img);
    var bands: [side * side]i32 = undefined;
    var scratch: [(side * side) / 2]i32 = undefined;
    try testing.expect(analyze(&img, side, 16, &bands, &scratch));

    // Independent path: horizontal floor-mean pairs, then vertical.
    var cur: [side * side]i32 = img;
    var n: usize = side;
    while (n > 16) : (n /= 2) {
        const s = n / 2;
        var next: [side * side]i32 = undefined;
        var r: usize = 0;
        while (r < s) : (r += 1) {
            var c: usize = 0;
            while (c < s) : (c += 1) {
                const h0 = @divFloor(cur[(2 * r) * n + 2 * c] + cur[(2 * r) * n + 2 * c + 1], 2);
                const h1 = @divFloor(cur[(2 * r + 1) * n + 2 * c] + cur[(2 * r + 1) * n + 2 * c + 1], 2);
                next[r * s + c] = @divFloor(h0 + h1, 2);
            }
        }
        cur = next;
    }
    try testing.expectEqualSlices(i32, cur[0 .. 16 * 16], bands[0 .. 16 * 16]);
}

test "prefix offsets telescope: every prefix is a rung" {
    // top ends at 16²; level s occupies [s², 4s²) — so consuming levels
    // 16, 32, 64, 128 in order walks the prefix through every rung side.
    try testing.expectEqual(@as(usize, 256), levelOffset(16));
    try testing.expectEqual(@as(usize, 1024), levelOffset(16) + levelLen(16));
    try testing.expectEqual(@as(usize, 4096), levelOffset(32) + levelLen(32));
    try testing.expectEqual(@as(usize, 16384), levelOffset(64) + levelLen(64));
    try testing.expectEqual(@as(usize, 65536), levelOffset(128) + levelLen(128));
}

test "sigma law: block-constant image has all-zero detail bands" {
    const side = 64;
    const k = side / 16;
    var img: [side * side]i32 = undefined;
    for (0..side) |r| {
        for (0..side) |c| {
            img[r * side + c] = @intCast(100 * (r / k) + (c / k));
        }
    }
    var bands: [side * side]i32 = undefined;
    var scratch: [(side * side) / 2]i32 = undefined;
    try testing.expect(analyze(&img, side, 16, &bands, &scratch));
    for (bands[256..]) |v| try testing.expectEqual(@as(i32, 0), v);

    img[0] += 1; // one perturbation must light the details up
    try testing.expect(analyze(&img, side, 16, &bands, &scratch));
    var energy: i64 = 0;
    for (bands[256..]) |v| energy += @abs(v);
    try testing.expect(energy > 0);
}

test "bad sides are rejected" {
    var img: [4]i32 = .{ 0, 0, 0, 0 };
    var bands: [4]i32 = undefined;
    var scratch: [2]i32 = undefined;
    try testing.expect(!analyze(&img, 3, 1, &bands, &scratch)); // not pow2
    try testing.expect(!analyze(&img, 2, 4, &bands, &scratch)); // base > side
    try testing.expect(!analyze(&img, 2, 0, &bands, &scratch)); // zero base
}
