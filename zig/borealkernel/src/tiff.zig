//! tiff.zig — owned 32-bit-float HDR TIFF encoder (Phase 3; see
//! ../../BOREAL-RGBT-HDR-WORKFLOW.md §3). Hand-written, zero TIFF libraries —
//! BOREAL emits every byte of the container itself.
//!
//! Output: a baseline little-endian ("II") TIFF, RGB, 32-bit IEEE float
//! (SampleFormat = 3), chunky/interleaved, single uncompressed strip — the
//! maximum-fidelity scene-linear master. An optional ICC profile blob is
//! embedded verbatim (tag 34675); the profile itself is caller-supplied color
//! data, not something we fabricate.
//!
//! The encoder is pure: it lays the file out deterministically and copies the
//! fused float pixels in (host is little-endian = file byte order, so the pixel
//! payload is a straight memcpy). No allocation, no global state.
//!
//! Layout:  [8B header][IFD0][BitsPerSample[3]][SampleFormat[3]][ICC?][pad][pixels]

const std = @import("std");

// TIFF field type codes used here.
const TYPE_SHORT: u16 = 3;
const TYPE_LONG: u16 = 4;
const TYPE_UNDEFINED: u16 = 7;

/// Computed byte layout of the file. Shared by `tiffSize` and `writeTiff` so
/// the two can never disagree.
pub const Layout = struct {
    n_entries: u16,
    bps_off: usize, // BitsPerSample[3] SHORTs
    sf_off: usize, // SampleFormat[3] SHORTs
    icc_off: usize, // 0 if no ICC
    pixel_off: usize,
    pixel_size: usize,
    total: usize,
};

const IFD_OFF: usize = 8;

pub fn computeLayout(width: u32, height: u32, icc_len: usize) Layout {
    const have_icc = icc_len > 0;
    const n_entries: u16 = if (have_icc) 12 else 11;
    const ifd_size = 2 + @as(usize, n_entries) * 12 + 4;
    const ext = IFD_OFF + ifd_size;
    const bps_off = ext;
    const sf_off = bps_off + 6;
    var cur = sf_off + 6;
    var icc_off: usize = 0;
    if (have_icc) {
        icc_off = cur;
        cur += icc_len;
    }
    const pixel_off = std.mem.alignForward(usize, cur, 4);
    const pixel_size = @as(usize, width) * @as(usize, height) * 3 * 4;
    return .{
        .n_entries = n_entries,
        .bps_off = bps_off,
        .sf_off = sf_off,
        .icc_off = icc_off,
        .pixel_off = pixel_off,
        .pixel_size = pixel_size,
        .total = pixel_off + pixel_size,
    };
}

/// Total file size for a width×height RGB-float TIFF with `icc_len`-byte ICC.
pub fn tiffSize(width: u32, height: u32, icc_len: usize) usize {
    return computeLayout(width, height, icc_len).total;
}

inline fn wU16(buf: []u8, off: usize, v: u16) void {
    buf[off + 0] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}
inline fn wU32(buf: []u8, off: usize, v: u32) void {
    buf[off + 0] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
    buf[off + 2] = @truncate(v >> 16);
    buf[off + 3] = @truncate(v >> 24);
}

/// Write one 12-byte IFD entry. For inline values (≤4 bytes) `value` is the
/// value itself (little-endian write places a SHORT in the low 2 bytes); for
/// out-of-line arrays `value` is the byte offset to the data.
inline fn entry(buf: []u8, pos: *usize, tag: u16, typ: u16, count: u32, value: u32) void {
    wU16(buf, pos.* + 0, tag);
    wU16(buf, pos.* + 2, typ);
    wU32(buf, pos.* + 4, count);
    wU32(buf, pos.* + 8, value);
    pos.* += 12;
}

/// Encode a 32-bit-float RGB TIFF into `buf`. `pixels` is interleaved RGB,
/// length ≥ width*height*3, scene-linear (or any) float. `icc` may be empty.
/// Returns bytes written, or null if `buf` is too small / `pixels` too short.
pub fn writeTiff(buf: []u8, width: u32, height: u32, pixels: []const f32, icc: []const u8) ?usize {
    const L = computeLayout(width, height, icc.len);
    if (buf.len < L.total) return null;
    if (pixels.len < @as(usize, width) * @as(usize, height) * 3) return null;

    // ── 8-byte header ──
    buf[0] = 'I';
    buf[1] = 'I';
    wU16(buf, 2, 42); // TIFF magic
    wU32(buf, 4, @intCast(IFD_OFF));

    // ── IFD0 (entries MUST be tag-ascending) ──
    wU16(buf, IFD_OFF, L.n_entries);
    var e = IFD_OFF + 2;
    entry(buf, &e, 256, TYPE_LONG, 1, width); // ImageWidth
    entry(buf, &e, 257, TYPE_LONG, 1, height); // ImageLength
    entry(buf, &e, 258, TYPE_SHORT, 3, @intCast(L.bps_off)); // BitsPerSample[3]
    entry(buf, &e, 259, TYPE_SHORT, 1, 1); // Compression = none
    entry(buf, &e, 262, TYPE_SHORT, 1, 2); // Photometric = RGB
    entry(buf, &e, 273, TYPE_LONG, 1, @intCast(L.pixel_off)); // StripOffsets
    entry(buf, &e, 277, TYPE_SHORT, 1, 3); // SamplesPerPixel
    entry(buf, &e, 278, TYPE_LONG, 1, height); // RowsPerStrip = height (1 strip)
    entry(buf, &e, 279, TYPE_LONG, 1, @intCast(L.pixel_size)); // StripByteCounts
    entry(buf, &e, 284, TYPE_SHORT, 1, 1); // PlanarConfig = chunky
    entry(buf, &e, 339, TYPE_SHORT, 3, @intCast(L.sf_off)); // SampleFormat[3]
    if (icc.len > 0) entry(buf, &e, 34675, TYPE_UNDEFINED, @intCast(icc.len), @intCast(L.icc_off));
    wU32(buf, e, 0); // next-IFD offset = 0

    // ── out-of-line arrays ──
    inline for (0..3) |k| wU16(buf, L.bps_off + k * 2, 32); // 32 bits/sample
    inline for (0..3) |k| wU16(buf, L.sf_off + k * 2, 3); // IEEE float
    if (icc.len > 0) @memcpy(buf[L.icc_off..][0..icc.len], icc);

    // zero any alignment padding before the pixel strip
    const cur = if (icc.len > 0) L.icc_off + icc.len else L.sf_off + 6;
    if (L.pixel_off > cur) @memset(buf[cur..L.pixel_off], 0);

    // ── pixel strip: host LE == file byte order → straight copy ──
    const src = std.mem.sliceAsBytes(pixels[0 .. @as(usize, width) * @as(usize, height) * 3]);
    @memcpy(buf[L.pixel_off..][0..L.pixel_size], src);

    return L.total;
}

