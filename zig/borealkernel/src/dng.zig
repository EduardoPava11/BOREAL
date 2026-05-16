//! TIFF/DNG parser scoped to what BOREAL writes: uncompressed 16-bit RGGB Bayer.
//!
//! Apple's iPhone Bayer RAW DNGs are big-endian (`MM\0*`); the raw mosaic lives
//! in IFD0 (not a SubIFD, unlike Adobe-style DNGs). Compression is always 1 (none).
//! See ~/BOREAL/BOREAL/Processing/DNGCropTagEditor.swift for the Swift companion
//! that writes the crop tags this parser consumes.
//!
//! We only read the tags we need to extract a cropped u16 mosaic ready for binning.

const std = @import("std");
const ljpeg = @import("ljpeg.zig");

pub const Error = error{
    BadTiffMagic,
    UnsupportedByteOrder,
    UnsupportedCompression,         // generic fallback
    UnsupportedCompressionDeflate,  // 8
    UnsupportedCompressionLossyDNG, // 34892
    UnsupportedCompressionAppleVc8r,// 'vc8r' = 0x76633872 (Apple ProRAW / compressed Bayer)
    UnsupportedCfaPattern,
    UnsupportedBitDepth,
    MissingTag,
    BadDimensions,
    ShortRead,
    LJPEGDecodeFailed,              // upstream LJPEG decoder rejected the strip
    OutOfMemory,
};

/// CFA pattern — declares which channel sits at each 2×2 unit-cell position.
/// iPhone 17 Pro main wide camera ships BGGR; older iPhones / Apple ProRAW
/// ship RGGB. The cropper and binner consume `cfa` to interpret the mosaic.
pub const CfaPattern = enum {
    rggb,
    bggr,
};

/// Compression-tag dispatch. Returns the corresponding named error for known
/// compressed schemes so callers can log "we hit JPEG, not random unsupported".
/// `null` means "supported by parse() — uncompressed (1) or LJPEG SOF3 (7)."
pub fn compressionError(value: u32) ?Error {
    return switch (value) {
        1          => null,                                  // None — uncompressed mosaic
        7          => null,                                  // LJPEG SOF3 — handled by ljpeg.decode
        8          => Error.UnsupportedCompressionDeflate,
        34892      => Error.UnsupportedCompressionLossyDNG,
        0x76633872 => Error.UnsupportedCompressionAppleVc8r, // 'vc8r' four-CC
        else       => Error.UnsupportedCompression,
    };
}

pub const ByteOrder = enum { little, big };

pub const Mosaic = struct {
    width:      u32,         // full sensor width (4224 on iPhone 17 Pro)
    height:     u32,         // full sensor height (3024 on iPhone 17 Pro)
    bits:       u32,         // bits per sample (14 on iPhone)
    black:      u32,         // black-level value in raw counts
    white:      u32,         // white-level value in raw counts
    cfa:        CfaPattern,  // .bggr on iPhone 17 Pro main wide
    crop_x:     u32,         // DefaultCropOrigin x
    crop_y:     u32,         // DefaultCropOrigin y
    crop_w:     u32,         // DefaultCropSize w
    crop_h:     u32,         // DefaultCropSize h
    samples:    []const u16, // packed row-major, length = width * height
                             // (BORROWED — backed by `backing`)
    backing:    []u16,       // OWNED slice allocator-allocated; free with same alloc
};

