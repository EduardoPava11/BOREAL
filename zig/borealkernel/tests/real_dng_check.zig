//! Standalone Zig program that decodes the user's airdropped iPhone DNG
//! and prints sanity stats. Not part of the test suite (Zig 0.16's file
//! API moved to std.Io.Dir which is awkward in tests).
//!
//! Run: zig build real-dng-check  (added as a build step in build.zig)

const std = @import("std");
const dng = @import("borealkernel").dng;

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();
    const alloc = debug_alloc.allocator();

    const path = "/Users/daniel/Downloads/frame-0.dng";

    // Use libc directly — Zig 0.16 moved the file API to std.Io.Dir which
    // requires an Io vtable and is awkward outside the new event loop.
    const c = std.c;
    const fd = c.open(path, .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) {
        std.debug.print("FAIL open {s}\n", .{path});
        return error.OpenFailed;
    }
    defer _ = c.close(fd);

    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.StatFailed;
    const size: usize = @intCast(st.size);
    std.debug.print("File: {s}\n", .{path});
    std.debug.print("Size: {d} bytes\n", .{size});

    const bytes_buf = try alloc.alloc(u8, size);
    defer alloc.free(bytes_buf);
    const n = c.read(fd, bytes_buf.ptr, size);
    if (n != @as(isize, @intCast(size))) return error.ReadShort;
    const bytes: []const u8 = bytes_buf;

    var m = dng.parse(alloc, bytes) catch |err| {
        std.debug.print("FAIL dng.parse: {s}\n", .{@errorName(err)});
        return;
    };
    defer dng.deinit(alloc, &m);

    std.debug.print("\n✓ DECODE SUCCESS\n", .{});
    std.debug.print("  width={d} height={d} bits={d}\n", .{ m.width, m.height, m.bits });
    std.debug.print("  black={d} white={d} cfa={s}\n", .{ m.black, m.white, @tagName(m.cfa) });
    std.debug.print("  crop_origin=({d}, {d}) crop_size={d}x{d}\n",
        .{ m.crop_x, m.crop_y, m.crop_w, m.crop_h });

    // Sample stats.
    var max_sample: u16 = 0;
    var min_sample: u16 = std.math.maxInt(u16);
    var sum: u64 = 0;
    var zeros: u32 = 0;
    for (m.samples) |s| {
        if (s > max_sample) max_sample = s;
        if (s < min_sample) min_sample = s;
        sum += s;
        if (s == 0) zeros += 1;
    }
    const mean = sum / m.samples.len;
    std.debug.print("\nSample stats over {d} samples:\n", .{m.samples.len});
    std.debug.print("  min={d} max={d} mean={d}\n", .{ min_sample, max_sample, mean });
    std.debug.print("  zeros={d} ({d:.2}%)\n", .{ zeros, 100.0 * @as(f64, @floatFromInt(zeros)) / @as(f64, @floatFromInt(m.samples.len)) });
    std.debug.print("  first 8 samples: ", .{});
    for (m.samples[0..@min(8, m.samples.len)]) |s| std.debug.print("{d} ", .{s});
    std.debug.print("\n", .{});
    std.debug.print("  middle 8 samples: ", .{});
    const mid = m.samples.len / 2;
    for (m.samples[mid..mid + 8]) |s| std.debug.print("{d} ", .{s});
    std.debug.print("\n", .{});

    // BGGR cell check: at (0, 0), BGGR phase says it's B. The B value should
    // be at the cell's center of distribution for the scene; just print.
    const w: usize = @intCast(m.width);
    std.debug.print("\nFirst 2x2 cell (BGGR phase):\n", .{});
    std.debug.print("  ({d}, {d}) → B={d}  G={d}\n", .{ 0, 0, m.samples[0], m.samples[1] });
    std.debug.print("  ({d}, {d}) → G={d}  R={d}\n", .{ 1, 0, m.samples[w], m.samples[w + 1] });
}
