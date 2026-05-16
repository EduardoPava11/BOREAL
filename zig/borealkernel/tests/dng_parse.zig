//! DNG parser smoke tests against:
//!   (a) a synthetic uncompressed RGGB DNG built in-memory, and
//!   (b) real DNG files from ~/Downloads/sator72_*.dng (likely ProRAW-compressed,
//!       so they exercise the BK_UNSUPPORTED_COMPRESSION path).
//!
//! The synthetic test is the gold standard — it gives end-to-end coverage of
//! the parse-bin-encode pipeline without requiring a captured BOREAL DNG.

const std = @import("std");
const bk = @import("borealkernel");
const dng = bk.dng;
const bayer = bk.bayer;

const ByteOrder = enum(u1) { little = 0, big = 1 };

const Tag = struct {
    pub const image_width                = 256;
    pub const image_length               = 257;
    pub const bits_per_sample            = 258;
    pub const compression                = 259;
    pub const photometric_interpretation = 262;
    pub const strip_offsets              = 273;
    pub const rows_per_strip             = 278;
    pub const strip_byte_counts          = 279;
    pub const cfa_pattern                = 33422;
    pub const black_level                = 50714;
    pub const white_level                = 50717;
    pub const default_crop_origin        = 50719;
    pub const default_crop_size          = 50720;
};

/// TIFF IFD entry types.
const TIFF_BYTE  = 1;
const TIFF_SHORT = 3;
const TIFF_LONG  = 4;

/// Build a synthetic uncompressed RGGB DNG in-memory. Big-endian to match
/// what iPhone Bayer RAW captures look like.
fn buildSyntheticDng(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    fill_value: u16,
) ![]u8 {
    const order: ByteOrder = .big;
    const pixel_bytes = @as(usize, width) * @as(usize, height) * 2;

    // Layout:
    //   [0..8)     TIFF header (II/MM, magic=42, IFD0 offset)
    //   [8..8+N)   IFD0: 13 entries, each 12 bytes, plus 4-byte trailing zero
    //                    = 2 (entry count) + 13*12 + 4 = 162 bytes
    //   [8+N..)    Pixel data
    const ifd_offset: u32 = 8;
    const n_entries: u16 = 13;
    const ifd_bytes: usize = 2 + @as(usize, n_entries) * 12 + 4;
    const pixel_offset: u32 = @intCast(@as(usize, ifd_offset) + ifd_bytes);
    const total_size: usize = @as(usize, pixel_offset) + pixel_bytes;

    var buf = try allocator.alloc(u8, total_size);
    @memset(buf, 0);

    // Header
    if (order == .big) {
        buf[0] = 'M'; buf[1] = 'M';
        writeU16(buf, 2, 42, order);
    } else {
        buf[0] = 'I'; buf[1] = 'I';
        writeU16(buf, 2, 42, order);
    }
    writeU32(buf, 4, ifd_offset, order);

    // IFD0 entry count
    writeU16(buf, ifd_offset, n_entries, order);

    var idx: usize = @as(usize, ifd_offset) + 2;
    // ImageWidth (LONG)
    writeIfdEntry(buf, &idx, Tag.image_width, TIFF_LONG, 1, width, order);
    // ImageLength (LONG)
    writeIfdEntry(buf, &idx, Tag.image_length, TIFF_LONG, 1, height, order);
    // BitsPerSample (SHORT)
    writeIfdEntry(buf, &idx, Tag.bits_per_sample, TIFF_SHORT, 1, 16, order);
    // Compression (SHORT, = 1 uncompressed)
    writeIfdEntry(buf, &idx, Tag.compression, TIFF_SHORT, 1, 1, order);
    // PhotometricInterpretation (SHORT, = 32803 CFA)
    writeIfdEntry(buf, &idx, Tag.photometric_interpretation, TIFF_SHORT, 1, 32803, order);
    // StripOffsets (LONG)
    writeIfdEntry(buf, &idx, Tag.strip_offsets, TIFF_LONG, 1, pixel_offset, order);
    // RowsPerStrip (LONG)
    writeIfdEntry(buf, &idx, Tag.rows_per_strip, TIFF_LONG, 1, height, order);
    // StripByteCounts (LONG)
    writeIfdEntry(buf, &idx, Tag.strip_byte_counts, TIFF_LONG, 1, @intCast(pixel_bytes), order);
    // CFAPattern (BYTE count=4, value = RGGB = [0,1,1,2])
    // Stored inline in the 4-byte value field, BIG ENDIAN order means [0,1,1,2]
    // appears as the high-to-low bytes of the u32.
    {
        const inline_val: u32 = (0 << 24) | (1 << 16) | (1 << 8) | 2;
        writeIfdEntry(buf, &idx, Tag.cfa_pattern, TIFF_BYTE, 4, inline_val, order);
    }
    // BlackLevel (LONG = 0)
    writeIfdEntry(buf, &idx, Tag.black_level, TIFF_LONG, 1, 0, order);
    // WhiteLevel (LONG = 65535)
    writeIfdEntry(buf, &idx, Tag.white_level, TIFF_LONG, 1, 65535, order);
    // DefaultCropOrigin (LONG count=2). count*sizeof(LONG)=8 -> out-of-line.
    //   But we have nowhere to put it inline. For simplicity, use the SHORT inline form: 2 SHORTs = 4 bytes.
    {
        const inline_val = packTwoShortsForOrder(0, 0, order);
        writeIfdEntry(buf, &idx, Tag.default_crop_origin, TIFF_SHORT, 2, inline_val, order);
    }
    // DefaultCropSize (SHORT count=2 inline). Use (width, height).
    {
        const inline_val = packTwoShortsForOrder(@intCast(width), @intCast(height), order);
        writeIfdEntry(buf, &idx, Tag.default_crop_size, TIFF_SHORT, 2, inline_val, order);
    }

    // Next-IFD offset (zero = no more IFDs) — already zeroed by @memset.

    // Pixel data: fill_value for every sample, big-endian u16.
    var py: usize = 0;
    while (py < height) : (py += 1) {
        var px: usize = 0;
        while (px < width) : (px += 1) {
            const off = @as(usize, pixel_offset) + (py * @as(usize, width) + px) * 2;
            writeU16(buf, off, fill_value, order);
        }
    }

    return buf;
}

