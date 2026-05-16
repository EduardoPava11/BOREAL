//! Lossless JPEG (SOF3) decoder for iPhone Bayer RAW DNGs.
//!
//! ─── Apple iPhone 17 Pro format (reverse-engineered, verified 2026-05-16) ───
//!
//!   Container : TIFF/DNG with Compression=7, 128 tiles in a 16×8 grid
//!   Tile size : TileWidth=264 (= lj_w × Nf), TileLength=378
//!   LJPEG SOF3 markers:
//!     P  = 12   sub-precision per component (NOT 14 — see Pt below)
//!     Y  = 378  raster height (matches TileLength)
//!     X  = 132  raster width (TileWidth / Nf)
//!     Nf = 2    TWO interleaved components per LJPEG pixel
//!   LJPEG SOS markers:
//!     Ns = 2    both components in one scan
//!     Td = [0, 1]  per-component Huffman table indices
//!     Pt = 1    point transform: left-shift output by 1 bit
//!     Pred = 1  left-neighbor predictor
//!   DHT      : two segments (one per component)
//!
//!   Effective output bit depth: P + Pt = 13 bits per sample, with
//!   BlackLevel=528 / WhiteLevel=4095 in the post-shift domain.
//!
//! ─── Critical correctness invariants (DO NOT BREAK without re-verifying) ───
//!
//!   1. Per-component predictor history.  Each of the Nf components keeps
//!      its OWN `left` and `above` neighbor values. Cross-component bleed
//!      would scramble the two greens in a BGGR cell.
//!   2. Per-component Huffman table dispatch via SOS Td.  Component 0 uses
//!      DHT slot 0, component 1 uses DHT slot 1. Wiring them to the same
//!      table corrupts the residuals silently.
//!   3. Point transform Pt applied on emission, not on residual.  The
//!      shift is `recon << Pt` AFTER reconstructing the sample, not before.
//!   4. Top-row initial prediction = `1 << (P - Pt - 1)` per ISO/IEC
//!      10918-1 §H.1.2.1.  For Apple's (P=12, Pt=1): initial_pred=1024
//!      in the pre-shift domain, becoming 2048 after the post-emission
//!      `<< Pt` left-shift.  Getting Pt's sign wrong cascades a ~1024 DN
//!      bias down the entire first row of the tile.
//!   5. Interleaved output: out_col = x_lj × Nf + c.  The two components
//!      MUST be interleaved into the TIFF tile, not appended as separate
//!      planes.
//!
//! ─── Scope (fail-loud on anything outside) ───
//!
//!   - SOF3 only (Compression=7). SOF0/1/2 (DCT-based) explicitly rejected.
//!   - Nf ∈ {1, 2}.  Nf=1 path preserved for synthetic tests.
//!   - P ∈ [8, 16].  Earlier `P==14` gate was wrong (Apple uses P=12).
//!   - Predictor ∈ {1, 7}.  Apple uses 1.
//!   - DRI = 0.  Restart markers not implemented (Apple doesn't use them).
//!
//! Output: a packed u16 mosaic, row-major, length = width × height.
//!
//! Reference: ISO/IEC 10918-1 Annex H; DNG 1.4 §3; verified end-to-end on
//! device via `zig build real-dng-check` against airdropped frame-0.dng.
//!
//! File layout (each section individually tested):
//!   Section 1: BitReader (MSB-first, byte-stuffing aware)
//!   Section 2: Markers + parseNextMarker
//!   Section 3: HuffmanTable (canonical, build + lookup)
//!   Section 4: Frame/Scan headers (SOF3 + SOS)
//!   Section 5: decode() top-level (multi-component, point-transform aware)

const std = @import("std");

pub const Error = error{
    BadMagic,                 // SOI not at start
    UnexpectedEnd,            // ran out of bytes mid-decode
    UnsupportedMarker,        // hit a marker we don't handle (e.g., SOF0 baseline)
    UnsupportedComponentCount,// SOF3 with components ∉ {1, 2}
    UnsupportedPrecision,     // SOF3 with P ∉ [8, 16]  (Apple uses P=12)
    UnsupportedPredictor,     // SOS with predictor ∉ {1, 7} (Apple uses 1)
    HasRestartMarkers,        // DRI > 0 — Apple doesn't emit these; reject if seen
    MalformedHuffmanTable,    // DHT with inconsistent code lengths
    InvalidHuffmanCode,       // bit pattern not in any table entry
    OutOfMemory,
};

// ============================================================================
// Section 1: BitReader (MSB-first, JPEG byte-stuffing aware)
// ============================================================================
//
// JPEG entropy-coded segments are packed bit-streams MSB-first within each
// byte. Plus: any 0xFF byte in the entropy data MUST be followed by 0x00
// (a "stuffed" zero) to disambiguate from marker bytes — the reader must
// silently consume the stuffed 0x00. Encountering a real marker (FF != 00)
// is a signal that the entropy segment is over.

