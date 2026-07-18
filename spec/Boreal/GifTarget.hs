-- ════════════════════════════════════════════════════════════════
-- Boreal.GifTarget — the ISP's target: GIF frames from the seed.
--
-- The custom ISP does not target TIFF or display buffers; it
-- targets GIF89a structure: a 256-COLOR PALETTE seeded by the
-- 16×16 latent (grid position ≡ palette color, OneSix A2) and an
-- INDEX MAP per rung image (16², 32², 64², 128², 256²).
--
--   palette  = the seed 16×16 latent, verbatim (Q16 OKLab triples)
--   indexing = integer argmin over squared Q16 distance, ties →
--              LOWEST index (the SixFour Q16 convention; i64-safe:
--              Δ ≤ 2^17 ⇒ 3·Δ² < 2^36)
--   display  = OKLab → linear sRGB via Ottosson's published
--              inverse literals (cube = y·y·y, pinned order — no
--              cbrt needed on the way DOWN), then an sRGB u8
--              encode TABLE (4096 entries, index = ⌊c·4095 + ½⌋
--              clamped).  The table is NORMATIVE DATA (like an
--              ICC blob): whatever this module computes is the
--              artifact; ports embed the emitted table and never
--              call pow.
-- ════════════════════════════════════════════════════════════════

module Boreal.GifTarget where

import Data.Word (Word8)
import Boreal.ColorPath (Lab (..))

-- ── Q16 palette + integer indexing ─────────────────────────────

type Q16Lab = (Int, Int, Int)

dist2 :: Q16Lab -> Q16Lab -> Int
dist2 (l1, a1, b1) (l2, a2, b2) = sq (l1 - l2) + sq (a1 - a2) + sq (b1 - b2)
  where sq d = d * d

-- Argmin over the palette; STRICTLY-LESS update ⇒ ties keep the
-- lowest index (normative).
nearestIndex :: [Q16Lab] -> Q16Lab -> Int
nearestIndex pal p = go 0 maxBound 0 pal
  where
    go _ _ best [] = best
    go j bestD best (c : cs)
      | d < bestD = go (j + 1) d j cs
      | otherwise = go (j + 1) bestD best cs
      where d = dist2 c p

indexMap :: [Q16Lab] -> [Q16Lab] -> [Int]
indexMap pal = map (nearestIndex pal)

-- ── OKLab → linear sRGB (Ottosson's inverse; pinned order) ─────

linearSrgbFromOklab :: Lab -> (Double, Double, Double)
linearSrgbFromOklab (Lab bigL a b) =
  let l' = bigL + 0.3963377774 * a + 0.2158037573 * b
      m' = bigL - 0.1055613458 * a - 0.0638541728 * b
      s' = bigL - 0.0894841775 * a - 1.2914855480 * b
      l = l' * l' * l'
      m = m' * m' * m'
      s = s' * s' * s'
  in ( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
     , -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
     , -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s )

-- ── The normative sRGB encode table ────────────────────────────

srgbTable :: [Word8]
srgbTable = [ enc (fromIntegral i / 4095) | i <- [0 .. 4095 :: Int] ]
  where
    enc c = fromIntegral (max 0 (min 255 (floor (255 * s + 0.5) :: Int)))
      where s | c <= 0.0031308 = 12.92 * c
              | otherwise      = 1.055 * c ** (1 / 2.4) - 0.055

srgb8FromLinear :: Double -> Word8
srgb8FromLinear c = srgbTable !! idx
  where idx = max 0 (min 4095 (floor (c * 4095 + 0.5)))

-- Q16 OKLab triple → display sRGB bytes (dequantize, inverse
-- transform, table encode).  Out-of-gamut clamps at the table edge.
srgb8FromOklabQ16 :: Q16Lab -> (Word8, Word8, Word8)
srgb8FromOklabQ16 (ql, qa, qb) =
  let lab = Lab (fromIntegral ql / 65536)
                (fromIntegral qa / 65536)
                (fromIntegral qb / 65536)
      (r, g, b) = linearSrgbFromOklab lab
  in (srgb8FromLinear r, srgb8FromLinear g, srgb8FromLinear b)
