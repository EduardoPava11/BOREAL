//! lut.zig — owned 3D LUT baker (Phase 4; see ../../BOREAL-RGBT-HDR-WORKFLOW.md §4).
//! Hand-written, zero color-management libraries — BOREAL owns the LUT it ships.
//!
//! Produces the best LUT Photoshop can use: a 64³ `.cube` in the ProPhoto RGB
//! working space, [0,1] domain (Photoshop's Color Lookup tops out at 64 grid
//! points and clamps to the unit cube — §4.1). We bake a deterministic "look"
//! operator into the lattice and emit the `.cube` text ourselves.
//!
//! The look operator is the ASC CDL — the industry-standard primary grade:
//!   cdl_c = (in_c · slope_c + offset_c) clamped[0,1], then ^ power_c
//!   luma  = Σ w_c · cdl_c
//!   out_c = luma + sat · (cdl_c − luma)              clamped[0,1]
//! Owned, fully parametric (slope/offset/power per channel + saturation), and
//! monotone for slope>0, power>0. Identity params (slope 1, offset 0, power 1,
//! sat 1) bake an identity LUT — the correctness anchor.
//!
//! SIMD: the lattice is iterated red-fastest (the `.cube` storage order). The
//! red axis is vectorized — `@Vector(8,f32)` lattice points per step with green
//! and blue fixed — so the cross-channel saturation mix is branchless and the
//! per-(g,b) work (green/blue CDL, their luma contribution) is hoisted out.

const std = @import("std");

pub const LANES = 8;
const Vf = @Vector(LANES, f32);

/// ASC-CDL look parameters. C-ABI mirror (extern).
pub const LookParams = extern struct {
    slope: [3]f32, // per-channel gain
    offset: [3]f32, // per-channel lift
    power: [3]f32, // per-channel gamma
    luma_w: [3]f32, // luminance weights for the saturation mix
    sat: f32, // saturation (1 = identity, 0 = monochrome)
};

/// Identity grade: bakes an identity LUT. Rec.709 luma weights (a fine luma
/// proxy; the look is artistic regardless of working-space primaries).
pub fn identity() LookParams {
    return .{
        .slope = .{ 1, 1, 1 },
        .offset = .{ 0, 0, 0 },
        .power = .{ 1, 1, 1 },
        .luma_w = .{ 0.2126, 0.7152, 0.0722 },
        .sat = 1.0,
    };
}

inline fn clamp01v(v: Vf) Vf {
    const z: Vf = @splat(0.0);
    const o: Vf = @splat(1.0);
    return @min(@max(v, z), o);
}

/// One CDL channel, scalar. Uses @exp/@log for pow so the scalar and vector
/// paths share an identical formula (tight SIMD≡scalar parity).
inline fn cdlScalar(x: f32, s: f32, o: f32, pw: f32) f32 {
    const base = std.math.clamp(x * s + o, 0.0, 1.0);
    return @exp(pw * @log(@max(base, 1.0e-8)));
}

/// One CDL channel, vectorized over the red axis.
inline fn cdlVec(x: Vf, s: f32, o: f32, pw: f32) Vf {
    const sv: Vf = @splat(s);
    const ov: Vf = @splat(o);
    const base = clamp01v(x * sv + ov);
    const floor: Vf = @splat(1.0e-8);
    const pwv: Vf = @splat(pw);
    return @exp(pwv * @log(@max(base, floor)));
}

/// Scalar reference look — the single source of truth for the math. The bake
/// loop's vector path replicates this; tests pin them equal.
pub fn applyLook(inp: [3]f32, p: LookParams) [3]f32 {
    var cdl: [3]f32 = undefined;
    inline for (0..3) |c| cdl[c] = cdlScalar(inp[c], p.slope[c], p.offset[c], p.power[c]);
    const luma = p.luma_w[0] * cdl[0] + p.luma_w[1] * cdl[1] + p.luma_w[2] * cdl[2];
    var out: [3]f32 = undefined;
    inline for (0..3) |c| out[c] = std.math.clamp(luma + p.sat * (cdl[c] - luma), 0.0, 1.0);
    return out;
}