// ── Tests (spec-first) ─────────────────────────────────────────────────────

const testing = std.testing;

/// Locate an IFD entry by tag; returns (type, count, value) or null.
fn findEntry(buf: []const u8, tag: u16) ?struct { typ: u16, count: u32, value: u32 } {
    const n = @as(u16, buf[IFD_OFF]) | (@as(u16, buf[IFD_OFF + 1]) << 8);
    var p = IFD_OFF + 2;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const t = @as(u16, buf[p]) | (@as(u16, buf[p + 1]) << 8);
        if (t == tag) {
            const typ = @as(u16, buf[p + 2]) | (@as(u16, buf[p + 3]) << 8);
            const count = readU32(buf, p + 4);
            const value = readU32(buf, p + 8);
            return .{ .typ = typ, .count = count, .value = value };
        }
        p += 12;
    }
    return null;
}
fn readU32(buf: []const u8, o: usize) u32 {
    return @as(u32, buf[o]) | (@as(u32, buf[o + 1]) << 8) | (@as(u32, buf[o + 2]) << 16) | (@as(u32, buf[o + 3]) << 24);
}

test "header: II, magic 42, IFD at 8" {
    var buf: [4096]u8 = undefined;
    const px = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2 }; // 2×2 RGB
    _ = writeTiff(&buf, 2, 2, &px, &.{}).?;
    try testing.expectEqual(@as(u8, 'I'), buf[0]);
    try testing.expectEqual(@as(u8, 'I'), buf[1]);
    try testing.expectEqual(@as(u16, 42), @as(u16, buf[2]) | (@as(u16, buf[3]) << 8));
    try testing.expectEqual(@as(u32, 8), readU32(&buf, 4));
}

test "tags: float RGB descriptors are correct" {
    var buf: [4096]u8 = undefined;
    const px = [_]f32{0} ** 12;
    _ = writeTiff(&buf, 2, 2, &px, &.{}).?;
    try testing.expectEqual(@as(u32, 2), findEntry(&buf, 262).?.value); // Photometric = RGB
    try testing.expectEqual(@as(u32, 3), findEntry(&buf, 277).?.value); // SamplesPerPixel
    try testing.expectEqual(@as(u32, 1), findEntry(&buf, 259).?.value); // Compression = none
    // SampleFormat[3] all == 3 (IEEE float)
    const sf = findEntry(&buf, 339).?;
    try testing.expectEqual(@as(u32, 3), sf.count);
    inline for (0..3) |k| try testing.expectEqual(@as(u16, 3), @as(u16, buf[sf.value + k * 2]) | (@as(u16, buf[sf.value + k * 2 + 1]) << 8));
    // BitsPerSample[3] all == 32
    const bps = findEntry(&buf, 258).?;
    inline for (0..3) |k| try testing.expectEqual(@as(u16, 32), @as(u16, buf[bps.value + k * 2]) | (@as(u16, buf[bps.value + k * 2 + 1]) << 8));
}

test "round-trip: pixels read back from StripOffsets bit-exact" {
    var buf: [4096]u8 = undefined;
    const px = [_]f32{ 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.25, 2.5, 100.0 };
    _ = writeTiff(&buf, 2, 2, &px, &.{}).?;
    const strip = findEntry(&buf, 273).?.value;
    const got = std.mem.bytesAsSlice(f32, buf[strip..][0 .. 12 * 4]);
    for (0..12) |i| try testing.expectEqual(px[i], got[i]);
}

test "ICC profile embeds verbatim with correct tag/count" {
    var buf: [4096]u8 = undefined;
    const px = [_]f32{0} ** 12;
    const icc = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03 };
    _ = writeTiff(&buf, 2, 2, &px, &icc).?;
    const ent = findEntry(&buf, 34675).?;
    try testing.expectEqual(@as(u16, TYPE_UNDEFINED), ent.typ);
    try testing.expectEqual(@as(u32, icc.len), ent.count);
    for (0..icc.len) |i| try testing.expectEqual(icc[i], buf[ent.value + i]);
}

test "tiffSize equals bytes written; too-small buffer → null" {
    const px = [_]f32{0} ** 12;
    var buf: [4096]u8 = undefined;
    const n = writeTiff(&buf, 2, 2, &px, &.{}).?;
    try testing.expectEqual(tiffSize(2, 2, 0), n);
    var tiny: [16]u8 = undefined;
    try testing.expect(writeTiff(&tiny, 2, 2, &px, &.{}) == null);
}
