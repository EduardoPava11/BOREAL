-- ════════════════════════════════════════════════════════════════
-- Boreal.GifWire — the ISP's native output: GIF89a bytes.
--
-- Deterministic single-palette animated GIF (D1 default: one
-- GLOBAL color table; per-cycle LCTs are a later flag):
--
--   GIF89a · LSD (GCT, 256 colors) · GCT 768 bytes ·
--   NETSCAPE2.0 infinite loop · per frame [GCE(delay) ·
--   image descriptor · LZW data] · trailer 0x3B
--
-- LZW SCHEME (normative — fixed 9-bit, byte-exact everywhere):
--   minCodeSize = 8; codes are 9 bits, packed LSB-FIRST into
--   bytes; stream = CLEAR(256) ++ indices in groups of ≤254 with
--   CLEAR between groups ++ EOI(257).  The re-CLEAR keeps any
--   standard decoder's dictionary strictly below 512 entries, so
--   the code width NEVER grows — no compression, total
--   determinism, and every GIF decoder on earth reads it.
--   Data bytes are chunked into ≤255-byte sub-blocks, then a 0x00
--   terminator.
--
-- Length closed form (law W2): for n pixels,
--   codes  = 1 + n + (⌈n/254⌉ − 1) + 1
--   dataB  = ⌈9·codes / 8⌉
--   frameB = 1 + dataB + ⌈dataB/255⌉ + 1
-- ════════════════════════════════════════════════════════════════

module Boreal.GifWire where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Word (Word8)

-- ── Little helpers ─────────────────────────────────────────────

u16le :: Int -> [Word8]
u16le v = [fromIntegral (v .&. 0xFF), fromIntegral ((v `shiftR` 8) .&. 0xFF)]

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = take n xs : chunksOf n (drop n xs)

-- 9-bit codes → bytes, LSB-first (GIF bit order); final byte padded
-- with zero bits.
packCodes :: [Int] -> [Word8]
packCodes = go 0 0
  where
    go acc nbits (c : cs) = emit (acc .|. (c `shiftL` nbits)) (nbits + 9) cs
    go acc nbits []
      | nbits > 0 = [fromIntegral (acc .&. 0xFF)]
      | otherwise = []
    emit acc nbits cs
      | nbits >= 8 = fromIntegral (acc .&. 0xFF) : emit (acc `shiftR` 8) (nbits - 8) cs
      | otherwise  = go acc nbits cs

subBlocks :: [Word8] -> [Word8]
subBlocks bytes =
  concat [ fromIntegral (length b) : b | b <- chunksOf 255 bytes ] ++ [0]

-- ── The LZW payload (fixed 9-bit, re-CLEAR every 254) ──────────

clearCode, eoiCode :: Int
clearCode = 256
eoiCode   = 257

lzwCodes :: [Word8] -> [Int]
lzwCodes indices =
  clearCode
    : concat [ map fromIntegral g ++ [clearCode] | g <- init groups ]
    ++ map fromIntegral (last groups)
    ++ [eoiCode]
  where groups = if null indices then [[]] else chunksOf 254 indices

frameData :: [Word8] -> [Word8]
frameData indices = 8 : subBlocks (packCodes (lzwCodes indices))

-- W2's closed form.
frameDataLen :: Int -> Int
frameDataLen n = 1 + dataB + (dataB + 254) `div` 255 + 1
  where codes = 1 + n + (nChunks - 1) + 1
        nChunks = max 1 ((n + 253) `div` 254)
        dataB = (9 * codes + 7) `div` 8

-- ── Whole-file assembly ────────────────────────────────────────