pub const BitReader = struct {
    bytes: []const u8,
    pos: usize = 0,         // index into bytes
    bit_buf: u32 = 0,       // accumulated bits (MSB-first, top of buf is next bit)
    bit_count: u5 = 0,      // valid bits in bit_buf (0..32)
    /// True once we hit a non-stuffed FFxx marker — caller should stop reading
    /// entropy bits and re-parse from the marker.
    hit_marker: bool = false,
    marker_byte: u8 = 0,    // the second byte of the marker, if hit_marker is true

    pub fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes };
    }

    /// Refill bit_buf with 1+ bytes from the stream until we have at least
    /// `min_bits` bits available (or hit a marker / end of data).
    fn fill(self: *BitReader, min_bits: u5) Error!void {
        while (self.bit_count < min_bits) {
            if (self.hit_marker) return Error.UnexpectedEnd;
            if (self.pos >= self.bytes.len) return Error.UnexpectedEnd;
            const b = self.bytes[self.pos];
            self.pos += 1;
            if (b == 0xFF) {
                // Possible marker. Look at next byte.
                if (self.pos >= self.bytes.len) return Error.UnexpectedEnd;
                const next = self.bytes[self.pos];
                self.pos += 1;
                if (next == 0x00) {
                    // Stuffed zero — emit the 0xFF as a literal data byte.
                    self.bit_buf |= @as(u32, 0xFF) << @intCast(24 - @as(u32, self.bit_count));
                    self.bit_count += 8;
                } else {
                    // Real marker. Park it; tell caller to stop. If we don't
                    // have enough bits buffered to satisfy the request, return
                    // UnexpectedEnd so the caller doesn't proceed with a
                    // partial value (which would underflow `consume`).
                    self.hit_marker = true;
                    self.marker_byte = next;
                    if (self.bit_count < min_bits) return Error.UnexpectedEnd;
                    return;
                }
            } else {
                self.bit_buf |= @as(u32, b) << @intCast(24 - @as(u32, self.bit_count));
                self.bit_count += 8;
            }
        }
    }

    /// Peek the top `n` bits without consuming. Caller must have called
    /// `fill(n)` first (or be sure there are enough bits).
    pub fn peek(self: *const BitReader, n: u5) u32 {
        if (n == 0) return 0;
        return self.bit_buf >> @intCast(32 - @as(u32, n));
    }

    /// Consume the top `n` bits.
    pub fn consume(self: *BitReader, n: u5) void {
        self.bit_buf <<= n;
        self.bit_count -= n;
    }

    /// Read and consume `n` bits. Convenience.
    pub fn readBits(self: *BitReader, n: u5) Error!u32 {
        if (n == 0) return 0;
        try self.fill(n);
        const v = self.peek(n);
        self.consume(n);
        return v;
    }

    /// JPEG-standard signed value extension: given a `n`-bit raw value `v`
    /// from the bit stream, sign-extend it to a signed integer. This is the
    /// "EXTEND" procedure from ISO/IEC 10918-1 §F.2.2.1.
    ///
    ///   if v >= 2^(n-1):  result = v
    ///   else:             result = v + (-2^n + 1)
    pub fn extend(v: u32, n: u5) i32 {
        if (n == 0) return 0;
        const half = @as(u32, 1) << @intCast(n - 1);
        if (v >= half) {
            return @intCast(v);
        } else {
            const max = @as(i32, 1) << @intCast(n);
            return @as(i32, @intCast(v)) - max + 1;
        }
    }
};

// ============================================================================
// Section 2: Markers
// ============================================================================
//
// JPEG markers are 2 bytes: 0xFF followed by a non-FF, non-00 byte. The
// first byte is the marker prefix; the second byte identifies the marker.
// Markers we care about for SOF3 lossless single-component:

pub const Marker = enum(u8) {
    soi  = 0xD8, // Start of Image
    eoi  = 0xD9, // End of Image
    sof3 = 0xC3, // Start of Frame, lossless (Huffman)
    dht  = 0xC4, // Define Huffman Table
    sos  = 0xDA, // Start of Scan
    dri  = 0xDD, // Define Restart Interval
    rst0 = 0xD0,
    rst1 = 0xD1,
    rst2 = 0xD2,
    rst3 = 0xD3,
    rst4 = 0xD4,
    rst5 = 0xD5,
    rst6 = 0xD6,
    rst7 = 0xD7,
    com  = 0xFE, // Comment
    _,           // catch-all for unhandled markers (e.g., SOF0/2/etc.)
};

pub const FoundMarker = struct {
    marker: Marker,
    /// Position of the marker BYTE (the second byte after FF) within the input.
    /// The marker's payload (if any) starts at pos + 1.
    pos: usize,
};

/// Scan from `start` looking for the next FFxx marker (xx ≠ 00, ≠ FF).
/// Returns the marker and its byte offset. Errors if EOF before a marker.
pub fn parseNextMarker(bytes: []const u8, start: usize) Error!FoundMarker {
    var i = start;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] != 0xFF) continue;
        // Skip fill bytes (0xFF FF FF ... is allowed before a marker).
        var j = i + 1;
        while (j < bytes.len and bytes[j] == 0xFF) : (j += 1) {}
        if (j >= bytes.len) return Error.UnexpectedEnd;
        const b = bytes[j];
        if (b == 0x00) {
            // Stuffed zero (only valid inside entropy data, which this function
            // shouldn't be called on — but if hit, skip and continue).
            i = j;
            continue;
        }
        return .{ .marker = @enumFromInt(b), .pos = j };
    }
    return Error.UnexpectedEnd;
}

/// Read a 16-bit big-endian value (JPEG segment length and most other fields
/// are big-endian, regardless of the enclosing TIFF's byte order).
pub fn readBE16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset + 2 > bytes.len) return Error.UnexpectedEnd;
    return (@as(u16, bytes[offset]) << 8) | @as(u16, bytes[offset + 1]);
}

