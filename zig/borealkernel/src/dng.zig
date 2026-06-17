//! TIFF/DNG parser for NAKED Bayer RAW (the raw CFA sensor mosaic) — 14/16-bit,
//! RGGB or BGGR, with the raw mosaic in IFD0 (not a SubIFD, unlike Adobe DNGs).
//! Accepts Compression=1 (uncompressed strips) AND Compression=7 (LJPEG SOF3
//! tiles, as iPhone Bayer RAW ships); rejects Apple-processed ProRAW variants
//! (Linear/demosaiced, 'vc8r' compressed Bayer, lossy DNG, deflate).
//!
//! Apple's iPhone Bayer RAW DNGs are big-endian (`MM\0*`). We read only the tags
//! needed to extract the cropped u16 mosaic + colour/exposure metadata.

const std = @import("std");
const ljpeg = @import("ljpeg.zig");
const color = @import("color.zig");

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
    LJPEGDecodeFailed,              // upstream LJPEG decoder rejected (generic fallback)
    // Per-variant LJPEG decoder errors. Mapped 1:1 from ljpeg.Error so the
    // C ABI status code (and downstream Swift breadcrumb) names exactly which
    // LJPEG decoder check failed on a real iPhone DNG tile. Without these,
    // every LJPEG failure collapses into LJPEGDecodeFailed=17, which wastes
    // a round trip when diagnosing.
    LJPEGBadMagic,
    LJPEGUnexpectedEnd,
    LJPEGUnsupportedMarker,
    LJPEGUnsupportedComponentCount,
    LJPEGUnsupportedPrecision,
    LJPEGUnsupportedPredictor,
    LJPEGHasRestartMarkers,
    LJPEGMalformedHuffmanTable,
    LJPEGInvalidHuffmanCode,
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
    // White-balance multipliers from AsShotNeutral, normalized so green = 1
    // (wb_c = asn_green / asn_c). Feeds the ETTR planner's WB prior. Defaults
    // to 1,1,1 (neutral) when AsShotNeutral is absent/unreadable — safe, since
    // live scene analysis overrides the prior anyway.
    wb_r:       f32,
    wb_g:       f32,
    wb_b:       f32,
    // Per-frame EXIF exposure metadata (from the EXIF SubIFD, tag 34665). Used by
    // fuse.relativeExposures to align EV-bracketed frames. 0 = absent sentinel.
    exposure_time: f32,     // ExposureTime (33434), seconds; 0 = absent
    iso:           f32,     // ISO (34855); 0 = absent
    fnumber:       f32,     // FNumber (33437); 0 = absent/canceling
    // Row-major 3×3 mapping camera-native linear RGB → ProPhoto linear RGB
    // (WB · ForwardMatrix · XYZ→ProPhoto, composed in color.zig). Identity and
    // has_color=false when no usable colour matrix is present → caller leaves the
    // image camera-native and embeds no ICC (honest, not mis-tagged).
    cam_to_pp:  [9]f32,
    has_color:  bool,
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
    pub const as_shot_neutral            = 50728;  // RATIONAL[3] — capture white balance
    pub const exif_ifd_pointer           = 34665;  // LONG → EXIF SubIFD offset
    pub const exposure_time              = 33434;  // RATIONAL seconds
    pub const fnumber                    = 33437;  // RATIONAL
    pub const iso                        = 34855;  // SHORT/LONG ISOSpeedRatings
    pub const color_matrix_1             = 50721;  // SRATIONAL[9] — XYZ(D65)→camera
    pub const forward_matrix_1           = 50964;  // SRATIONAL[9] — camera→XYZ(D50)
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
    var wb_r: f32 = 1.0;
    const wb_g: f32 = 1.0; // green is the reference; never reassigned
    var wb_b: f32 = 1.0;
    var exif_ifd_off: u32 = 0; // EXIF SubIFD offset (tag 34665), parsed after IFD0
    var forward_matrix: ?[9]f32 = null; // camera→XYZ(D50), preferred
    var color_matrix: ?[9]f32 = null;   // XYZ(D65)→camera, inverse used as fallback

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
            Tag.as_shot_neutral => {
                // RATIONAL[3] camera-neutral. WB multiplier = green/channel so a
                // channel that is darker in raw (smaller neutral coord) gets a
                // larger multiplier. Unreadable → leave neutral (1,1,1).
                if (readRational3(bytes, e, order)) |asn| {
                    const g = if (asn[1] > 1.0e-6) asn[1] else 1.0;
                    if (asn[0] > 1.0e-6) wb_r = g / asn[0];
                    if (asn[2] > 1.0e-6) wb_b = g / asn[2];
                    // wb_g stays 1 (green is the reference)
                } else |_| {}
            },
            // The SubIFD pointer can appear in any entry order, so just record the
            // offset here and parse the SubIFD after the IFD0 loop closes.
            Tag.exif_ifd_pointer => exif_ifd_off = e.inlineU32(order),
            // Colour matrices (SRATIONAL[9]). ForwardMatrix is preferred (it maps
            // camera→XYZ at D50 directly); ColorMatrix is the inverse-fallback.
            // Unreadable → leave null → camera-native passthrough downstream.
            Tag.forward_matrix_1 => forward_matrix = readSRational9(bytes, e, order) catch null,
            Tag.color_matrix_1   => color_matrix = readSRational9(bytes, e, order) catch null,
            else => {},
        }
    }

    // ── EXIF SubIFD pass (additive; never errors — leaves 0 sentinels) ──
    var exposure_time: f32 = 0;
    var iso: f32 = 0;
    var fnumber: f32 = 0;
    if (exif_ifd_off != 0 and bytes.len >= @as(usize, exif_ifd_off) + 2) {
        const ec = readU16(bytes, exif_ifd_off, order);
        const eb: usize = @as(usize, exif_ifd_off) + 2;
        if (bytes.len >= eb + @as(usize, ec) * 12) {
            var j: u16 = 0;
            while (j < ec) : (j += 1) {
                const eoff = eb + @as(usize, j) * 12;
                const ee = Entry{
                    .tag       = readU16(bytes, eoff,     order),
                    .type      = readU16(bytes, eoff + 2, order),
                    .count     = readU32(bytes, eoff + 4, order),
                    .value_off = readU32(bytes, eoff + 8, order),
                };
                switch (ee.tag) {
                    Tag.exposure_time => exposure_time = readRational1(bytes, ee, order),
                    Tag.fnumber       => fnumber = readRational1(bytes, ee, order),
                    // ISOSpeedRatings is SHORT/LONG and MAY have count>1 (the
                    // array is then stored out-of-line). readUintAt reads the
                    // first element in- or out-of-line with bounds + type guard;
                    // plain inlineU32 would return value_off (a FILE OFFSET) for
                    // count>1, decoding a bogus ISO. Unreadable → 0 absent sentinel.
                    Tag.iso           => iso = @floatFromInt(readUintAt(bytes, ee, order) catch 0),
                    else => {},
                }
            }
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

    // Compose the camera-native → ProPhoto-linear matrix. Prefer ForwardMatrix
    // (camera→XYZ D50); else invert ColorMatrix (XYZ→camera) as a fallback; else
    // leave camera-native (has_color=false → caller embeds no ICC, no mis-tag).
    const wb3 = [3]f32{ wb_r, wb_g, wb_b };
    var cam_to_pp = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
    var has_color = false;
    if (forward_matrix) |fm| {
        cam_to_pp = color.cameraToProPhoto(fm, wb3);
        has_color = true;
    } else if (color_matrix) |cm| {
        if (color.invert3(cm)) |cam_to_xyz| {
            cam_to_pp = color.cameraToProPhoto(cam_to_xyz, wb3);
            has_color = true;
        }
    }

    const pixel_count = @as(usize, w) * @as(usize, h);

    // ── Image-data layout dispatch (verified on iPhone 17 Pro 2026-05-16) ──
    //
    // iPhone DNGs use ONE layout in practice: tiles + Compression=7 (LJPEG).
    // The strip path is preserved for synthetic test fixtures (Compression=1
    // uncompressed Bayer) and for other DNG sources (Adobe, libraw). On
    // device the strip-related tags (StripOffsets=273, StripByteCounts=279,
    // RowsPerStrip=278) are ABSENT — only tile tags 322-325 are populated.
    //
    // iPhone 17 Pro at 12 MP binned Bayer:
    //   TileWidth  = 264   (= LJPEG raster width × Nf = 132 × 2)
    //   TileLength = 378
    //   Tile count = (4224/264) × (3024/378) = 16 × 8 = 128
    //
    // Each tile is an independent LJPEG SOF3 bitstream (SOI...EOI), which
    // means tiles are embarrassingly parallel — a future perf pass can
    // decode the 128 tiles concurrently via a thread pool. Currently the
    // loop below decodes serially; on iPhone 17 Pro this completes in
    // ~250 ms per frame, ~1.0 s for a 4-frame burst.
    var pixels: []u16 = undefined;
    if (tile_offsets_entry != null and tile_byte_counts_entry != null) {
        // Tile layout. We support N tiles laid out in row-major order.
        // Edge tiles may extend beyond the image bounds (the trailing rows
        // and columns are padding to be discarded by the copy loop below).
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
            var dec = ljpeg.decode(allocator, tile_bytes) catch |err| return mapLJPEGError(err);
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
                    var dec = ljpeg.decode(allocator, strip) catch |err| return mapLJPEGError(err);
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
        .wb_r    = wb_r,
        .wb_g    = wb_g,
        .wb_b    = wb_b,
        .exposure_time = exposure_time,
        .iso     = iso,
        .fnumber = fnumber,
        .cam_to_pp = cam_to_pp,
        .has_color = has_color,
        .samples = pixels,
        .backing = pixels,
    };
}

pub fn deinit(allocator: std.mem.Allocator, m: *Mosaic) void {
    allocator.free(m.backing);
    m.samples = &.{};
    m.backing = &.{};
}

/// Map an `ljpeg.Error` to the corresponding per-variant `dng.Error` so the
/// C ABI status code names which LJPEG decoder check failed. Without this
/// mapping, every LJPEG failure collapses to `LJPEGDecodeFailed=17` and
/// requires source spelunking to diagnose.
fn mapLJPEGError(err: ljpeg.Error) Error {
    return switch (err) {
        ljpeg.Error.BadMagic                  => Error.LJPEGBadMagic,
        ljpeg.Error.UnexpectedEnd             => Error.LJPEGUnexpectedEnd,
        ljpeg.Error.UnsupportedMarker         => Error.LJPEGUnsupportedMarker,
        ljpeg.Error.UnsupportedComponentCount => Error.LJPEGUnsupportedComponentCount,
        ljpeg.Error.UnsupportedPrecision      => Error.LJPEGUnsupportedPrecision,
        ljpeg.Error.UnsupportedPredictor      => Error.LJPEGUnsupportedPredictor,
        ljpeg.Error.HasRestartMarkers         => Error.LJPEGHasRestartMarkers,
        ljpeg.Error.MalformedHuffmanTable     => Error.LJPEGMalformedHuffmanTable,
        ljpeg.Error.InvalidHuffmanCode        => Error.LJPEGInvalidHuffmanCode,
        ljpeg.Error.OutOfMemory               => Error.OutOfMemory,
    };
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

/// Read a single RATIONAL value as f32. RATIONAL is always out-of-line (8 bytes).
/// Returns 0 (sentinel, NOT error/optional) on any unreadable condition so the
/// EXIF pass stays fully graceful. MUST be used for ExposureTime/FNumber instead
/// of readUintAt, which integer-divides (flooring e.g. 1/250 → 0).
fn readRational1(bytes: []const u8, e: Entry, order: ByteOrder) f32 {
    if (e.type != 5 or e.count < 1) return 0;
    const base = e.value_off; // RATIONAL always out-of-line
    if (bytes.len < @as(usize, base) + 8) return 0;
    const num = readU32(bytes, base, order);
    const den = readU32(bytes, base + 4, order);
    if (den == 0) return 0;
    return @as(f32, @floatFromInt(num)) / @as(f32, @floatFromInt(den));
}

/// Read a count-3 RATIONAL tag (e.g., AsShotNeutral) as three f32 ratios.
/// Always out-of-line (3 rationals = 24 bytes).
fn readRational3(bytes: []const u8, e: Entry, order: ByteOrder) Error![3]f32 {
    if (e.count != 3 or e.type != 5) return Error.MissingTag;
    const base = e.value_off;
    if (bytes.len < @as(usize, base) + 24) return Error.ShortRead;
    var out: [3]f32 = undefined;
    inline for (0..3) |k| {
        const num = readU32(bytes, base + k * 8, order);
        const den = readU32(bytes, base + k * 8 + 4, order);
        out[k] = if (den == 0) 0 else @as(f32, @floatFromInt(num)) / @as(f32, @floatFromInt(den));
    }
    return out;
}

/// Read a count-9 SRATIONAL tag (ColorMatrix1 / ForwardMatrix1) as a row-major
/// [9]f32. SRATIONAL = signed LONG num / signed LONG den; 9 of them = 72 bytes,
/// always out-of-line. Returns an error (caught to null by the caller) on any
/// unreadable condition so a malformed matrix degrades to camera-native.
fn readSRational9(bytes: []const u8, e: Entry, order: ByteOrder) Error![9]f32 {
    if (e.count != 9 or e.type != 10) return Error.MissingTag;
    const base = e.value_off;
    if (bytes.len < @as(usize, base) + 72) return Error.ShortRead;
    var out: [9]f32 = undefined;
    inline for (0..9) |k| {
        const num: i32 = @bitCast(readU32(bytes, base + k * 8, order));
        const den: i32 = @bitCast(readU32(bytes, base + k * 8 + 4, order));
        out[k] = if (den == 0) 0 else @as(f32, @floatFromInt(num)) / @as(f32, @floatFromInt(den));
    }
    return out;
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

// Real iPhone 17 Pro DNG end-to-end decode test. The fixture is the user's
// device capture, airdropped to ~/Downloads. Test skips (not fails) if the
// file isn't present so the suite still works in fresh checkouts. When the
// fixture IS present, this is the keystone integration test: parse → tile
// loop → ljpeg.decode (Nf=2, P=12, Pt=1) → output 4224×3024 BGGR mosaic.
// Real iPhone DNG verification happens via a standalone Zig program
// (zig/borealkernel/tests/real_dng_check.zig) since Zig 0.16's file API
// moved to std.Io.Dir which requires an Io instance — too noisy for a
// unit-test setup. Run via `zig run tests/real_dng_check.zig` if needed.

test "AsShotNeutral → WB prior (asn 0.5,1,0.667 ⇒ wb 2.0,1,1.5)" {
    const testing = std.testing;
    var buf = [_]u8{0} ** 40;
    const put = struct {
        fn u32le(b: []u8, o: usize, v: u32) void {
            b[o + 0] = @truncate(v);
            b[o + 1] = @truncate(v >> 8);
            b[o + 2] = @truncate(v >> 16);
            b[o + 3] = @truncate(v >> 24);
        }
    }.u32le;
    // 3 rationals at offset 8: 1/2, 1/1, 2/3
    put(&buf, 8, 1);  put(&buf, 12, 2);
    put(&buf, 16, 1); put(&buf, 20, 1);
    put(&buf, 24, 2); put(&buf, 28, 3);
    const e = Entry{ .tag = Tag.as_shot_neutral, .type = 5, .count = 3, .value_off = 8 };
    const asn = try readRational3(&buf, e, .little);
    try testing.expectApproxEqAbs(@as(f32, 0.5), asn[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 1.0), asn[1], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.6667), asn[2], 1e-3);
    // WB prior derivation (as parseIfd0 does): wb_c = green / asn_c
    try testing.expectApproxEqAbs(@as(f32, 2.0), asn[1] / asn[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.5), asn[1] / asn[2], 1e-3);
}

test "EXIF ISO: SHORT count>1 reads first array element, not the offset" {
    // The bug fix: ISOSpeedRatings (34855) with count>1 is an out-of-line SHORT
    // array; value_off is a FILE OFFSET. inlineU32 would return 8 (the offset);
    // readUintAt must read the first element (200) from offset 8.
    var buf = [_]u8{0} ** 16;
    buf[8] = 200; // LE SHORT 200 at offset 8
    buf[9] = 0;
    buf[10] = 0x90; // second element 400 (proves we take element 0, not 1)
    buf[11] = 0x01;
    const e = Entry{ .tag = Tag.iso, .type = 3, .count = 2, .value_off = 8 };
    try std.testing.expectEqual(@as(u32, 200), try readUintAt(&buf, e, .little));
    try std.testing.expect(e.inlineU32(.little) == 8); // the offset — what the bug returned
}

test "readRational3 rejects wrong count/type" {
    var buf = [_]u8{0} ** 40;
    const bad_type = Entry{ .tag = Tag.as_shot_neutral, .type = 4, .count = 3, .value_off = 8 };
    try std.testing.expectError(Error.MissingTag, readRational3(&buf, bad_type, .little));
    const bad_count = Entry{ .tag = Tag.as_shot_neutral, .type = 5, .count = 2, .value_off = 8 };
    try std.testing.expectError(Error.MissingTag, readRational3(&buf, bad_count, .little));
}

// ── EXIF SubIFD read tests ─────────────────────────────────────────────────
// A tiny endian-aware TIFF builder produces a 2×2 RGGB uncompressed-strip DNG
// (Compression=1) so dng.parse succeeds end-to-end, exercising the new EXIF
// SubIFD pass alongside the existing required-tag decode and strip layout.

const ExifFixture = struct {
    exif_time_num: u32 = 0, // ExposureTime numerator;   0/0 ⇒ tag omitted
    exif_time_den: u32 = 0,
    iso: u32 = 0, // ISOSpeedRatings (SHORT);  0 ⇒ tag omitted
    fnum_num: u32 = 0, // FNumber numerator;        0/0 ⇒ tag omitted
    fnum_den: u32 = 0,
    omit_subifd: bool = false, // no tag 34665 at all
    bad_subifd_off: u32 = 0, // if != 0, point 34665 here (out of bounds)
};

const TiffBuilder = struct {
    bytes: [512]u8 = undefined,
    len: usize = 0,
    order: ByteOrder,

    fn byte(self: *TiffBuilder, v: u8) void {
        self.bytes[self.len] = v;
        self.len += 1;
    }
    fn putU16(self: *TiffBuilder, v: u16) void {
        if (self.order == .little) {
            self.byte(@truncate(v));
            self.byte(@truncate(v >> 8));
        } else {
            self.byte(@truncate(v >> 8));
            self.byte(@truncate(v));
        }
    }
    fn putU32(self: *TiffBuilder, v: u32) void {
        if (self.order == .little) {
            self.byte(@truncate(v));
            self.byte(@truncate(v >> 8));
            self.byte(@truncate(v >> 16));
            self.byte(@truncate(v >> 24));
        } else {
            self.byte(@truncate(v >> 24));
            self.byte(@truncate(v >> 16));
            self.byte(@truncate(v >> 8));
            self.byte(@truncate(v));
        }
    }
    // A SHORT entry holds its value inline in the high or low half depending on
    // byte order (mirrors Entry.inlineU32).
    fn entryShort(self: *TiffBuilder, tag: u16, v: u16) void {
        self.putU16(tag);
        self.putU16(3); // SHORT
        self.putU32(1);
        self.putU16(v); // low (LE) / high (MM, written MSB-first) half
        self.putU16(0);
    }
    fn entryLong(self: *TiffBuilder, tag: u16, v: u32) void {
        self.putU16(tag);
        self.putU16(4); // LONG
        self.putU32(1);
        self.putU32(v);
    }
    // A tag whose value is stored out-of-line at `off`.
    fn entryPtr(self: *TiffBuilder, tag: u16, typ: u16, count: u32, off: u32) void {
        self.putU16(tag);
        self.putU16(typ);
        self.putU32(count);
        self.putU32(off);
    }
};

/// Build a valid 2×2 RGGB uncompressed DNG plus an optional EXIF SubIFD.
fn buildExifDng(order: ByteOrder, fx: ExifFixture) TiffBuilder {
    // Layout we lay down (offsets fixed so out-of-line pointers are easy):
    //   0   : header (II/MM, 42, ifd0_off=8)
    //   8   : IFD0
    //   then out-of-line blobs (crop origin/size, pixel data, exif rationals),
    //         then the EXIF SubIFD.
    var b = TiffBuilder{ .order = order };

    // Header.
    if (order == .little) {
        b.byte('I');
        b.byte('I');
    } else {
        b.byte('M');
        b.byte('M');
    }
    b.putU16(42);
    b.putU32(8); // IFD0 at offset 8

    const want_exif = !fx.omit_subifd;
    const want_time = fx.exif_time_den != 0;
    const want_fnum = fx.fnum_den != 0;
    const want_iso = fx.iso != 0;

    // Count IFD0 entries: 10 required (width, length, bits, compression,
    // photometric, strip_offsets, strip_byte_counts, cfa, crop_origin,
    // crop_size) + (exif pointer ? 1 : 0).
    var ifd0_count: u16 = 10;
    if (want_exif) ifd0_count += 1;

    // IFD0 spans: 2 (count) + 12*N + 4 (next-IFD). Out-of-line region follows.
    // We store crop origin/size as LONG[2] out-of-line (8 bytes each).
    const ifd0_size: u32 = 2 + 12 * @as(u32, ifd0_count) + 4;
    var off: u32 = 8 + ifd0_size; // running out-of-line cursor
    const crop_org_off = off;
    off += 8;
    const crop_size_off = off;
    off += 8;
    const pixel_off = off;
    off += 8; // 2×2 u16 = 8 bytes
    const time_off = off;
    if (want_exif and want_time) off += 8;
    const fnum_off = off;
    if (want_exif and want_fnum) off += 8;
    const subifd_off = off;

    // ── IFD0 ──
    b.putU16(ifd0_count);
    b.entryShort(Tag.image_width, 2);
    b.entryShort(Tag.image_length, 2);
    b.entryShort(Tag.bits_per_sample, 16);
    b.entryShort(Tag.compression, 1); // uncompressed
    b.entryShort(Tag.photometric_interpretation, @intCast(CFA_PHOTOMETRIC));
    b.entryLong(Tag.strip_offsets, pixel_off);
    b.entryLong(Tag.strip_byte_counts, 8);
    // CFA pattern RGGB inline (BYTE[4] = 0,1,1,2). Bytes are byte-packed; write
    // them low-end first regardless of order to match the decoder's accept set.
    {
        b.putU16(Tag.cfa_pattern);
        b.putU16(1); // BYTE
        b.putU32(4);
        b.byte(0);
        b.byte(1);
        b.byte(1);
        b.byte(2);
    }
    b.entryPtr(Tag.default_crop_origin, 4, 2, crop_org_off);
    b.entryPtr(Tag.default_crop_size, 4, 2, crop_size_off);
    if (want_exif) {
        const ptr = if (fx.bad_subifd_off != 0) fx.bad_subifd_off else subifd_off;
        b.entryLong(Tag.exif_ifd_pointer, ptr);
    }
    b.putU32(0); // next IFD = none

    // ── out-of-line blobs ──
    b.putU32(0); // crop origin x
    b.putU32(0); // crop origin y
    b.putU32(2); // crop size w
    b.putU32(2); // crop size h
    // pixel data: four u16 samples
    b.putU16(1000);
    b.putU16(2000);
    b.putU16(3000);
    b.putU16(4000);
    if (want_exif and want_time) {
        b.putU32(fx.exif_time_num);
        b.putU32(fx.exif_time_den);
    }
    if (want_exif and want_fnum) {
        b.putU32(fx.fnum_num);
        b.putU32(fx.fnum_den);
    }

    // ── EXIF SubIFD ──
    if (want_exif and fx.bad_subifd_off == 0) {
        var sub_count: u16 = 0;
        if (want_time) sub_count += 1;
        if (want_iso) sub_count += 1;
        if (want_fnum) sub_count += 1;
        b.putU16(sub_count);
        if (want_time) b.entryPtr(Tag.exposure_time, 5, 1, time_off);
        if (want_iso) b.entryShort(Tag.iso, @intCast(fx.iso));
        if (want_fnum) b.entryPtr(Tag.fnumber, 5, 1, fnum_off);
        b.putU32(0); // next IFD
    }

    return b;
}

test "exif read little-endian" {
    const alloc = std.testing.allocator;
    const b = buildExifDng(.little, .{
        .exif_time_num = 1,  .exif_time_den = 250, // 1/250 = 0.004
        .iso = 100,
        .fnum_num = 28, .fnum_den = 10,            // 2.8
    });
    const bytes = b.bytes[0..b.len];
    const m = try parse(alloc, bytes);
    defer alloc.free(m.backing);
    try std.testing.expectApproxEqAbs(@as(f32, 0.004), m.exposure_time, 1e-5);
    try std.testing.expectEqual(@as(f32, 100), m.iso);
    try std.testing.expectApproxEqAbs(@as(f32, 2.8), m.fnumber, 1e-4);
}

test "exif read big-endian (MM)" {
    const alloc = std.testing.allocator;
    const b = buildExifDng(.big, .{
        .exif_time_num = 1,  .exif_time_den = 250,
        .iso = 100,
        .fnum_num = 28, .fnum_den = 10,
    });
    const m = try parse(alloc, b.bytes[0..b.len]);
    defer alloc.free(m.backing);
    try std.testing.expectApproxEqAbs(@as(f32, 0.004), m.exposure_time, 1e-5);
    try std.testing.expectEqual(@as(f32, 100), m.iso); // SHORT high-half quirk
    try std.testing.expectApproxEqAbs(@as(f32, 2.8), m.fnumber, 1e-4);
}

test "exif absent -> sentinel zero" {
    const alloc = std.testing.allocator;
    const b = buildExifDng(.little, .{ .omit_subifd = true });
    const m = try parse(alloc, b.bytes[0..b.len]);
    defer alloc.free(m.backing);
    try std.testing.expectEqual(@as(f32, 0), m.exposure_time);
    try std.testing.expectEqual(@as(f32, 0), m.iso);
    try std.testing.expectEqual(@as(f32, 0), m.fnumber);
}

test "exif pointer truncated -> graceful" {
    const alloc = std.testing.allocator;
    const b = buildExifDng(.little, .{
        .exif_time_num = 1, .exif_time_den = 250,
        .bad_subifd_off = 0xFFFFFF, // points far past bytes.len
    });
    const m = try parse(alloc, b.bytes[0..b.len]); // must not crash/error
    defer alloc.free(m.backing);
    try std.testing.expectEqual(@as(f32, 0), m.exposure_time);
    try std.testing.expectEqual(@as(f32, 0), m.iso);
    try std.testing.expectEqual(@as(f32, 0), m.fnumber);
}
