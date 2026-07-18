//! Cross-language pyramid golden fixture test.
//!
//! `make -C spec gate` (Haskell) emits fixtures/pyramid_golden.json from the
//! SAME Boreal.Pyramid kernels the law suite verifies. This test runs the Zig
//! port on the same inputs and asserts BIT-EXACT agreement — exact band
//! arrays at 32²/64², FNV-1a-64 checksums at the 256² ceiling — proving
//! Zig kernel ≡ Haskell contract (≡ Python oracle).
//!
//! Skip-if-absent by default; pass `-Drequire_fixtures=true` to turn skip
//! into FAIL (the gate).

const std = @import("std");
const bk = @import("borealkernel");
const pyramid = bk.pyramid;
const build_options = @import("build_options");

fn readFileAlloc(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const io = std.testing.io;
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    defer alloc.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch
        return error.SkipZigTest;
}

fn intsInto(comptime T: type, alloc: std.mem.Allocator, arr: std.json.Value) ![]T {
    const items = arr.array.items;
    const out = try alloc.alloc(T, items.len);
    for (items, 0..) |v, i| out[i] = @intCast(v.integer);
    return out;
}

/// FNV-1a 64 over i32 little-endian bytes (normative stream convention).
fn fnv1a64(ints: []const i32) u64 {
    var h: u64 = 14695981039346656037;
    for (ints) |v| {
        const w: u32 = @bitCast(v);
        inline for (.{ 0, 8, 16, 24 }) |sh| {
            h = (h ^ @as(u64, (w >> sh) & 0xff)) *% 1099511628211;
        }
    }
    return h;
}

test "cross-language: pyramid bands match the Haskell goldens bit-exact" {
    const alloc = std.testing.allocator;
    const dir = build_options.fixture_dir;

    const raw = readFileAlloc(alloc, dir, "pyramid_golden.json") catch |e| {
        if (e == error.SkipZigTest) {
            if (build_options.require_fixtures) {
                std.debug.print(
                    "\n  [FAIL] pyramid_golden.json required but absent in '{s}'\n",
                    .{dir},
                );
                return error.FixtureMissing;
            }
            std.debug.print(
                "\n  [skip] pyramid_golden.json not in '{s}'; run `make -C spec gate`\n",
                .{dir},
            );
            return error.SkipZigTest;
        }
        return e;
    };
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // ── Exact fixtures: full band arrays at 32² and 64² ──────────────────
    for (root.get("fixtures").?.array.items) |fv| {
        const f = fv.object;
        const side: u32 = @intCast(f.get("side").?.integer);
        const base: u32 = @intCast(f.get("base").?.integer);
        const n: usize = @as(usize, side) * @as(usize, side);

        const image = try intsInto(i32, alloc, f.get("image").?);
        defer alloc.free(image);
        const top = try intsInto(i32, alloc, f.get("top").?);
        defer alloc.free(top);

        // Assemble the expected band buffer from the golden's per-level
        // (LH, HL, HH) arrays using the normative prefix layout.
        const expected = try alloc.alloc(i32, n);
        defer alloc.free(expected);
        @memcpy(expected[0..top.len], top);
        for (f.get("levels").?.array.items) |lv| {
            const l = lv.object;
            const s: usize = @intCast(l.get("detailSide").?.integer);
            const lh = try intsInto(i32, alloc, l.get("lh").?);
            defer alloc.free(lh);
            const hl = try intsInto(i32, alloc, l.get("hl").?);
            defer alloc.free(hl);
            const hh = try intsInto(i32, alloc, l.get("hh").?);
            defer alloc.free(hh);
            const off = pyramid.levelOffset(s);
            for (0..s * s) |i| {
                expected[off + 3 * i + 0] = lh[i];
                expected[off + 3 * i + 1] = hl[i];
                expected[off + 3 * i + 2] = hh[i];
            }
        }

        // Sanity: the fixture's own LCG convention reproduces its image.
        const regen = try alloc.alloc(i32, n);
        defer alloc.free(regen);
        pyramid.lcgFill(f.get("seed").?.integer, regen);
        try std.testing.expectEqualSlices(i32, image, regen);

        const bands = try alloc.alloc(i32, n);
        defer alloc.free(bands);
        const scratch = try alloc.alloc(i32, n / 2);
        defer alloc.free(scratch);
        try std.testing.expect(pyramid.analyze(image, side, base, bands, scratch));
        try std.testing.expectEqualSlices(i32, expected, bands);

        // And back: synthesize from the GOLDEN bands recovers the image.
        const back = try alloc.alloc(i32, n);
        defer alloc.free(back);
        try std.testing.expect(pyramid.synthesize(expected, side, base, back, scratch));
        try std.testing.expectEqualSlices(i32, image, back);
    }

    // ── Checksum fixtures: the 256² ceiling, pinned by FNV-1a-64 ─────────
    for (root.get("checksumFixtures").?.array.items) |fv| {
        const f = fv.object;
        const side: u32 = @intCast(f.get("side").?.integer);
        const base: u32 = @intCast(f.get("base").?.integer);
        const n: usize = @as(usize, side) * @as(usize, side);

        const image = try alloc.alloc(i32, n);
        defer alloc.free(image);
        pyramid.lcgFill(f.get("seed").?.integer, image);

        const imgSum = try std.fmt.parseInt(u64, f.get("imageFnv1a64").?.string, 10);
        try std.testing.expectEqual(imgSum, fnv1a64(image));

        const bands = try alloc.alloc(i32, n);
        defer alloc.free(bands);
        const scratch = try alloc.alloc(i32, n / 2);
        defer alloc.free(scratch);
        try std.testing.expect(pyramid.analyze(image, side, base, bands, scratch));

        // Human-readable anchor: first 8 of the top band.
        for (f.get("topFirstRow8").?.array.items, 0..) |v, i| {
            try std.testing.expectEqual(@as(i32, @intCast(v.integer)), bands[i]);
        }

        const bandSum = try std.fmt.parseInt(u64, f.get("bandsFnv1a64").?.string, 10);
        try std.testing.expectEqual(bandSum, fnv1a64(bands));

        // Round-trip at the ceiling for good measure.
        const back = try alloc.alloc(i32, n);
        defer alloc.free(back);
        try std.testing.expect(pyramid.synthesize(bands, side, base, back, scratch));
        try std.testing.expectEqualSlices(i32, image, back);
    }
}