/// TIFF tags we actually consume. Numeric values are from Adobe DNG Spec 1.4.0.0
/// and TIFF 6.0 spec. Two image-data layouts are supported:
///   - Strip layout: strip_offsets (273) + strip_byte_counts (279)
///     Used by iPhone uncompressed Bayer (Compression=1).
///   - Tile layout:  tile_width (322) + tile_length (323)
///                   + tile_offsets (324) + tile_byte_counts (325)
///     Used by iPhone LJPEG-compressed Bayer (Compression=7).
const Tag = struct {
    pub const image_width                = 256;
    pub const image_length               = 257;
    pub const bits_per_sample            = 258;
    pub const compression                = 259;
    pub const photometric_interpretation = 262;
    pub const strip_offsets              = 273;
    pub const rows_per_strip             = 278;
    pub const strip_byte_counts          = 279;
    pub const tile_width                 = 322;
    pub const tile_length                = 323;
    pub const tile_offsets               = 324;
    pub const tile_byte_counts           = 325;
    pub const cfa_pattern                = 33422;
    pub const black_level                = 50714;
    pub const white_level                = 50717;
    pub const default_crop_origin        = 50719;
    pub const default_crop_size          = 50720;
};

const CFA_PHOTOMETRIC = 32803;

/// Parse the DNG bytes and return the full-sensor Bayer mosaic plus crop metadata.
/// Caller owns `result.backing` and must free it with the same allocator.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Mosaic {
    if (bytes.len < 8) return Error.BadTiffMagic;

    const order: ByteOrder = blk: {
        if (bytes[0] == 'I' and bytes[1] == 'I') break :blk .little;
        if (bytes[0] == 'M' and bytes[1] == 'M') break :blk .big;
        return Error.BadTiffMagic;
    };

    const magic = readU16(bytes, 2, order);
    if (magic != 42) return Error.BadTiffMagic;

    const ifd0_off = readU32(bytes, 4, order);
    return parseIfd0(allocator, bytes, ifd0_off, order);
}