/// Bake the look into a `grid³ × 3` interleaved RGB lattice (red fastest, then
/// green, then blue — `.cube` order). `out.len` must be grid*grid*grid*3.
/// Strong SIMD on the red axis + scalar remainder. No allocation.
pub fn bakeLattice(out: []f32, grid: u32, p: LookParams) void {
    const N: usize = grid;
    std.debug.assert(out.len == N * N * N * 3);
    if (N < 2) return;
    const invN1: f32 = 1.0 / @as(f32, @floatFromInt(N - 1));

    const wr = p.luma_w[0];
    const wg = p.luma_w[1];
    const wb = p.luma_w[2];
    const sat = p.sat;

    var bi: usize = 0;
    while (bi < N) : (bi += 1) {
        const bn = @as(f32, @floatFromInt(bi)) * invN1;
        const cdl_b = cdlScalar(bn, p.slope[2], p.offset[2], p.power[2]);
        var gi: usize = 0;
        while (gi < N) : (gi += 1) {
            const gn = @as(f32, @floatFromInt(gi)) * invN1;
            const cdl_g = cdlScalar(gn, p.slope[1], p.offset[1], p.power[1]);
            const lum_gb = wg * cdl_g + wb * cdl_b; // hoisted: green+blue luma contribution
            const row = (bi * N + gi) * N;

            // ── SIMD red axis ──
            var ri: usize = 0;
            const wr_v: Vf = @splat(wr);
            const lum_gb_v: Vf = @splat(lum_gb);
            const sat_v: Vf = @splat(sat);
            const cdl_g_v: Vf = @splat(cdl_g);
            const cdl_b_v: Vf = @splat(cdl_b);
            while (ri + LANES <= N) : (ri += LANES) {
                var idx: Vf = undefined;
                inline for (0..LANES) |k| idx[k] = @floatFromInt(ri + k);
                const rn = idx * @as(Vf, @splat(invN1));
                const cdl_r = cdlVec(rn, p.slope[0], p.offset[0], p.power[0]);
                const luma = wr_v * cdl_r + lum_gb_v;
                const out_r = clamp01v(luma + sat_v * (cdl_r - luma));
                const out_g = clamp01v(luma + sat_v * (cdl_g_v - luma));
                const out_b = clamp01v(luma + sat_v * (cdl_b_v - luma));
                inline for (0..LANES) |k| {
                    const o = (row + ri + k) * 3;
                    out[o + 0] = out_r[k];
                    out[o + 1] = out_g[k];
                    out[o + 2] = out_b[k];
                }
            }
            // ── scalar remainder (red tail) ──
            while (ri < N) : (ri += 1) {
                const rn = @as(f32, @floatFromInt(ri)) * invN1;
                const tri = applyLook(.{ rn, gn, bn }, p);
                const o = (row + ri) * 3;
                out[o + 0] = tri[0];
                out[o + 1] = tri[1];
                out[o + 2] = tri[2];
            }
        }
    }
}

/// Serialize a baked lattice as an Adobe/Resolve `.cube` (3D LUT) into `buf`.
/// Returns bytes written, or null if `buf` is too small. Hand-rolled text — no
/// std.io dependency. Domain pinned to [0,1] (Photoshop requirement).
pub fn emitCube(buf: []u8, lattice: []const f32, grid: u32, title: []const u8) ?usize {
    var off: usize = 0;
    const hdr = std.fmt.bufPrint(buf[off..], "TITLE \"{s}\"\nLUT_3D_SIZE {d}\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n", .{ title, grid }) catch return null;
    off += hdr.len;
    const total: usize = @as(usize, grid) * grid * grid;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const line = std.fmt.bufPrint(buf[off..], "{d:.6} {d:.6} {d:.6}\n", .{ lattice[i * 3], lattice[i * 3 + 1], lattice[i * 3 + 2] }) catch return null;
        off += line.len;
    }
    return off;
}

// ── Tests (spec-first: §4 laws + SIMD≡scalar gate) ─────────────────────────

const testing = std.testing;

fn bakeRef(out: []f32, grid: u32, p: LookParams) void {
    const N: usize = grid;
    const invN1: f32 = 1.0 / @as(f32, @floatFromInt(N - 1));
    var bi: usize = 0;
    while (bi < N) : (bi += 1) {
        var gi: usize = 0;
        while (gi < N) : (gi += 1) {
            var ri: usize = 0;
            while (ri < N) : (ri += 1) {
                const inp = [3]f32{
                    @as(f32, @floatFromInt(ri)) * invN1,
                    @as(f32, @floatFromInt(gi)) * invN1,
                    @as(f32, @floatFromInt(bi)) * invN1,
                };
                const tri = applyLook(inp, p);
                const o = ((bi * N + gi) * N + ri) * 3;
                out[o + 0] = tri[0];
                out[o + 1] = tri[1];
                out[o + 2] = tri[2];
            }
        }
    }
}

