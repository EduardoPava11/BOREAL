//! Cross-language colorpath golden fixture test.
//!
//! `make -C spec gate` (Haskell) emits fixtures/colorpath_golden.json from
//! the SAME Boreal.ColorPath the law suite verifies, and the Python oracle
//! re-derives it from the written conventions. This test asserts the Zig
//! port agrees BIT-EXACT: owned cbrt values, the comptime-composed
//! PROPHOTO_TO_LMS matrix, OKLab f64 triples, and Q16 i32 quantizations.
//!
//! Skip-if-absent by default; `-Drequire_fixtures=true` turns skip to FAIL.

const std = @import("std");
const bk = @import("borealkernel");
const oklab = bk.oklab;
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

test "cross-language: ProPhoto→OKLab→Q16 matches the Haskell goldens bit-exact" {
    const alloc = std.testing.allocator;
    const dir = build_options.fixture_dir;

    const raw = readFileAlloc(alloc, dir, "colorpath_golden.json") catch |e| {
        if (e == error.SkipZigTest) {
            if (build_options.require_fixtures) {
                std.debug.print(
                    "\n  [FAIL] colorpath_golden.json required but absent in '{s}'\n",
                    .{dir},
                );
                return error.FixtureMissing;
            }
            std.debug.print(
                "\n  [skip] colorpath_golden.json not in '{s}'; run `make -C spec gate`\n",
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

    // The comptime-composed matrix must equal the spec's composition
    // bit for bit — this is the typed-f64-at-comptime guarantee.
    const composed = root.get("matrices").?.object.get("prophotoToLms").?.array.items;
    for (composed, 0..) |v, i| {
        try std.testing.expectEqual(asF64(v), oklab.PROPHOTO_TO_LMS[i]);
    }

    // Owned cbrt: bit-exact on every golden input.
    for (root.get("cbrt").?.array.items) |cv| {
        const c = cv.object;
        try std.testing.expectEqual(asF64(c.get("y").?), oklab.ownedCbrt(asF64(c.get("x").?)));
    }

    // Box reduce: dyadic 16×16 RGB → 2×2, bit-exact (inputs chosen so no
    // f64 rounding occurs; the f32 output is therefore exact too).
    {
        const br = root.get("boxReduce").?.object;
        const w: usize = @intCast(br.get("width").?.integer);
        const h: usize = @intCast(br.get("height").?.integer);
        const k: usize = @intCast(br.get("factor").?.integer);
        const rgbJ = br.get("rgb").?.array.items;
        const img = try alloc.alloc(f32, rgbJ.len);
        defer alloc.free(img);
        for (rgbJ, 0..) |v, i| img[i] = @floatCast(asF64(v));
        const out = try alloc.alloc(f32, 3 * (w / k) * (h / k));
        defer alloc.free(out);
        bk.reduce.boxReduceRgb(img, w, h, k, out);
        const want = br.get("out").?.array.items;
        for (want, 0..) |v, i| {
            try std.testing.expectEqual(@as(f32, @floatCast(asF64(v))), out[i]);
        }
    }

    // Full path: ProPhoto triple → OKLab f64 (bit-exact) → Q16 (exact),
    // exercised through the f32 kernel entry (inputs are f32-exact dyadics).
    for (root.get("samples").?.array.items) |sv| {
        const s = sv.object;
        const pp = s.get("prophoto").?.array.items;
        const rgb32 = [3]f32{
            @floatCast(asF64(pp[0])),
            @floatCast(asF64(pp[1])),
            @floatCast(asF64(pp[2])),
        };
        const lab = oklab.oklabFromProPhoto(rgb32[0], rgb32[1], rgb32[2]);
        const want = s.get("oklab").?.array.items;
        for (want, 0..) |v, i| {
            try std.testing.expectEqual(asF64(v), lab[i]);
        }
        var q: [3]i32 = undefined;
        oklab.quantizeProPhotoToOklab(&rgb32, &q);
        const wantQ = s.get("q16").?.array.items;
        for (wantQ, 0..) |v, i| {
            try std.testing.expectEqual(@as(i32, @intCast(v.integer)), q[i]);
        }
    }
}