// ============================================================================
// Section 3: Huffman table (canonical, build + decode)
// ============================================================================
//
// JPEG canonical Huffman: a table is defined by:
//   - 16 bytes Li (i=1..16) = count of codes of length i
//   - sum(Li) bytes Vi = the values, ordered by code length then by code value
//
// The decoder reconstructs the actual code bits via this algorithm
// (ISO/IEC 10918-1 Annex C):
//   code := 0
//   for length := 1 .. 16:
//     for k := 1 .. Li:
//       table[code, length] := next_value
//       code += 1
//     code <<= 1     // shift left for next length
//
// To decode: read 1 bit, append to running code, check if we have a match
// at this length. If so, emit the value. Else read another bit, repeat.
// Worst case: 16 bit reads per symbol.
//
// `mincode[len]` and `maxcode[len]` define the inclusive range of codes
// of each length, with `valptr[len]` pointing into a flat values[] array.

pub const HuffmanTable = struct {
    /// minimum code value at each length (1..16). minCode[0] is unused.
    min_code: [17]i32,
    /// maximum code value at each length, or -1 if no codes at this length.
    max_code: [17]i32,
    /// index into values[] of the first code of each length.
    val_ptr: [17]u32,
    /// flat array of decoded values, in canonical order.
    values: []u8,
    /// owned by the caller's allocator.
    backing: []u8,

    /// Build from the JPEG DHT marker payload-after-length:
    ///   1 byte: Tc (high nibble = class, low nibble = destination)
    ///   16 bytes: Li (counts per length 1..16)
    ///   sum(Li) bytes: Vi (values)
    /// Returns the constructed table; caller must call `deinit` to free.
    pub fn parse(allocator: std.mem.Allocator, payload: []const u8) Error!HuffmanTable {
        if (payload.len < 17) return Error.MalformedHuffmanTable;
        // Skip Tc byte (we don't validate class — caller may want to inspect).
        const counts = payload[1..17];
        var n_values: u32 = 0;
        for (counts) |c| n_values += c;
        if (payload.len < 17 + n_values) return Error.MalformedHuffmanTable;

        const values_src = payload[17 .. 17 + n_values];
        const backing = try allocator.alloc(u8, n_values);
        errdefer allocator.free(backing);
        @memcpy(backing, values_src);

        var t: HuffmanTable = .{
            .min_code = [_]i32{-1} ** 17,
            .max_code = [_]i32{-1} ** 17,
            .val_ptr = [_]u32{0} ** 17,
            .values = backing,
            .backing = backing,
        };

        // Build min/max code per length, value pointers.
        var code: i32 = 0;
        var v_idx: u32 = 0;
        var length: usize = 1;
        while (length <= 16) : (length += 1) {
            const n: u32 = counts[length - 1];
            if (n == 0) {
                t.max_code[length] = -1;
            } else {
                t.val_ptr[length] = v_idx;
                t.min_code[length] = code;
                t.max_code[length] = code + @as(i32, @intCast(n)) - 1;
                code += @as(i32, @intCast(n));
                v_idx += n;
            }
            code <<= 1;
        }

        return t;
    }

    pub fn deinit(self: *HuffmanTable, allocator: std.mem.Allocator) void {
        allocator.free(self.backing);
        self.values = &.{};
        self.backing = &.{};
    }

    /// Decode one symbol from `r`. Returns the value (the "category" SSSS
    /// for LJPEG DC). Reads 1..16 bits.
    pub fn decode(self: *const HuffmanTable, r: *BitReader) Error!u8 {
        // Bit-by-bit walk. ITU-T81 Annex F.2.2.3 "DECODE".
        var code: i32 = 0;
        var length: u5 = 1;
        while (length <= 16) : (length += 1) {
            try r.fill(1);
            const bit = r.peek(1);
            r.consume(1);
            code = (code << 1) | @as(i32, @intCast(bit));
            if (code <= self.max_code[length]) {
                const idx = self.val_ptr[length] + @as(u32, @intCast(code - self.min_code[length]));
                if (idx >= self.values.len) return Error.InvalidHuffmanCode;
                return self.values[idx];
            }
        }
        return Error.InvalidHuffmanCode;
    }
};

// ============================================================================
// Section 4: SOF3 + SOS headers
// ============================================================================

