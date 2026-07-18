//! Cross-language GIF-target golden fixture test: the Zig port of the seed
//! palette display path and integer index maps must agree BIT-EXACT with the
//! Haskell contract (and the Python oracle). Also pins the GENERATED
//! srgb_table.zig against the golden's table (codegen drift tripwire).
//!
//! Skip-if-absent by default; `-Drequire_fixtures=true` turns skip to FAIL.

const std = @import("std");
const bk = @import("borealkernel");
const gt = bk.giftarget;
const srgb_table = bk.srgb_table;
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

test "cross-language: GIF target matches the Haskell goldens bit-exact" {
    const alloc = std.testing.allocator;
    const dir = build_options.fixture_dir;

    const raw = readFileAlloc(alloc, dir, "giftarget_golden.json") catch |e| {
        if (e == error.SkipZigTest) {
            if (build_options.require_fixtures) return error.FixtureMissing;
            std.debug.print("\n  [skip] giftarget_golden.json not in '{s}'\n", .{dir});
            return error.SkipZigTest;
        }
        return e;
    };
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const root = parsed.value.object;

    // Generated table == golden table (codegen drift tripwire).
    const tbl = root.get("srgbTable").?.array.items;
    try std.testing.expectEqual(@as(usize, 4096), tbl.len);
    for (tbl, 0..) |v, i| {
        try std.testing.expectEqual(
            @as(u8, @intCast(v.integer)),
            srgb_table.SRGB8_FROM_LINEAR_4096[i],
        );
    }

    // Seed palette display path: Q16 → sRGB8, bit-exact.
    const p = root.get("palette").?.object;
    const palL = try intsInto(i32, alloc, p.get("q16L").?);
    defer alloc.free(palL);
    const palA = try intsInto(i32, alloc, p.get("q16a").?);
    defer alloc.free(palA);
    const palB = try intsInto(i32, alloc, p.get("q16b").?);
    defer alloc.free(palB);
    const rgbWant = try intsInto(u8, alloc, p.get("rgb8").?);
    defer alloc.free(rgbWant);
    const rgbGot = try alloc.alloc(u8, 3 * palL.len);
    defer alloc.free(rgbGot);
    gt.srgb8Batch(palL, palA, palB, rgbGot);
    try std.testing.expectEqualSlices(u8, rgbWant, rgbGot);

    // Index maps: LCG probes and the A2 self-indexing identity.
    const fx = root.get("indexFixture").?.object;
    const pr = fx.get("probes").?.object;
    const prL = try intsInto(i32, alloc, pr.get("q16L").?);
    defer alloc.free(prL);
    const prA = try intsInto(i32, alloc, pr.get("q16a").?);
    defer alloc.free(prA);
    const prB = try intsInto(i32, alloc, pr.get("q16b").?);
    defer alloc.free(prB);
    const idxWant = try intsInto(u8, alloc, fx.get("indices").?);
    defer alloc.free(idxWant);
    const idxGot = try alloc.alloc(u8, prL.len);
    defer alloc.free(idxGot);
    gt.indexMap(prL, prA, prB, palL, palA, palB, idxGot);
    try std.testing.expectEqualSlices(u8, idxWant, idxGot);

    const selfWant = try intsInto(u8, alloc, fx.get("selfIndices").?);
    defer alloc.free(selfWant);
    const selfGot = try alloc.alloc(u8, palL.len);
    defer alloc.free(selfGot);
    gt.indexMap(palL, palA, palB, palL, palA, palB, selfGot);
    try std.testing.expectEqualSlices(u8, selfWant, selfGot);
    for (selfGot, 0..) |v, i| try std.testing.expectEqual(@as(u8, @intCast(i)), v);
}