fn parseIfd0(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    ifd_off: u32,
    order: ByteOrder,
) Error!Mosaic {
    if (bytes.len < @as(usize, ifd_off) + 2) return Error.ShortRead;
    const entry_count = readU16(bytes, ifd_off, order);
    const entries_base: usize = @as(usize, ifd_off) + 2;
    if (bytes.len < entries_base + @as(usize, entry_count) * 12) return Error.ShortRead;

    // Required-to-find tags; default zeros mean "missing" and we error out at the end.
    var w: u32 = 0;
    var h: u32 = 0;
    var bits: u32 = 0;
    var compression: u32 = 0;
    var photometric: u32 = 0;
    var strip_offsets_val: u32 = 0;
    var rows_per_strip: u32 = 0;
    var strip_byte_counts_val: u32 = 0;
    var cfa_kind: ?CfaPattern = null;
    var black: u32 = 0;
    var white: u32 = 0;
    var crop_x: u32 = 0;
    var crop_y: u32 = 0;
    var crop_w: u32 = 0;
    var crop_h: u32 = 0;

    var strip_offsets_entry: ?Entry = null;
    var strip_byte_counts_entry: ?Entry = null;
    var tile_offsets_entry: ?Entry = null;
    var tile_byte_counts_entry: ?Entry = null;
    var tile_width: u32 = 0;
    var tile_length: u32 = 0;

    var i: u16 = 0;
    while (i < entry_count) : (i += 1) {
        const off = entries_base + @as(usize, i) * 12;
        const e = Entry{
            .tag       = readU16(bytes, off,     order),
            .type      = readU16(bytes, off + 2, order),
            .count     = readU32(bytes, off + 4, order),
            .value_off = readU32(bytes, off + 8, order),
        };
        switch (e.tag) {
            Tag.image_width                => w = e.inlineU32(order),
            Tag.image_length               => h = e.inlineU32(order),
            Tag.bits_per_sample            => bits = e.inlineU32(order),
            Tag.compression                => compression = e.inlineU32(order),
            Tag.photometric_interpretation => photometric = e.inlineU32(order),
            Tag.strip_offsets              => {
                strip_offsets_entry = e;
                if (e.count == 1) strip_offsets_val = e.inlineU32(order);
            },
            Tag.rows_per_strip             => rows_per_strip = e.inlineU32(order),
            Tag.strip_byte_counts          => {
                strip_byte_counts_entry = e;
                if (e.count == 1) strip_byte_counts_val = e.inlineU32(order);
            },
            Tag.tile_width                 => tile_width = e.inlineU32(order),
            Tag.tile_length                => tile_length = e.inlineU32(order),
            Tag.tile_offsets               => tile_offsets_entry = e,
            Tag.tile_byte_counts           => tile_byte_counts_entry = e,
            Tag.cfa_pattern => {
                // CFA pattern is 4 bytes inline for type=1 BYTE count=4: R=0 G=1 B=2.
                // Accept RGGB = [0,1,1,2] and BGGR = [2,1,1,0]. The 4 bytes sit in
                // value_off little-end-first since they're byte-packed (no endian
                // swap on individual bytes within the BYTE array).
                if (e.type == 1 and e.count == 4) {
                    const p0 = @as(u8, @truncate(e.value_off & 0xFF));
                    const p1 = @as(u8, @truncate((e.value_off >>  8) & 0xFF));
                    const p2 = @as(u8, @truncate((e.value_off >> 16) & 0xFF));
                    const p3 = @as(u8, @truncate((e.value_off >> 24) & 0xFF));
                    // Try both byte orders for big-endian DNGs (TIFF spec leaves
                    // BYTE-array layout ambiguous in BE files).
                    if (p0 == 0 and p1 == 1 and p2 == 1 and p3 == 2) cfa_kind = .rggb;
                    if (p3 == 0 and p2 == 1 and p1 == 1 and p0 == 2) cfa_kind = .rggb;
                    if (p0 == 2 and p1 == 1 and p2 == 1 and p3 == 0) cfa_kind = .bggr;
                    if (p3 == 2 and p2 == 1 and p1 == 1 and p0 == 0) cfa_kind = .bggr;
                }
            },
            Tag.black_level => black = try readUintAt(bytes, e, order),
            Tag.white_level => white = try readUintAt(bytes, e, order),
            Tag.default_crop_origin => {
                const vals = try readUintPair(bytes, e, order);
                crop_x = vals[0];
                crop_y = vals[1];
            },
            Tag.default_crop_size => {
                const vals = try readUintPair(bytes, e, order);
                crop_w = vals[0];
                crop_h = vals[1];
            },
            else => {},
        }
    }

    if (w == 0 or h == 0) return Error.BadDimensions;
    if (bits != 14 and bits != 16) return Error.UnsupportedBitDepth;
    if (compressionError(compression)) |comp_err| return comp_err;
    if (photometric != CFA_PHOTOMETRIC) return Error.UnsupportedCfaPattern;
    const cfa = cfa_kind orelse return Error.UnsupportedCfaPattern;
    if (crop_w == 0 or crop_h == 0) return Error.MissingTag;

    // Default sensible black/white if DNG omitted them.
    if (black == 0 and bits == 14) black = 528;     // iPhone 17 Pro typical
    if (white == 0) white = (@as(u32, 1) << @intCast(bits)) - 1;

    const pixel_count = @as(usize, w) * @as(usize, h);

    // Image-data layout dispatch. iPhone DNGs use one of two layouts:
    //   - Compression=1 (uncompressed Bayer): strip layout (StripOffsets/Counts)
    //   - Compression=7 (LJPEG-compressed Bayer): tile layout (TileOffsets/Counts)
    var pixels: []u16 = undefined;
    if (tile_offsets_entry != null and tile_byte_counts_entry != null) {
        // Tile layout. iPhone LJPEG DNGs typically have a single tile covering
        // the whole image, but we support N tiles laid out in row-major order.
        const to_entry = tile_offsets_entry.?;
        const tbc_entry = tile_byte_counts_entry.?;
        if (to_entry.count != tbc_entry.count) return Error.MissingTag;
        if (tile_width == 0) tile_width = w;     // single-tile fallback
        if (tile_length == 0) tile_length = h;
        if (compression != 7) return Error.UnsupportedCompression;

        const tiles_across = (w + tile_width - 1) / tile_width;
        const tiles_down = (h + tile_length - 1) / tile_length;
        const expected_tiles = tiles_across * tiles_down;
        if (to_entry.count != expected_tiles) return Error.BadDimensions;

        pixels = try allocator.alloc(u16, pixel_count);
        errdefer allocator.free(pixels);

        var ti: u32 = 0;
        while (ti < expected_tiles) : (ti += 1) {
            const tile_x = (ti % tiles_across) * tile_width;
            const tile_y = (ti / tiles_across) * tile_length;
            const off = try readArrayU32(bytes, to_entry, ti, order);
            const cnt = try readArrayU32(bytes, tbc_entry, ti, order);
            if (bytes.len < @as(usize, off) + @as(usize, cnt)) return Error.ShortRead;
            const tile_bytes = bytes[off..@as(usize, off) + @as(usize, cnt)];

            // Decode this tile's LJPEG payload.
            var dec = ljpeg.decode(allocator, tile_bytes) catch return Error.LJPEGDecodeFailed;
            defer dec.deinit(allocator);

            // Copy decoded tile samples into the right rectangle of `pixels`.
            // Handle the edge-tile case where the tile may overlap the image
            // boundary (the trailing part is padding to be discarded).
            const copy_w = @min(tile_width, w - tile_x);
            const copy_h = @min(tile_length, h - tile_y);
            var ry: u32 = 0;
            while (ry < copy_h) : (ry += 1) {
                const src_row = ry * dec.width;
                const dst_row = (tile_y + ry) * w + tile_x;
                @memcpy(
                    pixels[dst_row..][0..copy_w],
                    dec.samples[src_row..][0..copy_w],
                );
            }
        }
    } else if (strip_offsets_entry != null and strip_byte_counts_entry != null) {
        // Strip layout. Single-strip is the common case for uncompressed Bayer;
        // multi-strip falls back to the loop below.
        const so_entry = strip_offsets_entry.?;
        const sbc_entry = strip_byte_counts_entry.?;

        if (so_entry.count == 1 and sbc_entry.count == 1) {
            const data_off = so_entry.inlineU32(order);
            const data_len = sbc_entry.inlineU32(order);
            if (bytes.len < @as(usize, data_off) + @as(usize, data_len)) return Error.ShortRead;
            const strip = bytes[data_off..@as(usize, data_off) + @as(usize, data_len)];

            switch (compression) {
                1 => {
                    const single_strip_byte_count = pixel_count * 2;
                    if (data_len < single_strip_byte_count) return Error.ShortRead;
                    pixels = try allocator.alloc(u16, pixel_count);
                    errdefer allocator.free(pixels);
                    decodeMosaicU16(strip[0..single_strip_byte_count], pixels, order);
                },
                7 => {
                    var dec = ljpeg.decode(allocator, strip) catch return Error.LJPEGDecodeFailed;
                    if (dec.width != w or dec.height != h) {
                        dec.deinit(allocator);
                        return Error.BadDimensions;
                    }
                    pixels = dec.backing;
                },
                else => unreachable,
            }
        } else {
            // Multi-strip — only supported for uncompressed today.
            if (compression != 1) return Error.LJPEGDecodeFailed;
            const n_strips: usize = @intCast(so_entry.count);
            if (sbc_entry.count != so_entry.count) return Error.MissingTag;
            if (rows_per_strip == 0) return Error.MissingTag;

            pixels = try allocator.alloc(u16, pixel_count);
            errdefer allocator.free(pixels);

            var dst_idx: usize = 0;
            var si: usize = 0;
            while (si < n_strips) : (si += 1) {
                const off = try readArrayU32(bytes, so_entry, si, order);
                const cnt = try readArrayU32(bytes, sbc_entry, si, order);
                if (bytes.len < @as(usize, off) + @as(usize, cnt)) return Error.ShortRead;
                const dst_words = @as(usize, cnt) / 2;
                if (dst_idx + dst_words > pixel_count) return Error.BadDimensions;
                decodeMosaicU16(bytes[off..][0..@as(usize, cnt)], pixels[dst_idx..][0..dst_words], order);
                dst_idx += dst_words;
            }
            if (dst_idx != pixel_count) return Error.BadDimensions;
        }
    } else {
        // Neither tile nor strip layout — DNG is malformed for our purposes.
        return Error.MissingTag;
    }

    return Mosaic{
        .width   = w,
        .height  = h,
        .bits    = bits,
        .black   = black,
        .white   = white,
        .cfa     = cfa,
        .crop_x  = crop_x,
        .crop_y  = crop_y,
        .crop_w  = crop_w,
        .crop_h  = crop_h,
        .samples = pixels,
        .backing = pixels,
    };
}