test "applyLook: identity params map a color to itself" {
    const p = identity();
    const r = applyLook(.{ 0.2, 0.6, 0.9 }, p);
    try testing.expectApproxEqAbs(@as(f32, 0.2), r[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.6), r[1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.9), r[2], 1e-5);
}

test "applyLook: sat=0 → monochrome (all channels equal luma)" {
    var p = identity();
    p.sat = 0;
    const r = applyLook(.{ 0.2, 0.6, 0.9 }, p);
    try testing.expectApproxEqAbs(r[0], r[1], 1e-6);
    try testing.expectApproxEqAbs(r[1], r[2], 1e-6);
}

test "cdl: monotone increasing in input (slope>0, power>0)" {
    try testing.expect(cdlScalar(0.3, 1.2, 0.05, 0.9) < cdlScalar(0.7, 1.2, 0.05, 0.9));
}

test "bakeLattice: identity LUT reproduces the input lattice" {
    const grid = 8;
    var out: [grid * grid * grid * 3]f32 = undefined;
    bakeLattice(&out, grid, identity());
    const invN1: f32 = 1.0 / @as(f32, grid - 1);
    // spot-check a few lattice points
    for ([_][3]usize{ .{ 0, 0, 0 }, .{ 7, 3, 5 }, .{ 4, 4, 4 } }) |c| {
        const o = ((c[2] * grid + c[1]) * grid + c[0]) * 3;
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(c[0])) * invN1, out[o + 0], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(c[1])) * invN1, out[o + 1], 1e-5);
        try testing.expectApproxEqAbs(@as(f32, @floatFromInt(c[2])) * invN1, out[o + 2], 1e-5);
    }
}

test "bakeLattice: every output stays within [0,1]" {
    const grid = 16;
    var out: [grid * grid * grid * 3]f32 = undefined;
    var p = identity();
    p.slope = .{ 1.4, 1.1, 0.8 };
    p.offset = .{ 0.02, -0.03, 0.05 };
    p.power = .{ 0.85, 1.0, 1.2 };
    p.sat = 1.3;
    bakeLattice(&out, grid, p);
    for (out) |v| try testing.expect(v >= 0.0 and v <= 1.0);
}

test "SIMD ≡ scalar: bake matches reference (grid div by 8 AND ragged)" {
    var p = identity();
    p.slope = .{ 1.4, 1.1, 0.8 };
    p.offset = .{ 0.02, -0.03, 0.05 };
    p.power = .{ 0.85, 1.0, 1.2 };
    p.sat = 1.3;
    inline for ([_]u32{ 16, 13 }) |grid| { // 16 = pure vector; 13 = exercises red tail
        var got: [grid * grid * grid * 3]f32 = undefined;
        var ref: [grid * grid * grid * 3]f32 = undefined;
        bakeLattice(&got, grid, p);
        bakeRef(&ref, grid, p);
        for (0..got.len) |i| try testing.expectApproxEqAbs(ref[i], got[i], 1e-5);
    }
}

test "emitCube: header + correct data line count for a 2³ grid" {
    const grid = 2;
    var lat: [grid * grid * grid * 3]f32 = undefined;
    bakeLattice(&lat, grid, identity());
    var buf: [1024]u8 = undefined;
    const len = emitCube(&buf, &lat, grid, "BOREAL").?;
    const text = buf[0..len];
    try testing.expect(std.mem.indexOf(u8, text, "LUT_3D_SIZE 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "DOMAIN_MAX 1.0 1.0 1.0") != null);
    // 8 data lines for a 2³ lattice.
    var lines: usize = 0;
    for (text) |ch| {
        if (ch == '\n') lines += 1;
    }
    try testing.expectEqual(@as(usize, 4 + 8), lines); // 4 header lines + 8 data
}

test "emitCube: returns null when the buffer is too small" {
    var lat: [2 * 2 * 2 * 3]f32 = undefined;
    bakeLattice(&lat, 2, identity());
    var tiny: [8]u8 = undefined;
    try testing.expect(emitCube(&tiny, &lat, 2, "BOREAL") == null);
}
