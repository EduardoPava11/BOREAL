//! Cross-language multi-scale golden fixture test: the Zig port of the
//! per-rung demosaic + residual stack must agree BIT-EXACT with the Haskell
//! contract (and the Python oracle) on the 128² dyadic mosaic fixture.
//!
//! Skip-if-absent by default; `-Drequire_fixtures=true` turns skip to FAIL.

const std = @import("std");
const bk = @import("borealkernel");
const ms = bk.multiscale;
const build_options = @import("build_options");

fn readFileAlloc(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const io = std.testing.io;
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    defer alloc.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch
        return error.SkipZigTest;
}

fn asF64(v: std.json.Value) f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => unreachable,
    };
}

test "cross-language: multi-scale stack matches the Haskell goldens bit-exact" {
    const alloc = std.testing.allocator;
    const dir = build_options.fixture_dir;

    const raw = readFileAlloc(alloc, dir, "multiscale_golden.json") catch |e| {
        if (e == error.SkipZigTest) {
            if (build_options.require_fixtures) return error.FixtureMissing;
            std.debug.print("\n  [skip] multiscale_golden.json not in '{s}'\n", .{dir});
            return error.SkipZigTest;
        }
        return e;
    };
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const fx = parsed.value.object.get("fixture").?.object;

    const side: u32 = @intCast(fx.get("side").?.integer);
    const mosJ = fx.get("mosaicF64").?.array.items;
    const mosaic = try alloc.alloc(f32, mosJ.len);
    defer alloc.free(mosaic);
    for (mosJ, 0..) |v, i| mosaic[i] = @floatCast(asF64(v));

    const total = ms.stackLen(side);
    const bL = try alloc.alloc(i32, total);
    defer alloc.free(bL);
    const bA = try alloc.alloc(i32, total);
    defer alloc.free(bA);
    const bB = try alloc.alloc(i32, total);
    defer alloc.free(bB);
    const ident = [9]f64{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    try std.testing.expect(ms.encode(mosaic, side, 0, ident, bL, bA, bB));

    inline for (.{ "bandsL", "bandsA", "bandsB" }, 0..) |key, ch| {
        const want = fx.get(key).?.array.items;
        const got = switch (ch) {
            0 => bL,
            1 => bA,
            else => bB,
        };
        try std.testing.expectEqual(want.len, got.len);
        for (want, 0..) |v, i| {
            try std.testing.expectEqual(@as(i32, @intCast(v.integer)), got[i]);
        }
    }

    // MS3 through the golden: decode every rung from the GOLDEN bands and
    // compare against the direct per-rung demosaic.
    var rbuf: [5]u32 = undefined;
    for (ms.rungsFor(side, &rbuf)) |r| {
        const n = @as(usize, r) * r;
        const direct = try alloc.alloc(i32, n);
        defer alloc.free(direct);
        const dA = try alloc.alloc(i32, n);
        defer alloc.free(dA);
        const dB = try alloc.alloc(i32, n);
        defer alloc.free(dB);
        ms.computeRung(mosaic, side, 0, ident, r, direct, dA, dB);
        const got = try alloc.alloc(i32, n);
        defer alloc.free(got);
        try std.testing.expect(ms.decodeRung(bL, side, r, got));
        try std.testing.expectEqualSlices(i32, direct, got);
    }
}