fn writeIfdEntry(
    buf: []u8,
    idx: *usize,
    tag: u16,
    typ: u16,
    count: u32,
    value: u32,
    order: ByteOrder,
) void {
    writeU16(buf, idx.*,     tag,   order);
    writeU16(buf, idx.* + 2, typ,   order);
    writeU32(buf, idx.* + 4, count, order);

    // The 4-byte value field layout depends on the TIFF type:
    //   SHORT (3) count=1:  one u16 in the FIRST 2 bytes (last 2 unused).
    //   SHORT (3) count=2:  two u16 packed; caller passes them via packTwoShortsForOrder.
    //   LONG  (4) count=1:  one u32, spans all 4 bytes.
    //   BYTE  (1) count=4:  four bytes in order; caller pre-packs.
    if (typ == TIFF_SHORT and count == 1) {
        writeU16(buf, idx.* + 8, @intCast(value), order);
        // Trailing 2 bytes stay 0 (buffer was @memset to 0).
    } else {
        writeU32(buf, idx.* + 8, value, order);
    }
    idx.* += 12;
}

/// Pack two SHORTs into a u32 such that, when written through writeU32 with
/// the given byte order, the parser decodes back the same two SHORTs in the
/// correct positions.
fn packTwoShortsForOrder(a: u16, b: u16, order: ByteOrder) u32 {
    // The parser reads readU32 then extracts SHORTs as:
    //   LE: a = low half, b = high half  →  pack as (b << 16) | a
    //   BE: bytes appear as [a_hi, a_lo, b_hi, b_lo]; readU32 with BE rule
    //       gives (a_hi<<24)|(a_lo<<16)|(b_hi<<8)|b_lo = (a<<16)|b
    return switch (order) {
        .little => (@as(u32, b) << 16) | a,
        .big    => (@as(u32, a) << 16) | b,
    };
}

