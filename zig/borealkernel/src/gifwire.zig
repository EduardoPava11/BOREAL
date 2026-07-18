//! gifwire.zig — the ISP's native output: GIF89a bytes (Phase 4).
//! Hand-written, zero dependencies — BOREAL owns this encoder end to end.
//! Ported from `spec/Boreal/GifWire.hs`; gated byte-exact by
//! `fixtures/gifwire_golden.json` (tests/gifwire_fixtures.zig).
//!
//! PORT CONVENTIONS (normative — from the spec):
//!   · LZW: minCodeSize 8; FIXED 9-bit codes packed LSB-first; stream =
//!     CLEAR(256) ++ index groups of ≤254 with CLEAR between ++ EOI(257);
//!     the re-CLEAR keeps every decoder's dictionary < 512 so the code
//!     width NEVER grows — no compression, total determinism, and any
//!     standard GIF decoder reads it.  Sub-blocks ≤255 bytes + 0x00.
//!   · File: GIF89a · LSD 0xF7 (GCT 256) · GCT 768 · NETSCAPE2.0 loop 0 ·
//!     per frame GCE(delay) + full-canvas descriptor + LZW · 0x3B.
//!   · Length closed form: codes = 1 + n + (⌈n/254⌉−1) + 1;
//!     dataB = ⌈9·codes/8⌉; frameB = 1 + dataB + ⌈dataB/255⌉ + 1.

const std = @import("std");

const CLEAR: u32 = 256;
const EOI: u32 = 257;

pub fn frameDataLen(n: usize) usize {
    const chunks = if (n == 0) 1 else (n + 253) / 254;
    const codes = 1 + n + (chunks - 1) + 1;
    const data_b = (9 * codes + 7) / 8;
    return 1 + data_b + (data_b + 254) / 255 + 1;
}

/// Exact whole-file size for n_frames frames of side² pixels.
pub fn encodedLen(side: u32, n_frames: u32) usize {
    const n = @as(usize, side) * side;
    return 6 + 7 + 768 + 19 + @as(usize, n_frames) * (8 + 10 + frameDataLen(n)) + 1;
}

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn byte(w: *Writer, b: u8) void {
        w.buf[w.pos] = b;
        w.pos += 1;
    }
    fn bytes(w: *Writer, bs: []const u8) void {
        @memcpy(w.buf[w.pos .. w.pos + bs.len], bs);
        w.pos += bs.len;
    }
    fn u16le(w: *Writer, v: u32) void {
        w.byte(@intCast(v & 0xFF));
        w.byte(@intCast((v >> 8) & 0xFF));
    }
};

/// Bit packer: 9-bit codes, LSB-first, streamed straight into ≤255-byte
/// sub-blocks (the block's length byte is back-patched when it fills).
const BlockPacker = struct {
    w: *Writer,
    acc: u32 = 0,
    nbits: u5 = 0,
    len_at: usize = 0,   // position of the current block's length byte
    fill: usize = 0,     // bytes in the current block

    fn openBlock(p: *BlockPacker) void {
        p.len_at = p.w.pos;
        p.w.byte(0);     // patched later
        p.fill = 0;
    }
    fn putByte(p: *BlockPacker, b: u8) void {
        if (p.fill == 255) {
            p.w.buf[p.len_at] = 255;
            p.openBlock();
        }
        p.w.byte(b);
        p.fill += 1;
    }
    fn code(p: *BlockPacker, c: u32) void {
        p.acc |= c << p.nbits;
        p.nbits += 9;
        while (p.nbits >= 8) {
            p.putByte(@intCast(p.acc & 0xFF));
            p.acc >>= 8;
            p.nbits -= 8;
        }
    }
    fn finish(p: *BlockPacker) void {
        if (p.nbits > 0) p.putByte(@intCast(p.acc & 0xFF));
        p.w.buf[p.len_at] = @intCast(p.fill);
        p.w.byte(0);     // sub-block terminator
    }
};

fn writeFrameData(w: *Writer, indices: []const u8) void {
    w.byte(8); // minCodeSize
    var p = BlockPacker{ .w = w };
    p.openBlock();
    p.code(CLEAR);
    var emitted: usize = 0;
    for (indices) |ix| {
        if (emitted == 254) {
            p.code(CLEAR);
            emitted = 0;
        }
        p.code(ix);
        emitted += 1;
    }
    p.code(EOI);
    p.finish();
}

/// Encode a whole animated GIF. `frames` is n_frames × side² indices, flat.
/// `gct` is 768 bytes. Returns bytes written (== encodedLen) or 0 on a
/// too-small buffer.
pub fn encode(
    frames: []const u8,
    n_frames: u32,
    side: u32,
    gct: []const u8,
    delay_cs: u32,
    out: []u8,
) usize {
    const total = encodedLen(side, n_frames);
    if (out.len < total or gct.len < 768) return 0;
    const n = @as(usize, side) * side;
    if (frames.len < @as(usize, n_frames) * n) return 0;

    var w = Writer{ .buf = out };
    w.bytes("GIF89a");
    w.u16le(side);
    w.u16le(side);
    w.bytes(&.{ 0xF7, 0x00, 0x00 });
    w.bytes(gct[0..768]);
    w.bytes(&.{ 0x21, 0xFF, 0x0B });
    w.bytes("NETSCAPE2.0");
    w.bytes(&.{ 0x03, 0x01, 0x00, 0x00, 0x00 });

    var f: usize = 0;
    while (f < n_frames) : (f += 1) {
        w.bytes(&.{ 0x21, 0xF9, 0x04, 0x00 });
        w.u16le(delay_cs);
        w.bytes(&.{ 0x00, 0x00 });
        w.byte(0x2C);
        w.u16le(0);
        w.u16le(0);
        w.u16le(side);
        w.u16le(side);
        w.byte(0x00);
        writeFrameData(&w, frames[f * n .. (f + 1) * n]);
    }
    w.byte(0x3B);
    std.debug.assert(w.pos == total);
    return w.pos;
}

// ── Tests (pure; cross-language fixture in tests/gifwire_fixtures.zig) ─────

const testing = std.testing;

test "closed-form length matches the writer, across the re-CLEAR boundary" {
    var frames: [2 * 256]u8 = undefined;
    for (&frames, 0..) |*v, i| v.* = @intCast(i % 256);
    var gct: [768]u8 = undefined;
    for (&gct, 0..) |*v, i| v.* = @intCast(i % 251);
    var out: [4096]u8 = undefined;
    const n = encode(&frames, 2, 16, &gct, 20, &out);
    try testing.expectEqual(encodedLen(16, 2), n);
    try testing.expectEqualSlices(u8, "GIF89a", out[0..6]);
    try testing.expectEqual(@as(u8, 0x3B), out[n - 1]);
}