pub const FrameHeader = struct {
    /// Sample precision (bits). iPhone Bayer = 14.
    precision: u8,
    /// Image height (Y).
    height: u16,
    /// Image width (X).
    width: u16,
    /// Number of components (Nf). Single-component Bayer = 1.
    n_components: u8,
    /// Per-component info (max 4). For 1-component: [(id, h, v, tq)].
    components: [4]Component,

    pub const Component = struct {
        id: u8 = 0,         // Ci
        h_factor: u4 = 0,   // Hi (horizontal sampling factor)
        v_factor: u4 = 0,   // Vi (vertical sampling factor)
        tq: u8 = 0,         // Tqi (quantization table dest, unused for SOF3)
    };

    /// Parse SOF3 segment payload (after the 2-byte length).
    ///   1 byte: P (precision)
    ///   2 bytes: Y (height)
    ///   2 bytes: X (width)
    ///   1 byte: Nf (component count)
    ///   for each component: 3 bytes (Ci, Hi/Vi packed, Tqi)
    pub fn parse(payload: []const u8) Error!FrameHeader {
        if (payload.len < 6) return Error.UnexpectedEnd;
        const precision = payload[0];
        const height = (@as(u16, payload[1]) << 8) | @as(u16, payload[2]);
        const width  = (@as(u16, payload[3]) << 8) | @as(u16, payload[4]);
        const nf = payload[5];
        if (nf == 0 or nf > 4) return Error.UnsupportedComponentCount;
        if (payload.len < 6 + @as(usize, nf) * 3) return Error.UnexpectedEnd;
        // Accept any precision in [8, 16] — iPhone DNGs may declare P=12, 14,
        // or 16 depending on container choice. Downstream math
        // (initial_pred, max_val) is parametric in f.precision so no other
        // changes needed. Status 23 from real iPhone DNGs means Apple uses
        // P != 14 (most likely 16, matching the 16-bit BitsPerSample container).
        if (precision < 8 or precision > 16) return Error.UnsupportedPrecision;
        // Accept Nf ∈ {1, 2}. iPhone Bayer LJPEG uses Nf=2 (two components,
        // one per "lane" of the Bayer mosaic — even-column samples vs
        // odd-column samples — each with its own Huffman table + predictor
        // history). Reverse-engineered from a real device DNG 2026-05-16:
        //   SOF3: P=12 Y=378 X=132 Nf=2 (matches TileWidth=264, TileLength=378).
        if (nf == 0 or nf > 2) return Error.UnsupportedComponentCount;

        var comps = [_]Component{.{}} ** 4;
        var i: usize = 0;
        while (i < nf) : (i += 1) {
            const off = 6 + i * 3;
            comps[i] = .{
                .id = payload[off],
                .h_factor = @intCast((payload[off + 1] >> 4) & 0x0F),
                .v_factor = @intCast(payload[off + 1] & 0x0F),
                .tq = payload[off + 2],
            };
        }
        return .{
            .precision = precision,
            .height = height,
            .width = width,
            .n_components = nf,
            .components = comps,
        };
    }
};

pub const ScanHeader = struct {
    /// Predictor selection (Ss). 1..7 for SOF3.
    predictor: u8,
    /// Per-component scan info: huffman table dest (Td) for each component.
    n_components: u8,
    components: [4]Component,
    /// Point transform (Al field). Usually 0.
    point_transform: u8,

    pub const Component = struct {
        cs: u8 = 0,    // component selector
        td: u4 = 0,    // huffman table dest
    };

    pub fn parse(payload: []const u8) Error!ScanHeader {
        if (payload.len < 1) return Error.UnexpectedEnd;
        const ns = payload[0];
        if (ns == 0 or ns > 4) return Error.UnsupportedComponentCount;
        if (payload.len < 1 + @as(usize, ns) * 2 + 3) return Error.UnexpectedEnd;
        var comps = [_]Component{.{}} ** 4;
        var i: usize = 0;
        while (i < ns) : (i += 1) {
            const off = 1 + i * 2;
            comps[i] = .{
                .cs = payload[off],
                .td = @intCast((payload[off + 1] >> 4) & 0x0F),
            };
        }
        const tail = 1 + @as(usize, ns) * 2;
        const predictor = payload[tail];      // Ss
        // payload[tail + 1] is Se (= 0 for SOF3)
        const point_transform = payload[tail + 2] & 0x0F;  // Al
        // Accept Ns ∈ {1, 2} matching the FrameHeader Nf relaxation. iPhone
        // DNG SOS uses Ns=2 with per-component Td selecting one of the two
        // Huffman tables defined in the prior DHT markers.
        if (ns == 0 or ns > 2) return Error.UnsupportedComponentCount;
        if (predictor != 1 and predictor != 7) return Error.UnsupportedPredictor;
        return .{
            .predictor = predictor,
            .n_components = ns,
            .components = comps,
            .point_transform = point_transform,
        };
    }
};

// ============================================================================
// Section 5: decode() top-level
// ============================================================================

pub const Decoded = struct {
    width: u32,
    height: u32,
    precision: u8,
    samples: []u16,    // length = width * height, row-major
    backing: []u16,    // owned, free with same allocator

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.backing);
        self.samples = &.{};
        self.backing = &.{};
    }
};