pub fn deinit(allocator: std.mem.Allocator, m: *Mosaic) void {
    allocator.free(m.backing);
    m.samples = &.{};
    m.backing = &.{};
}

// --- Internals ---

const Entry = struct {
    tag: u16,
    type: u16,
    count: u32,
    value_off: u32,

    fn typeSize(self: Entry) usize {
        return switch (self.type) {
            1, 2, 7 => 1,                  // BYTE, ASCII, UNDEFINED
            3       => 2,                  // SHORT
            4       => 4,                  // LONG
            5       => 8,                  // RATIONAL
            else    => 0,
        };
    }

    /// SHORT (count=1) lives in different halves of the 4-byte value field
    /// depending on byte order — mirrors Swift `valueAsInlineUInt32`.
    fn inlineU32(self: Entry, order: ByteOrder) u32 {
        if (self.type == 3 and self.count == 1) {
            return if (order == .little)
                self.value_off & 0xFFFF                // low half
            else
                self.value_off >> 16;                  // high half (we already byte-swapped on read)
        }
        return self.value_off;
    }
};

fn readUintAt(bytes: []const u8, e: Entry, order: ByteOrder) Error!u32 {
    // Read the first value of an array-of-uint tag. Used for BlackLevel / WhiteLevel
    // which may be SHORT or LONG, and may have count > 1 (per-CFA-position black).
    switch (e.type) {
        3 => {
            if (e.count == 1) return e.inlineU32(order);
            const base = e.value_off;
            if (bytes.len < @as(usize, base) + 2) return Error.ShortRead;
            return readU16(bytes, base, order);
        },
        4 => {
            if (e.count == 1) return e.inlineU32(order);
            const base = e.value_off;
            if (bytes.len < @as(usize, base) + 4) return Error.ShortRead;
            return readU32(bytes, base, order);
        },
        5 => {
            // RATIONAL = LONG numerator / LONG denominator, always out-of-line.
            const base = e.value_off;
            if (bytes.len < @as(usize, base) + 8) return Error.ShortRead;
            const num = readU32(bytes, base, order);
            const den = readU32(bytes, base + 4, order);
            if (den == 0) return 0;
            return num / den;
        },
        else => return Error.MissingTag,
    }
}