-- side² frames of palette indices + a 768-byte GCT → GIF89a bytes.
encodeGif :: Int -> Int -> [Word8] -> [[Word8]] -> [Word8]
encodeGif side delayCs gct frames =
  header ++ lsd ++ gct ++ netscape
    ++ concatMap frame frames
    ++ [0x3B]
  where
    header = map (fromIntegral . fromEnum) "GIF89a"
    lsd = u16le side ++ u16le side ++ [0xF7, 0x00, 0x00]
    netscape =
      [0x21, 0xFF, 0x0B]
        ++ map (fromIntegral . fromEnum) "NETSCAPE2.0"
        ++ [0x03, 0x01] ++ u16le 0 ++ [0x00]
    gce =
      [0x21, 0xF9, 0x04, 0x00] ++ u16le delayCs ++ [0x00, 0x00]
    descriptor =
      0x2C : u16le 0 ++ u16le 0 ++ u16le side ++ u16le side ++ [0x00]
    frame indices = gce ++ descriptor ++ frameData indices

-- ── Decoder (the round-trip oracle for law W3) ─────────────────

-- Unpack LSB-first 9-bit codes from bytes.
unpackCodes :: [Word8] -> [Int]
unpackCodes = go 0 0
  where
    go acc nbits (b : bs) = emit (acc .|. (fromIntegral b `shiftL` nbits)) (nbits + 8) bs
    go _ _ [] = []
    emit acc nbits bs
      | nbits >= 9 = (acc .&. 0x1FF) : emit (acc `shiftR` 9) (nbits - 9) bs
      | otherwise  = go acc nbits bs

-- General fixed-9 LZW decode (dictionary-building, so it is a true
-- inverse for any conforming stream, not just our literal-only one).
lzwDecode :: [Int] -> [Word8]
lzwDecode = start
  where
    start (c : cs) | c == clearCode = run initDict Nothing cs
    start _ = []
    initDict = [ [fromIntegral i] | i <- [0 .. 255 :: Int] ] ++ [[], []]
    run _ _ [] = []
    run dict prev (c : cs)
      | c == eoiCode   = []
      | c == clearCode = run initDict Nothing cs
      | otherwise =
          let entry
                | c < length dict = dict !! c
                | otherwise = case prev of
                    Just p  -> p ++ [head p]
                    Nothing -> []
              dict' = case prev of
                Just p  -> dict ++ [p ++ [head entry]]
                Nothing -> dict
          in entry ++ run dict' (Just entry) cs

-- Parse a GIF produced by encodeGif: (delayCs, gct, frames).
decodeGif :: [Word8] -> (Int, [Word8], [[Word8]])
decodeGif bytes0 =
  let afterHeader = drop 6 bytes0
      lsdBytes    = take 7 afterHeader
      gct         = take 768 (drop 7 afterHeader)
      body        = drop (7 + 768) afterHeader
      _           = lsdBytes
  in walk body 0 []
  where
    walk (0x3B : _) delay frames = (delay, take 768 (drop 13 bytes0), reverse frames)
    walk (0x21 : 0xFF : rest) delay frames =
      walk (skipSub (drop (fromIntegral (head rest)) (drop 1 rest))) delay frames
    walk (0x21 : 0xF9 : _n : _p : d0 : d1 : _t : 0x00 : rest) _ frames =
      walk rest (fromIntegral d0 + 256 * fromIntegral d1) frames
    walk (0x2C : rest) delay frames =
      let rest'   = drop 9 rest          -- descriptor body
          rest''  = drop 1 rest'         -- minCodeSize
          (dat, after) = takeSub rest''
      in walk after delay (lzwDecode (unpackCodes dat) : frames)
    walk (_ : rest) delay frames = walk rest delay frames
    walk [] delay frames = (delay, [], reverse frames)
    takeSub (n : rest)
      | n == 0    = ([], rest)
      | otherwise = let (blk, r2) = splitAt (fromIntegral n) rest
                        (more, after) = takeSub r2
                    in (blk ++ more, after)
    takeSub [] = ([], [])
    skipSub (n : rest)
      | n == 0    = rest
      | otherwise = skipSub (drop (fromIntegral n) rest)
    skipSub [] = []