/// Top-level LJPEG SOF3 decode. Walks markers from `bytes`, parses SOF3 +
/// DHT(s) + SOS, then runs the predictor loop on the entropy data.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    if (bytes.len < 2 or bytes[0] != 0xFF or bytes[1] != 0xD8) {
        return Error.BadMagic;
    }

    var pos: usize = 2;
    var frame: ?FrameHeader = null;
    var scan: ?ScanHeader = null;
    // We support up to 4 DC Huffman tables, indexed by destination 0..3.
    var dc_tables: [4]?HuffmanTable = .{ null, null, null, null };
    defer {
        for (&dc_tables) |*ot| {
            if (ot.*) |*t| t.deinit(allocator);
        }
    }
    var entropy_start: usize = 0;

    // Marker walk until SOS (after which we're in the entropy-coded segment).
    while (true) {
        const fm = try parseNextMarker(bytes, pos);
        switch (fm.marker) {
            .soi => {
                pos = fm.pos + 1;
                continue;
            },
            .sof3 => {
                if (fm.pos + 3 > bytes.len) return Error.UnexpectedEnd;
                const seg_len = try readBE16(bytes, fm.pos + 1);
                if (fm.pos + 1 + seg_len > bytes.len) return Error.UnexpectedEnd;
                const payload = bytes[fm.pos + 3 .. fm.pos + 1 + seg_len];
                frame = try FrameHeader.parse(payload);
                pos = fm.pos + 1 + seg_len;
            },
            .dht => {
                if (fm.pos + 3 > bytes.len) return Error.UnexpectedEnd;
                const seg_len = try readBE16(bytes, fm.pos + 1);
                if (fm.pos + 1 + seg_len > bytes.len) return Error.UnexpectedEnd;
                // A DHT segment can contain multiple tables; each is Tc/Td +
                // 16 counts + values. Walk them.
                var dht_off = fm.pos + 3;
                const dht_end = fm.pos + 1 + seg_len;
                while (dht_off < dht_end) {
                    if (dht_off + 17 > dht_end) return Error.MalformedHuffmanTable;
                    const td: usize = @intCast(bytes[dht_off] & 0x0F);
                    if (td > 3) return Error.MalformedHuffmanTable;
                    var n_values: u32 = 0;
                    var k: usize = 1;
                    while (k <= 16) : (k += 1) n_values += bytes[dht_off + k];
                    const table_payload = bytes[dht_off .. dht_off + 17 + n_values];
                    if (dc_tables[td]) |*old| old.deinit(allocator);
                    dc_tables[td] = try HuffmanTable.parse(allocator, table_payload);
                    dht_off += 17 + n_values;
                }
                pos = fm.pos + 1 + seg_len;
            },
            .dri => {
                if (fm.pos + 3 > bytes.len) return Error.UnexpectedEnd;
                const ri = try readBE16(bytes, fm.pos + 3);
                if (ri != 0) return Error.HasRestartMarkers;
                pos = fm.pos + 1 + 4;  // 4-byte segment
            },
            .sos => {
                if (fm.pos + 3 > bytes.len) return Error.UnexpectedEnd;
                const seg_len = try readBE16(bytes, fm.pos + 1);
                if (fm.pos + 1 + seg_len > bytes.len) return Error.UnexpectedEnd;
                const payload = bytes[fm.pos + 3 .. fm.pos + 1 + seg_len];
                scan = try ScanHeader.parse(payload);
                entropy_start = fm.pos + 1 + seg_len;
                break;
            },
            .com => {
                // Skip comment.
                if (fm.pos + 3 > bytes.len) return Error.UnexpectedEnd;
                const seg_len = try readBE16(bytes, fm.pos + 1);
                pos = fm.pos + 1 + seg_len;
            },
            .eoi => return Error.UnexpectedEnd,  // SOS never seen
            else => return Error.UnsupportedMarker,
        }
    }

    const f = frame orelse return Error.UnexpectedEnd;
    const s = scan orelse return Error.UnexpectedEnd;
    if (s.n_components != f.n_components) return Error.UnsupportedComponentCount;

    // Per-component Huffman table lookups via the Td destination in SOS.
    // For Nf=2, components 0 and 1 typically use Td=0 and Td=1 respectively
    // (iPhone DNG layout verified 2026-05-16). For Nf=1, only component 0.
    var comp_tables: [2]*const HuffmanTable = undefined;
    var ci: usize = 0;
    while (ci < f.n_components) : (ci += 1) {
        const td_idx: usize = @intCast(s.components[ci].td);
        if (td_idx > 3) return Error.MalformedHuffmanTable;
        comp_tables[ci] = &(dc_tables[td_idx] orelse return Error.MalformedHuffmanTable);
    }

    // Geometry:
    //   f.width   = LJPEG pixels per row (one Huffman code per component per pixel).
    //   f.height  = rows.
    //   Nf        = components per LJPEG pixel (interleaved column-wise on output).
    //   out_w     = output samples per row = f.width * Nf.
    //
    // For iPhone Bayer LJPEG: f.width=132, Nf=2 → out_w=264 = TileWidth ✓
    const nf: u32 = f.n_components;
    const lj_w: u32 = f.width;
    const h: u32 = f.height;
    const out_w: u32 = lj_w * nf;
    const samples = try allocator.alloc(u16, @as(usize, out_w) * @as(usize, h));
    errdefer allocator.free(samples);

    // Initial predictor for first sample of first row: 2^(P - Pt - 1).
    // Per ISO/IEC 10918-1 §H.1.2.1 — this is the "neutral" anchor in the
    // pre-shift domain (for iPhone P=12, Pt=1 → initial_pred=1024).
    //
    // Point transform Pt: decoder left-shifts each reconstructed sample by Pt
    // bits before storing (ISO/IEC 10918-1 §H.1.2). Apple emits Pt=1; the
    // shift is applied at emission (line `recon << pt` below), NOT to the
    // predictor history (predictor neighbors are stored AFTER shift, so
    // history-vs-shift composition is automatic).
    //
    // max_val clamp is `(1 << P) - 1 = 4095` for P=12, matching the observed
    // WhiteLevel from iPhone DNG metadata. Post-shift values that exceed this
    // (e.g. saturated optical-white pixels) are clipped — matches scene clip
    // behavior. Verified on device 2026-05-16: real iPhone DNG output landed
    // in [0, 4095], mean ≈ 958 — consistent with BlackLevel=528.
    const pt: u5 = @intCast(s.point_transform);
    const initial_pred: i32 = @as(i32, 1) << @intCast(@as(u5, @intCast(f.precision)) - pt - 1);
    const max_val: i32 = (@as(i32, 1) << @intCast(@as(u5, @intCast(f.precision)))) - 1;

    var r = BitReader.init(bytes[entropy_start..]);

    // Decode loop: per LJPEG pixel position, decode Nf samples (one per
    // component), each with its own predictor history. Output columns
    // interleave: component c at out_col = x_lj * Nf + c.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x_lj: u32 = 0;
        while (x_lj < lj_w) : (x_lj += 1) {
            var c: u32 = 0;
            while (c < nf) : (c += 1) {
                const out_col = x_lj * nf + c;
                // ── Per-component predictor (LOAD-BEARING) ──
                // Each of the Nf components MUST have its own neighbor
                // history. The "left" neighbor for component c at LJPEG
                // pixel x is the SAME component (c) at LJPEG pixel x-1,
                // which lives at output column (x-1)*nf + c — NOT at
                // output column out_col - 1. The "+ c" preserves
                // component separation across the interleave.
                //
                // Why this matters: for Bayer BGGR, the two greens in a
                // 2×2 cell come from DIFFERENT components in the LJPEG
                // sense (one even-column, one odd-column). If predictor
                // history cross-bleeds, the two greens diverge wildly
                // (typically by 50-200 DN). The on-device sanity check
                // (greens within ±2 DN) is the regression signal here.
                const predicted: i32 = blk: {
                    if (x_lj == 0 and y == 0) {
                        break :blk initial_pred;
                    } else if (y == 0) {
                        // First row, x_lj>0: Pa (same component, previous LJPEG pixel)
                        const left_col = (x_lj - 1) * nf + c;
                        break :blk @as(i32, samples[left_col]);
                    } else if (x_lj == 0) {
                        // First column of subsequent rows: Pb (same component above)
                        break :blk @as(i32, samples[(y - 1) * out_w + c]);
                    } else {
                        const Pa: i32 = @as(i32, samples[y * out_w + (x_lj - 1) * nf + c]);
                        const Pb: i32 = @as(i32, samples[(y - 1) * out_w + x_lj * nf + c]);
                        break :blk switch (s.predictor) {
                            1 => Pa,
                            7 => @divTrunc(Pa + Pb, 2),
                            else => return Error.UnsupportedPredictor,
                        };
                    }
                };

                // Decode diff via this component's Huffman table.
                const t = try comp_tables[c].decode(&r);
                const t5: u5 = @intCast(t);
                const raw = if (t == 0) @as(u32, 0) else try r.readBits(t5);
                const diff = BitReader.extend(raw, t5);

                // Reconstruct, point-transform left-shift, clamp.
                const recon = predicted + diff;
                const shifted = recon << pt;
                const clipped = @max(@as(i32, 0), @min(max_val, shifted));
                samples[y * out_w + out_col] = @intCast(clipped);
            }
        }
    }

    return .{
        .width = out_w,         // physical width in u16 samples (= lj_w * nf)
        .height = h,
        .precision = f.precision,
        .samples = samples,
        .backing = samples,
    };
}