/// Read a count-2 uint tag (e.g., DefaultCropOrigin = [x, y]).
fn readUintPair(bytes: []const u8, e: Entry, order: ByteOrder) Error![2]u32 {
    if (e.count != 2) return Error.MissingTag;
    switch (e.type) {
        3 => {
            // Two SHORTs fit inline in 4 bytes.
            const a = if (order == .little) e.value_off & 0xFFFF else e.value_off >> 16;
            const b = if (order == .little) e.value_off >> 16 else e.value_off & 0xFFFF;
            return .{ a, b };
        },
        4 => {
            const base = e.value_off;
            if (bytes.len < @as(usize, base) + 8) return Error.ShortRead;
            return .{
                readU32(bytes, base,     order),
                readU32(bytes, base + 4, order),
            };
        },
        5 => {
            const base = e.value_off;
            if (bytes.len < @as(usize, base) + 16) return Error.ShortRead;
            const n0 = readU32(bytes, base, order);
            const d0 = readU32(bytes, base + 4, order);
            const n1 = readU32(bytes, base + 8, order);
            const d1 = readU32(bytes, base + 12, order);
            return .{
                if (d0 == 0) 0 else n0 / d0,
                if (d1 == 0) 0 else n1 / d1,
            };
        },
        else => return Error.MissingTag,
    }
}

