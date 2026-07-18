//! Cross-language GIF-wire golden fixture test: the Zig encoder's output
//! must equal the Haskell contract's bytes EXACTLY (and the Python oracle
//! re-derives the same bytes from the written conventions).
//!
//! Skip-if-absent by default; `-Drequire_fixtures=true` turns skip to FAIL.

const std = @import("std");
const bk = @import("borealkernel");
const gw = bk.gifwire;
const build_options = @import("build_options");

fn readFileAlloc(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    const io = std.testing.io;
    const path = try std.fs.path.join(alloc, &.{ dir, name });
    defer alloc.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch
        return error.SkipZigTest;
}

test "cross-language: GIF bytes match the Haskell golden exactly" {
    const alloc = std.testing.allocator;
    const dir = build_options.fixture_dir;

    const raw = readFileAlloc(alloc, dir, "gifwire_golden.json") catch |e| {
        if (e == error.SkipZigTest) {
            if (build_options.require_fixtures) return error.FixtureMissing;
            std.debug.print("\n  [skip] gifwire_golden.json not in '{s}'\n", .{dir});
            return error.SkipZigTest;
        }
        return e;
    };
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const fx = parsed.value.object.get("fixture").?.object;

    const side: u32 = @intCast(fx.get("side").?.integer);
    const delay: u32 = @intCast(fx.get("delayCs").?.integer);

    const palJ = fx.get("palette").?.array.items;
    var gct: [768]u8 = undefined;
    for (palJ, 0..) |v, i| gct[i] = @intCast(v.integer);

    const framesJ = fx.get("frames").?.array.items;
    const n = @as(usize, side) * side;
    const flat = try alloc.alloc(u8, framesJ.len * n);
    defer alloc.free(flat);
    for (framesJ, 0..) |fv, fi| {
        for (fv.array.items, 0..) |v, i| flat[fi * n + i] = @intCast(v.integer);
    }

    const want = fx.get("gifBytes").?.array.items;
    const out = try alloc.alloc(u8, gw.encodedLen(side, @intCast(framesJ.len)));
    defer alloc.free(out);
    const written = gw.encode(flat, @intCast(framesJ.len), side, &gct, delay, out);
    try std.testing.expectEqual(want.len, written);
    for (want, 0..) |v, i| {
        try std.testing.expectEqual(@as(u8, @intCast(v.integer)), out[i]);
    }
}