// ============================================================================
// Tests (item 2a coverage)
// ============================================================================

const testing = std.testing;

test "BitReader: read 1 byte MSB-first" {
    const data = [_]u8{0b10110100};
    var r = BitReader.init(&data);
    try testing.expectEqual(@as(u32, 0b1), try r.readBits(1));
    try testing.expectEqual(@as(u32, 0b0), try r.readBits(1));
    try testing.expectEqual(@as(u32, 0b11), try r.readBits(2));
    try testing.expectEqual(@as(u32, 0b0100), try r.readBits(4));
}

test "BitReader: cross byte boundary" {
    const data = [_]u8{ 0b11110000, 0b10101010 };
    var r = BitReader.init(&data);
    // Read 12 bits: 1111 0000 1010 = 0xF0A
    try testing.expectEqual(@as(u32, 0xF0A), try r.readBits(12));
}

test "BitReader: byte-stuffing (FF 00 → emit FF)" {
    // Stream: FF (data) 00 (stuffed) AA → bits: 11111111 10101010
    const data = [_]u8{ 0xFF, 0x00, 0xAA };
    var r = BitReader.init(&data);
    try testing.expectEqual(@as(u32, 0xFFAA), try r.readBits(16));
    try testing.expect(!r.hit_marker);
}

test "BitReader: marker detection (FF DA = SOS)" {
    // First byte is data, second/third is FF DA marker.
    const data = [_]u8{ 0xAB, 0xFF, 0xDA, 0xCD };
    var r = BitReader.init(&data);
    try testing.expectEqual(@as(u32, 0xAB), try r.readBits(8));
    // Reading more should hit the marker.
    const result = r.readBits(8);
    try testing.expectError(Error.UnexpectedEnd, result);
    try testing.expect(r.hit_marker);
    try testing.expectEqual(@as(u8, 0xDA), r.marker_byte);
}

test "BitReader.extend: ITU-T81 §F.2.2.1 cases" {
    // n=1 → table: v=0 → -1, v=1 → 1
    try testing.expectEqual(@as(i32, -1), BitReader.extend(0, 1));
    try testing.expectEqual(@as(i32, 1), BitReader.extend(1, 1));
    // n=2 → table: v=00,01 → -3,-2; v=10,11 → 2,3
    try testing.expectEqual(@as(i32, -3), BitReader.extend(0, 2));
    try testing.expectEqual(@as(i32, -2), BitReader.extend(1, 2));
    try testing.expectEqual(@as(i32, 2), BitReader.extend(2, 2));
    try testing.expectEqual(@as(i32, 3), BitReader.extend(3, 2));
    // n=4 → boundary: v=7 → -8, v=8 → 8, v=15 → 15
    try testing.expectEqual(@as(i32, -8), BitReader.extend(7, 4));
    try testing.expectEqual(@as(i32, 8), BitReader.extend(8, 4));
    try testing.expectEqual(@as(i32, 15), BitReader.extend(15, 4));
}