fn readArrayU32(bytes: []const u8, e: Entry, idx: usize, order: ByteOrder) Error!u32 {
    const elem_size = e.typeSize();
    const base = e.value_off;
    const at = @as(usize, base) + idx * elem_size;
    return switch (e.type) {
        3 => blk: {
            if (bytes.len < at + 2) return Error.ShortRead;
            break :blk @as(u32, readU16(bytes, @intCast(at), order));
        },
        4 => blk: {
            if (bytes.len < at + 4) return Error.ShortRead;
            break :blk readU32(bytes, @intCast(at), order);
        },
        else => Error.MissingTag,
    };
}

fn readU16(bytes: []const u8, offset: usize, order: ByteOrder) u16 {
    const lo = @as(u16, bytes[offset]);
    const hi = @as(u16, bytes[offset + 1]);
    return switch (order) {
        .little => (hi << 8) | lo,
        .big    => (lo << 8) | hi,
    };
}

fn readU32(bytes: []const u8, offset: usize, order: ByteOrder) u32 {
    const b0 = @as(u32, bytes[offset]);
    const b1 = @as(u32, bytes[offset + 1]);
    const b2 = @as(u32, bytes[offset + 2]);
    const b3 = @as(u32, bytes[offset + 3]);
    return switch (order) {
        .little => (b3 << 24) | (b2 << 16) | (b1 << 8) | b0,
        .big    => (b0 << 24) | (b1 << 16) | (b2 << 8) | b3,
    };
}

fn decodeMosaicU16(src: []const u8, dst: []u16, order: ByteOrder) void {
    // Pixels are packed as 2 bytes per sample. The TIFF spec gives BPS=14 with
    // values left-justified in 16-bit containers — or right-justified depending
    // on writer. iPhone writes left-justified, but the downstream black/white
    // levels we read from the DNG describe the actual values, so we don't need
    // to shift here.
    var i: usize = 0;
    while (i < dst.len) : (i += 1) {
        dst[i] = readU16(src, i * 2, order);
    }
}

// --- Small unit tests on synthetic TIFF headers ---

test "tiff magic: little-endian recognised" {
    var buf: [16]u8 = .{ 'I', 'I', 42, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const m = parse(std.testing.allocator, &buf);
    // Empty IFD with 0 entries: parseIfd0 will try to read tags and find none.
    // We expect BadDimensions because w/h never got set.
    try std.testing.expectError(Error.BadDimensions, m);
}

test "tiff magic: big-endian recognised" {
    var buf: [16]u8 = .{ 'M', 'M', 0, 42, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0 };
    const m = parse(std.testing.allocator, &buf);
    try std.testing.expectError(Error.BadDimensions, m);
}

test "tiff magic: bogus magic rejected" {
    var buf: [8]u8 = .{ 'X', 'X', 0, 42, 0, 0, 0, 8 };
    try std.testing.expectError(Error.BadTiffMagic, parse(std.testing.allocator, &buf));
}

test "byte order: u16/u32 read consistency" {
    const le: [4]u8 = .{ 0x34, 0x12, 0x78, 0x56 };
    try std.testing.expectEqual(@as(u16, 0x1234), readU16(&le, 0, .little));
    try std.testing.expectEqual(@as(u32, 0x56781234), readU32(&le, 0, .little));

    const be: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };
    try std.testing.expectEqual(@as(u16, 0x1234), readU16(&be, 0, .big));
    try std.testing.expectEqual(@as(u32, 0x12345678), readU32(&be, 0, .big));
}