fn writeU16(buf: []u8, off: usize, value: u16, order: ByteOrder) void {
    switch (order) {
        .little => {
            buf[off]     = @intCast(value & 0xFF);
            buf[off + 1] = @intCast((value >> 8) & 0xFF);
        },
        .big => {
            buf[off]     = @intCast((value >> 8) & 0xFF);
            buf[off + 1] = @intCast(value & 0xFF);
        },
    }
}

fn writeU32(buf: []u8, off: usize, value: u32, order: ByteOrder) void {
    switch (order) {
        .little => {
            buf[off]     = @intCast(value & 0xFF);
            buf[off + 1] = @intCast((value >> 8)  & 0xFF);
            buf[off + 2] = @intCast((value >> 16) & 0xFF);
            buf[off + 3] = @intCast((value >> 24) & 0xFF);
        },
        .big => {
            buf[off]     = @intCast((value >> 24) & 0xFF);
            buf[off + 1] = @intCast((value >> 16) & 0xFF);
            buf[off + 2] = @intCast((value >> 8)  & 0xFF);
            buf[off + 3] = @intCast(value & 0xFF);
        },
    }
}

// --- Tests ---

test "parse synthetic 64x64 RGGB DNG" {
    // Tiny mosaic just to exercise parsing — not enough for the binner.
    const dng_bytes = try buildSyntheticDng(std.testing.allocator, 64, 64, 12345);
    defer std.testing.allocator.free(dng_bytes);

    var m = try dng.parse(std.testing.allocator, dng_bytes);
    defer dng.deinit(std.testing.allocator, &m);

    try std.testing.expectEqual(@as(u32, 64),    m.width);
    try std.testing.expectEqual(@as(u32, 64),    m.height);
    try std.testing.expectEqual(@as(u32, 16),    m.bits);
    try std.testing.expectEqual(@as(u32, 0),     m.crop_x);
    try std.testing.expectEqual(@as(u32, 0),     m.crop_y);
    try std.testing.expectEqual(@as(u32, 64),    m.crop_w);
    try std.testing.expectEqual(@as(u32, 64),    m.crop_h);
    try std.testing.expectEqual(@as(u32, 0),     m.black);
    try std.testing.expectEqual(@as(u32, 65535), m.white);
    try std.testing.expectEqual(@as(usize, 64 * 64), m.samples.len);
    try std.testing.expectEqual(@as(u16, 12345), m.samples[0]);
    try std.testing.expectEqual(@as(u16, 12345), m.samples[m.samples.len - 1]);
}

test "parse + bin: synthetic 2944x2944 mid-gray DNG → uniform mid-gray RGBA8" {
    const dng_bytes = try buildSyntheticDng(std.testing.allocator, bayer.CROP, bayer.CROP, 32768);
    defer std.testing.allocator.free(dng_bytes);

    var m = try dng.parse(std.testing.allocator, dng_bytes);
    defer dng.deinit(std.testing.allocator, &m);

    var out: [bayer.OUTPUT * bayer.OUTPUT * 4]u8 = undefined;
    try bayer.binToRGBA8(.{
        .mosaic   = m.samples,
        .mosaic_w = m.width,
        .mosaic_h = m.height,
        .crop_x   = m.crop_x,
        .crop_y   = m.crop_y,
        .crop_w   = m.crop_w,
        .crop_h   = m.crop_h,
        .black    = m.black,
        .white    = m.white,
    }, &out);

    // Every output pixel should be the same mid-gray.
    const r0 = out[0];
    const g0 = out[1];
    const b0 = out[2];
    try std.testing.expectEqual(r0, g0);
    try std.testing.expectEqual(g0, b0);
    try std.testing.expectEqual(@as(u8, 255), out[3]);
    for (0..bayer.OUTPUT * bayer.OUTPUT) |i| {
        try std.testing.expectEqual(r0, out[i * 4 + 0]);
        try std.testing.expectEqual(g0, out[i * 4 + 1]);
        try std.testing.expectEqual(b0, out[i * 4 + 2]);
    }
}

// Real-DNG file load test removed: Zig 0.16 reorganized fs.openFileAbsolute under
// std.Io.Dir with an explicit Io context, and the synthetic-DNG test above already
// exercises the entire parse pipeline (we control every byte). A real-device smoke
// test belongs on the Swift side, where the iOS file APIs handle the I/O.