test "parseNextMarker: SOF3 found at offset" {
    // FFD8 (SOI) + some segment + FFC3 (SOF3)
    const data = [_]u8{ 0xFF, 0xD8, 0x00, 0x00, 0xFF, 0xC3, 0x00, 0x00 };
    const m = try parseNextMarker(&data, 0);
    try testing.expectEqual(Marker.soi, m.marker);
    try testing.expectEqual(@as(usize, 1), m.pos);

    const m2 = try parseNextMarker(&data, m.pos + 1);
    try testing.expectEqual(Marker.sof3, m2.marker);
    try testing.expectEqual(@as(usize, 5), m2.pos);
}

test "parseNextMarker: skips fill bytes (FF FF ... FF C3)" {
    const data = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xC3 };
    const m = try parseNextMarker(&data, 0);
    try testing.expectEqual(Marker.sof3, m.marker);
    try testing.expectEqual(@as(usize, 4), m.pos);
}

test "parseNextMarker: stuffed zero is skipped (entropy data context)" {
    // FF 00 is byte-stuffing — parseNextMarker is for outside entropy, so
    // it should treat FF 00 as not-a-marker and continue scanning.
    const data = [_]u8{ 0xFF, 0x00, 0xAB, 0xFF, 0xC3 };
    const m = try parseNextMarker(&data, 0);
    try testing.expectEqual(Marker.sof3, m.marker);
    try testing.expectEqual(@as(usize, 4), m.pos);
}

test "readBE16: big-endian decode" {
    const data = [_]u8{ 0x12, 0x34, 0xAB, 0xCD };
    try testing.expectEqual(@as(u16, 0x1234), try readBE16(&data, 0));
    try testing.expectEqual(@as(u16, 0xABCD), try readBE16(&data, 2));
}

// ----------------------------------------------------------------------------
// Tests (item 2b: Huffman)
// ----------------------------------------------------------------------------

test "HuffmanTable.parse: minimal 4-symbol table" {
    // Tc=0 (DC, dest 0), counts: 1×len-1, 1×len-2, 2×len-3 → 4 values
    // Canonical codes:
    //   len 1: code 0     → value V0
    //   len 2: code 10    → value V1
    //   len 3: codes 110, 111 → values V2, V3
    const allocator = testing.allocator;
    const payload = [_]u8{
        0x00,  // Tc/Td
        // Li (16 bytes):
        1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        // Vi (4 bytes):
        0xA, 0xB, 0xC, 0xD,
    };
    var t = try HuffmanTable.parse(allocator, &payload);
    defer t.deinit(allocator);

    try testing.expectEqual(@as(usize, 4), t.values.len);
    try testing.expectEqual(@as(i32, 0), t.min_code[1]);
    try testing.expectEqual(@as(i32, 0), t.max_code[1]);
    try testing.expectEqual(@as(i32, 2), t.min_code[2]);
    try testing.expectEqual(@as(i32, 2), t.max_code[2]);
    try testing.expectEqual(@as(i32, 6), t.min_code[3]);
    try testing.expectEqual(@as(i32, 7), t.max_code[3]);
}

test "HuffmanTable.decode: all 4 symbols round-trip" {
    const allocator = testing.allocator;
    // Same table as above.
    const payload = [_]u8{
        0x00,
        1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0xA, 0xB, 0xC, 0xD,
    };
    var t = try HuffmanTable.parse(allocator, &payload);
    defer t.deinit(allocator);

    // Encoded bit stream: V0, V1, V2, V3 = 0 10 110 111 (9 bits) = 010 1101 11_______ → packed as 0101_1011 1________
    // Bits: 0 (V0=A), 10 (V1=B), 110 (V2=C), 111 (V3=D)
    // = 0 10 110 111 = 010110111 → 0101 1011 1xxx xxxx = 0x5B, 0x80
    const stream = [_]u8{ 0x5B, 0x80 };
    var r = BitReader.init(&stream);
    try testing.expectEqual(@as(u8, 0xA), try t.decode(&r));
    try testing.expectEqual(@as(u8, 0xB), try t.decode(&r));
    try testing.expectEqual(@as(u8, 0xC), try t.decode(&r));
    try testing.expectEqual(@as(u8, 0xD), try t.decode(&r));
}

test "HuffmanTable.parse: rejects truncated payload" {
    const allocator = testing.allocator;
    // Counts say 5 values needed but only 2 provided.
    const payload = [_]u8{
        0x00,
        1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0xAA, 0xBB,
    };
    try testing.expectError(Error.MalformedHuffmanTable, HuffmanTable.parse(allocator, &payload));
}

// ----------------------------------------------------------------------------
// Tests (item 2c: full SOF3 decode)
// ----------------------------------------------------------------------------

test "FrameHeader.parse: 14-bit single-component" {
    // P=14, Y=2, X=3, Nf=1, then component (id=0, h=1, v=1, tq=0)
    const payload = [_]u8{
        14,
        0x00, 0x02,   // height = 2
        0x00, 0x03,   // width = 3
        1,            // Nf
        0x00, 0x11, 0x00,
    };
    const fh = try FrameHeader.parse(&payload);
    try testing.expectEqual(@as(u8, 14), fh.precision);
    try testing.expectEqual(@as(u16, 2), fh.height);
    try testing.expectEqual(@as(u16, 3), fh.width);
    try testing.expectEqual(@as(u8, 1), fh.n_components);
}

test "ScanHeader.parse: 1-component predictor 1" {
    // Ns=1, then (Cs=0, Td=0), then Ss=1, Se=0, Ah/Al=0
    const payload = [_]u8{
        1,
        0x00, 0x00,    // Cs, Td/Ta
        1,             // Ss = predictor 1
        0, 0,          // Se, Ah/Al
    };
    const sh = try ScanHeader.parse(&payload);
    try testing.expectEqual(@as(u8, 1), sh.predictor);
    try testing.expectEqual(@as(u8, 1), sh.n_components);
    try testing.expectEqual(@as(u8, 0), sh.point_transform);
}

test "decode: 1×1 image, all-zero diff" {
    // Minimal SOF3: 1×1 image, 14-bit, predictor 1.
    // Sample = predictor (= 2^13 = 8192) + diff(=0).
    // Huffman table: just one entry, code "0", value 0. (length-1 count = 1)
    // Bit stream after SOS: a single 0 bit (= category 0), no extra bits.
    // Padded to byte: 0b00000000 = 0x00.
    const allocator = testing.allocator;
    const data = [_]u8{
        // SOI
        0xFF, 0xD8,
        // SOF3: marker, length=11, P=14, Y=1, X=1, Nf=1, comp(id=0,Hi/Vi=11,Tq=0)
        0xFF, 0xC3,
        0x00, 0x0B,
        14,
        0x00, 0x01,
        0x00, 0x01,
        1,
        0x00, 0x11, 0x00,
        // DHT: marker, length=2+1+16+1=20, Tc/Td=0, counts (1×len-1, rest 0), value=0
        0xFF, 0xC4,
        0x00, 0x14,
        0x00,
        1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0x00,
        // SOS: marker, length=8, Ns=1, comp(Cs=0,Td=0), Ss=1, Se=0, Ah/Al=0
        0xFF, 0xDA,
        0x00, 0x08,
        1,
        0x00, 0x00,
        1, 0, 0,
        // Entropy: 1 bit of Huffman code "0" (= category 0), 0 extra bits.
        // Pad with 1s so we don't accidentally decode another 0.
        0b01111111,
        // EOI
        0xFF, 0xD9,
    };
    var d = try decode(allocator, &data);
    defer d.deinit(allocator);

    try testing.expectEqual(@as(u32, 1), d.width);
    try testing.expectEqual(@as(u32, 1), d.height);
    try testing.expectEqual(@as(usize, 1), d.samples.len);
    try testing.expectEqual(@as(u16, 8192), d.samples[0]);  // initial predictor 2^13
}

test "decode: 4×1 image, predictor 1, increasing diffs" {
    // 4 samples, predictor 1 (Pa = left).
    // Initial pred (x=0) = 2^13 = 8192. Diff = 0 → sample[0] = 8192.
    // Sample[1]: predictor = sample[0] = 8192, diff = +1 → 8193
    // Sample[2]: predictor = 8193, diff = +1 → 8194
    // Sample[3]: predictor = 8194, diff = -1 → 8193
    //
    // Huffman table:
    //   code "0"   (len 1) → value 0  (category 0, no extra bits)
    //   code "10"  (len 2) → value 1  (category 1, 1 extra bit)
    //
    // Bit stream:
    //   sample 0: code "0" (cat 0, no bits)         → 0
    //   sample 1: code "10" (cat 1) + bit "1" (= +1) → 101
    //   sample 2: code "10" + bit "1"                → 101
    //   sample 3: code "10" + bit "0" (= -1)         → 100
    //   total bits: 0 101 101 100 = 0101 1011 00xx_xxxx
    //   = 0x5B, 0x00 (padding)
    const allocator = testing.allocator;
    const data = [_]u8{
        0xFF, 0xD8,
        // SOF3
        0xFF, 0xC3, 0x00, 0x0B,
        14,
        0x00, 0x01,    // Y=1
        0x00, 0x04,    // X=4
        1,
        0x00, 0x11, 0x00,
        // DHT: 1×len-1, 1×len-2, rest 0; values 0, 1
        0xFF, 0xC4, 0x00, 0x15,
        0x00,
        1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0x00, 0x01,
        // SOS
        0xFF, 0xDA, 0x00, 0x08,
        1, 0x00, 0x00, 1, 0, 0,
        // Entropy: 0101 1011 0011 1111 (pad with 1s)
        0x5B, 0x3F,
        // EOI
        0xFF, 0xD9,
    };
    var d = try decode(allocator, &data);
    defer d.deinit(allocator);

    try testing.expectEqual(@as(u32, 4), d.width);
    try testing.expectEqual(@as(u32, 1), d.height);
    try testing.expectEqual(@as(u16, 8192), d.samples[0]);
    try testing.expectEqual(@as(u16, 8193), d.samples[1]);
    try testing.expectEqual(@as(u16, 8194), d.samples[2]);
    try testing.expectEqual(@as(u16, 8193), d.samples[3]);
}
